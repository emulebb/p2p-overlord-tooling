from __future__ import annotations

import json
import threading
import time
from dataclasses import dataclass
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


@dataclass
class SearchCallbackSession:
    session_dir: Path
    base_url: str
    events_path: Path
    results_path: Path
    _server: ThreadingHTTPServer
    _thread: threading.Thread
    _lock: threading.Lock


def start_search_callback_collector(session_dir: Path) -> SearchCallbackSession:
    session_dir.mkdir(parents=True, exist_ok=True)
    events_path = session_dir / "search-events.jsonl"
    results_path = session_dir / "result-batches.jsonl"
    lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self) -> None:  # noqa: N802 - stdlib handler name
            try:
                content_length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                self.send_error(HTTPStatus.BAD_REQUEST, "invalid content length")
                return
            raw = self.rfile.read(content_length)
            try:
                payload = json.loads(raw.decode("utf-8"))
            except json.JSONDecodeError:
                self.send_error(HTTPStatus.BAD_REQUEST, "invalid json")
                return

            if self.path == "/api/internal/search-events":
                target = events_path
            elif self.path == "/api/internal/results":
                target = results_path
            else:
                self.send_error(HTTPStatus.NOT_FOUND, "unknown callback path")
                return

            with lock:
                with target.open("a", encoding="utf-8", newline="\n") as handle:
                    json.dump(payload, handle)
                    handle.write("\n")

            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b"{}\n")

        def log_message(self, format: str, *args) -> None:  # noqa: A003 - stdlib signature
            return

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, name="search-callback-collector", daemon=True)
    thread.start()
    host, port = server.server_address
    return SearchCallbackSession(
        session_dir=session_dir,
        base_url=f"http://{host}:{port}",
        events_path=events_path,
        results_path=results_path,
        _server=server,
        _thread=thread,
        _lock=lock,
    )


def stop_search_callback_collector(session: SearchCallbackSession) -> None:
    session._server.shutdown()
    session._server.server_close()
    session._thread.join(timeout=5)


def read_search_events(session: SearchCallbackSession) -> list[dict[str, Any]]:
    return _read_jsonl(session.events_path)


def read_result_batches(session: SearchCallbackSession) -> list[dict[str, Any]]:
    return _read_jsonl(session.results_path)


def wait_for_search_event(
    session: SearchCallbackSession,
    *,
    job_id: str,
    status: str,
    timeout_seconds: int,
) -> dict[str, Any]:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        for event in read_search_events(session):
            if str(event.get("job_id")) == job_id and str(event.get("status")) == status:
                return event
        time.sleep(0.25)
    raise TimeoutError(
        f"did not observe search event status={status!r} for job_id={job_id} within {timeout_seconds}s"
    )


def wait_for_result_batch(
    session: SearchCallbackSession,
    *,
    job_id: str,
    timeout_seconds: int,
) -> dict[str, Any]:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        for batch in read_result_batches(session):
            if str(batch.get("job_id")) == job_id:
                return batch
        time.sleep(0.25)
    raise TimeoutError(f"did not observe result batch for job_id={job_id} within {timeout_seconds}s")


def _read_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.is_file():
        return []
    records: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            stripped = line.strip()
            if not stripped:
                continue
            value = json.loads(stripped)
            if isinstance(value, dict):
                records.append(value)
    return records
