from __future__ import annotations

import subprocess
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import pytest

from overlord_tooling.scenarios import write_json
from tests.e2e.lib.paths import WorkspacePaths


def run_private_ed2k_listener_queue_scenario(
    workspace_paths: WorkspacePaths,
    pytestconfig: pytest.Config,
    *,
    scenario_id: str,
    artifact_scenario_id: str | None = None,
    run_slug: str | None = None,
    metadata: dict[str, Any] | None = None,
    transport_mode: str | None = None,
) -> Path:
    selected_transport = str(pytestconfig.getoption("--transport"))
    scenario_transport = transport_mode or "plaintext"
    if selected_transport not in {"both", scenario_transport}:
        pytest.skip(
            f"{scenario_id} is {scenario_transport}, selected --transport={selected_transport}"
        )

    run_id = f"{run_slug or scenario_id}-{_run_timestamp()}"
    artifact_root = workspace_paths.run_root(artifact_scenario_id or scenario_id, run_id)
    artifact_root.mkdir(parents=True, exist_ok=True)
    command = [
        "cargo",
        "test",
        "-p",
        "overlord-agent-emule",
        "ed2k_tcp::tests::listener::queue",
        "--",
        "--nocapture",
    ]
    result = subprocess.run(
        command,
        cwd=workspace_paths.agents_root,
        text=True,
        capture_output=True,
        check=False,
    )
    summary = {
        "schemaVersion": "ed2k-listener-queue-summary/v1",
        "scenarioId": scenario_id,
        "artifactScenarioId": artifact_scenario_id or scenario_id,
        "runId": run_id,
        "completed": result.returncode == 0,
        "transport": scenario_transport,
        "command": command,
        "evidence": {
            "listenerQueueRustTests": result.returncode == 0,
            "queueRankingCovered": True,
            "acceptUploadCovered": True,
            "duplicateReconnectCovered": True,
            "fileSwitchRankCovered": True,
        },
        "metadata": metadata or {},
        "stdoutTail": _tail_lines(result.stdout),
        "stderrTail": _tail_lines(result.stderr),
        "finishedAtUtc": datetime.now(UTC).isoformat(),
    }
    if result.returncode != 0:
        summary["failedReason"] = "listener_queue_rust_tests_failed"
    summary_path = artifact_root / "run-summary.json"
    write_json(summary_path, summary)
    if result.returncode != 0:
        raise AssertionError(
            f"{scenario_id} listener queue Rust tests failed; summary={summary_path}"
        )
    return summary_path


def run_private_ed2k_downloader_queue_scenario(
    workspace_paths: WorkspacePaths,
    pytestconfig: pytest.Config,
    *,
    scenario_id: str,
    artifact_scenario_id: str | None = None,
    run_slug: str | None = None,
    metadata: dict[str, Any] | None = None,
    transport_mode: str | None = None,
) -> Path:
    selected_transport = str(pytestconfig.getoption("--transport"))
    scenario_transport = transport_mode or "plaintext"
    if selected_transport not in {"both", scenario_transport}:
        pytest.skip(
            f"{scenario_id} is {scenario_transport}, selected --transport={selected_transport}"
        )

    run_id = f"{run_slug or scenario_id}-{_run_timestamp()}"
    artifact_root = workspace_paths.run_root(artifact_scenario_id or scenario_id, run_id)
    artifact_root.mkdir(parents=True, exist_ok=True)
    command = [
        "cargo",
        "test",
        "-p",
        "overlord-agent-emule",
        "ed2k_tcp::tests::download::queue_only",
        "--",
        "--nocapture",
    ]
    result = subprocess.run(
        command,
        cwd=workspace_paths.agents_root,
        text=True,
        capture_output=True,
        check=False,
    )
    summary = {
        "schemaVersion": "ed2k-downloader-queue-summary/v1",
        "scenarioId": scenario_id,
        "artifactScenarioId": artifact_scenario_id or scenario_id,
        "runId": run_id,
        "completed": result.returncode == 0,
        "transport": scenario_transport,
        "command": command,
        "evidence": {
            "downloaderQueueRustTests": result.returncode == 0,
            "queueOnlyAcceptedButIncompleteCovered": True,
            "lateAcceptUploadCovered": True,
            "queueRankingCovered": True,
        },
        "metadata": metadata or {},
        "stdoutTail": _tail_lines(result.stdout),
        "stderrTail": _tail_lines(result.stderr),
        "finishedAtUtc": datetime.now(UTC).isoformat(),
    }
    if result.returncode != 0:
        summary["failedReason"] = "downloader_queue_rust_tests_failed"
    summary_path = artifact_root / "run-summary.json"
    write_json(summary_path, summary)
    if result.returncode != 0:
        raise AssertionError(
            f"{scenario_id} downloader queue Rust tests failed; summary={summary_path}"
        )
    return summary_path


def run_private_ed2k_listener_serving_scenario(
    workspace_paths: WorkspacePaths,
    pytestconfig: pytest.Config,
    *,
    scenario_id: str,
    artifact_scenario_id: str | None = None,
    run_slug: str | None = None,
    metadata: dict[str, Any] | None = None,
    transport_mode: str | None = None,
) -> Path:
    return _run_rust_e2e_module(
        workspace_paths,
        pytestconfig,
        scenario_id=scenario_id,
        artifact_scenario_id=artifact_scenario_id,
        run_slug=run_slug,
        metadata=metadata,
        transport_mode=transport_mode,
        module_filter="ed2k_tcp::tests::listener::serving",
        schema_version="ed2k-listener-serving-summary/v1",
        evidence={
            "listenerServingRustTests": True,
            "compressedPartServingCovered": True,
            "obfuscatedTransportCovered": transport_mode == "obfuscated",
        },
        failure_reason="listener_serving_rust_tests_failed",
    )


def run_private_ed2k_listener_resume_scenario(
    workspace_paths: WorkspacePaths,
    pytestconfig: pytest.Config,
    *,
    scenario_id: str,
    artifact_scenario_id: str | None = None,
    run_slug: str | None = None,
    metadata: dict[str, Any] | None = None,
    transport_mode: str | None = None,
) -> Path:
    scenario_transport = transport_mode or "plaintext"
    if scenario_transport != "plaintext":
        pytest.skip(f"{scenario_id} does not have obfuscated listener resume coverage yet")
    return _run_rust_e2e_module(
        workspace_paths,
        pytestconfig,
        scenario_id=scenario_id,
        artifact_scenario_id=artifact_scenario_id,
        run_slug=run_slug,
        metadata=metadata,
        transport_mode=scenario_transport,
        module_filter="ed2k_tcp::tests::listener::resume",
        schema_version="ed2k-listener-resume-summary/v1",
        evidence={
            "listenerResumeRustTests": True,
            "partialDownloadReconnectCovered": True,
            "helloIdentityReconnectCovered": True,
        },
        failure_reason="listener_resume_rust_tests_failed",
    )


def _run_rust_e2e_module(
    workspace_paths: WorkspacePaths,
    pytestconfig: pytest.Config,
    *,
    scenario_id: str,
    artifact_scenario_id: str | None,
    run_slug: str | None,
    metadata: dict[str, Any] | None,
    transport_mode: str | None,
    module_filter: str,
    schema_version: str,
    evidence: dict[str, Any],
    failure_reason: str,
) -> Path:
    selected_transport = str(pytestconfig.getoption("--transport"))
    scenario_transport = transport_mode or "plaintext"
    if selected_transport not in {"both", scenario_transport}:
        pytest.skip(
            f"{scenario_id} is {scenario_transport}, selected --transport={selected_transport}"
        )

    run_id = f"{run_slug or scenario_id}-{_run_timestamp()}"
    artifact_root = workspace_paths.run_root(artifact_scenario_id or scenario_id, run_id)
    artifact_root.mkdir(parents=True, exist_ok=True)
    command = [
        "cargo",
        "test",
        "-p",
        "overlord-agent-emule",
        module_filter,
        "--",
        "--nocapture",
    ]
    result = subprocess.run(
        command,
        cwd=workspace_paths.agents_root,
        text=True,
        capture_output=True,
        check=False,
    )
    summary = {
        "schemaVersion": schema_version,
        "scenarioId": scenario_id,
        "artifactScenarioId": artifact_scenario_id or scenario_id,
        "runId": run_id,
        "completed": result.returncode == 0,
        "transport": scenario_transport,
        "command": command,
        "evidence": {**evidence, "rustTestsPassed": result.returncode == 0},
        "metadata": metadata or {},
        "stdoutTail": _tail_lines(result.stdout),
        "stderrTail": _tail_lines(result.stderr),
        "finishedAtUtc": datetime.now(UTC).isoformat(),
    }
    if result.returncode != 0:
        summary["failedReason"] = failure_reason
    summary_path = artifact_root / "run-summary.json"
    write_json(summary_path, summary)
    if result.returncode != 0:
        raise AssertionError(f"{scenario_id} Rust tests failed; summary={summary_path}")
    return summary_path


def _tail_lines(text: str, limit: int = 40) -> list[str]:
    lines = text.splitlines()
    return lines[-limit:]


def _run_timestamp() -> str:
    return datetime.now(UTC).strftime("%Y%m%d-%H%M%S")
