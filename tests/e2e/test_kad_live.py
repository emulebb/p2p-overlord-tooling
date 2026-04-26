from __future__ import annotations

import pytest

from tests.e2e.lib.kad_live import _kad_bootstrap_ready, bounded_transfer_timeout_seconds


def test_kad_live_bootstrap_ready_uses_agent_bootstrap_state() -> None:
    assert not _kad_bootstrap_ready({})
    assert not _kad_bootstrap_ready({"kad_bootstrapped": False, "peers_connected": 20})
    assert _kad_bootstrap_ready({"kad_bootstrapped": True, "peers_connected": 1})


def test_bounded_transfer_timeout_caps_to_remaining_budget() -> None:
    assert bounded_transfer_timeout_seconds(
        125.0,
        max_seconds=900,
        now_monotonic=100.0,
    ) == 25
    assert bounded_transfer_timeout_seconds(
        2000.0,
        max_seconds=900,
        now_monotonic=100.0,
    ) == 900


def test_bounded_transfer_timeout_fails_before_budget_is_exhausted() -> None:
    with pytest.raises(TimeoutError, match="scenario budget expired"):
        bounded_transfer_timeout_seconds(
            109.0,
            max_seconds=900,
            now_monotonic=100.0,
        )
