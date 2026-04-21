from __future__ import annotations

from pathlib import Path


def write_deterministic_binary(path: Path, *, size_bytes: int, pattern: str) -> Path:
    if size_bytes < 0:
        raise ValueError("size_bytes must be non-negative")
    pattern_bytes = pattern.encode("ascii")
    if not pattern_bytes:
        raise ValueError("pattern must not be empty")

    path.parent.mkdir(parents=True, exist_ok=True)
    tile_size = max(len(pattern_bytes), min(1024 * 1024, max(size_bytes, 1)))
    tile = bytearray(tile_size)
    offset = 0
    while offset < tile_size:
        chunk = min(len(pattern_bytes), tile_size - offset)
        tile[offset : offset + chunk] = pattern_bytes[:chunk]
        offset += chunk

    remaining = size_bytes
    with path.open("wb") as handle:
        while remaining:
            chunk = min(remaining, len(tile))
            handle.write(tile[:chunk])
            remaining -= chunk
    return path
