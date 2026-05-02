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
    create_private_ed2k_run,
    run_identity,
    seed_export_timeout,
    run_agent_to_harness_stage,
    run_harness_to_agent_stage,
    utc_now,
)
from tests.e2e.lib.ed2k_live_same_server import (
    extract_harness_server_evidence,
    live_server_entry_for_agent,
    prioritized_live_server_entries,
    same_server_mode_summary,
    summarize_same_server_source_discovery,
    wait_harness_connected_server,
)
from tests.e2e.lib.emule_harness import EmuleHarnessRuntime, EmuleProfile, EmuleSession
from tests.e2e.lib.live_runtime import LiveScenarioPrerequisites, resolve_live_scenario_prerequisites
from tests.e2e.lib.live_search_terms import DEFAULT_LIVE_WIRE_STRESS_SEARCH_TERM
from overlord_tooling.scenarios import write_json
from tests.e2e.lib.payloads import write_deterministic_binary
from tests.e2e.lib.paths import WorkspacePaths
from tests.e2e.lib.waits import wait_path
from tests.e2e.lib import ed2k


def materialize_live_harness_profile(
    emule: EmuleHarnessRuntime,
    *,
    profile_root: Path,
    prerequisites: LiveScenarioPrerequisites,
    harness_cfg: dict[str, Any],
    enable_obfuscation: bool,
    enable_kademlia: bool = False,
) -> EmuleProfile:
    profile = emule.materialize_private_ed2k_profile(
        profile_root=profile_root,
        bind_addr=prerequisites.interface_binding.bind_ip,
        tcp_port=int(harness_cfg["tcpPort"]),
        udp_port=int(harness_cfg["udpPort"]),
        server_udp_port=int(harness_cfg["serverUdpPort"]),
        web_port=int(harness_cfg["webPort"]),
        kad_udp_key=int(harness_cfg.get("kadUdpKey", 0)),
        enable_kademlia=enable_kademlia,
        enable_ed2k=True,
        reset_transient_state=True,
    )
    materialize_live_seed_bundle_to_harness_profile(profile, prerequisites)
    emule.set_obfuscation_mode(profile, obfuscated_preferred=enable_obfuscation)
    return profile


def materialize_live_seed_bundle_to_harness_profile(
    profile: EmuleProfile,
    prerequisites: LiveScenarioPrerequisites,
) -> None:
    shutil.copy2(
        prerequisites.seed_bundle.server_met_path,
        profile.profile_root / "config" / "server.met",
    )
    shutil.copy2(
        prerequisites.seed_bundle.nodes_dat_path,
        profile.profile_root / "config" / "nodes.dat",
    )


def materialize_live_seed_bundle_to_agent_state(
    state_root: Path,
    prerequisites: LiveScenarioPrerequisites,
) -> Path:
    state_root.mkdir(parents=True, exist_ok=True)
    destination = state_root / "overlord-kad.nodes.dat"
    shutil.copy2(prerequisites.seed_bundle.nodes_dat_path, destination)
    return destination


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
    connected_server = wait_harness_connected_server(
        session,
        timeout_seconds=min(30, max(1, int(timeouts_cfg["harnessReadySeconds"]))),
    )
    if connected_server is None:
        profile, session, connected_server = restart_live_harness_seeder_after_log_flush(
            emule,
            run=run,
            prerequisites=prerequisites,
            seeder_cfg=seeder_cfg,
            session=session,
            seed_link_path=seed_link_path,
        )
    return HarnessSeederResult(
        profile=profile,
        session=session,
        parsed_link=parsed_link,
        connected_server=connected_server,
    )


def restart_live_harness_seeder_after_log_flush(
    emule: EmuleHarnessRuntime,
    *,
    run: PrivateEd2kRun,
    prerequisites: LiveScenarioPrerequisites,
    seeder_cfg: dict[str, Any],
    session: EmuleSession,
    seed_link_path: Path,
) -> tuple[EmuleProfile, EmuleSession, dict[str, Any] | None]:
    stopped_session = emule.stop(session)
    established, connected = extract_harness_server_evidence(stopped_session)
    connected_server = established or connected
    profile = materialize_live_harness_profile(
        emule,
        profile_root=run.artifact_root / "seed-same-server",
        prerequisites=prerequisites,
        harness_cfg=seeder_cfg,
        enable_obfuscation=run.enable_obfuscation,
    )
    if connected_server is not None:
        ed2k.write_server_met(
            profile.profile_root / "config" / "server.met",
            server_ip=str(connected_server["host"]),
            server_port=int(connected_server["port"]),
        )
    seed_file_path = profile.incoming_root / run.file_name
    write_deterministic_binary(seed_file_path, size_bytes=run.file_size, pattern=run.file_pattern)
    restarted_session = emule.start_private_ed2k_session(
        profile=profile,
        seed_file_path=seed_file_path,
        export_link_path=seed_link_path,
        export_source_ip=prerequisites.interface_binding.bind_ip,
        skip_build=True,
    )
    wait_path(seed_link_path, timeout_seconds=60)
    refreshed = wait_harness_connected_server(restarted_session, timeout_seconds=30)
    return profile, restarted_session, refreshed or connected_server


def start_live_agent_session(
    agent: AgentRuntime,
    run: PrivateEd2kRun,
    prerequisites: LiveScenarioPrerequisites,
    agent_cfg: dict[str, Any],
    manifest: dict[str, Any],
    *,
    reset_runtime_root: bool,
    preferred_server: dict[str, Any] | None = None,
    disable_kad: bool = True,
    probe_search_term: str = DEFAULT_LIVE_WIRE_STRESS_SEARCH_TERM,
) -> AgentSession:
    server_selection = manifest.get("serverSelection")
    connect_timeout_milliseconds = 8_000
    if isinstance(server_selection, dict) and server_selection.get("connectTimeoutMilliseconds") is not None:
        connect_timeout_milliseconds = int(server_selection["connectTimeoutMilliseconds"])
    connect_timeout_seconds = max(1, (connect_timeout_milliseconds + 999) // 1000)
    server_entries = prioritized_live_server_entries(prerequisites, preferred_server)
    session = agent.start_private_ed2k_session(
        scenario_root=run.artifact_root / "agt",
        control_port=int(agent_cfg["controlPort"]),
        kad_port=int(agent_cfg["kadPort"]),
        ed2k_port=int(agent_cfg["ed2kPort"]),
        p2p_bind_ip=None,
        p2p_bind_iface=prerequisites.interface_binding.interface_alias,
        disable_kad=disable_kad,
        server_entries=[live_server_entry_for_agent(entry) for entry in server_entries],
        server_connect_timeout_seconds=connect_timeout_seconds,
        probe_search_term=probe_search_term,
        nodes_dat_seed_path=prerequisites.seed_bundle.nodes_dat_path,
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


def run_live_ed2k_server_roundtrip_scenario(
    workspace_paths: WorkspacePaths,
    pytestconfig,
    *,
    scenario_id: str,
    manifest: dict[str, Any],
    artifact_scenario_id: str | None = None,
    run_slug: str | None = None,
    metadata: dict[str, Any] | None = None,
) -> None:
    prerequisites = resolve_live_scenario_prerequisites(workspace_paths, manifest)
    file_size = int(pytestconfig.getoption("--file-size-bytes") or manifest["file"]["sizeBytes"])
    run = create_private_ed2k_run(
        workspace_paths,
        scenario_id=scenario_id,
        transport_mode="plaintext",
        file_name=str(manifest["file"]["name"]),
        file_size=file_size,
        file_pattern=str(manifest["file"]["pattern"]),
        keep_sessions_running=bool(pytestconfig.getoption("--keep-sessions-running")),
        skip_build=bool(pytestconfig.getoption("--skip-runtime-build")),
        artifact_scenario_id=artifact_scenario_id,
        run_slug=run_slug,
        metadata=metadata,
    )

    emule = EmuleHarnessRuntime(workspace_paths)
    agent = AgentRuntime(workspace_paths)

    seeder_session: EmuleSession | None = None
    downloader_session: EmuleSession | None = None
    agent_stage1_session: AgentSession | None = None
    agent_stage2_session: AgentSession | None = None
    failed_reason: str | None = None
    seeder_result = None
    stage1_result = None
    stage2_result = None

    try:
        if not run.skip_build:
            emule.build()
            agent.build()

        seeder_result = start_live_harness_seeder(
            emule,
            run,
            prerequisites,
            manifest["harnessSeeder"],
            manifest["timeouts"],
        )
        seeder_session = seeder_result.session

        agent_stage1_session = start_live_agent_session(
            agent,
            run,
            prerequisites,
            manifest["agent"],
            manifest,
            reset_runtime_root=True,
            preferred_server=seeder_result.connected_server,
        )
        pseudo_server_cfg = {"host": prerequisites.interface_binding.bind_ip}
        stage1_result = run_harness_to_agent_stage(
            agent,
            run,
            agent_stage1_session,
            seeder_result.parsed_link,
            seeder_session=seeder_session,
            server_cfg=pseudo_server_cfg,
            seeder_cfg=manifest["harnessSeeder"],
            timeouts_cfg=manifest["timeouts"],
            use_plaintext_loopback_source_hint=False,
        )
        agent.copy_transfer(
            agent_stage1_session,
            file_hash=seeder_result.parsed_link.file_hash,
            destination_root=run.agent_stage1_artifacts,
        )

        if not run.keep_sessions_running and seeder_session is not None:
            seeder_session = emule.stop(seeder_session)
        if not run.keep_sessions_running and agent_stage1_session is not None:
            agent.stop(agent_stage1_session)

        agent_stage2_session = start_live_agent_session(
            agent,
            run,
            prerequisites,
            manifest["agent"],
            manifest,
            reset_runtime_root=False,
            preferred_server=seeder_result.connected_server,
        )
        stage2_result = run_agent_to_harness_stage(
            emule,
            agent,
            run,
            agent_stage2_session,
            seeder_result.parsed_link,
            server_cfg=pseudo_server_cfg,
            downloader_cfg=manifest["harnessDownloader"],
            agent_cfg=manifest["agent"],
            timeouts_cfg=manifest["timeouts"],
            download_link_override=clean_ed2k_file_link(seeder_result.parsed_link),
        )
        downloader_session = stage2_result.session

        if not run.keep_sessions_running and downloader_session is not None:
            downloader_session = emule.stop(downloader_session)
        copy_live_roundtrip_artifacts(
            agent_stage1_session=agent_stage1_session,
            stage1_dump_path=stage1_result.agent_dump_path,
            agent_stage2_session=agent_stage2_session,
            stage2_dump_path=stage2_result.agent_dump_path,
            seeder_session=seeder_session,
            downloader_session=downloader_session,
            run=run,
            downloaded_file=stage2_result.downloaded_file,
        )
        if not run.keep_sessions_running:
            downloader_session = None
            seeder_session = None
            agent_stage1_session = None

        write_json(
            run.run_summary_path,
            {
                "schemaVersion": "run-summary/v1",
                **run_identity(run),
                "completed": True,
                "bindIp": prerequisites.interface_binding.bind_ip,
                "interfaceAlias": prerequisites.interface_binding.interface_alias,
                "fileHash": seeder_result.parsed_link.file_hash,
                "fileName": seeder_result.parsed_link.file_name,
                "fileSize": seeder_result.parsed_link.file_size,
                "transportMode": run.transport_mode,
                "selectedServerCount": len(prerequisites.server_entries),
                "selectedServerEntries": [
                    {
                        "host": entry.host,
                        "port": entry.port,
                        "name": entry.name,
                        "description": entry.description,
                        "udpFlags": entry.udp_flags,
                        "obfuscationPortTcp": entry.obfuscation_port_tcp,
                        "obfuscationPortUdp": entry.obfuscation_port_udp,
                    }
                    for entry in prerequisites.server_entries
                ],
                "sameHostTransferMode": same_server_mode_summary(
                    seeder_result.connected_server,
                    stage2_harness_download_link=stage2_result.harness_download_link,
                ),
                "sameServerSourceDiscovery": summarize_same_server_source_discovery(
                    agent_stage1_session,
                    run,
                    file_hash=seeder_result.parsed_link.file_hash,
                    connected_server=seeder_result.connected_server,
                ),
                "evidence": {
                    "exportedLinkHasAich": bool(seeder_result.parsed_link.aich_root),
                    "agentManifestAichAcquired": bool(stage1_result.transfer_manifest.get("aich_hashset_acquired")),
                    "stage1HashsetRequestAich": True,
                    "stage1HashsetAnswerAich": True,
                    "stage1CompressedParts": True,
                    "stage1TransportModes": stage1_result.transport_modes,
                    "stage1EvidenceSource": stage1_result.evidence_source,
                    "stage2HashsetRequestAich": True,
                    "stage2HashsetAnswerAich": True,
                    "stage2CompressedParts": True,
                    "stage2TransportModes": stage2_result.transport_modes,
                    "stage2EvidenceSource": stage2_result.evidence_source,
                    "harnessVerifierAichOk": True,
                    "sameServerSourceDiscoveryStatus": summarize_same_server_source_discovery(
                        agent_stage1_session,
                        run,
                        file_hash=seeder_result.parsed_link.file_hash,
                        connected_server=seeder_result.connected_server,
                    )["status"],
                    "agentStage1Ed2kDumpPresent": stage1_result.agent_dump_path is not None,
                    "agentStage2Ed2kDumpPresent": stage2_result.agent_dump_path is not None,
                },
                "finishedAtUtc": utc_now(),
            },
        )
    except Exception as exc:
        failed_reason = str(exc)
        raise
    finally:
        if not run.keep_sessions_running:
            if downloader_session is not None:
                emule.stop(downloader_session)
            if seeder_session is not None:
                emule.stop(seeder_session)
            if agent_stage2_session is not None:
                agent.stop(agent_stage2_session)
            if agent_stage1_session is not None:
                agent.stop(agent_stage1_session)
        if not run.run_summary_path.exists():
            write_json(
                run.run_summary_path,
                {
                    "schemaVersion": "run-summary/v1",
                    **run_identity(run),
                    "completed": False,
                    "transportMode": run.transport_mode,
                    "bindIp": prerequisites.interface_binding.bind_ip,
                    "fileHash": seeder_result.parsed_link.file_hash if seeder_result else None,
                    "fileName": seeder_result.parsed_link.file_name if seeder_result else str(manifest["file"]["name"]),
                    "fileSize": seeder_result.parsed_link.file_size if seeder_result else file_size,
                    "sameHostTransferMode": same_server_mode_summary(
                        seeder_result.connected_server if seeder_result else None,
                    ),
                    "sameServerSourceDiscovery": summarize_same_server_source_discovery(
                        agent_stage1_session,
                        run,
                        file_hash=seeder_result.parsed_link.file_hash if seeder_result else None,
                        connected_server=seeder_result.connected_server if seeder_result else None,
                    ),
                    "failedReason": failed_reason,
                    "finishedAtUtc": utc_now(),
                },
            )
