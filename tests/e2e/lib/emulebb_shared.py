from __future__ import annotations

import json
import sys
from pathlib import Path

from tests.e2e.lib.paths import WorkspacePaths


EMULEBB_TESTS_REPO_KEY = "tests"
EMULEBB_SEED_CONFIG_RELATIVE = Path("manifests") / "live-profile-seed" / "config"


def resolve_emulebb_tests_root(paths: WorkspacePaths) -> Path:
    """Resolves the shared eMuleBB test-harness repo from workspace topology."""

    workspace = paths.emule_workspace_root
    if workspace is not None:
        deps_path = workspace / "workspaces" / "workspace" / "deps.json"
        if deps_path.is_file():
            deps = json.loads(deps_path.read_text(encoding="utf-8"))
            repo_path = deps.get("workspace", {}).get("repos", {}).get(EMULEBB_TESTS_REPO_KEY)
            if repo_path:
                deps_candidate = (deps_path.parent / str(repo_path)).resolve()
                if deps_candidate.is_dir():
                    return deps_candidate
        workspace_candidate = workspace / "repos" / "emulebb-build-tests"
        if workspace_candidate.is_dir():
            return workspace_candidate.resolve()

    sibling_candidate = paths.tooling_root.parent / "emulebb-build-tests"
    if sibling_candidate.is_dir():
        return sibling_candidate.resolve()
    raise RuntimeError("could not resolve emulebb-build-tests from workspace deps or repo siblings")


def resolve_emulebb_live_profile_seed_config_dir(paths: WorkspacePaths) -> Path:
    """Resolves the shared deterministic eMule live-profile seed config."""

    seed_config_dir = resolve_emulebb_tests_root(paths) / EMULEBB_SEED_CONFIG_RELATIVE
    if not seed_config_dir.is_dir():
        raise RuntimeError(f"eMule live-profile seed config not found at {seed_config_dir}")
    return seed_config_dir


def load_emulebb_live_profiles(paths: WorkspacePaths):
    """Imports the shared profile materialization module from emulebb-build-tests."""

    tests_root = resolve_emulebb_tests_root(paths)
    if str(tests_root) not in sys.path:
        sys.path.insert(0, str(tests_root))
    from emule_test_harness import live_profiles

    return live_profiles
