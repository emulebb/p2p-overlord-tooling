from __future__ import annotations

from pathlib import Path

from tests.e2e.lib.agent import AgentRuntime
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
