from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


COMMANDS = [
    ("help", "Show CLI help"),
    ("layout", "Show the platform directory layout"),
    ("paths", "Show canonical workspace and repo paths"),
    ("show-scenario", "Print a scenario manifest"),
    ("show-parity-matrix", "Print parity cell and campaign inventory from scenario manifests"),
    ("parity-status", "Print parity inventory with latest run-summary status"),
    ("guard-tracked-files", "Fail when tracked files contain local path or configured identifier leaks"),
    ("guard-workspace-conventions", "Fail when workspace conventions or no-wrapper rules are violated"),
    ("import-emule-harness-seeds", "Import local nodes.dat and server.met into the untracked seed bundle"),
]

CANONICAL_REPOS = ("p2p-overlord-tooling", "p2p-overlord-agents", "p2p-overlord-be")
FORBIDDEN_WRAPPER_SUFFIXES = (".ps1", ".psm1", ".psd1", ".cmd")
SKIP_DIRS = {".git", ".local", ".pytest_cache", "__pycache__", "node_modules", "target"}


@dataclass(frozen=True)
class Paths:
    workspace_root: Path
    tooling_root: Path

    @property
    def docs_root(self) -> Path:
        return self.tooling_root / "docs"

    @property
    def schemas_root(self) -> Path:
        return self.tooling_root / "schemas"

    @property
    def scenarios_root(self) -> Path:
        return self.tooling_root / "scenarios"


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    paths = discover_paths()
    command = args[0] if args else "help"
    command_args = args[1:] if args else []

    handlers = {
        "help": command_help,
        "layout": command_layout,
        "paths": command_paths,
        "show-scenario": command_show_scenario,
        "show-parity-matrix": command_show_parity_matrix,
        "parity-status": command_parity_status,
        "guard-tracked-files": command_guard_tracked_files,
        "guard-workspace-conventions": command_guard_workspace_conventions,
        "import-emule-harness-seeds": command_import_emule_harness_seeds,
    }
    handler = handlers.get(command)
    if handler is None:
        raise SystemExit(f"Unknown overlord-tooling command '{command}'. Run 'python -m overlord_tooling help'.")

    result = handler(paths, command_args)
    if result is not None:
        write_json(result)
    return 0


def command_help(paths: Paths, argv: list[str]) -> Any:
    parser = argparse.ArgumentParser(prog="python -m overlord_tooling help")
    parser.parse_args(argv)
    return [{"name": name, "kind": "builtin", "description": description} for name, description in COMMANDS]


def command_layout(paths: Paths, argv: list[str]) -> Any:
    parser = argparse.ArgumentParser(prog="python -m overlord_tooling layout")
    parser.parse_args(argv)
    names = [
        "cli",
        "docs",
        "normalizers",
        "orchestration",
        "reports",
        "scenarios",
        "schemas",
        "tests",
        "overlord_tooling",
    ]
    return [{"name": name, "exists": (paths.tooling_root / name).exists(), "path": str(paths.tooling_root / name)} for name in names]


def command_paths(paths: Paths, argv: list[str]) -> Any:
    parser = argparse.ArgumentParser(prog="python -m overlord_tooling paths")
    parser.parse_args(argv)
    return {
        "workspaceRoot": str(paths.workspace_root),
        "toolingRepoRoot": str(paths.tooling_root),
        "docsRoot": str(paths.docs_root),
        "schemasRoot": str(paths.schemas_root),
        "scenariosRoot": str(paths.scenarios_root),
    }


def command_show_scenario(paths: Paths, argv: list[str]) -> Any:
    parser = argparse.ArgumentParser(prog="python -m overlord_tooling show-scenario")
    parser.add_argument("scenario_id")
    parsed = parser.parse_args(argv)
    return read_scenario_manifest(paths.tooling_root, parsed.scenario_id)


def command_show_parity_matrix(paths: Paths, argv: list[str]) -> Any:
    parser = argparse.ArgumentParser(prog="python -m overlord_tooling show-parity-matrix")
    parser.add_argument("--scenario-kind", choices=["All", "cell", "campaign"], default="All")
    parser.add_argument("--protocol", choices=["All", "kad2", "ed2k", "mixed"], default="All")
    parser.add_argument("--availability", choices=["All", "available", "planned"], default="All")
    parser.add_argument("--tier", choices=["All", "deterministic-private", "broad-private", "realnet-confidence"], default="All")
    parsed = parser.parse_args(argv)

    rows = []
    for record in iter_scenario_manifests(paths.tooling_root):
        manifest = record["manifest"]
        scenario_kind = str(manifest.get("scenarioKind", ""))
        if scenario_kind not in {"cell", "campaign"}:
            continue
        if parsed.scenario_kind != "All" and scenario_kind != parsed.scenario_kind:
            continue
        if parsed.protocol != "All" and manifest.get("protocol") != parsed.protocol:
            continue
        if parsed.tier != "All" and manifest.get("tier") != parsed.tier:
            continue

        parity = manifest.get("parity") if isinstance(manifest.get("parity"), dict) else {}
        campaign = manifest.get("campaign") if isinstance(manifest.get("campaign"), dict) else {}
        execution = manifest.get("execution") if isinstance(manifest.get("execution"), dict) else {}
        availability = campaign.get("availability") if scenario_kind == "campaign" else parity.get("availability")
        if parsed.availability != "All" and availability != parsed.availability:
            continue

        command = execution.get("command")
        rows.append(
            {
                "scenarioId": record["scenarioId"],
                "scenarioKind": scenario_kind,
                "protocol": manifest.get("protocol"),
                "tier": manifest.get("tier"),
                "matrixId": parity.get("matrixId"),
                "cellId": parity.get("cellId"),
                "availability": availability,
                "command": command,
                "summarySourceScenarioId": execution.get("summarySourceScenarioId"),
                "memberCount": len(campaign.get("members", [])) if isinstance(campaign.get("members"), list) else 0,
                "expectedBranch": parity.get("expectedBranch"),
                "comparisonMode": parity.get("comparisonMode"),
                "description": manifest.get("description"),
            }
        )
    return rows


def command_parity_status(paths: Paths, argv: list[str]) -> Any:
    parser = argparse.ArgumentParser(prog="python -m overlord_tooling parity-status")
    parser.add_argument("--scenario-kind", choices=["All", "cell", "campaign"], default="All")
    parser.add_argument("--protocol", choices=["All", "kad2", "ed2k", "mixed"], default="All")
    parser.add_argument("--availability", choices=["All", "available", "planned"], default="All")
    parser.add_argument("--tier", choices=["All", "deterministic-private", "broad-private", "realnet-confidence"], default="All")
    parsed = parser.parse_args(argv)

    matrix_rows = command_show_parity_matrix(
        paths,
        [
            "--scenario-kind",
            parsed.scenario_kind,
            "--protocol",
            parsed.protocol,
            "--availability",
            parsed.availability,
            "--tier",
            parsed.tier,
        ],
    )
    run_root = Path(os.environ.get("OVERLORD_TMP_DIR", Path(os.environ.get("TEMP", "/tmp")) / "p2p-overlord"))
    run_root = run_root / "overlord-tooling" / "runs"
    rows = []
    for row in matrix_rows:
        latest = latest_run_summary(run_root, str(row["scenarioId"]))
        status = {
            "latestRunId": None,
            "latestCompleted": None,
            "latestFailedReason": None,
            "latestRunSummaryPath": None,
        }
        if latest is not None:
            summary = json.loads(latest.read_text(encoding="utf-8"))
            status = {
                "latestRunId": summary.get("runId"),
                "latestCompleted": summary.get("completed"),
                "latestFailedReason": summary.get("failedReason"),
                "latestRunSummaryPath": str(latest),
            }
        rows.append({**row, **status})
    return rows


def command_import_emule_harness_seeds(paths: Paths, argv: list[str]) -> Any:
    parser = argparse.ArgumentParser(prog="python -m overlord_tooling import-emule-harness-seeds")
    parser.add_argument("nodes_dat_positional", nargs="?")
    parser.add_argument("server_met_positional", nargs="?")
    parser.add_argument("--nodes-dat-path", dest="nodes_dat_option")
    parser.add_argument("--server-met-path", dest="server_met_option")
    parser.add_argument("--bundle-id", default="canonical")
    parsed = parser.parse_args(argv)

    nodes_value = parsed.nodes_dat_option or parsed.nodes_dat_positional
    server_value = parsed.server_met_option or parsed.server_met_positional
    if not nodes_value:
        raise SystemExit("nodes.dat path is required")
    if not server_value:
        raise SystemExit("server.met path is required")

    nodes_path = Path(nodes_value).resolve()
    server_path = Path(server_value).resolve()
    if not nodes_path.is_file():
        raise SystemExit("nodes.dat not found at the supplied path")
    if not server_path.is_file():
        raise SystemExit("server.met not found at the supplied path")

    seed_root = paths.tooling_root / ".local" / "emule-harness-seeds" / parsed.bundle_id
    seed_root.mkdir(parents=True, exist_ok=True)
    nodes_target = seed_root / "nodes.dat"
    server_target = seed_root / "server.met"
    shutil.copy2(nodes_path, nodes_target)
    shutil.copy2(server_path, server_target)

    manifest = {
        "schemaVersion": "emule-harness-seed-bundle/v1",
        "bundleId": parsed.bundle_id,
        "importedAtUtc": datetime.now(timezone.utc).isoformat(),
        "files": [
            file_record("nodes.dat", nodes_target),
            file_record("server.met", server_target),
        ],
    }
    manifest_path = seed_root / "seed-bundle.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return {
        "seedRoot": str(seed_root),
        "manifestPath": str(manifest_path),
        "bundleId": parsed.bundle_id,
        "files": manifest["files"],
    }


def command_guard_tracked_files(paths: Paths, argv: list[str]) -> Any:
    parser = argparse.ArgumentParser(prog="python -m overlord_tooling guard-tracked-files")
    parser.add_argument("--repo-root", type=Path, default=paths.tooling_root)
    parser.add_argument("--policy-path", type=Path)
    parser.add_argument("--local-policy-path", type=Path)
    parsed = parser.parse_args(argv)

    repo_root = parsed.repo_root.resolve()
    policy_path = parsed.policy_path.resolve() if parsed.policy_path else default_policy_path(repo_root)
    local_policy_path = parsed.local_policy_path.resolve() if parsed.local_policy_path else default_local_policy_path(repo_root)
    summary = run_privacy_guard(repo_root, policy_path, local_policy_path)
    if not summary["passed"]:
        write_json(summary)
        raise SystemExit("Tracked-file privacy guard failed")
    return summary


def command_guard_workspace_conventions(paths: Paths, argv: list[str]) -> Any:
    parser = argparse.ArgumentParser(prog="python -m overlord_tooling guard-workspace-conventions")
    parser.add_argument("--workspace-root", type=Path, default=paths.workspace_root)
    parser.add_argument("--repo-root", action="append", type=Path)
    parsed = parser.parse_args(argv)

    workspace_root = parsed.workspace_root.resolve()
    repo_roots = [repo.resolve() for repo in parsed.repo_root] if parsed.repo_root else canonical_repo_roots(workspace_root)
    repos = [run_workspace_conventions_guard(repo_root) for repo_root in repo_roots]
    summary = {
        "schemaVersion": "workspace-conventions-guard-summary/v2",
        "workspaceRoot": str(workspace_root),
        "repos": repos,
        "passed": all(repo["passed"] for repo in repos),
    }
    if not summary["passed"]:
        write_json(summary)
        raise SystemExit("Workspace conventions guard failed")
    return summary


def discover_paths() -> Paths:
    tooling_root = find_tooling_root(Path(__file__).resolve())
    workspace_root = Path(os.environ.get("OVERLORD_PROJECT_DIR", tooling_root.parent)).resolve()
    return Paths(workspace_root=workspace_root, tooling_root=tooling_root)


def find_tooling_root(start: Path) -> Path:
    for parent in (start, *start.parents):
        if (parent / "pyproject.toml").is_file() and (parent / "scenarios").is_dir() and (parent / "overlord_tooling").is_dir():
            return parent
    raise RuntimeError(f"Could not find p2p-overlord-tooling root from {start}")


def canonical_repo_roots(workspace_root: Path) -> list[Path]:
    return [(workspace_root / name).resolve() for name in CANONICAL_REPOS if (workspace_root / name).is_dir()]


def read_scenario_manifest(tooling_root: Path, scenario_id: str) -> dict[str, Any]:
    manifest_path = tooling_root / "scenarios" / scenario_id / "manifest.v1.json"
    if not manifest_path.is_file():
        raise SystemExit(f"Scenario manifest not found at {manifest_path}")
    return json.loads(manifest_path.read_text(encoding="utf-8"))


def iter_scenario_manifests(tooling_root: Path) -> list[dict[str, Any]]:
    records = []
    for scenario_dir in sorted((tooling_root / "scenarios").iterdir()):
        manifest_path = scenario_dir / "manifest.v1.json"
        if not manifest_path.is_file():
            continue
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        records.append(
            {
                "scenarioId": str(manifest.get("scenarioId", scenario_dir.name)),
                "manifest": manifest,
                "manifestPath": str(manifest_path),
            }
        )
    return sorted(records, key=lambda record: record["scenarioId"])


def latest_run_summary(run_root: Path, scenario_id: str) -> Path | None:
    scenario_root = run_root / scenario_id
    if not scenario_root.is_dir():
        return None
    candidates = [path for path in scenario_root.rglob("run-summary.json") if path.is_file()]
    if not candidates:
        return None
    return max(candidates, key=lambda path: path.stat().st_mtime)


def run_privacy_guard(repo_root: Path, policy_path: Path, local_policy_path: Path) -> dict[str, Any]:
    if not policy_path.is_file():
        raise SystemExit(f"Privacy-guard policy not found at {policy_path}")
    policy = load_policy(policy_path)
    if local_policy_path.is_file():
        merge_policy(policy, load_policy(local_policy_path))
    identifiers = [item.strip() for item in os.environ.get("OVERLORD_PRIVACY_GUARD_IDENTIFIERS", "").split(",") if item.strip()]
    if identifiers:
        merge_policy(policy, identifier_policy(identifiers))

    tracked_files = git_lines(repo_root, ["ls-files"])
    path_matches = []
    for relative_path in tracked_files:
        for rule in policy["pathRules"]:
            if re.search(rule["regex"], relative_path):
                path_matches.append({"path": relative_path, "reason": rule.get("reason"), "regex": rule.get("regex")})

    content_matches = []
    for relative_path in tracked_files:
        file_path = repo_root / relative_path
        if not file_path.is_file():
            continue
        try:
            lines = file_path.read_text(encoding="utf-8", errors="ignore").splitlines()
        except OSError:
            continue
        for line_number, line in enumerate(lines, start=1):
            match_line = f"{relative_path}:{line_number}:{line}"
            if any(re.search(rule["regex"], match_line) for rule in policy["contentAllowRules"]):
                continue
            for rule in policy["contentRules"]:
                if re.search(rule["regex"], line):
                    content_matches.append({"rule": rule.get("id"), "reason": rule.get("reason"), "match": match_line})

    return {
        "schemaVersion": "privacy-guard-summary/v1",
        "repoRoot": str(repo_root),
        "policyVersion": policy.get("policyVersion"),
        "scannedTrackedFiles": len(tracked_files),
        "pathMatches": path_matches,
        "contentMatches": content_matches,
        "passed": not path_matches and not content_matches,
    }


def load_policy(path: Path) -> dict[str, Any]:
    policy = json.loads(path.read_text(encoding="utf-8"))
    policy.setdefault("pathRules", [])
    policy.setdefault("contentRules", [])
    policy.setdefault("contentAllowRules", [])
    return policy


def merge_policy(base: dict[str, Any], extra: dict[str, Any]) -> None:
    base["pathRules"] = [*base.get("pathRules", []), *extra.get("pathRules", [])]
    base["contentRules"] = [*base.get("contentRules", []), *extra.get("contentRules", [])]
    base["contentAllowRules"] = [*base.get("contentAllowRules", []), *extra.get("contentAllowRules", [])]


def identifier_policy(identifiers: list[str]) -> dict[str, Any]:
    path_rules = []
    for identifier in identifiers:
        path_rules.append(
            {
                "id": "local-identifier-filename",
                "reason": "Tracked filenames must not embed configured personal identifiers.",
                "regex": rf"(^|[\\/])[^\\/]*{re.escape(identifier)}[^\\/]*$",
            }
        )
    return {"pathRules": path_rules, "contentRules": [], "contentAllowRules": []}


def default_policy_path(repo_root: Path) -> Path:
    return repo_root / "schemas" / "privacy-guard" / "policy.v1.json"


def default_local_policy_path(repo_root: Path) -> Path:
    return repo_root / "schemas" / "privacy-guard" / "policy.local.json"


def run_workspace_conventions_guard(repo_root: Path) -> dict[str, Any]:
    tracked_files = git_lines(repo_root, ["ls-files"])
    stale_matches = find_stale_repo_dir_matches(repo_root, tracked_files)
    forbidden_files = sorted(set(find_forbidden_wrapper_files(repo_root, tracked_files)))
    return {
        "repoRoot": str(repo_root),
        "scannedTrackedFiles": len(tracked_files),
        "staleRepoDirMatches": stale_matches,
        "forbiddenWrapperFiles": forbidden_files,
        "passed": not stale_matches and not forbidden_files,
    }


def find_stale_repo_dir_matches(repo_root: Path, tracked_files: list[str]) -> list[str]:
    patterns = [
        r"(^|[^A-Za-z0-9-])\./overlord-(agents|be|tooling)([\\/]|$)",
        r"(^|[^A-Za-z0-9-])\.\./overlord-(agents|be|tooling)([\\/]|$)",
        r"%OVERLORD_PROJECT_DIR%\\overlord-(agents|be|tooling)(\\|$)",
        r"Join-Path\s+\$[A-Za-z0-9_]+\s+\"overlord-(agents|be|tooling)\\",
        r"[├└]──\s+overlord-(agents|be|tooling)(/|$)",
        r"`overlord-(agents|be|tooling)/(docs|scripts|overlord-be-coordinator|overlord-be-db|runtime|README\.md|AGENTS\.md|BACKLOG(_ARCHIVE)?\.md|overlord\.toml(\.example)?)`",
    ]
    compiled = [re.compile(pattern) for pattern in patterns]
    matches = []
    for relative_path in tracked_files:
        path = repo_root / relative_path
        if not path.is_file():
            continue
        try:
            lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
        except OSError:
            continue
        for line_number, line in enumerate(lines, start=1):
            if any(pattern.search(line) for pattern in compiled):
                matches.append(f"{relative_path}:{line_number}:{line}")
    return sorted(set(matches))


def find_forbidden_wrapper_files(repo_root: Path, tracked_files: list[str]) -> list[str]:
    forbidden = [
        path
        for path in tracked_files
        if path.lower().endswith(FORBIDDEN_WRAPPER_SUFFIXES) and (repo_root / path).exists()
    ]
    for path in repo_root.rglob("*"):
        if not path.is_file() or path.suffix.lower() not in FORBIDDEN_WRAPPER_SUFFIXES:
            continue
        if any(part in SKIP_DIRS for part in path.relative_to(repo_root).parts):
            continue
        forbidden.append(path.relative_to(repo_root).as_posix())
    return forbidden


def file_record(name: str, path: Path) -> dict[str, Any]:
    return {
        "name": name,
        "sha256": sha256_file(path),
        "length": path.stat().st_size,
        "relativePath": name,
    }


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def git_lines(repo_root: Path, args: list[str]) -> list[str]:
    result = subprocess.run(["git", "-C", str(repo_root), *args], check=False, capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"git {' '.join(args)} failed for {repo_root}: {result.stderr.strip()}")
    return [line for line in result.stdout.splitlines() if line]


def write_json(value: Any) -> None:
    sys.stdout.write(json.dumps(value, indent=2, ensure_ascii=False) + "\n")
