from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from tests.e2e.lib.paths import WorkspacePaths


@dataclass(frozen=True)
class EmuleHarnessSeedBundle:
    bundle_id: str
    seed_root: Path
    manifest_path: Path
    nodes_dat_path: Path
    server_met_path: Path
    manifest: dict[str, Any]


def resolve_emule_harness_seed_bundle(
    paths: WorkspacePaths,
    *,
    bundle_id: str = "canonical",
) -> EmuleHarnessSeedBundle:
    seed_root = paths.tooling_root / ".local" / "emule-harness-seeds" / bundle_id
    manifest_path = seed_root / "seed-bundle.json"
    nodes_dat_path = seed_root / "nodes.dat"
    server_met_path = seed_root / "server.met"

    if not manifest_path.is_file():
        raise FileNotFoundError(f"seed bundle manifest not found at {manifest_path}")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("bundleId") != bundle_id:
        raise ValueError(f"seed bundle manifest {manifest_path} has bundleId={manifest.get('bundleId')!r}")
    if not nodes_dat_path.is_file():
        raise FileNotFoundError(f"seed bundle nodes.dat not found at {nodes_dat_path}")
    if not server_met_path.is_file():
        raise FileNotFoundError(f"seed bundle server.met not found at {server_met_path}")

    return EmuleHarnessSeedBundle(
        bundle_id=bundle_id,
        seed_root=seed_root,
        manifest_path=manifest_path,
        nodes_dat_path=nodes_dat_path,
        server_met_path=server_met_path,
        manifest=manifest,
    )
