from __future__ import annotations

from pathlib import Path

from tests.e2e.lib.emule_harness import (
    EmuleHarnessRuntime,
    PRIVATE_HARNESS_RATE_LIMIT_BITS_PER_SEC,
    PRIVATE_HARNESS_RATE_LIMIT_KIB_PER_SEC,
    _load_shared_live_profiles,
)
from tests.e2e.lib.paths import WorkspacePaths


def _workspace_paths(tmp_path: Path, *, emule_workspace_root: Path | None = None) -> WorkspacePaths:
    tooling_root = Path(__file__).resolve().parents[2]
    project_root = tooling_root.parent
    return WorkspacePaths(
        project_root=project_root,
        tooling_root=tooling_root,
        agents_root=project_root / "p2p-overlord-agents",
        be_root=project_root / "p2p-overlord-be",
        tmp_dir=tmp_path / "tmp",
        log_dir=tmp_path / "logs",
        emule_workspace_root=emule_workspace_root,
    )


def _section_text(text: str, section: str) -> str:
    marker = f"[{section}]"
    tail = text.split(marker, 1)[1]
    return tail.split("\n[", 1)[0]


def test_private_harness_rate_cap_matches_shared_builder(tmp_path: Path) -> None:
    shared_profiles = _load_shared_live_profiles(_workspace_paths(tmp_path))

    assert PRIVATE_HARNESS_RATE_LIMIT_BITS_PER_SEC == 10_000_000_000
    assert PRIVATE_HARNESS_RATE_LIMIT_KIB_PER_SEC == (
        PRIVATE_HARNESS_RATE_LIMIT_BITS_PER_SEC // 8 // 1024
    )
    assert PRIVATE_HARNESS_RATE_LIMIT_KIB_PER_SEC == 1_220_703
    assert PRIVATE_HARNESS_RATE_LIMIT_BITS_PER_SEC == (
        shared_profiles.PRIVATE_HARNESS_RATE_LIMIT_BITS_PER_SEC
    )
    assert PRIVATE_HARNESS_RATE_LIMIT_KIB_PER_SEC == (
        shared_profiles.PRIVATE_HARNESS_RATE_LIMIT_KIB_PER_SEC
    )


def test_private_harness_profile_uses_shared_materializer(tmp_path: Path) -> None:
    paths = _workspace_paths(tmp_path)
    runtime = EmuleHarnessRuntime(paths)

    profile = runtime.materialize_private_ed2k_profile(
        profile_root=tmp_path / "profile",
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

    shared_profiles = _load_shared_live_profiles(paths)
    content = shared_profiles.read_ini_text(profile.preferences_path)
    emule_section = _section_text(content, "eMule")
    upnp_section = _section_text(content, "UPnP")
    assert profile.preferences_path.read_bytes().startswith(b"\xff\xfe")
    assert f"MaxDownload={PRIVATE_HARNESS_RATE_LIMIT_KIB_PER_SEC}" in emule_section
    assert f"MaxUpload={PRIVATE_HARNESS_RATE_LIMIT_KIB_PER_SEC}" in emule_section
    assert "BindAddr=127.0.0.1" in emule_section
    assert "BindInterface=" not in emule_section
    assert "NetworkED2K=1" in emule_section
    assert "NetworkKademlia=0" in emule_section
    assert "EnableUPnP=0" in upnp_section
    assert not (profile.profile_root / "config" / "server.met").exists()
    assert not (profile.profile_root / "config" / "nodes.dat").exists()


def test_private_harness_obfuscation_uses_shared_ini_mutation(tmp_path: Path) -> None:
    paths = _workspace_paths(tmp_path)
    runtime = EmuleHarnessRuntime(paths)
    profile = runtime.materialize_private_ed2k_profile(
        profile_root=tmp_path / "profile",
        bind_addr="127.0.0.1",
        tcp_port=4662,
        udp_port=4672,
    )

    runtime.set_obfuscation_mode(profile, obfuscated_preferred=True)

    shared_profiles = _load_shared_live_profiles(paths)
    content = shared_profiles.read_ini_text(profile.preferences_path)
    emule_section = _section_text(content, "eMule")
    assert emule_section.count("CryptLayerRequested=1") == 1
    assert emule_section.count("CryptLayerRequired=0") == 1
    assert emule_section.count("CryptLayerSupported=1") == 1


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

    runtime = EmuleHarnessRuntime(_workspace_paths(tmp_path, emule_workspace_root=tmp_path))

    assert runtime.resolve_debug_dir() == debug_dir
    assert runtime.runtime_exe_path() == runtime_exe
