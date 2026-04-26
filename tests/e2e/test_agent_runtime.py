from __future__ import annotations

from pathlib import Path

from tests.e2e.lib import agent as agent_lib
from tests.e2e.lib.agent import AgentRuntime, AgentSession
from tests.e2e.lib.paths import WorkspacePaths


def test_private_agent_config_writes_kad_bootstrap_node(tmp_path: Path) -> None:
    paths = WorkspacePaths.discover()
    runtime = AgentRuntime(paths)

    runtime.write_private_local_config(
        scenario_root=tmp_path / "scenario",
        control_port=13301,
        kad_port=41120,
        ed2k_port=41121,
        p2p_bind_ip="127.0.0.1",
        emule_harness_bootstrap_node="127.0.0.1:42072",
        kad_bootstrap_ready_contacts=1,
        disable_kad=False,
    )

    config = runtime.config_path.read_text(encoding="utf-8")
    assert 'bootstrap_nodes = ["127.0.0.1:42072"]' in config
    assert "bootstrap_min_routing_contacts = 1" in config


def test_private_agent_config_writes_multiple_server_entries(tmp_path: Path) -> None:
    paths = WorkspacePaths.discover()
    runtime = AgentRuntime(paths)

    runtime.write_private_local_config(
        scenario_root=tmp_path / "scenario",
        control_port=13301,
        kad_port=41120,
        ed2k_port=41121,
        p2p_bind_ip="10.8.0.4",
        disable_kad=True,
        server_entries=[
            {
                "host": "1.2.3.4",
                "port": 4661,
                "name": "alpha",
                "description": "primary",
                "udp_flags": 0x91,
                "udp_key": 17,
                "udp_key_ip": 18,
                "obfuscation_port_tcp": 4461,
                "obfuscation_port_udp": 4471,
            },
            {
                "host": "5.6.7.8",
                "port": 4665,
                "name": "beta",
                "description": "backup",
            },
        ],
    )

    config = runtime.config_path.read_text(encoding="utf-8")
    assert 'bind_ip = "10.8.0.4"' in config
    assert 'server_endpoints = ["1.2.3.4:4661", "5.6.7.8:4665"]' in config
    assert 'host = "1.2.3.4", port = 4661, name = "alpha", description = "primary"' in config
    assert 'udp_flags = 145, udp_key = 17, udp_key_ip = 18' in config
    assert 'obfuscation_port_tcp = 4461, obfuscation_port_udp = 4471' in config
    assert 'host = "5.6.7.8", port = 4665, name = "beta", description = "backup"' in config


def test_private_agent_config_writes_kad_timing_overrides(tmp_path: Path) -> None:
    paths = WorkspacePaths.discover()
    runtime = AgentRuntime(paths)

    runtime.write_private_local_config(
        scenario_root=tmp_path / "scenario",
        control_port=13301,
        kad_port=41120,
        ed2k_port=41121,
        p2p_bind_ip="10.8.0.4",
        disable_kad=False,
        kad_republish_interval_secs=3_600,
        kad_publish_contact_fanout=7,
        kad_hello_intro_interval_secs=5,
        kad_hello_intro_fanout=3,
        kad_publish_max_outbound_pps=2,
        kad_synthetic_publish_interval_secs=900,
        kad_synthetic_publish_batch_items=2,
        kad_synthetic_publish_contact_fanout=5,
    )

    config = runtime.config_path.read_text(encoding="utf-8")
    assert "republish_interval_secs = 3600" in config
    assert "publish_contact_fanout = 7" in config
    assert "hello_intro_interval_secs = 5" in config
    assert "hello_intro_fanout = 3" in config
    assert "publish_max_outbound_pps = 2" in config
    assert "synthetic_publish_interval_secs = 900" in config
    assert "synthetic_publish_batch_items = 2" in config
    assert "synthetic_publish_contact_fanout = 5" in config


def test_private_agent_config_writes_notes_publish_enabled(tmp_path: Path) -> None:
    paths = WorkspacePaths.discover()
    runtime = AgentRuntime(paths)

    runtime.write_private_local_config(
        scenario_root=tmp_path / "scenario",
        control_port=13301,
        kad_port=41120,
        ed2k_port=41121,
        p2p_bind_ip="10.8.0.4",
        disable_kad=False,
        enable_kad_notes_publish=True,
    )

    config = runtime.config_path.read_text(encoding="utf-8")
    assert "seed_notes_publish_enabled = true" in config


def test_private_agent_config_can_bind_p2p_by_interface(tmp_path: Path) -> None:
    paths = WorkspacePaths.discover()
    runtime = AgentRuntime(paths)

    runtime.write_private_local_config(
        scenario_root=tmp_path / "scenario",
        control_port=13301,
        kad_port=41120,
        ed2k_port=41121,
        p2p_bind_ip=None,
        p2p_bind_iface="hide.me",
        disable_kad=False,
    )

    config = runtime.config_path.read_text(encoding="utf-8")
    assert 'bind_iface = "hide.me"' in config
    assert 'bind_ip = ""' in config


def test_wait_transfer_manifest_returns_on_terminal_agent_error(
    tmp_path: Path,
    monkeypatch,
) -> None:
    paths = WorkspacePaths.discover()
    runtime = AgentRuntime(paths)
    file_hash = "a" * 32
    transfer_dir = tmp_path / "transfers" / file_hash
    transfer_dir.mkdir(parents=True)
    (transfer_dir / "resume-manifest.json").write_text(
        '{"completed": false, "sources": []}\n',
        encoding="utf-8",
    )
    session = AgentSession(
        session_dir=tmp_path,
        session_name="agent",
        state_root=tmp_path / "state",
        log_root=tmp_path / "logs",
        config_path=tmp_path / "agent.toml",
        config_backup_path=None,
        stdout_path=tmp_path / "stdout.log",
        stderr_path=tmp_path / "stderr.log",
        agent_log_path=tmp_path / "agent.log",
        control_url="http://127.0.0.1:9",
        stats_url="http://127.0.0.1:9/api/internal/stats",
        transfer_root=tmp_path / "transfers",
        control_port=9,
        kad_port=10,
        ed2k_port=11,
        bind_ip="127.0.0.1",
        pid=1234,
        started_at_utc="2026-04-25T00:00:00Z",
    )

    monkeypatch.setattr(
        agent_lib,
        "_agent_reported_terminal_download_error",
        lambda _session, *, file_hash: file_hash == "a" * 32,
    )

    manifest = runtime.wait_transfer_manifest(
        session,
        file_hash=file_hash,
        timeout_seconds=30,
        stop_on_terminal_error=True,
    )

    assert manifest["completed"] is False
