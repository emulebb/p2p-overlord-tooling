from __future__ import annotations

from tests.e2e.lib import ed2k
from tests.e2e.lib.ed2k_private import build_ed2k_link


def test_encode_aich_root_for_link_converts_hex_to_base32() -> None:
    assert (
        ed2k.encode_aich_root_for_link("cb59e0f3ab5fce821d639e751f6dcdaf13e83a54")
        == "ZNM6B45LL7HIEHLDTZ2R63ONV4J6QOSU"
    )


def test_build_ed2k_link_emits_base32_aich_segment() -> None:
    link = build_ed2k_link(
        file_name="ubuntu-linux-agent-private-server-large.bin",
        file_size=10_485_760,
        file_hash="65641870bb96a165ce97d30bfa0d50fe",
        aich_root="cb59e0f3ab5fce821d639e751f6dcdaf13e83a54",
    )

    assert (
        link.link
        == "ed2k://|file|ubuntu-linux-agent-private-server-large.bin|10485760|65641870bb96a165ce97d30bfa0d50fe|h=ZNM6B45LL7HIEHLDTZ2R63ONV4J6QOSU|/"
    )
    assert link.aich_root == "ZNM6B45LL7HIEHLDTZ2R63ONV4J6QOSU"
