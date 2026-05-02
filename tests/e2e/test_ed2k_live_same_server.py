from __future__ import annotations

from pathlib import Path

from tests.e2e.lib.ed2k_live_same_server import (
    extract_harness_server_evidence,
    prioritized_live_server_entries,
    summarize_same_server_source_discovery,
)
from tests.e2e.lib.emule_harness import EmuleSession
from tests.e2e.lib.live_runtime import LiveScenarioPrerequisites
from tests.e2e.lib.live_servers import LiveEd2kServerEntry
from tests.e2e.lib.live_network import LiveInterfaceBinding
from tests.e2e.lib.live_seeds import EmuleHarnessSeedBundle


def test_extract_harness_server_evidence_prefers_established_login(tmp_path: Path) -> None:
    session = _emule_session(tmp_path)
    (tmp_path / "logs" / "eMule.log").write_text(
        "\n".join(
            [
                "02/05/2026 15:43:18: Connected to eMule Security (45.82.80.155:5687), sending login request",
                "02/05/2026 15:43:19: Connected to Gaal (185.237.185.226:31031), sending login request",
                "02/05/2026 15:43:27: Connection established on: eMule Security (45.82.80.155:5687)",
            ]
        )
        + "\n",
        encoding="utf-8",
        newline="\n",
    )

    established, connected = extract_harness_server_evidence(session)

    assert established == {
        "endpoint": "45.82.80.155:5687",
        "host": "45.82.80.155",
        "port": 5687,
        "name": "eMule Security",
        "evidenceSource": "harness_log",
        "confidence": "login_established",
    }
    assert connected["endpoint"] == "185.237.185.226:31031"


def test_extract_harness_server_evidence_reads_utf16_harness_log(tmp_path: Path) -> None:
    session = _emule_session(tmp_path)
    (tmp_path / "logs" / "eMule.log").write_text(
        "02/05/2026 18:30:12: Connection established on: eMule Security (45.82.80.155:5687)\n",
        encoding="utf-16",
        newline="\n",
    )

    established, connected = extract_harness_server_evidence(session)

    assert established["endpoint"] == "45.82.80.155:5687"
    assert connected is None


def test_prioritized_live_server_entries_moves_harness_server_to_front(tmp_path: Path) -> None:
    seed_bundle = _seed_bundle(tmp_path)
    prerequisites = _prerequisites(
        seed_bundle,
        [
            LiveEd2kServerEntry(host="1.1.1.1", port=4661, name="first"),
            LiveEd2kServerEntry(host="2.2.2.2", port=4662, name="second"),
        ],
    )

    entries = prioritized_live_server_entries(
        prerequisites,
        {"host": "2.2.2.2", "port": 4662, "name": "second"},
    )

    assert [entry.host for entry in entries] == ["2.2.2.2", "1.1.1.1"]


def test_prioritized_live_server_entries_recovers_match_outside_manifest_budget(
    tmp_path: Path,
) -> None:
    seed_bundle = _seed_bundle(
        tmp_path,
        server_met_entries=[
            LiveEd2kServerEntry(host="1.1.1.1", port=4661, name="selected"),
            LiveEd2kServerEntry(host="3.3.3.3", port=4663, name="outside"),
        ],
    )
    prerequisites = _prerequisites(
        seed_bundle,
        [LiveEd2kServerEntry(host="1.1.1.1", port=4661, name="selected")],
    )

    entries = prioritized_live_server_entries(
        prerequisites,
        {"host": "3.3.3.3", "port": 4663, "name": "outside"},
    )

    assert entries[0] == LiveEd2kServerEntry(host="3.3.3.3", port=4663, name="outside")
    assert entries[1].host == "1.1.1.1"


def test_same_server_source_discovery_summarizes_no_sources(tmp_path: Path) -> None:
    agent = _agent_session(tmp_path)
    file_hash = "f240c17db2eeedbbf6fa1592fb6fa01a"
    agent.agent_log_path.write_text(
        "\n".join(
            [
                f"INFO sent ED2K background source search file_hash={file_hash} endpoint=45.82.80.155:5687 trace_id=1",
                f"INFO native ED2K download source acquisition completed file_hash={file_hash} aggregated_source_count=0 background_search_enabled=false",
            ]
        )
        + "\n",
        encoding="utf-8",
        newline="\n",
    )

    summary = summarize_same_server_source_discovery(
        agent,
        _run(tmp_path),
        file_hash=file_hash,
        connected_server={"endpoint": "45.82.80.155:5687", "host": "45.82.80.155", "port": 5687},
    )

    assert summary["status"] == "no_sources"
    assert summary["sameServerSearchAttempted"] is True
    assert summary["foundSourceCount"] == 0


def test_same_server_source_discovery_summarizes_found_sources_from_manifest(
    tmp_path: Path,
) -> None:
    agent = _agent_session(tmp_path)
    file_hash = "f240c17db2eeedbbf6fa1592fb6fa01a"
    manifest = agent.transfer_root / file_hash / "resume-manifest.json"
    manifest.parent.mkdir(parents=True)
    manifest.write_text('{"sources":[{"ip":"10.0.0.1"},{"ip":"10.0.0.2"}]}\n', encoding="utf-8")
    agent.agent_log_path.write_text(
        f"INFO ED2K source search attempt=1/3 endpoint=45.82.80.155:5687 name=eMule Security file_hash={file_hash}\n",
        encoding="utf-8",
        newline="\n",
    )

    summary = summarize_same_server_source_discovery(
        agent,
        _run(tmp_path),
        file_hash=file_hash,
        connected_server={"endpoint": "45.82.80.155:5687", "host": "45.82.80.155", "port": 5687},
    )

    assert summary["status"] == "found_sources"
    assert summary["foundSourceCount"] == 2


def _emule_session(tmp_path: Path) -> EmuleSession:
    logs = tmp_path / "logs"
    logs.mkdir(parents=True)
    return EmuleSession(
        session_dir=tmp_path / "session",
        session_name="harness",
        profile_root=tmp_path,
        ready_file=tmp_path / "harness.ready",
        status_log_path=tmp_path / "status.log",
        trace_log_path=logs / "emule-harness-kad-trace.log",
        verbose_log_path=logs / "eMule_Verbose.log",
        stdout_path=tmp_path / "stdout.log",
        stderr_path=tmp_path / "stderr.log",
        export_link_path=None,
        export_aich_path=None,
        download_link_path=None,
        udp_dump_path=None,
        ed2k_dump_path=None,
        pid=1,
        started_at_utc="2026-05-02T00:00:00Z",
        started_at_timestamp=0.0,
    )


def _agent_session(tmp_path: Path):
    from tests.e2e.lib.agent import AgentSession

    log_root = tmp_path / "agent-logs"
    state_root = tmp_path / "agent-state"
    log_root.mkdir()
    state_root.mkdir()
    return AgentSession(
        session_dir=tmp_path / "agent-session",
        session_name="agent",
        state_root=state_root,
        log_root=log_root,
        config_path=tmp_path / "agent.toml",
        config_backup_path=None,
        stdout_path=tmp_path / "stdout.log",
        stderr_path=tmp_path / "stderr.log",
        agent_log_path=log_root / "overlord-agent-emule.log",
        control_url="http://127.0.0.1:13301",
        stats_url="http://127.0.0.1:13301/api/internal/stats",
        transfer_root=state_root / "overlord-ed2k-transfer",
        control_port=13301,
        kad_port=41000,
        ed2k_port=41001,
        bind_ip="10.46.51.16",
        pid=1,
        started_at_utc="2026-05-02T00:00:00Z",
    )


def _seed_bundle(
    tmp_path: Path,
    *,
    server_met_entries: list[LiveEd2kServerEntry] | None = None,
) -> EmuleHarnessSeedBundle:
    from tests.e2e.test_live_servers import _encode_server_met

    seed_root = tmp_path / "seed-bundle"
    seed_root.mkdir(parents=True, exist_ok=True)
    nodes_dat = seed_root / "nodes.dat"
    server_met = seed_root / "server.met"
    nodes_dat.write_bytes(b"nodes")
    server_met.write_bytes(
        _encode_server_met(
            server_met_entries
            or [
                LiveEd2kServerEntry(host="1.1.1.1", port=4661, name="first"),
                LiveEd2kServerEntry(host="2.2.2.2", port=4662, name="second"),
            ]
        )
    )
    return EmuleHarnessSeedBundle(
        bundle_id="canonical",
        seed_root=seed_root,
        manifest_path=seed_root / "seed-bundle.json",
        nodes_dat_path=nodes_dat,
        server_met_path=server_met,
        manifest={"schemaVersion": "emule-harness-seed-bundle/v1", "bundleId": "canonical"},
    )


def _prerequisites(
    seed_bundle: EmuleHarnessSeedBundle,
    server_entries: list[LiveEd2kServerEntry],
) -> LiveScenarioPrerequisites:
    return LiveScenarioPrerequisites(
        interface_binding=LiveInterfaceBinding(
            interface_alias="hide.me",
            bind_ip="10.46.51.16",
        ),
        seed_bundle=seed_bundle,
        server_entries=server_entries,
        file_size_bytes=10_485_760,
    )


def _run(tmp_path: Path):
    from tests.e2e.lib.ed2k_private import create_private_ed2k_run
    from tests.e2e.lib.paths import WorkspacePaths

    return create_private_ed2k_run(
        WorkspacePaths(
            project_root=tmp_path,
            tooling_root=tmp_path / "tooling",
            agents_root=tmp_path / "agents",
            be_root=tmp_path / "be",
            tmp_dir=tmp_path / "tmp",
            log_dir=tmp_path / "logs",
            emule_workspace_root=None,
        ),
        scenario_id="scenario",
        transport_mode="plaintext",
        file_name="file.bin",
        file_size=10,
        file_pattern="pattern",
        keep_sessions_running=False,
        skip_build=True,
    )
