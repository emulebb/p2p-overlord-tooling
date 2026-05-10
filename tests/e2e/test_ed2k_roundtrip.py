from __future__ import annotations

import pytest

from tests.e2e.lib.agent import AgentRuntime, AgentSession
from tests.e2e.lib.emule_harness import EmuleHarnessRuntime, EmuleSession
from tests.e2e.lib.ed2k_private import (
    ED2K_PART_SIZE_BYTES,
    AgentDownloadResult,
    HarnessDownloadResult,
    HarnessSeederResult,
    copy_agent_artifacts,
    copy_harness_artifacts,
    copy_server_artifacts,
    copy_small_download,
    create_private_ed2k_run,
    run_agent_to_harness_stage,
    run_harness_to_agent_stage,
    start_private_agent_session,
    start_private_harness_seeder,
    start_private_server,
    utc_now,
)
from tests.e2e.lib.ed2k_server import Ed2kServerRuntime, Ed2kServerSession
from overlord_tooling.scenarios import load_manifest, write_json
from tests.e2e.lib.paths import WorkspacePaths


SCENARIO_ID = "ed2k.server.emule-harness.agent.roundtrip.private.large.v1"


@pytest.mark.e2e
@pytest.mark.local
@pytest.mark.ed2k
@pytest.mark.roundtrip
@pytest.mark.compressed
@pytest.mark.harness_to_agent
@pytest.mark.agent_to_harness
@pytest.mark.slow
def test_private_ed2k_server_roundtrip(
    workspace_paths: WorkspacePaths,
    pytestconfig: pytest.Config,
    transport_mode: str,
) -> None:
    manifest = load_manifest(workspace_paths.tooling_root, SCENARIO_ID)
    file_size = int(pytestconfig.getoption("--file-size-bytes") or manifest["file"]["sizeBytes"])
    if file_size <= ED2K_PART_SIZE_BYTES:
        pytest.fail(
            f"{SCENARIO_ID} requires a payload larger than one ED2K part "
            f"({ED2K_PART_SIZE_BYTES} bytes) to validate AICH/hashset behavior"
        )
    file_name = str(manifest["file"]["name"])
    file_pattern = str(manifest["file"]["pattern"])
    run = create_private_ed2k_run(
        workspace_paths,
        scenario_id=SCENARIO_ID,
        transport_mode=transport_mode,
        file_name=file_name,
        file_size=file_size,
        file_pattern=file_pattern,
        keep_sessions_running=bool(pytestconfig.getoption("--keep-sessions-running")),
        skip_build=bool(pytestconfig.getoption("--skip-runtime-build")),
    )

    emule = EmuleHarnessRuntime(workspace_paths)
    agent = AgentRuntime(workspace_paths)
    ed2k_server = Ed2kServerRuntime(workspace_paths)

    server_session: Ed2kServerSession | None = None
    seeder_session: EmuleSession | None = None
    downloader_session: EmuleSession | None = None
    agent_stage1_session: AgentSession | None = None
    agent_stage2_session: AgentSession | None = None
    seeder_result: HarnessSeederResult | None = None
    stage1_result: AgentDownloadResult | None = None
    stage2_result: HarnessDownloadResult | None = None
    failed_reason: str | None = None

    try:
        if not run.skip_build:
            emule.build()
            agent.build()

        server = manifest["server"]
        server_session = start_private_server(ed2k_server, run, server)
        seeder_result = start_private_harness_seeder(emule, run, server, manifest["harnessSeeder"], manifest["timeouts"])
        seeder_session = seeder_result.session

        published = ed2k_server.wait_file_available(
            server_session,
            file_hash=seeder_result.parsed_link.file_hash,
            timeout_seconds=180,
        )
        agent_cfg = manifest["agent"]
        agent_stage1_session = start_private_agent_session(
            agent,
            run,
            agent_cfg,
            server,
            reset_runtime_root=True,
        )
        stage1_result = run_harness_to_agent_stage(
            agent,
            run,
            agent_stage1_session,
            seeder_result.parsed_link,
            seeder_session=seeder_session,
            server_cfg=server,
            seeder_cfg=manifest["harnessSeeder"],
            timeouts_cfg=manifest["timeouts"],
        )
        agent.copy_transfer(
            agent_stage1_session,
            file_hash=seeder_result.parsed_link.file_hash,
            destination_root=run.agent_stage1_artifacts,
        )

        if not run.keep_sessions_running and seeder_session:
            seeder_session = emule.stop(seeder_session)
        copy_agent_artifacts(agent_stage1_session, stage1_result.agent_dump_path, run.agent_stage1_artifacts)
        copy_harness_artifacts(seeder_session, run.seeder_artifacts)
        if not run.keep_sessions_running:
            seeder_session = None
        if not run.keep_sessions_running and agent_stage1_session:
            agent.stop(agent_stage1_session)
            agent_stage1_session = None

        agent_stage2_session = start_private_agent_session(
            agent,
            run,
            agent_cfg,
            server,
            reset_runtime_root=False,
        )
        stage2_result = run_agent_to_harness_stage(
            emule,
            agent,
            run,
            agent_stage2_session,
            seeder_result.parsed_link,
            server_cfg=server,
            downloader_cfg=manifest["harnessDownloader"],
            agent_cfg=agent_cfg,
            timeouts_cfg=manifest["timeouts"],
        )
        downloader_session = stage2_result.session
        if not run.keep_sessions_running and downloader_session:
            downloader_session = emule.stop(downloader_session)
        copy_agent_artifacts(agent_stage2_session, stage2_result.agent_dump_path, run.agent_stage2_artifacts)
        copy_harness_artifacts(downloader_session, run.downloader_artifacts)
        copy_small_download(stage2_result.downloaded_file, run.downloader_artifacts)
        if not run.keep_sessions_running:
            downloader_session = None
        copy_server_artifacts(server_session, run.server_artifacts)

        summary = {
            "schemaVersion": "run-summary/v1",
            "scenarioId": run.scenario_id,
            "runId": run.run_id,
            "completed": True,
            "bindAddr": str(server["host"]),
            "fileHash": seeder_result.parsed_link.file_hash,
            "fileName": seeder_result.parsed_link.file_name,
            "fileSize": seeder_result.parsed_link.file_size,
            "serverAdminBaseUrl": server_session.admin_base_url,
            "serverPublishedName": published.get("name"),
            "serverPublishedSources": published.get("sources"),
            "transportMode": run.transport_mode,
            "sameHostTransferMode": {
                "enabled": True,
                "rationale": "local_server_source_search" if run.enable_obfuscation else "local_server_plus_loopback_source_hint",
                "agentSourceHint": stage1_result.source_hint is not None,
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
        }
        write_json(run.run_summary_path, summary)
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
            if server_session is not None:
                ed2k_server.stop(server_session)
        if not run.run_summary_path.exists():
            write_json(
                run.run_summary_path,
                {
                    "schemaVersion": "run-summary/v1",
                    "scenarioId": run.scenario_id,
                    "runId": run.run_id,
                    "completed": False,
                    "transportMode": run.transport_mode,
                    "fileHash": seeder_result.parsed_link.file_hash if seeder_result else None,
                    "fileName": seeder_result.parsed_link.file_name if seeder_result else file_name,
                    "fileSize": seeder_result.parsed_link.file_size if seeder_result else file_size,
                    "failedReason": failed_reason,
                    "finishedAtUtc": utc_now(),
                },
            )
