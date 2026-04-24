from __future__ import annotations

from pathlib import Path

import pytest

from tests.e2e.lib.live_seeds import resolve_emule_harness_seed_bundle
from tests.e2e.lib.paths import WorkspacePaths


def test_resolve_emule_harness_seed_bundle_reads_manifest_and_files(tmp_path: Path) -> None:
    tooling_root = tmp_path / "tooling"
    seed_root = tooling_root / ".local" / "emule-harness-seeds" / "canonical"
    seed_root.mkdir(parents=True, exist_ok=True)
    (seed_root / "nodes.dat").write_bytes(b"nodes")
    (seed_root / "server.met").write_bytes(b"server")
    (seed_root / "seed-bundle.json").write_text(
        '{\n  "schemaVersion": "emule-harness-seed-bundle/v1",\n  "bundleId": "canonical"\n}\n',
        encoding="utf-8",
        newline="\n",
    )

    bundle = resolve_emule_harness_seed_bundle(
        WorkspacePaths(
            project_root=tmp_path,
            tooling_root=tooling_root,
            agents_root=tmp_path / "agents",
            be_root=tmp_path / "be",
            tmp_dir=tmp_path / "tmp",
            log_dir=tmp_path / "logs",
            emule_workspace_root=None,
        )
    )

    assert bundle.bundle_id == "canonical"
    assert bundle.nodes_dat_path == seed_root / "nodes.dat"
    assert bundle.server_met_path == seed_root / "server.met"
    assert bundle.manifest["bundleId"] == "canonical"


def test_resolve_emule_harness_seed_bundle_rejects_mismatched_bundle_id(tmp_path: Path) -> None:
    tooling_root = tmp_path / "tooling"
    seed_root = tooling_root / ".local" / "emule-harness-seeds" / "canonical"
    seed_root.mkdir(parents=True, exist_ok=True)
    (seed_root / "nodes.dat").write_bytes(b"nodes")
    (seed_root / "server.met").write_bytes(b"server")
    (seed_root / "seed-bundle.json").write_text(
        '{\n  "schemaVersion": "emule-harness-seed-bundle/v1",\n  "bundleId": "not-canonical"\n}\n',
        encoding="utf-8",
        newline="\n",
    )

    paths = WorkspacePaths(
        project_root=tmp_path,
        tooling_root=tooling_root,
        agents_root=tmp_path / "agents",
        be_root=tmp_path / "be",
        tmp_dir=tmp_path / "tmp",
        log_dir=tmp_path / "logs",
        emule_workspace_root=None,
    )

    with pytest.raises(ValueError, match="bundleId"):
        resolve_emule_harness_seed_bundle(paths)
