from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any, Callable


SOURCE_SUFFIXES = {".rs", ".ts", ".svelte", ".py", ".mjs", ".js"}
DEFAULT_SOURCE_WARN_LINES = 700
DEFAULT_SOURCE_WARN_KIB = 32
DEFAULT_SOURCE_SEVERE_LINES = 1000
DEFAULT_SOURCE_SEVERE_KIB = 48


def add_source_size_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--source-warn-lines", type=int, default=DEFAULT_SOURCE_WARN_LINES)
    parser.add_argument("--source-warn-kib", type=int, default=DEFAULT_SOURCE_WARN_KIB)
    parser.add_argument("--source-severe-lines", type=int, default=DEFAULT_SOURCE_SEVERE_LINES)
    parser.add_argument("--source-severe-kib", type=int, default=DEFAULT_SOURCE_SEVERE_KIB)


def source_size_policy_from_args(args: argparse.Namespace, mode: str = "advisory") -> dict[str, Any]:
    return {
        "schemaVersion": "source-size-policy/v1",
        "trackedSuffixes": sorted(SOURCE_SUFFIXES),
        "warnLines": args.source_warn_lines,
        "warnKiB": args.source_warn_kib,
        "severeLines": args.source_severe_lines,
        "severeKiB": args.source_severe_kib,
        "mode": mode,
    }


def source_size_findings(
    repo_root: Path, tracked_files: list[str], policy: dict[str, Any]
) -> list[dict[str, Any]]:
    findings = []
    warn_bytes = int(policy["warnKiB"]) * 1024
    severe_bytes = int(policy["severeKiB"]) * 1024
    for relative_path in tracked_files:
        path = repo_root / relative_path
        if path.suffix.lower() not in SOURCE_SUFFIXES or not path.is_file():
            continue
        byte_count = path.stat().st_size
        line_count = count_lines(path)
        severe = byte_count > severe_bytes or line_count > int(policy["severeLines"])
        warn = byte_count > warn_bytes or line_count > int(policy["warnLines"])
        if not warn and not severe:
            continue
        findings.append(
            {
                "path": relative_path,
                "severity": "severe" if severe else "warn",
                "bytes": byte_count,
                "kib": round(byte_count / 1024, 1),
                "lines": line_count,
                "reasons": source_size_reasons(byte_count, line_count, policy),
            }
        )
    return sorted(findings, key=lambda item: (item["severity"] != "severe", -item["bytes"], item["path"]))


def source_size_reasons(byte_count: int, line_count: int, policy: dict[str, Any]) -> list[str]:
    reasons = []
    if byte_count > int(policy["severeKiB"]) * 1024:
        reasons.append("bytes>severe")
    elif byte_count > int(policy["warnKiB"]) * 1024:
        reasons.append("bytes>warn")
    if line_count > int(policy["severeLines"]):
        reasons.append("lines>severe")
    elif line_count > int(policy["warnLines"]):
        reasons.append("lines>warn")
    return reasons


def count_lines(path: Path) -> int:
    return len(path.read_text(encoding="utf-8", errors="ignore").splitlines())


def largest_source_files(repo_root: Path, tracked_files: list[str], limit: int) -> list[dict[str, Any]]:
    files = []
    for relative_path in tracked_files:
        path = repo_root / relative_path
        if path.suffix.lower() not in SOURCE_SUFFIXES or not path.is_file():
            continue
        files.append(
            {
                "path": relative_path,
                "bytes": path.stat().st_size,
                "kib": round(path.stat().st_size / 1024, 1),
            }
        )
    return sorted(files, key=lambda item: item["bytes"], reverse=True)[:limit]


def load_source_size_baseline(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def baseline_findings_by_repo(baseline: dict[str, Any]) -> dict[str, dict[str, dict[str, Any]]]:
    repos = {}
    for repo in baseline.get("repos", []):
        repos[repo["name"]] = {finding["path"]: finding for finding in repo.get("sourceSizeFindings", [])}
    return repos


def source_size_ratchet_violations(
    repo_name: str, findings: list[dict[str, Any]], baseline: dict[str, Any] | None
) -> list[dict[str, Any]]:
    if baseline is None:
        return []
    baseline_by_path = baseline_findings_by_repo(baseline).get(repo_name, {})
    violations = []
    for finding in findings:
        baseline_finding = baseline_by_path.get(finding["path"])
        if baseline_finding is None:
            violations.append({"kind": "new-finding", "current": finding})
            continue
        grew_lines = finding["lines"] > int(baseline_finding["lines"])
        grew_bytes = finding["bytes"] > int(baseline_finding["bytes"])
        if grew_lines or grew_bytes:
            violations.append(
                {
                    "kind": "grown-finding",
                    "path": finding["path"],
                    "current": finding,
                    "baseline": baseline_finding,
                    "reasons": [
                        reason
                        for reason, grew in (("lines>baseline", grew_lines), ("bytes>baseline", grew_bytes))
                        if grew
                    ],
                }
            )
    return violations


def source_size_guard_summary(
    workspace_root: Path,
    repo_roots: list[Path],
    policy: dict[str, Any],
    *,
    git_lines: Callable[[Path, list[str]], list[str]],
    enforce: bool,
    ratchet_baseline: dict[str, Any] | None = None,
    baseline_path: Path | None = None,
) -> dict[str, Any]:
    repos = []
    for repo_root in repo_roots:
        tracked_files = git_lines(repo_root, ["ls-files"])
        findings = source_size_findings(repo_root, tracked_files, policy)
        repos.append(
            {
                "name": repo_root.name,
                "repoRoot": str(repo_root),
                "scannedTrackedFiles": len(tracked_files),
                "sourceSizeFindings": findings,
                "sourceSizeRatchetViolations": source_size_ratchet_violations(
                    repo_root.name, findings, ratchet_baseline
                ),
            }
        )
    ratchet = ratchet_baseline is not None
    return {
        "schemaVersion": "source-size-guard-summary/v1",
        "workspaceRoot": str(workspace_root),
        "policy": policy,
        "baselinePath": str(baseline_path) if baseline_path else None,
        "repos": repos,
        "enforced": enforce,
        "ratcheted": ratchet,
        "passed": (not enforce or all(not repo["sourceSizeFindings"] for repo in repos))
        and (not ratchet or all(not repo["sourceSizeRatchetViolations"] for repo in repos)),
    }


def run_guard_source_size(
    paths: Any,
    argv: list[str],
    *,
    canonical_repo_roots: Callable[[Path], list[Path]],
    git_lines: Callable[[Path, list[str]], list[str]],
    write_json: Callable[[Any], None],
) -> dict[str, Any]:
    parser = argparse.ArgumentParser(prog="python -m overlord_tooling guard-source-size")
    parser.add_argument("--workspace-root", type=Path, default=paths.workspace_root)
    parser.add_argument("--repo-root", action="append", type=Path)
    mode_group = parser.add_mutually_exclusive_group()
    mode_group.add_argument(
        "--enforce",
        action="store_true",
        help="Exit non-zero when tracked source files exceed configured thresholds.",
    )
    mode_group.add_argument(
        "--ratchet",
        action="store_true",
        help="Exit non-zero when source-size findings are new or grow past the tracked baseline.",
    )
    parser.add_argument(
        "--baseline",
        type=Path,
        default=paths.tooling_root / "docs" / "source-size-baseline.json",
        help="Tracked source-size baseline used by --ratchet.",
    )
    add_source_size_args(parser)
    parsed = parser.parse_args(argv)

    workspace_root = parsed.workspace_root.resolve()
    repo_roots = [repo.resolve() for repo in parsed.repo_root] if parsed.repo_root else canonical_repo_roots(workspace_root)
    baseline_path = parsed.baseline.resolve()
    ratchet_baseline = None
    if parsed.ratchet:
        if not baseline_path.is_file():
            raise SystemExit(f"Source-size baseline not found: {baseline_path}")
        ratchet_baseline = load_source_size_baseline(baseline_path)
    mode = "ratchet" if parsed.ratchet else "enforced" if parsed.enforce else "advisory"
    summary = source_size_guard_summary(
        workspace_root,
        repo_roots,
        source_size_policy_from_args(parsed, mode),
        git_lines=git_lines,
        enforce=parsed.enforce,
        ratchet_baseline=ratchet_baseline,
        baseline_path=baseline_path if parsed.ratchet else None,
    )
    if not summary["passed"]:
        write_json(summary)
        raise SystemExit("Source-size guard failed")
    return summary
