from __future__ import annotations

from pathlib import Path

from overlord_tooling.scenarios import load_manifest
from tests.e2e.lib.live_search_terms import (
    CANONICAL_LIVE_WIRE_STRESS_SEARCH_TERMS,
    DEFAULT_LIVE_WIRE_STRESS_SEARCH_TERM,
)
from tests.e2e.lib.paths import WorkspacePaths


def test_canonical_live_wire_stress_search_terms_are_persisted_in_python() -> None:
    assert CANONICAL_LIVE_WIRE_STRESS_SEARCH_TERMS == (
        "linux",
        "ubuntu",
        "fedora",
        "freebsd",
        "debian",
        "emule",
    )
    assert DEFAULT_LIVE_WIRE_STRESS_SEARCH_TERM == "linux"


def test_workspace_policy_lists_python_live_wire_stress_terms() -> None:
    tooling_root = Path(__file__).resolve().parents[2]
    policy = (tooling_root / "docs" / "WORKSPACE_POLICY.md").read_text(encoding="utf-8")

    for term in CANONICAL_LIVE_WIRE_STRESS_SEARCH_TERMS:
        assert f"`{term}`" in policy


def test_live_wire_stress_manifest_uses_canonical_search_terms(
    workspace_paths: WorkspacePaths,
) -> None:
    manifest = load_manifest(
        workspace_paths.tooling_root,
        "ed2k.cell.live-wire.stress.search-download.realnet.v1",
    )

    assert tuple(manifest["stress"]["searchTerms"]) == CANONICAL_LIVE_WIRE_STRESS_SEARCH_TERMS
