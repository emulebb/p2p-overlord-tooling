from __future__ import annotations

import socket
import time
from pathlib import Path


def wait_path(path: Path, *, timeout_seconds: int, poll_seconds: float = 0.25) -> Path:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        if path.exists():
            return path
        time.sleep(poll_seconds)
    raise TimeoutError(f"timed out waiting for path {path}")


def wait_file_size(
    path: Path,
    *,
    expected_size: int,
    timeout_seconds: int,
    poll_seconds: float = 2.0,
) -> Path:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        if path.is_file() and path.stat().st_size == expected_size:
            return path
        time.sleep(poll_seconds)
    observed = path.stat().st_size if path.exists() else None
    raise TimeoutError(f"{path} did not reach {expected_size} bytes; observed={observed}")


def wait_tcp(host: str, port: int, *, timeout_seconds: int) -> None:
    deadline = time.monotonic() + timeout_seconds
    last_error: Exception | None = None
    while time.monotonic() < deadline:
        try:
            with socket.create_connection((host, port), timeout=1):
                return
        except OSError as exc:
            last_error = exc
            time.sleep(0.25)
    raise TimeoutError(f"TCP listener {host}:{port} was not ready") from last_error
