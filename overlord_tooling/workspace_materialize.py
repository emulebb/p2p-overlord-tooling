from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any


ORG = "p2p-overlord"
ED2K_LEGACY_PATH = Path("ext-deps") / "goed2k-server"


@dataclass(frozen=True)
class ManagedRepo:
    name: str
    branch: str

    @property
    def url(self) -> str:
        return f"https://github.com/{ORG}/{self.name}.git"


MANAGED_REPOS = (
    ManagedRepo("p2p-overlord-tooling", "develop"),
    ManagedRepo("p2p-overlord-agents", "develop"),
    ManagedRepo("p2p-overlord-be", "develop"),
    ManagedRepo("p2p-overlord-ed2k-server", "master"),
)


def default_tmp_dir() -> Path:
    return Path(os.environ.get("OVERLORD_TMP_DIR", Path(tempfile.gettempdir()) / "p2p-overlord")).resolve()


def default_log_dir(tmp_dir: Path) -> Path:
    return Path(os.environ.get("OVERLORD_LOG_DIR", tmp_dir / "logs")).resolve()


def materialize_workspace(
    workspace_root: Path,
    *,
    persist_environment: bool,
    include_clone: bool = True,
) -> dict[str, Any]:
    root = workspace_root.resolve()
    root.mkdir(parents=True, exist_ok=True)
    tmp_dir = default_tmp_dir()
    log_dir = default_log_dir(tmp_dir)
    tmp_dir.mkdir(parents=True, exist_ok=True)
    log_dir.mkdir(parents=True, exist_ok=True)

    repos = []
    migrate_legacy_ed2k_server(root)
    for repo in MANAGED_REPOS:
        repo_path = root / repo.name
        repos.append(ensure_repo(root, repo, repo_path, include_clone=include_clone))

    env = {
        "OVERLORD_PROJECT_DIR": str(root),
        "OVERLORD_TMP_DIR": str(tmp_dir),
        "OVERLORD_LOG_DIR": str(log_dir),
    }
    set_process_environment(env)
    if persist_environment:
        persist_user_environment(env)
    return {
        "schemaVersion": "overlord-workspace-materialize-summary/v1",
        "workspaceRoot": str(root),
        "environment": {name: {"value": value, "persisted": persist_environment} for name, value in env.items()},
        "repos": repos,
    }


def sync_workspace(workspace_root: Path) -> dict[str, Any]:
    root = workspace_root.resolve()
    migrate_legacy_ed2k_server(root)
    repos = [
        ensure_repo(root, repo, root / repo.name, include_clone=True)
        for repo in MANAGED_REPOS
    ]
    return {
        "schemaVersion": "overlord-workspace-sync-summary/v1",
        "workspaceRoot": str(root),
        "repos": repos,
    }


def validate_workspace(workspace_root: Path) -> dict[str, Any]:
    root = workspace_root.resolve()
    tmp_dir = default_tmp_dir()
    log_dir = default_log_dir(tmp_dir)
    return {
        "schemaVersion": "overlord-workspace-validation-summary/v1",
        "workspaceRoot": str(root),
        "environment": {
            "OVERLORD_PROJECT_DIR": env_status("OVERLORD_PROJECT_DIR", str(root)),
            "OVERLORD_TMP_DIR": env_status("OVERLORD_TMP_DIR", str(tmp_dir)),
            "OVERLORD_LOG_DIR": env_status("OVERLORD_LOG_DIR", str(log_dir)),
            "EMULE_WORKSPACE_ROOT": {
                "present": bool(os.environ.get("EMULE_WORKSPACE_ROOT")),
                "value": os.environ.get("EMULE_WORKSPACE_ROOT"),
                "requiredFor": "emule-harness scenarios",
            },
        },
        "tools": {
            "git": tool_status("git"),
            "gh": tool_status("gh"),
            "go": tool_status("go"),
            "cargo": tool_status("cargo"),
            "npm": tool_status("npm"),
            "python": tool_status(sys.executable),
        },
        "repos": [repo_validation(root, repo) for repo in MANAGED_REPOS],
    }


def handle_materialize(default_workspace_root: Path, argv: list[str]) -> dict[str, Any]:
    import argparse

    parser = argparse.ArgumentParser(prog="python -m overlord_tooling materialize")
    parser.add_argument("--workspace-root", type=Path, default=default_workspace_root)
    parser.add_argument("--no-persist-env", action="store_true", help="Set only this process environment")
    parsed = parser.parse_args(argv)
    return materialize_workspace(
        parsed.workspace_root,
        persist_environment=not parsed.no_persist_env,
        include_clone=True,
    )


def handle_sync(default_workspace_root: Path, argv: list[str]) -> dict[str, Any]:
    import argparse

    parser = argparse.ArgumentParser(prog="python -m overlord_tooling sync")
    parser.add_argument("--workspace-root", type=Path, default=default_workspace_root)
    parsed = parser.parse_args(argv)
    return sync_workspace(parsed.workspace_root)


def handle_validate(default_workspace_root: Path, argv: list[str]) -> dict[str, Any]:
    import argparse

    parser = argparse.ArgumentParser(prog="python -m overlord_tooling validate")
    parser.add_argument("--workspace-root", type=Path, default=default_workspace_root)
    parsed = parser.parse_args(argv)
    return validate_workspace(parsed.workspace_root)


def ensure_repo(root: Path, repo: ManagedRepo, repo_path: Path, *, include_clone: bool) -> dict[str, Any]:
    if not repo_path.exists():
        if not include_clone:
            return repo_summary(repo, repo_path, action="missing")
        run(["git", "clone", "--branch", repo.branch, repo.url, str(repo_path)], cwd=root)
        return repo_summary(repo, repo_path, action="cloned")
    if not (repo_path / ".git").exists():
        raise RuntimeError(f"Canonical repo path exists but is not a Git checkout: {repo_path}")

    current_url = git(repo_path, ["remote", "get-url", "origin"], allow_failure=True).strip()
    if current_url != repo.url:
        run(["git", "remote", "set-url", "origin", repo.url], cwd=repo_path)
    run(["git", "fetch", "origin", "--prune"], cwd=repo_path)
    ensure_branch(repo_path, repo)
    return repo_summary(repo, repo_path, action="ready")


def ensure_branch(repo_path: Path, repo: ManagedRepo) -> None:
    current = git(repo_path, ["branch", "--show-current"], allow_failure=True).strip()
    if current == repo.branch:
        return
    if git(repo_path, ["status", "--short"], allow_failure=False).strip():
        raise RuntimeError(
            f"Refusing to switch dirty repo '{repo.name}' from '{current}' to '{repo.branch}'."
        )
    local_exists = ref_exists(repo_path, f"refs/heads/{repo.branch}")
    if local_exists:
        run(["git", "switch", repo.branch], cwd=repo_path)
    else:
        run(["git", "switch", "--track", f"origin/{repo.branch}"], cwd=repo_path)


def ref_exists(repo_path: Path, ref: str) -> bool:
    result = subprocess.run(
        ["git", "show-ref", "--verify", "--quiet", ref],
        cwd=repo_path,
        check=False,
    )
    return result.returncode == 0


def migrate_legacy_ed2k_server(root: Path) -> None:
    legacy = root / ED2K_LEGACY_PATH
    canonical = root / "p2p-overlord-ed2k-server"
    if canonical.exists() or not legacy.exists():
        return
    if git(legacy, ["status", "--short"], allow_failure=False).strip():
        raise RuntimeError(f"Refusing to move dirty legacy ED2K server checkout: {legacy}")
    canonical.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(legacy), str(canonical))


def repo_validation(root: Path, repo: ManagedRepo) -> dict[str, Any]:
    repo_path = root / repo.name
    if not (repo_path / ".git").is_dir():
        return {
            "name": repo.name,
            "path": str(repo_path),
            "exists": repo_path.exists(),
            "gitCheckout": False,
            "passed": False,
        }
    origin = git(repo_path, ["remote", "get-url", "origin"], allow_failure=True).strip()
    branch = git(repo_path, ["branch", "--show-current"], allow_failure=True).strip()
    head = git(repo_path, ["rev-parse", "--short", "HEAD"], allow_failure=True).strip()
    return {
        "name": repo.name,
        "path": str(repo_path),
        "exists": True,
        "gitCheckout": True,
        "origin": origin,
        "expectedOrigin": repo.url,
        "branch": branch,
        "expectedBranch": repo.branch,
        "head": head,
        "passed": origin == repo.url and bool(head),
    }


def repo_summary(repo: ManagedRepo, repo_path: Path, *, action: str) -> dict[str, Any]:
    branch = git(repo_path, ["branch", "--show-current"], allow_failure=True).strip() if repo_path.exists() else ""
    origin = git(repo_path, ["remote", "get-url", "origin"], allow_failure=True).strip() if repo_path.exists() else ""
    return {
        "name": repo.name,
        "path": str(repo_path),
        "action": action,
        "origin": origin,
        "expectedOrigin": repo.url,
        "branch": branch,
        "expectedBranch": repo.branch,
    }


def env_status(name: str, expected: str) -> dict[str, Any]:
    value = os.environ.get(name)
    if value and os.name == "nt":
        matches = os.path.normcase(value) == os.path.normcase(expected)
    else:
        matches = value == expected
    return {"present": bool(value), "value": value, "expected": expected, "matchesExpected": matches}


def tool_status(name: str) -> dict[str, Any]:
    resolved = shutil.which(name) if name != sys.executable else sys.executable
    return {"present": bool(resolved), "path": resolved}


def set_process_environment(values: dict[str, str]) -> None:
    for name, value in values.items():
        os.environ[name] = value


def persist_user_environment(values: dict[str, str]) -> None:
    if sys.platform != "win32":
        return
    import winreg

    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment", 0, winreg.KEY_SET_VALUE) as key:
        for name, value in values.items():
            winreg.SetValueEx(key, name, 0, winreg.REG_EXPAND_SZ, value)


def git(repo_path: Path, args: list[str], *, allow_failure: bool) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=repo_path,
        check=False,
        capture_output=True,
        encoding="utf-8",
        errors="replace",
        text=True,
    )
    if result.returncode and not allow_failure:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip())
    return result.stdout


def run(command: list[str], *, cwd: Path) -> None:
    result = subprocess.run(
        command,
        cwd=cwd,
        check=False,
        capture_output=True,
        encoding="utf-8",
        errors="replace",
        text=True,
    )
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip())
