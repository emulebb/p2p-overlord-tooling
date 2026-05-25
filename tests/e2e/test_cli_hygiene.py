from __future__ import annotations

import ast
from pathlib import Path

from overlord_tooling import cli
from overlord_tooling.line_endings import source_normalization_summary
from overlord_tooling.source_size import source_size_guard_summary, source_size_policy_from_args
from overlord_tooling.workspace_materialize import validate_workspace
from tests.e2e.lib.paths import WorkspacePaths


def test_help_lists_quality_and_hygiene_commands(workspace_paths: WorkspacePaths) -> None:
    paths = cli.Paths(workspace_paths.project_root, workspace_paths.tooling_root)
    names = {entry["name"] for entry in cli.command_help(paths, [])}

    assert "quality-baseline" in names
    assert "hygiene-report" in names
    assert "guard-source-size" in names
    assert "guard-line-endings" in names
    assert "normalize-source" in names
    assert "materialize" in names
    assert "sync" in names
    assert "validate" in names


def test_cli_keeps_line_ending_dependency_lazy() -> None:
    module = ast.parse(Path(cli.__file__).read_text(encoding="utf-8"))
    top_level_imports = [node for node in module.body if isinstance(node, ast.ImportFrom)]

    assert all(node.module != "overlord_tooling.line_endings" for node in top_level_imports)


def test_hygiene_report_summarizes_workspace(workspace_paths: WorkspacePaths) -> None:
    paths = cli.Paths(workspace_paths.project_root, workspace_paths.tooling_root)

    report = cli.command_hygiene_report(paths, ["--top-files", "2"])

    assert report["schemaVersion"] == "workspace-hygiene-report/v1"
    assert report["sourceSizePolicy"]["mode"] == "advisory"
    assert report["parity"]["totalRows"] >= report["parity"]["availableRows"]
    assert len(report["repos"]) == 4
    assert all(len(repo["largestSourceFiles"]) <= 2 for repo in report["repos"])
    assert all("sourceSizeFindings" in repo for repo in report["repos"])


def test_paths_report_includes_ed2k_server_root(workspace_paths: WorkspacePaths) -> None:
    paths = cli.Paths(workspace_paths.project_root, workspace_paths.tooling_root)

    report = cli.command_paths(paths, [])

    assert report["ed2kServerRepoRoot"].endswith("p2p-overlord-ed2k-server")


def test_validate_reports_emule_workspace_root_as_harness_only(workspace_paths: WorkspacePaths) -> None:
    report = validate_workspace(workspace_paths.project_root)

    assert set(report["environment"]) == {
        "OVERLORD_PROJECT_DIR",
        "OVERLORD_TMP_DIR",
        "OVERLORD_LOG_DIR",
        "EMULE_WORKSPACE_ROOT",
    }
    assert report["environment"]["EMULE_WORKSPACE_ROOT"]["requiredFor"] == "emule-harness scenarios"


def test_source_size_guard_is_advisory_by_default(workspace_paths: WorkspacePaths) -> None:
    paths = cli.Paths(workspace_paths.project_root, workspace_paths.tooling_root)

    summary = cli.command_guard_source_size(
        paths,
        [
            "--repo-root",
            str(workspace_paths.tooling_root),
            "--source-warn-lines",
            "1",
            "--source-warn-kib",
            "1",
        ],
    )

    assert summary["schemaVersion"] == "source-size-guard-summary/v1"
    assert summary["enforced"] is False
    assert summary["ratcheted"] is False
    assert summary["passed"] is True
    assert summary["repos"][0]["sourceSizeFindings"]


def test_source_size_ratchet_accepts_current_baseline(workspace_paths: WorkspacePaths) -> None:
    paths = cli.Paths(workspace_paths.project_root, workspace_paths.tooling_root)

    summary = cli.command_guard_source_size(paths, ["--ratchet"])

    assert summary["ratcheted"] is True
    assert summary["passed"] is True
    assert all(not repo["sourceSizeRatchetViolations"] for repo in summary["repos"])


def test_source_size_ratchet_flags_new_or_grown_findings(tmp_path) -> None:
    repo_root = tmp_path / "p2p-overlord-tooling"
    repo_root.mkdir()
    oversized = repo_root / "oversized.py"
    oversized.write_text("line\n" * 4, encoding="utf-8")
    new_oversized = repo_root / "new_oversized.py"
    new_oversized.write_text("line\n" * 3, encoding="utf-8")

    class Args:
        source_warn_lines = 1
        source_warn_kib = 999
        source_severe_lines = 10
        source_severe_kib = 999

    baseline = {
        "schemaVersion": "source-size-baseline/v1",
        "repos": [
            {
                "name": repo_root.name,
                "sourceSizeFindings": [
                    {
                        "path": "oversized.py",
                        "severity": "warn",
                        "bytes": 10,
                        "kib": 0.0,
                        "lines": 2,
                        "reasons": ["lines>warn"],
                    }
                ],
            }
        ],
    }
    summary = source_size_guard_summary(
        tmp_path,
        [repo_root],
        source_size_policy_from_args(Args(), "ratchet"),
        git_lines=lambda _repo_root, _args: ["oversized.py", "new_oversized.py"],
        enforce=False,
        ratchet_baseline=baseline,
    )

    assert summary["passed"] is False
    violations = summary["repos"][0]["sourceSizeRatchetViolations"]
    assert violations[0]["kind"] == "grown-finding"
    assert violations[1]["kind"] == "new-finding"


def test_line_ending_guard_accepts_lf_text(tmp_path) -> None:
    repo_root = tmp_path / "p2p-overlord-tooling"
    repo_root.mkdir()
    (repo_root / ".editorconfig").write_bytes(b"root = true\n[*]\nend_of_line = lf\ninsert_final_newline = true\n")
    (repo_root / "ok.py").write_bytes(b"print('ok')\n")

    summary = source_normalization_summary(
        tmp_path,
        [repo_root],
        git_lines=lambda _repo_root, _args: [".editorconfig", "ok.py"],
        write=False,
    )

    assert summary["passed"] is True


def test_normalize_source_reports_and_fixes_crlf(tmp_path) -> None:
    repo_root = tmp_path / "p2p-overlord-tooling"
    repo_root.mkdir()
    (repo_root / ".editorconfig").write_bytes(b"root = true\n[*]\nend_of_line = lf\ninsert_final_newline = true\n")
    target = repo_root / "bad.ps1"
    target.write_bytes(b"Write-Output 'bad'\r\n")

    dry_run = source_normalization_summary(
        tmp_path,
        [repo_root],
        git_lines=lambda _repo_root, _args: [".editorconfig", "bad.ps1"],
        write=False,
    )
    written = source_normalization_summary(
        tmp_path,
        [repo_root],
        git_lines=lambda _repo_root, _args: [".editorconfig", "bad.ps1"],
        write=True,
    )

    assert dry_run["passed"] is False
    assert dry_run["repos"][0]["normalizationFindings"][0]["reasons"] == ["line-endings"]
    assert written["repos"][0]["normalizationFindings"][0]["written"] is True
    assert target.read_bytes() == b"Write-Output 'bad'\n"


def test_quality_baseline_uses_supported_direct_commands(
    monkeypatch, workspace_paths: WorkspacePaths
) -> None:
    paths = cli.Paths(workspace_paths.project_root, workspace_paths.tooling_root)
    seen: list[str] = []
    commands: dict[str, list[str]] = {}

    def fake_run_quality_command(command):
        seen.append(command["name"])
        commands[command["name"]] = command["command"]
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
    assert "clippy::too_many_arguments" in commands["agents:clippy"]
    assert "clippy::type_complexity" in commands["agents:clippy"]
    assert "clippy::cognitive_complexity" in commands["agents:clippy"]
    assert "backend:check" in seen
    assert "backend:prisma-validate" in seen
    assert "tooling:pytest" in seen
    assert "guard:workspace-conventions" in seen
    assert "guard:line-endings" in seen
    assert "guard:source-size-ratchet" in seen
    assert "--ratchet" in commands["guard:source-size-ratchet"]


def test_internal_api_drift_report_is_advisory(workspace_paths: WorkspacePaths) -> None:
    report = cli.internal_api_drift_summary(workspace_paths.project_root)

    assert report["checked"] is True
    assert "comparisons" in report
