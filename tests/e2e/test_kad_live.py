from __future__ import annotations

from tests.e2e.lib.kad_live import _kad_bootstrap_ready


def test_kad_live_bootstrap_ready_uses_agent_bootstrap_state() -> None:
    assert not _kad_bootstrap_ready({})
    assert not _kad_bootstrap_ready({"kad_bootstrapped": False, "peers_connected": 20})
    assert _kad_bootstrap_ready({"kad_bootstrapped": True, "peers_connected": 1})

