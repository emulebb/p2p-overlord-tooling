from __future__ import annotations

from typing import Any

import pytest

from tests.e2e.lib import kad_startup_live
from tests.e2e.lib.kad_startup_live import (
    _kad_bootstrap_ready,
    _post_seed_popular_after_bootstrap,
)


class FakeAgent:
    def __init__(self) -> None:
        self.calls = 0
        self.timeout: int | None = None

    def post_seed_popular(self, *args: Any, **kwargs: Any) -> list[dict[str, Any]]:
        self.calls += 1
        self.timeout = int(kwargs["timeout"])
        if self.calls == 1:
            raise RuntimeError("HTTP 500: {\"error\":\"kad node is not bootstrapped yet\"}")
        return [{"canonical_name": kwargs["canonical_name"]}]


def test_seed_popular_retry_waits_for_agent_bootstrap_guard(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(kad_startup_live.time, "sleep", lambda _seconds: None)
    agent = FakeAgent()
    payload = _post_seed_popular_after_bootstrap(
        agent,  # type: ignore[arg-type]
        object(),  # type: ignore[arg-type]
        {
            "hash": "00112233445566778899AABBCCDDEEFF",
            "canonicalName": "synthetic-manual-publish.iso",
            "size": 734003200,
            "sourceCount": 1,
        },
    )

    assert payload == [{"canonical_name": "synthetic-manual-publish.iso"}]
    assert agent.calls == 2
    assert agent.timeout == kad_startup_live.LIVE_PUBLISH_POST_TIMEOUT_SECONDS


def test_kad_bootstrap_ready_uses_agent_bootstrap_state() -> None:
    assert not _kad_bootstrap_ready({})
    assert not _kad_bootstrap_ready({"kad_bootstrapped": False, "peers_connected": 20})
    assert _kad_bootstrap_ready({"kad_bootstrapped": True, "peers_connected": 1})
