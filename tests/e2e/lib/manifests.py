from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from tests.e2e.lib.paths import WorkspacePaths


def manifest_path(paths: WorkspacePaths, scenario_id: str) -> Path:
    return paths.tooling_root / "scenarios" / scenario_id / "manifest.v1.json"


def load_manifest(paths: WorkspacePaths, scenario_id: str) -> dict[str, Any]:
    path = manifest_path(paths, scenario_id)
    with path.open("r", encoding="utf-8") as handle:
        manifest = json.load(handle)
    if manifest.get("scenarioId") != scenario_id:
        raise ValueError(f"manifest {path} has scenarioId={manifest.get('scenarioId')!r}")
    return manifest


def iter_manifests(
    paths: WorkspacePaths,
    *,
    protocol: str | None = None,
    tier: str | None = None,
    scenario_kind: str | None = None,
    availability: str | None = None,
) -> list[dict[str, Any]]:
    manifests: list[dict[str, Any]] = []
    for scenario_dir in sorted((paths.tooling_root / "scenarios").iterdir()):
        path = scenario_dir / "manifest.v1.json"
        if not path.is_file():
            continue
        with path.open("r", encoding="utf-8") as handle:
            manifest = json.load(handle)
        if manifest.get("scenarioId") != scenario_dir.name:
            raise ValueError(f"manifest {path} has scenarioId={manifest.get('scenarioId')!r}")
        if protocol is not None and manifest.get("protocol") != protocol:
            continue
        if tier is not None and manifest.get("tier") != tier:
            continue
        if scenario_kind is not None and manifest.get("scenarioKind") != scenario_kind:
            continue
        if availability is not None and manifest_availability(manifest) != availability:
            continue
        manifests.append(manifest)
    return manifests


def manifest_availability(manifest: dict[str, Any]) -> str | None:
    scenario_kind = manifest.get("scenarioKind")
    if scenario_kind == "campaign":
        campaign = manifest.get("campaign")
        if isinstance(campaign, dict):
            value = campaign.get("availability")
            return str(value) if value is not None else None

    parity = manifest.get("parity")
    if isinstance(parity, dict):
        value = parity.get("availability")
        return str(value) if value is not None else None

    return None


def load_manifest_inventory(
    paths: WorkspacePaths,
    *,
    protocol: str | None = None,
    tier: str | None = None,
    scenario_kind: str | None = None,
    availability: str | None = None,
) -> list[dict[str, Any]]:
    return iter_manifests(
        paths,
        protocol=protocol,
        tier=tier,
        scenario_kind=scenario_kind,
        availability=availability,
    )


def load_manifest_ids(
    paths: WorkspacePaths,
    *,
    protocol: str | None = None,
    tier: str | None = None,
    scenario_kind: str | None = None,
    availability: str | None = None,
) -> list[str]:
    return [
        str(manifest["scenarioId"])
        for manifest in iter_manifests(
            paths,
            protocol=protocol,
            tier=tier,
            scenario_kind=scenario_kind,
            availability=availability,
        )
    ]


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        json.dump(payload, handle, indent=2)
        handle.write("\n")
