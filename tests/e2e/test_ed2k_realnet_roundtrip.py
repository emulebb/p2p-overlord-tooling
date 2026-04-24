from __future__ import annotations

import pytest

from tests.e2e.lib.agent import AgentRuntime, AgentSession
from tests.e2e.lib.ed2k_live import (
    clean_ed2k_file_link,
    copy_live_roundtrip_artifacts,
    start_live_agent_session,
    start_live_harness_seeder,
)
from tests.e2e.lib.ed2k_private import (
    create_private_ed2k_run,
    run_agent_to_harness_stage,
    run_harness_to_agent_stage,
    utc_now,
    write_json,
)
from tests.e2e.lib.emule_harness import EmuleHarnessRuntime, EmuleSession
from tests.e2e.lib.live_runtime import resolve_live_scenario_prerequisites
from tests.e2e.lib.manifests import load_manifest
from tests.e2e.lib.paths import WorkspacePaths


SCENARIO_ID = "ed2k.server.emule-harness.agent.roundtrip.realnet.v1"


@pytest.mark.e2e
@pytest.mark.live
@pytest.mark.requires_vpn
@pytest.mark.ed2k
@pytest.mark.roundtrip
@pytest.mark.harness_to_agent
@pytest.mark.agent_to_harness
@pytest.mark.slow
def test_live_ed2k_server_roundtrip(
    workspace_paths: WorkspacePaths,
    pytestconfig: pytest.Config,
) -> None:
    manifest = load_manifest(workspace_paths, SCENARIO_ID)
    prerequisites = resolve_live_scenario_prerequisites(workspace_paths, manifest)
    file_size = int(pytestconfig.getoption("--file-size-bytes") or manifest["file"]["sizeBytes"])
    run = create_private_ed2k_run(
        workspace_paths,
        scenario_id=SCENARIO_ID,
        transport_mode="plaintext",
        file_name=str(manifest["file"]["name"]),
        file_size=file_size,
        file_pattern=str(manifest["file"]["pattern"]),
        keep_sessions_running=bool(pytestconfig.getoption("--keep-sessions-running")),
        skip_build=bool(pytestconfig.getoption("--skip-runtime-build")),
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
        if not run.keep_sessions_running:
            seeder_session = None
        if not run.keep_sessions_running:
            agent_stage1_session = None

        write_json(
            run.run_summary_path,
            {
                "schemaVersion": "run-summary/v1",
                "scenarioId": run.scenario_id,
                "runId": run.run_id,
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
                "sameHostTransferMode": {
                    "enabled": False,
                    "rationale": "realnet_server_only_source_discovery",
                    "agentSourceHint": False,
                    "harnessDownloadLink": stage2_result.harness_download_link,
                },
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
                    "scenarioId": run.scenario_id,
                    "runId": run.run_id,
                    "completed": False,
                    "transportMode": run.transport_mode,
                    "bindIp": prerequisites.interface_binding.bind_ip,
                    "fileHash": seeder_result.parsed_link.file_hash if seeder_result else None,
                    "fileName": seeder_result.parsed_link.file_name if seeder_result else str(manifest["file"]["name"]),
                    "fileSize": seeder_result.parsed_link.file_size if seeder_result else file_size,
                    "failedReason": failed_reason,
                    "finishedAtUtc": utc_now(),
                },
            )
