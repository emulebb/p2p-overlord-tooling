from __future__ import annotations

from tests.e2e.lib.search_callbacks import select_ed2k_keyword_candidate


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
