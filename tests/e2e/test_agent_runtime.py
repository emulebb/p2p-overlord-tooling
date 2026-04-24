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
