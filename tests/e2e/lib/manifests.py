from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from tests.e2e.lib.paths import WorkspacePaths


def load_manifest(paths: WorkspacePaths, scenario_id: str) -> dict[str, Any]:
    path = paths.tooling_root / "scenarios" / scenario_id / "manifest.v1.json"
    with path.open("r", encoding="utf-8") as handle:
        manifest = json.load(handle)
    if manifest.get("scenarioId") != scenario_id:
        raise ValueError(f"manifest {path} has scenarioId={manifest.get('scenarioId')!r}")
    return manifest


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        json.dump(payload, handle, indent=2)
        handle.write("\n")
