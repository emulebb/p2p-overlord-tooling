from __future__ import annotations

import json
import time
from copy import deepcopy
from pathlib import Path
from typing import Any

from overlord_tooling.scenarios import write_json
from tests.e2e.lib.ed2k_private import utc_now
from tests.e2e.lib.kad_live import (
    MIN_BOUNDED_TRANSFER_TIMEOUT_SECONDS,
    run_live_kad_search_download_to_agent_scenario,
)
from tests.e2e.lib.live_search_terms import CANONICAL_LIVE_WIRE_STRESS_SEARCH_TERMS
from tests.e2e.lib.paths import WorkspacePaths


def run_live_wire_stress_search_download_scenario(
    workspace_paths: WorkspacePaths,
    pytestconfig,
    *,
    scenario_id: str,
    manifest: dict[str, Any],
    source_manifest: dict[str, Any] | None,
    artifact_scenario_id: str | None = None,
    run_slug: str | None = None,
    metadata: dict[str, Any] | None = None,
) -> None:
    stress_cfg = manifest.get("stress")
    if not isinstance(stress_cfg, dict):
        raise ValueError(f"{scenario_id}: missing stress object")
    source_template = deepcopy(source_manifest or manifest)
    terms = tuple(str(term) for term in stress_cfg.get("searchTerms") or CANONICAL_LIVE_WIRE_STRESS_SEARCH_TERMS)
    if terms != CANONICAL_LIVE_WIRE_STRESS_SEARCH_TERMS:
        raise ValueError(
            f"{scenario_id}: stress search terms must match CANONICAL_LIVE_WIRE_STRESS_SEARCH_TERMS"
        )

    transports = _selected_stress_transports(pytestconfig, stress_cfg)
    term_budget_seconds = int(stress_cfg.get("perTermBudgetSeconds") or 300)
    total_budget_seconds = int(stress_cfg.get("totalBudgetSeconds") or 2700)
    required_completed_downloads = int(stress_cfg.get("requiredCompletedDownloadCount") or 2)
    campaign_artifact_id = artifact_scenario_id or scenario_id
    campaign_run_slug = run_slug or "live-wire-stress"
    deadline = time.monotonic() + total_budget_seconds
    outcomes: list[dict[str, Any]] = []

    for term in terms:
        for transport in transports:
            if time.monotonic() >= deadline:
                outcomes.append(
                    {
                        "term": term,
                        "transportMode": transport,
                        "completed": False,
                        "terminalReason": "stress_budget_expired",
                    }
                )
                continue
            child_manifest = deepcopy(source_template)
            child_manifest.setdefault("search", {})
            child_manifest["search"]["query"] = term
            child_run_slug = f"{campaign_run_slug}-{term}-{transport}"
            child_metadata = {
                **(metadata or {}),
                "stressScenarioId": scenario_id,
                "stressSearchTerm": term,
                "stressTransportMode": transport,
            }
            try:
                summary_path = run_live_kad_search_download_to_agent_scenario(
                    workspace_paths,
                    pytestconfig,
                    scenario_id=scenario_id,
                    manifest=child_manifest,
                    transport_mode=transport,
                    artifact_scenario_id=campaign_artifact_id,
                    run_slug=child_run_slug,
                    metadata=child_metadata,
                    download_budget_seconds=min(
                        term_budget_seconds,
                        max(MIN_BOUNDED_TRANSFER_TIMEOUT_SECONDS, int(deadline - time.monotonic())),
                    ),
                )
                outcomes.append(_stress_outcome(term, transport, summary_path))
            except Exception as exc:
                summary_path = _latest_stress_summary_path(
                    workspace_paths,
                    campaign_artifact_id,
                    child_run_slug,
                    transport,
                )
                outcome = _stress_outcome(term, transport, summary_path)
                outcome["failedReason"] = str(exc)
                outcomes.append(outcome)

    completed_count = sum(1 for outcome in outcomes if outcome.get("completed") is True)
    aggregate_path = (
        workspace_paths.tmp_dir
        / "overlord-tooling"
        / "runs"
        / campaign_artifact_id
        / f"{campaign_run_slug}.stress-summary-{utc_now().replace(':', '').replace('-', '')}.json"
    )
    write_json(
        aggregate_path,
        {
            "schemaVersion": "live-wire-stress-summary/v1",
            "scenarioId": scenario_id,
            "artifactScenarioId": campaign_artifact_id,
            "searchTerms": list(terms),
            "transportModes": list(transports),
            "perTermBudgetSeconds": term_budget_seconds,
            "totalBudgetSeconds": total_budget_seconds,
            "requiredCompletedDownloadCount": required_completed_downloads,
            "completedDownloadCount": completed_count,
            "outcomes": outcomes,
            "finishedAtUtc": utc_now(),
        },
    )

    covered_terms = {str(outcome["term"]) for outcome in outcomes}
    missing_terms = [term for term in terms if term not in covered_terms]
    if missing_terms:
        raise AssertionError(f"live-wire stress did not produce evidence for terms {missing_terms}")
    if completed_count < required_completed_downloads:
        raise AssertionError(
            "live-wire stress completed too few downloads "
            f"completed={completed_count} required={required_completed_downloads} "
            f"summary={aggregate_path}"
        )


def _selected_stress_transports(pytestconfig, stress_cfg: dict[str, Any]) -> tuple[str, ...]:
    configured = tuple(
        _normalize_transport_mode(str(value))
        for value in stress_cfg.get("transportModes", ("plaintext", "obfuscated"))
    )
    selected = str(pytestconfig.getoption("--transport"))
    if selected == "both":
        return configured
    return tuple(value for value in configured if value == selected)


def _normalize_transport_mode(value: str) -> str:
    normalized = value.strip().lower()
    if normalized in {"plaintext", "plaintextonly"}:
        return "plaintext"
    if normalized in {"obfuscated", "obfuscatedonly"}:
        return "obfuscated"
    raise ValueError(f"unsupported stress transport mode {value!r}")


def _stress_outcome(term: str, transport: str, summary_path: Path | None) -> dict[str, Any]:
    outcome: dict[str, Any] = {
        "term": term,
        "transportMode": transport,
        "summaryPath": str(summary_path) if summary_path else None,
        "completed": False,
        "terminalReason": "summary_missing",
    }
    if summary_path is None or not summary_path.is_file():
        return outcome
    summary = json.loads(summary_path.read_text(encoding="utf-8"))
    attempted_candidates = summary.get("attemptedCandidates") or []
    terminal_reasons = [
        str(candidate.get("terminalReason"))
        for candidate in attempted_candidates
        if isinstance(candidate, dict) and candidate.get("terminalReason")
    ]
    outcome.update(
        {
            "completed": summary.get("completed") is True,
            "failedReason": summary.get("failedReason"),
            "searchJobId": summary.get("searchJobId"),
            "searchResultBatchCount": (summary.get("evidence") or {}).get("searchResultBatchCount"),
            "attemptedCandidateCount": len(attempted_candidates),
            "terminalReason": "completed"
            if summary.get("completed") is True
            else (terminal_reasons[-1] if terminal_reasons else summary.get("failedReason") or "unknown"),
            "agentEd2kDumpPresent": (summary.get("evidence") or {}).get("agentEd2kDumpPresent"),
            "agentUdpDumpPresent": (summary.get("evidence") or {}).get("agentUdpDumpPresent"),
        }
    )
    return outcome


def _latest_stress_summary_path(
    workspace_paths: WorkspacePaths,
    artifact_scenario_id: str,
    run_slug: str,
    transport: str,
) -> Path | None:
    scenario_root = workspace_paths.tmp_dir / "overlord-tooling" / "runs" / artifact_scenario_id
    if not scenario_root.is_dir():
        return None
    matches = list(scenario_root.glob(f"{run_slug}.{transport}-*/run-summary.json"))
    if not matches:
        return None
    return max(matches, key=lambda path: path.stat().st_mtime)
