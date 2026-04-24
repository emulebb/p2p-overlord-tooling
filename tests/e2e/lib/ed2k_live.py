from __future__ import annotations

import shutil
from pathlib import Path
from typing import Any

from tests.e2e.lib.agent import AgentRuntime, AgentSession
from tests.e2e.lib.ed2k_private import (
    HarnessSeederResult,
    PrivateEd2kRun,
    build_ed2k_link,
    copy_agent_artifacts,
    copy_harness_artifacts,
    copy_small_download,
    seed_export_timeout,
)
from tests.e2e.lib.emule_harness import EmuleHarnessRuntime, EmuleProfile, EmuleSession
from tests.e2e.lib.live_runtime import LiveScenarioPrerequisites
from tests.e2e.lib.payloads import write_deterministic_binary
from tests.e2e.lib.waits import wait_path
from tests.e2e.lib import ed2k


def materialize_live_harness_profile(
    emule: EmuleHarnessRuntime,
    *,
    profile_root: Path,
    prerequisites: LiveScenarioPrerequisites,
    harness_cfg: dict[str, Any],
    enable_obfuscation: bool,
) -> EmuleProfile:
    profile = emule.materialize_private_ed2k_profile(
        profile_root=profile_root,
        bind_addr=prerequisites.interface_binding.bind_ip,
        tcp_port=int(harness_cfg["tcpPort"]),
        udp_port=int(harness_cfg["udpPort"]),
        server_udp_port=int(harness_cfg["serverUdpPort"]),
        web_port=int(harness_cfg["webPort"]),
        kad_udp_key=int(harness_cfg["kadUdpKey"]),
        enable_kademlia=False,
        enable_ed2k=True,
        reset_transient_state=True,
    )
    shutil.copy2(
        prerequisites.seed_bundle.server_met_path,
        profile.profile_root / "config" / "server.met",
    )
    emule.set_obfuscation_mode(profile, obfuscated_preferred=enable_obfuscation)
    return profile


def start_live_harness_seeder(
    emule: EmuleHarnessRuntime,
    run: PrivateEd2kRun,
    prerequisites: LiveScenarioPrerequisites,
    seeder_cfg: dict[str, Any],
    timeouts_cfg: dict[str, Any],
) -> HarnessSeederResult:
    profile = materialize_live_harness_profile(
        emule,
        profile_root=run.artifact_root / "seed",
        prerequisites=prerequisites,
        harness_cfg=seeder_cfg,
        enable_obfuscation=run.enable_obfuscation,
    )
    seed_file_path = profile.incoming_root / run.file_name
    write_deterministic_binary(seed_file_path, size_bytes=run.file_size, pattern=run.file_pattern)
    seed_link_path = run.artifact_root / "seed.ed2k"
    session = emule.start_private_ed2k_session(
        profile=profile,
        seed_file_path=seed_file_path,
        export_link_path=seed_link_path,
        export_source_ip=prerequisites.interface_binding.bind_ip,
        skip_build=True,
    )
    wait_path(
        seed_link_path,
        timeout_seconds=seed_export_timeout(run.file_size, int(timeouts_cfg["harnessReadySeconds"])),
    )
    parsed_link = ed2k.parse_ed2k_link_file(seed_link_path)
    if not parsed_link.aich_root:
        raise AssertionError("seeder export link did not include AICH")
    return HarnessSeederResult(profile=profile, session=session, parsed_link=parsed_link)


def start_live_agent_session(
    agent: AgentRuntime,
    run: PrivateEd2kRun,
    prerequisites: LiveScenarioPrerequisites,
    agent_cfg: dict[str, Any],
    manifest: dict[str, Any],
    *,
    reset_runtime_root: bool,
) -> AgentSession:
    server_selection = manifest.get("serverSelection")
    connect_timeout_milliseconds = 8_000
    if isinstance(server_selection, dict) and server_selection.get("connectTimeoutMilliseconds") is not None:
        connect_timeout_milliseconds = int(server_selection["connectTimeoutMilliseconds"])
    connect_timeout_seconds = max(1, (connect_timeout_milliseconds + 999) // 1000)
    session = agent.start_private_ed2k_session(
        scenario_root=run.artifact_root / "agt",
        control_port=int(agent_cfg["controlPort"]),
        kad_port=int(agent_cfg["kadPort"]),
        ed2k_port=int(agent_cfg["ed2kPort"]),
        p2p_bind_ip=prerequisites.interface_binding.bind_ip,
        disable_kad=True,
        server_entries=[
            {
                "host": entry.host,
                "port": entry.port,
                "name": entry.name or "",
                "description": entry.description or "",
                "udp_flags": entry.udp_flags,
                "udp_key": entry.udp_key,
                "udp_key_ip": entry.udp_key_ip,
                "obfuscation_port_tcp": entry.obfuscation_port_tcp,
                "obfuscation_port_udp": entry.obfuscation_port_udp,
            }
            for entry in prerequisites.server_entries
        ],
        server_connect_timeout_seconds=connect_timeout_seconds,
        enable_obfuscation=run.enable_obfuscation,
        skip_build=run.skip_build,
    )
    if reset_runtime_root:
        agent.wait_control_ready(session, timeout_seconds=180)
        return session
    agent.wait_control_ready(session, timeout_seconds=180)
    return session


def clean_ed2k_file_link(parsed_link: ed2k.Ed2kLink) -> str:
    return build_ed2k_link(
        file_name=parsed_link.file_name,
        file_size=parsed_link.file_size,
        file_hash=parsed_link.file_hash,
        aich_root=parsed_link.aich_root,
    ).link


def copy_live_roundtrip_artifacts(
    agent_stage1_session: AgentSession | None,
    stage1_dump_path: Path | None,
    agent_stage2_session: AgentSession | None,
    stage2_dump_path: Path | None,
    seeder_session: EmuleSession | None,
    downloader_session: EmuleSession | None,
    run: PrivateEd2kRun,
    downloaded_file: Path | None,
) -> None:
    if agent_stage1_session is not None:
        copy_agent_artifacts(agent_stage1_session, stage1_dump_path, run.agent_stage1_artifacts)
    if agent_stage2_session is not None:
        copy_agent_artifacts(agent_stage2_session, stage2_dump_path, run.agent_stage2_artifacts)
    copy_harness_artifacts(seeder_session, run.seeder_artifacts)
    copy_harness_artifacts(downloader_session, run.downloader_artifacts)
    copy_small_download(downloaded_file, run.downloader_artifacts)
