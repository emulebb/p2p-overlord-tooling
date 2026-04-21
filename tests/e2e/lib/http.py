from __future__ import annotations

import json
import time
import urllib.error
import urllib.request
from typing import Any, Mapping


def get_json(url: str, *, headers: Mapping[str, str] | None = None, timeout: int = 10) -> Any:
    request = urllib.request.Request(url, headers=dict(headers or {}), method="GET")
    with urllib.request.urlopen(request, timeout=timeout) as response:
        body = response.read().decode("utf-8")
    return json.loads(body) if body.strip() else None


def post_json(
    url: str,
    payload: Any,
    *,
    headers: Mapping[str, str] | None = None,
    timeout: int = 30,
) -> Any:
    merged_headers = {"Content-Type": "application/json", **dict(headers or {})}
    request = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers=merged_headers,
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = response.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"POST {url} failed with HTTP {exc.code}: {body}") from exc
    return json.loads(body) if body.strip() else None


def wait_json(url: str, *, timeout_seconds: int, poll_seconds: float = 1.0) -> Any:
    deadline = time.monotonic() + timeout_seconds
    last_error: Exception | None = None
    while time.monotonic() < deadline:
        try:
            return get_json(url, timeout=10)
        except Exception as exc:  # noqa: BLE001 - readiness polling records any failure.
            last_error = exc
            time.sleep(poll_seconds)
    raise TimeoutError(f"{url} did not return JSON within {timeout_seconds}s") from last_error
