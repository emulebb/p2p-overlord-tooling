from __future__ import annotations

import os
import tempfile
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class WorkspacePaths:
    project_root: Path
    tooling_root: Path
    agents_root: Path
    be_root: Path
    tmp_dir: Path
    log_dir: Path
    emule_workspace_root: Path | None

    @classmethod
    def discover(cls) -> "WorkspacePaths":
        tooling_root = _find_tooling_root(Path(__file__).resolve())
        project_root = Path(os.environ.get("OVERLORD_PROJECT_DIR", tooling_root.parent)).resolve()
        tmp_dir = Path(os.environ.get("OVERLORD_TMP_DIR", Path(tempfile.gettempdir()) / "p2p-overlord")).resolve()
        log_dir = Path(os.environ.get("OVERLORD_LOG_DIR", tmp_dir / "logs")).resolve()
        emule_workspace = os.environ.get("EMULE_WORKSPACE_ROOT")

        return cls(
            project_root=project_root,
            tooling_root=tooling_root,
            agents_root=project_root / "p2p-overlord-agents",
            be_root=project_root / "p2p-overlord-be",
            tmp_dir=tmp_dir,
            log_dir=log_dir,
            emule_workspace_root=Path(emule_workspace).resolve() if emule_workspace else None,
        )

    @property
    def ed2k_server_root(self) -> Path:
        return self.project_root / "p2p-overlord-ed2k-server"

    def require_emule_workspace(self) -> Path:
        if self.emule_workspace_root is None:
            raise RuntimeError("EMULE_WORKSPACE_ROOT is not set")
        return self.emule_workspace_root

    def run_root(self, scenario_id: str, run_id: str) -> Path:
        return self.tmp_dir / "overlord-tooling" / "runs" / scenario_id / run_id


def _find_tooling_root(start: Path) -> Path:
    for parent in [start, *start.parents]:
        if (parent / "pyproject.toml").is_file() and (parent / "overlord_tooling").is_dir():
            return parent
    raise RuntimeError(f"Could not find p2p-overlord-tooling root from {start}")
