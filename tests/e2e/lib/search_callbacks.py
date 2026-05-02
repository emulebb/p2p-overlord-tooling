from __future__ import annotations

import json
import threading
import time
from dataclasses import dataclass
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

UNSAFE_LIVE_NAME_TOKENS = (
    "preteen",
    "underage",
    "child porn",
    "lolita",
    "school girls",
    "rape",
    "13 yrs",
    "12 yrs",
    "11 yrs",
    "10 yrs",
)


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


def wait_for_search_terminal_event(
    session: SearchCallbackSession,
    *,
    job_id: str,
    timeout_seconds: int,
) -> dict[str, Any]:
    terminal_statuses = {"completed", "failed", "cancelled"}
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        for event in read_search_events(session):
            if str(event.get("job_id")) != job_id:
                continue
            if str(event.get("status")) in terminal_statuses:
                return event
        time.sleep(0.25)
    raise TimeoutError(
        f"did not observe terminal search event for job_id={job_id} within {timeout_seconds}s"
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


def select_ed2k_keyword_candidate(
    batches: list[dict[str, Any]],
    *,
    query: str,
    min_source_count: int = 0,
    max_file_size: int | None = None,
    deny_hashes: set[str] | None = None,
) -> dict[str, Any]:
    return select_ed2k_keyword_candidates(
        batches,
        query=query,
        min_source_count=min_source_count,
        max_file_size=max_file_size,
        deny_hashes=deny_hashes,
        limit=1,
    )[0]


def select_ed2k_keyword_candidates(
    batches: list[dict[str, Any]],
    *,
    query: str,
    min_source_count: int = 0,
    max_file_size: int | None = None,
    deny_hashes: set[str] | None = None,
    limit: int = 1,
) -> list[dict[str, Any]]:
    tokens = [token.lower() for token in query.split() if len(token) >= 3]
    deny_hashes = {value.lower() for value in deny_hashes or set()}
    candidates: list[tuple[tuple[int, int, int, int, str], dict[str, Any]]] = []
    for batch in batches:
        for file_record in batch.get("files", []):
            if not isinstance(file_record, dict):
                continue
            file_hash = _ed2k_hash(file_record)
            file_name = _first_name(file_record)
            file_size = _file_size(file_record)
            if file_hash is None or file_name is None or file_size is None or file_size <= 0:
                continue
            if file_hash in deny_hashes:
                continue
            if is_unsafe_live_candidate_name(file_name):
                continue
            if max_file_size is not None and file_size > max_file_size:
                continue
            lower_name = file_name.lower()
            matched_tokens = sum(1 for token in tokens if token in lower_name)
            source_count = _source_count(file_record)
            if source_count < min_source_count:
                continue
            preferred_extension = int(lower_name.endswith((".iso", ".bin", ".mp4", ".mkv", ".avi")))
            score = (
                -matched_tokens,
                -source_count,
                -preferred_extension,
                file_size,
                lower_name,
            )
            candidates.append(
                (
                    score,
                    {
                        "file_hash": file_hash,
                        "file_name": file_name,
                        "file_size": file_size,
                        "file_record": file_record,
                    },
                )
            )
    if not candidates:
        raise ValueError(f"did not find a usable ED2K candidate for query {query!r}")
    candidates.sort(key=lambda item: item[0])
    return [candidate for _, candidate in candidates[: max(1, limit)]]


def ed2k_candidate_source_count(candidate: dict[str, Any]) -> int:
    file_record = candidate.get("file_record")
    if not isinstance(file_record, dict):
        return 0
    return _source_count(file_record)


def is_unsafe_live_candidate_name(name: object) -> bool:
    lower_name = str(name or "").lower()
    return any(token in lower_name for token in UNSAFE_LIVE_NAME_TOKENS)


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


def _ed2k_hash(file_record: dict[str, Any]) -> str | None:
    for hash_entry in file_record.get("hashes", []):
        if not isinstance(hash_entry, dict):
            continue
        if hash_entry.get("kind") != "ed2k":
            continue
        value = hash_entry.get("value")
        return str(value).lower() if value else None
    return None


def _first_name(file_record: dict[str, Any]) -> str | None:
    names = file_record.get("names")
    if not isinstance(names, list) or not names:
        return None
    value = names[0]
    return str(value) if value else None


def _file_size(file_record: dict[str, Any]) -> int | None:
    value = file_record.get("size")
    if value is None:
        return None
    return int(value)


def _source_count(file_record: dict[str, Any]) -> int:
    source_counts: list[int] = []
    for source in file_record.get("sources", []):
        if not isinstance(source, dict):
            continue
        extra = source.get("extra")
        if not isinstance(extra, dict):
            continue
        value = extra.get("source_count")
        if value is not None:
            source_counts.append(int(value))
    return max(source_counts, default=0)
