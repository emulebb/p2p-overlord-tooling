from __future__ import annotations

from pathlib import Path

from tests.e2e.lib import http
from tests.e2e.lib.search_callbacks import (
    read_result_batches,
    read_search_events,
    start_search_callback_collector,
    stop_search_callback_collector,
    wait_for_result_batch,
    wait_for_search_event,
)


def test_search_callback_collector_records_events_and_results(tmp_path: Path) -> None:
    session = start_search_callback_collector(tmp_path / "callbacks")
    try:
        http.post_json(
            f"{session.base_url}/api/internal/search-events",
            {
                "job_id": "job-1",
                "indexer_id": "idx-1",
                "status": "started",
                "result_count": None,
                "batch_count": None,
                "error": None,
            },
        )
        http.post_json(
            f"{session.base_url}/api/internal/results",
            {
                "job_id": "job-1",
                "indexer_id": "idx-1",
                "protocol": "kad2",
                "files": [{"names": ["ubuntu-linux.iso"], "size": 12345}],
            },
        )

        event = wait_for_search_event(session, job_id="job-1", status="started", timeout_seconds=5)
        batch = wait_for_result_batch(session, job_id="job-1", timeout_seconds=5)

        assert event["indexer_id"] == "idx-1"
        assert batch["protocol"] == "kad2"
        assert batch["files"][0]["names"] == ["ubuntu-linux.iso"]
        assert read_search_events(session) == [event]
        assert read_result_batches(session) == [batch]
    finally:
        stop_search_callback_collector(session)
