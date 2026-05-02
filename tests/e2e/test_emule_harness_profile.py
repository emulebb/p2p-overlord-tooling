from __future__ import annotations

from pathlib import Path

from tests.e2e.lib.emule_harness import (
    EmuleHarnessRuntime,
    PRIVATE_HARNESS_RATE_LIMIT_BITS_PER_SEC,
    PRIVATE_HARNESS_RATE_LIMIT_KIB_PER_SEC,
    _preferences_content,
)
from tests.e2e.lib.paths import WorkspacePaths


def test_private_harness_rate_cap_matches_high_derived_limit_in_kib_per_second() -> None:
    assert PRIVATE_HARNESS_RATE_LIMIT_BITS_PER_SEC == 10_000_000_000
    assert PRIVATE_HARNESS_RATE_LIMIT_KIB_PER_SEC == (
        PRIVATE_HARNESS_RATE_LIMIT_BITS_PER_SEC // 8 // 1024
    )
    assert PRIVATE_HARNESS_RATE_LIMIT_KIB_PER_SEC == 1_220_703


def test_private_harness_profile_sets_high_rate_caps() -> None:
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


def test_runtime_resolves_community_harness_emule_exe(tmp_path: Path) -> None:
    debug_dir = (
        tmp_path
        / "workspaces"
        / "v0.72a"
        / "app"
        / "eMule-v0.72a-tracing-harness-community"
        / "srchybrid"
        / "x64"
        / "Debug"
    )
    debug_dir.mkdir(parents=True)
    runtime_exe = debug_dir / "emule.exe"
    runtime_exe.write_text("", encoding="ascii")

    runtime = EmuleHarnessRuntime(
        WorkspacePaths(
            project_root=tmp_path,
            tooling_root=tmp_path / "p2p-overlord-tooling",
            agents_root=tmp_path / "p2p-overlord-agents",
            be_root=tmp_path / "p2p-overlord-be",
            tmp_dir=tmp_path / "tmp",
            log_dir=tmp_path / "logs",
            emule_workspace_root=tmp_path,
        )
    )

    assert runtime.resolve_debug_dir() == debug_dir
    assert runtime.runtime_exe_path() == runtime_exe
