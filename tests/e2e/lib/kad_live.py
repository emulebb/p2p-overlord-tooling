from __future__ import annotations

import json
import re
import time
from pathlib import Path
from typing import Any

from tests.e2e.lib import ed2k, http
from tests.e2e.lib.artifacts import copy_if_exists
from tests.e2e.lib.agent import AgentRuntime, AgentSession
from tests.e2e.lib.artifacts import latest_file
from tests.e2e.lib.ed2k_live import start_live_agent_session
from tests.e2e.lib.ed2k_private import copy_agent_artifacts, create_private_ed2k_run, run_identity, utc_now
from tests.e2e.lib.live_runtime import resolve_live_scenario_prerequisites
from overlord_tooling.scenarios import write_json
from tests.e2e.lib.paths import WorkspacePaths
from tests.e2e.lib.search_callbacks import (
    ed2k_candidate_source_count,
    is_unsafe_live_candidate_name,
    read_result_batches,
    select_ed2k_keyword_candidates,
    start_search_callback_collector,
    stop_search_callback_collector,
    wait_for_search_event,
)


DEFAULT_AGENT_CFG = {
    "controlPort": 13301,
    "kadPort": 41000,
    "ed2kPort": 41001,
}
SEARCH_TIMEOUT_SECONDS = 180
DOWNLOAD_TIMEOUT_SECONDS = 900
BOOTSTRAP_READY_TIMEOUT_SECONDS = 180
LIVE_SEARCH_DOWNLOAD_BUDGET_SECONDS = 2400
MIN_BOUNDED_TRANSFER_TIMEOUT_SECONDS = 10
SOURCE_ATTEMPT_RE = re.compile(
    r"ED2K source search attempt=(?P<attempt>\d+)/(?P<budget>\d+) "
    r"endpoint=(?P<endpoint>\S+) .* file_hash=(?P<file_hash>[0-9a-fA-F]{32})"
)
SOURCE_COMPLETED_RE = re.compile(
    r"native ED2K download (?P<phase>background|active) source acquisition "
    r"completed file_hash=(?P<file_hash>[0-9a-fA-F]{32}) "
    r"source_count=(?P<source_count>\d+) "
    r"aggregated_source_count=(?P<aggregated_source_count>\d+)"
)
KAD_PRODUCED_RE = re.compile(
    r"native ED2K download Kad source (?P<phase>fallback|supplement) produced "
    r"file_hash=(?P<file_hash>[0-9a-fA-F]{32}) source_count=(?P<source_count>\d+) "
    r"added_source_count=(?P<added_source_count>\d+) "
    r"aggregated_source_count=(?P<aggregated_source_count>\d+)"
)
KAD_EMPTY_RE = re.compile(
    r"native ED2K download Kad source (?P<phase>fallback|supplement) returned no sources "
    r"for file_hash=(?P<file_hash>[0-9a-fA-F]{32}) "
    r"aggregated_source_count=(?P<aggregated_source_count>\d+)"
)
FINAL_SOURCE_RE = re.compile(
    r"native ED2K download source acquisition completed "
    r"file_hash=(?P<file_hash>[0-9a-fA-F]{32}) "
    r"aggregated_source_count=(?P<aggregated_source_count>\d+) "
    r"background_search_enabled=(?P<background_search_enabled>true|false)"
)
SOURCE_FILTER_RE = re.compile(
    r"native ED2K download source filtering file_hash=(?P<file_hash>[0-9a-fA-F]{32}) "
    r"pre_filter_source_count=(?P<pre_filter_source_count>\d+) "
    r"callback_only_source_count=(?P<callback_only_source_count>\d+) "
    r"post_filter_source_count=(?P<post_filter_source_count>\d+)"
)
DOWNLOAD_SOURCE_FAILURE_RE = re.compile(
    r"native ED2K download (?P<phase>background|active server) source search "
    r"failed for file_hash=(?P<file_hash>[0-9a-fA-F]{32}): (?P<error>.+)"
)
DIRECT_DOWNLOAD_ATTEMPT_RE = re.compile(
    r"native ED2K download attempt file_hash=(?P<file_hash>[0-9a-fA-F]{32}) "
    r"peer=(?P<endpoint>\S+) .* obfuscated=(?P<obfuscated>true|false)"
)
DIRECT_DOWNLOAD_FAILURE_RE = re.compile(
    r"native ED2K download peer failed file_hash=(?P<file_hash>[0-9a-fA-F]{32}) "
    r"peer=(?P<endpoint>\S+): (?P<error>.+)"
)
SOURCE_REFRESH_RE = re.compile(
    r"native ED2K download source refresh completed file_hash=(?P<file_hash>[0-9a-fA-F]{32}) "
    r"requery_round=(?P<requery_round>\d+) "
    r"refreshed_source_count=(?P<refreshed_source_count>\d+) "
    r"added_source_count=(?P<added_source_count>\d+) "
    r"aggregated_source_count=(?P<aggregated_source_count>\d+) "
    r"new_direct_source_count=(?P<new_direct_source_count>\d+)"
)
SOURCE_REFRESH_SKIPPED_RE = re.compile(
    r"native ED2K download skipping source refresh file_hash=(?P<file_hash>[0-9a-fA-F]{32}) "
    r"reason=(?P<reason>\S+) .* known_new_direct_source_count=(?P<known_new_direct_source_count>\d+)"
)


def run_live_kad_search_download_to_agent_scenario(
    workspace_paths: WorkspacePaths,
    pytestconfig,
    *,
    scenario_id: str,
    manifest: dict[str, Any],
    transport_mode: str,
    artifact_scenario_id: str | None = None,
    run_slug: str | None = None,
    metadata: dict[str, Any] | None = None,
) -> None:
    prerequisites = resolve_live_scenario_prerequisites(workspace_paths, manifest)
    query = str(manifest["search"]["query"])
    run = create_private_ed2k_run(
        workspace_paths,
        scenario_id=scenario_id,
        transport_mode=transport_mode,
        file_name=f"{query.replace(' ', '-')}-{transport_mode}.candidate",
        file_size=1,
        file_pattern="live-kad-search-download",
        keep_sessions_running=bool(pytestconfig.getoption("--keep-sessions-running")),
        skip_build=bool(pytestconfig.getoption("--skip-runtime-build")),
        artifact_scenario_id=artifact_scenario_id,
        run_slug=run_slug,
        metadata=metadata,
    )

    agent = AgentRuntime(workspace_paths)
    callback_session = start_search_callback_collector(run.artifact_root / "callbacks")
    agent_session: AgentSession | None = None
    candidate: dict[str, object] | None = None
    transfer_manifest: dict | None = None
    agent_udp_dump_path: Path | None = None
    agent_dump_path: Path | None = None
    agent_server_dump_path: Path | None = None
    failed_reason: str | None = None
    search_job: dict[str, object] | None = None
    result_batches: list[dict[str, Any]] = []
    bootstrap_stats: dict[str, Any] | None = None
    attempted_candidates: list[dict[str, Any]] = []
    scenario_deadline = time.monotonic() + LIVE_SEARCH_DOWNLOAD_BUDGET_SECONDS

    try:
        if not run.skip_build:
            agent.build()

        agent_session = start_live_agent_session(
            agent,
            run,
            prerequisites,
            DEFAULT_AGENT_CFG,
            {"serverSelection": {"connectTimeoutMilliseconds": 5_000}},
            reset_runtime_root=True,
            disable_kad=False,
            probe_search_term=query,
        )
        bootstrap_stats = http.wait_json_until(
            agent_session.stats_url,
            predicate=_kad_bootstrap_ready,
            timeout_seconds=BOOTSTRAP_READY_TIMEOUT_SECONDS,
            poll_seconds=2,
        )

        search_job = agent.post_search_keyword(
            agent_session,
            query=query,
            callback_url=callback_session.base_url,
        )
        job_id = str(search_job["job_id"])
        wait_for_search_event(
            callback_session,
            job_id=job_id,
            status="started",
            timeout_seconds=SEARCH_TIMEOUT_SECONDS,
        )
        wait_for_search_event(
            callback_session,
            job_id=job_id,
            status="completed",
            timeout_seconds=SEARCH_TIMEOUT_SECONDS,
        )
        result_batches = [
            batch for batch in read_result_batches(callback_session) if str(batch.get("job_id")) == job_id
        ]
        candidate_policy = manifest["search"].get("candidatePolicy") or {}
        max_file_size = candidate_policy.get("maxFileSize")
        deny_hashes = {
            str(value).lower()
            for value in candidate_policy.get("denyHashes", [])
        }
        candidates = select_ed2k_keyword_candidates(
            result_batches,
            query=query,
            min_source_count=int(candidate_policy.get("minSourceCount") or 0),
            max_file_size=int(max_file_size) if max_file_size is not None else None,
            deny_hashes=deny_hashes,
            limit=int(candidate_policy.get("maxCandidates") or 1),
        )

        for candidate in candidates:
            transfer_timeout_seconds = bounded_transfer_timeout_seconds(
                scenario_deadline,
                max_seconds=DOWNLOAD_TIMEOUT_SECONDS,
            )
            agent.post_enrich_download(
                agent_session,
                file_hash=str(candidate["file_hash"]),
                file_name=str(candidate["file_name"]),
                file_size=int(candidate["file_size"]),
            )
            transfer_manifest = agent.wait_transfer_manifest(
                agent_session,
                file_hash=str(candidate["file_hash"]),
                timeout_seconds=transfer_timeout_seconds,
                stop_on_terminal_error=True,
            )
            unsafe_canonical_name = is_unsafe_live_candidate_name(
                transfer_manifest.get("canonical_name")
            )
            attempted_candidates.append(
                {
                    **_candidate_summary(candidate),
                    "completed": transfer_manifest.get("completed") is True,
                    "sourceCount": len(transfer_manifest.get("sources") or []),
                    "aichRootPresent": bool(transfer_manifest.get("aich_root")),
                    "unsafeCanonicalName": unsafe_canonical_name,
                    **candidate_terminal_evidence(
                        transfer_manifest,
                        agent_session.agent_log_path if agent_session is not None else None,
                        file_hash=str(candidate["file_hash"]),
                    ),
                }
            )
            if unsafe_canonical_name:
                continue
            if transfer_manifest.get("completed") is True:
                break
            bounded_transfer_timeout_seconds(
                scenario_deadline,
                max_seconds=DOWNLOAD_TIMEOUT_SECONDS,
            )
        else:
            raise AssertionError(
                "no live candidate completed "
                f"attempts={len(attempted_candidates)} "
                f"last_file_hash={candidate['file_hash'] if candidate else None} "
                f"last_sources={len(transfer_manifest.get('sources') or []) if transfer_manifest else 0} "
                f"last_aich_root={transfer_manifest.get('aich_root') if transfer_manifest else None!r}"
            )

        assert transfer_manifest.get("aich_root")
        assert transfer_manifest.get("sources")
        assert not is_unsafe_live_candidate_name(transfer_manifest.get("canonical_name"))

        agent_dump_path = agent.latest_ed2k_dump(agent_session)
        agent_server_dump_path = latest_file(agent_session.log_root, "agent-ed2k-server-dump-*.jsonl")
        assert agent_dump_path is not None
        agent_udp_dump_path = latest_file(agent_session.log_root, "agent-udp-dump-*.jsonl")
        assert agent_udp_dump_path is not None
        assert _dump_has_state_id(agent_udp_dump_path, direction="send", state_id="kad.send.kademlia2_search_key_req")
        assert _dump_has_state_id(agent_udp_dump_path, direction="recv", state_id="kad.recv.kademlia2_search_res")
        assert ed2k.dump_has_opcode(agent_dump_path, direction="send", opcode_names=("OP_HELLO",))
        assert ed2k.dump_has_opcode(agent_dump_path, direction="recv", opcode_names=("OP_HELLOANSWER",))
        assert ed2k.dump_has_opcode(agent_dump_path, direction="send", opcode_names=("OP_STARTUPLOADREQ",))
        assert ed2k.dump_has_opcode(
            agent_dump_path,
            direction="recv",
            opcode_names=ed2k.PART_PAYLOAD_OPCODE_NAMES,
        )
        assert transport_mode in ed2k.dump_transport_modes(agent_dump_path)

        agent.copy_transfer(
            agent_session,
            file_hash=str(candidate["file_hash"]),
            destination_root=run.agent_stage1_artifacts,
        )
        copy_agent_artifacts(agent_session, agent_dump_path, run.agent_stage1_artifacts)

        write_json(
            run.run_summary_path,
            {
                "schemaVersion": "run-summary/v1",
                **run_identity(run),
                "completed": True,
                "query": query,
                "searchJobId": job_id,
                "transportMode": run.transport_mode,
                "candidate": {
                    "fileHash": candidate["file_hash"],
                    "fileName": candidate["file_name"],
                    "fileSize": candidate["file_size"],
                    "advertisedSourceCount": ed2k_candidate_source_count(candidate),
                },
                "attemptedCandidates": attempted_candidates,
                "transferManifest": transfer_manifest,
                "selectedServerCount": len(prerequisites.server_entries),
                "bootstrapStats": {
                    "peersConnected": int(
                        bootstrap_stats.get("peers_connected") or 0
                    ),
                },
                "evidence": {
                    "bootstrapStatsObserved": True,
                    "searchStarted": True,
                    "searchCompleted": True,
                    "searchResultBatchCount": len(result_batches),
                    "kadKeywordSearchObserved": True,
                    "transferCompleted": True,
                    "sourceAcquisition": source_acquisition_evidence(
                        agent_session.agent_log_path,
                        server_dump_path=agent_server_dump_path,
                        file_hash=str(candidate["file_hash"]),
                    ),
                    "transportModes": ed2k.dump_transport_modes(agent_dump_path),
                    "agentEd2kDumpPresent": agent_dump_path is not None,
                    "agentEd2kServerDumpPresent": agent_server_dump_path is not None,
                    "agentUdpDumpPresent": agent_udp_dump_path is not None,
                },
                "finishedAtUtc": utc_now(),
            },
        )
    except Exception as exc:
        failed_reason = str(exc)
        raise
    finally:
        if not run.keep_sessions_running and agent_session is not None:
            agent.stop(agent_session)
        stop_search_callback_collector(callback_session)
        if agent_session is not None and agent_dump_path is None:
            agent_dump_path = agent.latest_ed2k_dump(agent_session)
        if agent_session is not None and agent_server_dump_path is None:
            agent_server_dump_path = latest_file(
                agent_session.log_root,
                "agent-ed2k-server-dump-*.jsonl",
            )
        if agent_session is not None and agent_udp_dump_path is None:
            agent_udp_dump_path = latest_file(agent_session.log_root, "agent-udp-dump-*.jsonl")
        if agent_session is not None:
            copy_agent_artifacts(agent_session, agent_dump_path, run.agent_stage1_artifacts)
            copy_if_exists(agent_server_dump_path, run.agent_stage1_artifacts)
        if not run.run_summary_path.exists():
            write_json(
                run.run_summary_path,
                {
                    "schemaVersion": "run-summary/v1",
                    **run_identity(run),
                    "completed": False,
                    "transportMode": run.transport_mode,
                    "query": query,
                    "searchJobId": search_job["job_id"] if search_job else None,
                    "candidate": _candidate_summary(candidate),
                    "attemptedCandidates": attempted_candidates,
                    "transferManifest": transfer_manifest,
                    "failedReason": failed_reason,
                    "selectedServerCount": len(prerequisites.server_entries),
                    "bootstrapStats": _bootstrap_summary(bootstrap_stats),
                    "evidence": {
                        "bootstrapStatsObserved": bootstrap_stats is not None,
                        "searchStarted": search_job is not None,
                        "searchCompleted": bool(result_batches),
                        "searchResultBatchCount": len(result_batches),
                        "candidateSelected": candidate is not None,
                        "transferManifestCaptured": transfer_manifest is not None,
                        "sourceAcquisition": source_acquisition_evidence(
                            agent_session.agent_log_path if agent_session is not None else None,
                            server_dump_path=agent_server_dump_path,
                            file_hash=str(candidate["file_hash"]) if candidate else None,
                        ),
                        "agentEd2kDumpPresent": agent_dump_path is not None,
                        "agentEd2kServerDumpPresent": agent_server_dump_path is not None,
                        "agentUdpDumpPresent": agent_udp_dump_path is not None,
                    },
                    "finishedAtUtc": utc_now(),
                },
            )


def _dump_has_state_id(path: Path, *, direction: str, state_id: str) -> bool:
    return any(
        record.get("direction") == direction and record.get("state_id") == state_id
        for record in ed2k.dump_records(path)
    )


def _kad_bootstrap_ready(response: dict[str, Any]) -> bool:
    return bool(response.get("kad_bootstrapped"))


def bounded_transfer_timeout_seconds(
    deadline_monotonic: float,
    *,
    max_seconds: int,
    now_monotonic: float | None = None,
) -> int:
    now = time.monotonic() if now_monotonic is None else now_monotonic
    remaining = int(deadline_monotonic - now)
    if remaining < MIN_BOUNDED_TRANSFER_TIMEOUT_SECONDS:
        raise TimeoutError(
            "live Kad search/download scenario budget expired "
            f"remaining_seconds={remaining} minimum_seconds={MIN_BOUNDED_TRANSFER_TIMEOUT_SECONDS}"
        )
    return min(max_seconds, remaining)


def source_acquisition_evidence(
    path: Path | None,
    *,
    server_dump_path: Path | None = None,
    file_hash: str | None,
) -> dict[str, Any]:
    target_hash = file_hash.lower() if file_hash else None
    evidence: dict[str, Any] = {
        "agentLogPresent": path is not None and path.is_file(),
        "agentEd2kServerDumpPresent": server_dump_path is not None and server_dump_path.is_file(),
        "lowIdWarningObserved": False,
        "serverConnectionCount": 0,
        "sourceSearchAttemptCount": 0,
        "sourceSearchAttemptBudget": 0,
        "sourceSearchEndpoints": [],
        "backgroundSourceSearchObserved": False,
        "backgroundSourceCount": None,
        "activeSourceSearchObserved": False,
        "activeSourceCount": None,
        "kadSourceFallbackObserved": False,
        "kadSourceSupplementObserved": False,
        "kadSourceCount": None,
        "finalAggregatedSourceCount": None,
        "backgroundSearchEnabled": None,
        "sourceFilteringObserved": False,
        "callbackOnlySourceCount": None,
        "directDialableSourceCount": None,
        "sourceSearchFailureCount": 0,
        "sourceSearchFailures": [],
        "serverGetSourcesRequestCount": 0,
        "serverFoundSourcesResponseCount": 0,
        "serverSourceSearchRoles": [],
        "serverSourceSearchTransports": [],
        "directDownloadAttemptCount": 0,
        "directDownloadAttemptedEndpointCount": 0,
        "directDownloadEndpoints": [],
        "directDownloadFailureCount": 0,
        "directDownloadFailureReasons": [],
        "sourceRefreshCount": 0,
        "sourceRefreshNewDirectEndpointCount": 0,
        "sourceRefreshSkipped": False,
        "sourceRefreshSkippedReason": None,
    }
    if path is not None and path.is_file():
        _merge_agent_log_source_evidence(evidence, path, target_hash)
    if server_dump_path is not None and server_dump_path.is_file():
        _merge_server_dump_source_evidence(evidence, server_dump_path, target_hash)
    return evidence


def _merge_agent_log_source_evidence(
    evidence: dict[str, Any],
    path: Path,
    target_hash: str | None,
) -> None:
    endpoints: list[str] = []
    direct_endpoints: list[str] = []
    failures: list[str] = []
    direct_failures: list[str] = []
    for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        if "WARNING : You have a lowid" in line or "lowid" in line.lower():
            evidence["lowIdWarningObserved"] = True
        if "connected to ED2K server " in line:
            evidence["serverConnectionCount"] = int(evidence["serverConnectionCount"]) + 1

        source_attempt = SOURCE_ATTEMPT_RE.search(line)
        if source_attempt and _matches_file_hash(source_attempt, target_hash):
            endpoint = source_attempt.group("endpoint")
            evidence["sourceSearchAttemptCount"] = int(evidence["sourceSearchAttemptCount"]) + 1
            evidence["sourceSearchAttemptBudget"] = max(
                int(evidence["sourceSearchAttemptBudget"]),
                int(source_attempt.group("budget")),
            )
            if endpoint not in endpoints:
                endpoints.append(endpoint)

        completed = SOURCE_COMPLETED_RE.search(line)
        if completed and _matches_file_hash(completed, target_hash):
            phase = completed.group("phase")
            evidence[f"{phase}SourceSearchObserved"] = True
            evidence[f"{phase}SourceCount"] = int(completed.group("source_count"))

        kad_produced = KAD_PRODUCED_RE.search(line)
        if kad_produced and _matches_file_hash(kad_produced, target_hash):
            _record_kad_source_evidence(evidence, kad_produced)

        kad_empty = KAD_EMPTY_RE.search(line)
        if kad_empty and _matches_file_hash(kad_empty, target_hash):
            _record_kad_source_evidence(evidence, kad_empty)
            evidence["kadSourceCount"] = 0

        final = FINAL_SOURCE_RE.search(line)
        if final and _matches_file_hash(final, target_hash):
            evidence["finalAggregatedSourceCount"] = int(final.group("aggregated_source_count"))
            evidence["backgroundSearchEnabled"] = final.group("background_search_enabled") == "true"

        source_filter = SOURCE_FILTER_RE.search(line)
        if source_filter and _matches_file_hash(source_filter, target_hash):
            evidence["sourceFilteringObserved"] = True
            evidence["callbackOnlySourceCount"] = int(source_filter.group("callback_only_source_count"))
            evidence["directDialableSourceCount"] = int(source_filter.group("post_filter_source_count"))

        download_failure = DOWNLOAD_SOURCE_FAILURE_RE.search(line)
        if download_failure and _matches_file_hash(download_failure, target_hash):
            evidence["sourceSearchFailureCount"] = int(evidence["sourceSearchFailureCount"]) + 1
            if len(failures) < 5:
                failures.append(
                    f"{download_failure.group('phase')}: {download_failure.group('error')}"
                )

        direct_attempt = DIRECT_DOWNLOAD_ATTEMPT_RE.search(line)
        if direct_attempt and _matches_file_hash(direct_attempt, target_hash):
            endpoint = direct_attempt.group("endpoint")
            evidence["directDownloadAttemptCount"] = int(evidence["directDownloadAttemptCount"]) + 1
            if endpoint not in direct_endpoints:
                direct_endpoints.append(endpoint)

        direct_failure = DIRECT_DOWNLOAD_FAILURE_RE.search(line)
        if direct_failure and _matches_file_hash(direct_failure, target_hash):
            evidence["directDownloadFailureCount"] = int(evidence["directDownloadFailureCount"]) + 1
            if len(direct_failures) < 5:
                direct_failures.append(direct_failure.group("error"))

        source_refresh = SOURCE_REFRESH_RE.search(line)
        if source_refresh and _matches_file_hash(source_refresh, target_hash):
            evidence["sourceRefreshCount"] = int(evidence["sourceRefreshCount"]) + 1
            evidence["sourceRefreshNewDirectEndpointCount"] = (
                int(evidence["sourceRefreshNewDirectEndpointCount"])
                + int(source_refresh.group("new_direct_source_count"))
            )

        source_refresh_skipped = SOURCE_REFRESH_SKIPPED_RE.search(line)
        if source_refresh_skipped and _matches_file_hash(source_refresh_skipped, target_hash):
            evidence["sourceRefreshSkipped"] = True
            evidence["sourceRefreshSkippedReason"] = source_refresh_skipped.group("reason")
            evidence["sourceRefreshNewDirectEndpointCount"] = (
                int(evidence["sourceRefreshNewDirectEndpointCount"])
                + int(source_refresh_skipped.group("known_new_direct_source_count"))
            )

    evidence["sourceSearchEndpoints"] = endpoints
    evidence["sourceSearchFailures"] = failures
    evidence["directDownloadEndpoints"] = direct_endpoints
    evidence["directDownloadAttemptedEndpointCount"] = len(direct_endpoints)
    evidence["directDownloadFailureReasons"] = direct_failures


def candidate_terminal_evidence(
    transfer_manifest: dict[str, Any] | None,
    agent_log_path: Path | None,
    *,
    file_hash: str,
) -> dict[str, Any]:
    evidence = source_acquisition_evidence(agent_log_path, file_hash=file_hash)
    return {
        "terminalReason": classify_candidate_terminal_reason(transfer_manifest, evidence),
        "attemptedDirectEndpointCount": evidence["directDownloadAttemptedEndpointCount"],
        "refreshedNewDirectEndpointCount": evidence["sourceRefreshNewDirectEndpointCount"],
    }


def classify_candidate_terminal_reason(
    transfer_manifest: dict[str, Any] | None,
    source_evidence: dict[str, Any],
) -> str:
    if transfer_manifest and transfer_manifest.get("completed") is True:
        return "completed"
    if _transfer_manifest_has_progress(transfer_manifest):
        return "in_progress"
    if (
        int(source_evidence.get("directDownloadAttemptedEndpointCount") or 0) != 0
        and (
            int(source_evidence.get("sourceRefreshCount") or 0) != 0
            or source_evidence.get("sourceRefreshSkipped") is True
        )
        and int(source_evidence.get("sourceRefreshNewDirectEndpointCount") or 0) == 0
    ):
        return "no_progress_repeated_endpoints"
    direct_failures = [str(value).lower() for value in source_evidence.get("directDownloadFailureReasons") or []]
    if any("does not serve requested file" in value for value in direct_failures):
        return "peer_not_serving"
    if any(
        "failed to read ed2k packet" in value
        or "closed ed2k download session" in value
        or "forcibly closed" in value
        for value in direct_failures
    ):
        return "peer_closed_after_hello"
    if int(source_evidence.get("sourceSearchFailureCount") or 0) != 0:
        return "source_search_timeout"
    return "unknown"


def _transfer_manifest_has_progress(transfer_manifest: dict[str, Any] | None) -> bool:
    if not transfer_manifest:
        return False
    return (
        transfer_manifest.get("md4_hashset_acquired") is True
        or transfer_manifest.get("aich_hashset_acquired") is True
        or bool(transfer_manifest.get("aich_root"))
        or bool(transfer_manifest.get("verified_ranges"))
        or any(
            int(piece.get("bytes_written") or 0) != 0
            for piece in transfer_manifest.get("pieces") or []
            if isinstance(piece, dict)
        )
    )


def _merge_server_dump_source_evidence(
    evidence: dict[str, Any],
    path: Path,
    target_hash: str | None,
) -> None:
    roles: list[str] = []
    transports: list[str] = []
    for record in _read_jsonl_dicts(path):
        opcode_name = str(record.get("opcode_name") or "")
        direction = str(record.get("direction") or "")
        payload_hex = str(record.get("payload_hex") or "").lower()
        note = str(record.get("note") or "").lower()
        record_matches_hash = (
            target_hash is None
            or payload_hex.startswith(target_hash)
            or target_hash in note
        )
        if not record_matches_hash:
            continue
        if direction == "tx" and opcode_name in {"OP_GETSOURCES", "OP_GETSOURCES_OBFU"}:
            evidence["serverGetSourcesRequestCount"] = (
                int(evidence["serverGetSourcesRequestCount"]) + 1
            )
            _append_unique(roles, str(record.get("role") or ""))
            _append_unique(transports, str(record.get("transport") or ""))
        if direction == "rx" and opcode_name in {"OP_FOUNDSOURCES", "OP_FOUNDSOURCES_OBFU"}:
            evidence["serverFoundSourcesResponseCount"] = (
                int(evidence["serverFoundSourcesResponseCount"]) + 1
            )
            _append_unique(roles, str(record.get("role") or ""))
            _append_unique(transports, str(record.get("transport") or ""))
    evidence["serverSourceSearchRoles"] = roles
    evidence["serverSourceSearchTransports"] = transports


def _read_jsonl_dicts(path: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            stripped = line.strip()
            if not stripped:
                continue
            value = json.loads(stripped)
            if isinstance(value, dict):
                records.append(value)
    return records


def _append_unique(values: list[str], value: str) -> None:
    if value and value not in values:
        values.append(value)


def _record_kad_source_evidence(evidence: dict[str, Any], match: re.Match[str]) -> None:
    phase = match.group("phase")
    if phase == "fallback":
        evidence["kadSourceFallbackObserved"] = True
    else:
        evidence["kadSourceSupplementObserved"] = True
    if "source_count" in match.groupdict():
        evidence["kadSourceCount"] = int(match.group("source_count"))


def _matches_file_hash(match: re.Match[str], target_hash: str | None) -> bool:
    return target_hash is None or match.group("file_hash").lower() == target_hash


def _candidate_summary(candidate: dict[str, object] | None) -> dict[str, object] | None:
    if candidate is None:
        return None
    return {
        "fileHash": candidate["file_hash"],
        "fileName": candidate["file_name"],
        "fileSize": candidate["file_size"],
        "advertisedSourceCount": ed2k_candidate_source_count(candidate),
    }


def _bootstrap_summary(stats: dict[str, Any] | None) -> dict[str, Any] | None:
    if stats is None:
        return None
    return {
        "peersConnected": int(stats.get("peers_connected") or 0),
        "kadBootstrapped": bool(stats.get("kad_bootstrapped")),
    }
