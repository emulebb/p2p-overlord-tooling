from __future__ import annotations

from overlord_tooling import cli
from tests.e2e.lib.paths import WorkspacePaths


def test_help_lists_quality_and_hygiene_commands(workspace_paths: WorkspacePaths) -> None:
    paths = cli.Paths(workspace_paths.project_root, workspace_paths.tooling_root)
    names = {entry["name"] for entry in cli.command_help(paths, [])}

    assert "quality-baseline" in names
    assert "hygiene-report" in names


def test_hygiene_report_summarizes_workspace(workspace_paths: WorkspacePaths) -> None:
    paths = cli.Paths(workspace_paths.project_root, workspace_paths.tooling_root)

    report = cli.command_hygiene_report(paths, ["--top-files", "2"])

    assert report["schemaVersion"] == "workspace-hygiene-report/v1"
    assert report["parity"]["totalRows"] >= report["parity"]["availableRows"]
    assert len(report["repos"]) == 3
    assert all(len(repo["largestSourceFiles"]) <= 2 for repo in report["repos"])


def test_quality_baseline_uses_supported_direct_commands(
    monkeypatch, workspace_paths: WorkspacePaths
) -> None:
    paths = cli.Paths(workspace_paths.project_root, workspace_paths.tooling_root)
    seen: list[str] = []

    def fake_run_quality_command(command):
        seen.append(command["name"])
        return {
            "name": command["name"],
            "cwd": str(command["cwd"]),
            "command": command["command"],
            "exitCode": 0,
            "passed": True,
            "stdoutTail": [],
            "stderrTail": [],
        }

    monkeypatch.setattr(cli, "run_quality_command", fake_run_quality_command)

    summary = cli.command_quality_baseline(paths, [])

    assert summary["passed"]
    assert "agents:fmt" in seen
    assert "agents:clippy" in seen
    assert "backend:check" in seen
    assert "backend:prisma-validate" in seen
    assert "tooling:pytest" in seen
    assert "guard:workspace-conventions" in seen


def test_internal_api_drift_report_is_advisory(workspace_paths: WorkspacePaths) -> None:
    report = cli.internal_api_drift_summary(workspace_paths.project_root)

    assert report["checked"] is True
    assert "comparisons" in report
