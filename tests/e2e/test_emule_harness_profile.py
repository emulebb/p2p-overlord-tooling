from __future__ import annotations

from tests.e2e.lib.emule_harness import PRIVATE_HARNESS_RATE_LIMIT_KIB_PER_SEC, _preferences_content


def test_private_harness_profile_sets_100mbit_rate_caps() -> None:
    content = _preferences_content(
        bind_addr="127.0.0.1",
        tcp_port=4662,
        udp_port=4672,
        server_udp_port=0,
        web_port=4711,
        kad_udp_key=4_206_201,
        enable_kademlia=False,
        enable_ed2k=True,
        enable_upnp=False,
    )

    assert f"MaxDownload={PRIVATE_HARNESS_RATE_LIMIT_KIB_PER_SEC}" in content
    assert f"MaxUpload={PRIVATE_HARNESS_RATE_LIMIT_KIB_PER_SEC}" in content
