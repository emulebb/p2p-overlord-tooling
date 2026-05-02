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


def _tail_lines(text: str, limit: int = 40) -> list[str]:
    lines = text.splitlines()
    return lines[-limit:]


def _run_timestamp() -> str:
    return datetime.now(UTC).strftime("%Y%m%d-%H%M%S")
