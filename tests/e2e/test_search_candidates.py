from __future__ import annotations

from tests.e2e.lib.search_callbacks import (
    ed2k_candidate_source_count,
    select_ed2k_keyword_candidate,
    select_ed2k_keyword_candidates,
)


def test_select_ed2k_keyword_candidate_prefers_query_match_then_smaller_file() -> None:
    candidate = select_ed2k_keyword_candidate(
        [
            {
                "job_id": "job-1",
                "files": [
                    {
                        "hashes": [{"kind": "ed2k", "value": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}],
                        "names": ["random archive.bin"],
                        "size": 2_000_000,
                    },
                    {
                        "hashes": [{"kind": "ed2k", "value": "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"}],
                        "names": ["ubuntu-linux-desktop.iso"],
                        "size": 3_000_000,
                    },
                    {
                        "hashes": [{"kind": "ed2k", "value": "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"}],
                        "names": ["ubuntu-linux-mini.iso"],
                        "size": 1_000_000,
                    },
                ],
            }
        ],
        query="ubuntu linux",
    )

    assert candidate["file_hash"] == "cccccccccccccccccccccccccccccccc"
    assert candidate["file_name"] == "ubuntu-linux-mini.iso"
    assert candidate["file_size"] == 1_000_000


def test_select_ed2k_keyword_candidate_prefers_higher_source_count() -> None:
    candidate = select_ed2k_keyword_candidate(
        [
            {
                "job_id": "job-1",
                "files": [
                    {
                        "hashes": [{"kind": "ed2k", "value": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}],
                        "names": ["ubuntu-linux-small.mp4"],
                        "size": 700_000,
                        "sources": [
                            {
                                "protocol": "kad2",
                                "address": "127.0.0.1:41000",
                                "extra": {"source_count": 1},
                            }
                        ],
                    },
                    {
                        "hashes": [{"kind": "ed2k", "value": "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"}],
                        "names": ["ubuntu-linux-guide.pdf"],
                        "size": 120_000_000,
                        "sources": [
                            {
                                "protocol": "kad2",
                                "address": "127.0.0.1:41000",
                                "extra": {"source_count": 6},
                            }
                        ],
                    },
                ],
            }
        ],
        query="ubuntu linux",
    )

    assert candidate["file_hash"] == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    assert ed2k_candidate_source_count(candidate) == 6


def test_select_ed2k_keyword_candidate_applies_live_size_and_source_policy() -> None:
    candidate = select_ed2k_keyword_candidate(
        [
            {
                "job_id": "job-1",
                "files": [
                    {
                        "hashes": [{"kind": "ed2k", "value": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}],
                        "names": ["ubuntu-linux-large.iso"],
                        "size": 700_000_000,
                        "sources": [{"extra": {"source_count": 8}}],
                    },
                    {
                        "hashes": [{"kind": "ed2k", "value": "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"}],
                        "names": ["ubuntu linux manual.pdf"],
                        "size": 20_000_000,
                        "sources": [{"extra": {"source_count": 3}}],
                    },
                    {
                        "hashes": [{"kind": "ed2k", "value": "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"}],
                        "names": ["ubuntu linux stale.txt"],
                        "size": 2_000_000,
                        "sources": [{"extra": {"source_count": 1}}],
                    },
                ],
            }
        ],
        query="ubuntu linux",
        min_source_count=1,
        max_file_size=100_000_000,
    )

    assert candidate["file_hash"] == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"


def test_select_ed2k_keyword_candidates_applies_deny_hashes_and_limit() -> None:
    candidates = select_ed2k_keyword_candidates(
        [
            {
                "job_id": "job-1",
                "files": [
                    {
                        "hashes": [{"kind": "ed2k", "value": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}],
                        "names": ["ubuntu linux unsafe.pdf"],
                        "size": 20_000_000,
                        "sources": [{"extra": {"source_count": 4}}],
                    },
                    {
                        "hashes": [{"kind": "ed2k", "value": "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"}],
                        "names": ["ubuntu linux lesson.mp4"],
                        "size": 30_000_000,
                        "sources": [{"extra": {"source_count": 3}}],
                    },
                    {
                        "hashes": [{"kind": "ed2k", "value": "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"}],
                        "names": ["ubuntu linux lab.mp4"],
                        "size": 40_000_000,
                        "sources": [{"extra": {"source_count": 2}}],
                    },
                ],
            }
        ],
        query="ubuntu linux",
        min_source_count=1,
        deny_hashes={"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
        limit=2,
    )

    assert [candidate["file_hash"] for candidate in candidates] == [
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "cccccccccccccccccccccccccccccccc",
    ]


def test_select_ed2k_keyword_candidate_rejects_unsafe_live_names() -> None:
    candidate = select_ed2k_keyword_candidate(
        [
            {
                "job_id": "job-1",
                "files": [
                    {
                        "hashes": [{"kind": "ed2k", "value": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}],
                        "names": ["ubuntu linux preteen bait.pdf"],
                        "size": 1_000,
                        "sources": [{"extra": {"source_count": 9}}],
                    },
                    {
                        "hashes": [{"kind": "ed2k", "value": "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"}],
                        "names": ["ubuntu linux admin guide.pdf"],
                        "size": 2_000,
                        "sources": [{"extra": {"source_count": 1}}],
                    },
                ],
            }
        ],
        query="ubuntu linux",
    )

    assert candidate["file_hash"] == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
