from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

import editorconfig
from charset_normalizer import from_bytes


UTF8_BOM = b"\xef\xbb\xbf"
UTF16LE_BOM = b"\xff\xfe"
UTF16BE_BOM = b"\xfe\xff"
TEXT_SUFFIXES = {
    ".bat",
    ".cmd",
    ".css",
    ".html",
    ".js",
    ".json",
    ".lock",
    ".md",
    ".mjs",
    ".ps1",
    ".psd1",
    ".psm1",
    ".py",
    ".rs",
    ".svelte",
    ".toml",
    ".ts",
    ".yaml",
    ".yml",
}
SPECIAL_FILENAMES = {".editorconfig", ".gitattributes", ".gitignore", "Dockerfile"}


@dataclass(frozen=True)
class TextInspection:
    label: str
    text: str | None


@dataclass(frozen=True)
class NormalizationResult:
    path: str
    encoding: str
    target_encoding: str
    changed: bool
    written: bool
    failed: bool
    reasons: list[str]


def is_target_text_file(relative_path: str) -> bool:
    path = Path(relative_path)
    return path.name in SPECIAL_FILENAMES or path.suffix.lower() in TEXT_SUFFIXES


def inspect_bytes(data: bytes) -> TextInspection:
    if not data:
        return TextInspection("empty", "")
    if data.startswith(UTF8_BOM):
        return TextInspection("utf-8-bom", data.decode("utf-8-sig"))
    if data.startswith(UTF16LE_BOM):
        return TextInspection("utf-16le-bom", data.decode("utf-16"))
    if data.startswith(UTF16BE_BOM):
        return TextInspection("utf-16be-bom", data.decode("utf-16"))
    try:
        return TextInspection("utf-8", data.decode("utf-8"))
    except UnicodeDecodeError:
        match = from_bytes(data).best()
        if match is None or not match.encoding:
            return TextInspection("legacy:undetected", None)
        try:
            return TextInspection(f"legacy:{match.encoding.lower().replace('_', '-')}", data.decode(match.encoding))
        except (LookupError, UnicodeDecodeError):
            return TextInspection(f"legacy:{match.encoding.lower().replace('_', '-')}", None)


def editorconfig_properties(path: Path) -> dict[str, str]:
    return {str(key): str(value) for key, value in editorconfig.get_properties(str(path)).items()}


def target_encoding(properties: dict[str, str]) -> str:
    charset = properties.get("charset", "utf-8").lower()
    return "utf-8" if charset in {"utf-8", "utf8"} else charset


def normalize_text(text: str, properties: dict[str, str]) -> str:
    normalized = text.replace("\r\n", "\n").replace("\r", "\n")
    if properties.get("trim_trailing_whitespace", "false").lower() == "true":
        normalized = "\n".join(line.rstrip(" \t") for line in normalized.split("\n"))
    if properties.get("insert_final_newline", "false").lower() == "true":
        normalized = normalized.rstrip("\n") + "\n" if normalized else "\n"
    else:
        normalized = normalized.rstrip("\n")
    return normalized


def encode_text(text: str, encoding: str) -> bytes:
    if encoding == "utf-8":
        return text.encode("utf-8")
    if encoding == "utf-8-bom":
        return UTF8_BOM + text.encode("utf-8")
    if encoding == "utf-16le":
        return UTF16LE_BOM + text.encode("utf-16-le")
    if encoding == "utf-16be":
        return UTF16BE_BOM + text.encode("utf-16-be")
    return text.encode(encoding)


def normalize_file(repo_root: Path, relative_path: str, *, write: bool) -> NormalizationResult:
    path = repo_root / relative_path
    data = path.read_bytes()
    inspection = inspect_bytes(data)
    if inspection.text is None:
        return NormalizationResult(relative_path, inspection.label, "utf-8", False, False, True, ["decode-failed"])
    properties = editorconfig_properties(path)
    encoding = target_encoding(properties)
    normalized_text = normalize_text(inspection.text, properties)
    target_bytes = encode_text(normalized_text, encoding)
    changed = data != target_bytes
    written = False
    reasons = normalization_reasons(data, target_bytes, inspection.label, encoding)
    if changed and write:
        path.write_bytes(target_bytes)
        written = True
    return NormalizationResult(relative_path, inspection.label, encoding, changed, written, False, reasons)


def normalization_reasons(current: bytes, target: bytes, encoding: str, target_encoding_name: str) -> list[str]:
    reasons = []
    if b"\r\n" in current or b"\r" in current.replace(b"\r\n", b""):
        reasons.append("line-endings")
    if encoding != target_encoding_name and not (encoding == "empty" and target_encoding_name == "utf-8"):
        reasons.append("encoding")
    if current != target and not reasons:
        reasons.append("whitespace")
    return reasons


def source_normalization_summary(
    workspace_root: Path,
    repo_roots: list[Path],
    *,
    git_lines: Callable[[Path, list[str]], list[str]],
    write: bool,
) -> dict[str, Any]:
    repos = []
    for repo_root in repo_roots:
        results = [
            normalize_file(repo_root, relative_path, write=write)
            for relative_path in git_lines(repo_root, ["ls-files"])
            if is_target_text_file(relative_path) and (repo_root / relative_path).is_file()
        ]
        findings = [
            {
                "path": result.path,
                "encoding": result.encoding,
                "targetEncoding": result.target_encoding,
                "reasons": result.reasons,
                "written": result.written,
            }
            for result in results
            if result.changed or result.failed
        ]
        repos.append(
            {
                "name": repo_root.name,
                "repoRoot": str(repo_root),
                "scannedFiles": len(results),
                "normalizationFindings": findings,
                "passed": not findings,
            }
        )
    return {
        "schemaVersion": "source-normalization-summary/v1",
        "workspaceRoot": str(workspace_root),
        "write": write,
        "repos": repos,
        "passed": all(repo["passed"] for repo in repos),
    }


def add_common_args(parser: argparse.ArgumentParser, paths: Any) -> None:
    parser.add_argument("--workspace-root", type=Path, default=paths.workspace_root)
    parser.add_argument("--repo-root", action="append", type=Path)


def selected_repo_roots(parsed: argparse.Namespace, canonical_repo_roots: Callable[[Path], list[Path]]) -> tuple[Path, list[Path]]:
    workspace_root = parsed.workspace_root.resolve()
    repo_roots = [repo.resolve() for repo in parsed.repo_root] if parsed.repo_root else canonical_repo_roots(workspace_root)
    return workspace_root, repo_roots


def run_guard_line_endings(
    paths: Any,
    argv: list[str],
    *,
    canonical_repo_roots: Callable[[Path], list[Path]],
    git_lines: Callable[[Path, list[str]], list[str]],
    write_json: Callable[[Any], None],
) -> dict[str, Any]:
    parser = argparse.ArgumentParser(prog="python -m overlord_tooling guard-line-endings")
    add_common_args(parser, paths)
    parsed = parser.parse_args(argv)
    workspace_root, repo_roots = selected_repo_roots(parsed, canonical_repo_roots)
    summary = source_normalization_summary(workspace_root, repo_roots, git_lines=git_lines, write=False)
    if not summary["passed"]:
        write_json(summary)
        raise SystemExit("Line-ending guard failed")
    return summary


def run_normalize_source(
    paths: Any,
    argv: list[str],
    *,
    canonical_repo_roots: Callable[[Path], list[Path]],
    git_lines: Callable[[Path, list[str]], list[str]],
    write_json: Callable[[Any], None],
) -> dict[str, Any]:
    parser = argparse.ArgumentParser(prog="python -m overlord_tooling normalize-source")
    add_common_args(parser, paths)
    parser.add_argument("--write", action="store_true", help="Rewrite files in place; omit for a dry-run report.")
    parsed = parser.parse_args(argv)
    workspace_root, repo_roots = selected_repo_roots(parsed, canonical_repo_roots)
    return source_normalization_summary(workspace_root, repo_roots, git_lines=git_lines, write=parsed.write)
