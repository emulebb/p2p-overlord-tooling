from __future__ import annotations

import shutil
from pathlib import Path


def copy_if_exists(path: Path | None, destination_root: Path) -> Path | None:
    if path is None or not path.exists():
        return None
    destination_root.mkdir(parents=True, exist_ok=True)
    destination = destination_root / path.name
    if path.is_dir():
        if destination.exists():
            shutil.rmtree(destination)
        shutil.copytree(path, destination)
    else:
        shutil.copy2(path, destination)
    return destination


def copy_if_small(path: Path | None, destination_root: Path, *, max_size_bytes: int = 67_108_864) -> Path | None:
    if path is None or not path.is_file() or path.stat().st_size > max_size_bytes:
        return None
    return copy_if_exists(path, destination_root)


def latest_file(root: Path, pattern: str, *, since_timestamp: float | None = None) -> Path | None:
    if not root.exists():
        return None
    candidates = [path for path in root.glob(pattern) if path.is_file()]
    if since_timestamp is not None:
        candidates = [path for path in candidates if path.stat().st_mtime >= since_timestamp]
    if not candidates:
        return None
    return max(candidates, key=lambda path: path.stat().st_mtime)
