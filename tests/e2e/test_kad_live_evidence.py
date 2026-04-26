from __future__ import annotations

import json
from pathlib import Path

from tests.e2e.lib.kad_live import classify_candidate_terminal_reason, source_acquisition_evidence


def test_source_acquisition_evidence_summarizes_zero_source_live_failure(tmp_path: Path) -> None:
    file_hash = "3cb1cecb844d0c124d3db1c9c6972bca"
    log_path = tmp_path / "overlord-agent-emule.log"
    log_path.write_text(
        "\n".join(
            [
                "connected to ED2K server 145.239.2.134:4661 name=GrupoTS Server trace_id=a role=background",
                "ED2K server message from 145.239.2.134:4661: WARNING : You have a lowid",
                "ED2K source search attempt=1/3 endpoint=145.239.2.134:4661 name=GrupoTS Server "
                f"file_hash={file_hash}",
                "ED2K source search attempt=2/3 endpoint=109.104.154.246:43333 name=Astra-2 "
                f"file_hash={file_hash}",
                "native ED2K download active source acquisition completed "
                f"file_hash={file_hash} source_count=0 aggregated_source_count=0",
                "native ED2K download Kad source fallback returned no sources "
                f"for file_hash={file_hash} aggregated_source_count=0",
                "native ED2K download source acquisition completed "
                f"file_hash={file_hash} aggregated_source_count=0 background_search_enabled=false",
            ]
        )
        + "\n",
        encoding="utf-8",
    )

    evidence = source_acquisition_evidence(log_path, file_hash=file_hash)

    assert evidence["agentLogPresent"] is True
    assert evidence["lowIdWarningObserved"] is True
    assert evidence["serverConnectionCount"] == 1
    assert evidence["sourceSearchAttemptCount"] == 2
    assert evidence["sourceSearchAttemptBudget"] == 3
    assert evidence["sourceSearchEndpoints"] == [
        "145.239.2.134:4661",
        "109.104.154.246:43333",
    ]
    assert evidence["activeSourceSearchObserved"] is True
    assert evidence["activeSourceCount"] == 0
    assert evidence["kadSourceFallbackObserved"] is True
    assert evidence["kadSourceCount"] == 0
    assert evidence["finalAggregatedSourceCount"] == 0
    assert evidence["backgroundSearchEnabled"] is False


def test_source_acquisition_evidence_filters_other_hashes(tmp_path: Path) -> None:
    log_path = tmp_path / "overlord-agent-emule.log"
    log_path.write_text(
        "ED2K source search attempt=1/3 endpoint=145.239.2.134:4661 name=server "
        "file_hash=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n",
        encoding="utf-8",
    )

    evidence = source_acquisition_evidence(
        log_path,
        file_hash="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    )

    assert evidence["sourceSearchAttemptCount"] == 0
    assert evidence["sourceSearchEndpoints"] == []


def test_source_acquisition_evidence_reads_server_getsources_dump(tmp_path: Path) -> None:
    file_hash = "015e857e37b1948f3230566d179af3e4"
    log_path = tmp_path / "overlord-agent-emule.log"
    server_dump_path = tmp_path / "agent-ed2k-server-dump.jsonl"
    log_path.write_text(
        "native ED2K download background source search failed "
        f"for file_hash={file_hash}: timed out waiting for OP_FOUNDSOURCES\n",
        encoding="utf-8",
    )
    server_dump_path.write_text(
        json.dumps(
            {
                "direction": "tx",
                "role": "background",
                "transport": "obfuscated",
                "opcode_name": "OP_GETSOURCES_OBFU",
                "payload_hex": file_hash + "00000000088c4644401000000",
            }
        )
        + "\n",
        encoding="utf-8",
    )

    evidence = source_acquisition_evidence(
        log_path,
        server_dump_path=server_dump_path,
        file_hash=file_hash,
    )

    assert evidence["agentEd2kServerDumpPresent"] is True
    assert evidence["serverGetSourcesRequestCount"] == 1
    assert evidence["serverFoundSourcesResponseCount"] == 0
    assert evidence["serverSourceSearchRoles"] == ["background"]
    assert evidence["serverSourceSearchTransports"] == ["obfuscated"]
    assert evidence["sourceSearchFailureCount"] == 1
    assert evidence["sourceSearchFailures"] == [
        "background: timed out waiting for OP_FOUNDSOURCES"
    ]


def test_source_acquisition_evidence_tracks_direct_attempt_refresh_terminal_reason(tmp_path: Path) -> None:
    file_hash = "372c0a482e8cfa5148f7a98943dc1468"
    log_path = tmp_path / "overlord-agent-emule.log"
    log_path.write_text(
        "\n".join(
            [
                "native ED2K download attempt "
                f"file_hash={file_hash} peer=93.41.146.101:44662 client_id=1 "
                "obfuscated=true has_user_hash=true",
                "native ED2K download peer failed "
                f"file_hash={file_hash} peer=93.41.146.101:44662: "
                "failed to read eD2k packet from 93.41.146.101:44662",
                "native ED2K download source refresh completed "
                f"file_hash={file_hash} requery_round=1 refreshed_source_count=2 "
                "added_source_count=0 aggregated_source_count=2 new_direct_source_count=0",
            ]
        )
        + "\n",
        encoding="utf-8",
    )

    evidence = source_acquisition_evidence(log_path, file_hash=file_hash)

    assert evidence["directDownloadAttemptCount"] == 1
    assert evidence["directDownloadAttemptedEndpointCount"] == 1
    assert evidence["directDownloadFailureCount"] == 1
    assert evidence["sourceRefreshCount"] == 1
    assert evidence["sourceRefreshNewDirectEndpointCount"] == 0
    assert classify_candidate_terminal_reason({"completed": False}, evidence) == (
        "no_progress_repeated_endpoints"
    )


def test_candidate_terminal_reason_classifies_peer_and_source_failures() -> None:
    assert classify_candidate_terminal_reason(
        {"completed": False},
        {
            "directDownloadAttemptedEndpointCount": 1,
            "sourceRefreshCount": 0,
            "sourceRefreshSkipped": False,
            "sourceRefreshNewDirectEndpointCount": 0,
            "directDownloadFailureReasons": ["peer does not serve requested file abc"],
            "sourceSearchFailureCount": 0,
        },
    ) == "peer_not_serving"
    assert classify_candidate_terminal_reason(
        {"completed": False},
        {
            "directDownloadAttemptedEndpointCount": 1,
            "sourceRefreshCount": 0,
            "sourceRefreshSkipped": False,
            "sourceRefreshNewDirectEndpointCount": 0,
            "directDownloadFailureReasons": ["failed to read eD2k packet from peer"],
            "sourceSearchFailureCount": 0,
        },
    ) == "peer_closed_after_hello"
    assert classify_candidate_terminal_reason(
        {"completed": False},
        {
            "directDownloadAttemptedEndpointCount": 0,
            "sourceRefreshCount": 0,
            "sourceRefreshSkipped": False,
            "sourceRefreshNewDirectEndpointCount": 0,
            "directDownloadFailureReasons": [],
            "sourceSearchFailureCount": 1,
        },
    ) == "source_search_timeout"
