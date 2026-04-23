from __future__ import annotations

import pytest

from tests.e2e.lib.agent import AgentRuntime, AgentSession
from tests.e2e.lib.ed2k_private import (
    ED2K_PART_SIZE_BYTES,
    AgentSeedResult,
    HarnessDownloadResult,
    copy_agent_artifacts,
    copy_harness_artifacts,
    copy_server_artifacts,
    copy_small_download,
    create_private_ed2k_run,
    ingest_local_file_via_agent,
    run_agent_to_harness_stage,
    start_private_agent_session,
    start_private_server,
    utc_now,
)
from tests.e2e.lib.emule_harness import EmuleHarnessRuntime, EmuleSession
from tests.e2e.lib.goed2k import Goed2kRuntime, Goed2kSession
from tests.e2e.lib.manifests import load_manifest, write_json
from tests.e2e.lib.paths import WorkspacePaths


SCENARIO_ID = "ed2k.server.agent.emule-harness.private.large.v1"


@pytest.mark.e2e
@pytest.mark.local
@pytest.mark.ed2k
@pytest.mark.agent_to_harness
@pytest.mark.compressed
@pytest.mark.slow
def test_private_ed2k_agent_seed_to_harness_download(
    workspace_paths: WorkspacePaths,
    pytestconfig: pytest.Config,
    transport_mode: str,
) -> None:
    manifest = load_manifest(workspace_paths, SCENARIO_ID)
    file_size = int(pytestconfig.getoption("--file-size-bytes") or manifest["file"]["sizeBytes"])
    if file_size <= ED2K_PART_SIZE_BYTES:
        pytest.fail(
            f"{SCENARIO_ID} requires a payload larger than one ED2K part "
            f"({ED2K_PART_SIZE_BYTES} bytes) to validate AICH/hashset behavior"
        )

    run = create_private_ed2k_run(
        workspace_paths,
        scenario_id=SCENARIO_ID,
        transport_mode=transport_mode,
        file_name=str(manifest["file"]["name"]),
        file_size=file_size,
        file_pattern=str(manifest["file"]["pattern"]),
        keep_sessions_running=bool(pytestconfig.getoption("--keep-sessions-running")),
        skip_build=bool(pytestconfig.getoption("--skip-runtime-build")),
    )

    emule = EmuleHarnessRuntime(workspace_paths)
    agent = AgentRuntime(workspace_paths)
    goed2k = Goed2kRuntime(workspace_paths)

    server_session: Goed2kSession | None = None
    agent_session: AgentSession | None = None
    downloader_session: EmuleSession | None = None
    seed_result: AgentSeedResult | None = None
    download_result: HarnessDownloadResult | None = None
    failed_reason: str | None = None

    try:
        if not run.skip_build:
            emule.build()
            agent.build()

        server = manifest["server"]
        agent_cfg = manifest["agent"]
        server_session = start_private_server(goed2k, run, server)
        agent_session = start_private_agent_session(
            agent,
            run,
            agent_cfg,
            server,
            reset_runtime_root=True,
        )
        seed_result = ingest_local_file_via_agent(agent, run, agent_session)
        agent.copy_transfer(
            agent_session,
            file_hash=seed_result.parsed_link.file_hash,
            destination_root=run.agent_stage2_artifacts,
        )

        published = goed2k.wait_file_available(
            server_session,
            file_hash=seed_result.parsed_link.file_hash,
            timeout_seconds=int(manifest["timeouts"]["serverPublishSeconds"]),
        )
        download_result = run_agent_to_harness_stage(
            emule,
            agent,
            run,
            agent_session,
            seed_result.parsed_link,
            server_cfg=server,
            downloader_cfg=manifest["harnessDownloader"],
            agent_cfg=agent_cfg,
            timeouts_cfg=manifest["timeouts"],
        )
        downloader_session = download_result.session
        if not run.keep_sessions_running and downloader_session:
            downloader_session = emule.stop(downloader_session)

        copy_agent_artifacts(agent_session, download_result.agent_dump_path, run.agent_stage2_artifacts)
        copy_harness_artifacts(downloader_session, run.downloader_artifacts)
        copy_small_download(download_result.downloaded_file, run.downloader_artifacts)
        if not run.keep_sessions_running:
            downloader_session = None
        copy_server_artifacts(server_session, run.server_artifacts)

        write_json(
            run.run_summary_path,
            {
                "schemaVersion": "run-summary/v1",
                "scenarioId": run.scenario_id,
                "runId": run.run_id,
                "completed": True,
                "bindAddr": str(server["host"]),
                "fileHash": seed_result.parsed_link.file_hash,
                "fileName": seed_result.parsed_link.file_name,
                "fileSize": seed_result.parsed_link.file_size,
                "transportMode": run.transport_mode,
                "serverAdminBaseUrl": server_session.admin_base_url,
                "serverPublishedName": published.get("name"),
                "serverPublishedSources": published.get("sources"),
                "localIngest": seed_result.ingest_summary,
                "evidence": {
                    "exportedLinkHasAich": bool(seed_result.parsed_link.aich_root),
                    "stage2HashsetRequestAich": True,
                    "stage2HashsetAnswerAich": True,
                    "stage2CompressedParts": True,
                    "stage2TransportModes": download_result.transport_modes,
                    "stage2EvidenceSource": download_result.evidence_source,
                    "harnessVerifierAichOk": True,
                    "agentStage2Ed2kDumpPresent": download_result.agent_dump_path is not None,
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
            if agent_session is not None:
                agent.stop(agent_session)
            if server_session is not None:
                goed2k.stop(server_session)
        if not run.run_summary_path.exists():
            write_json(
                run.run_summary_path,
                {
                    "schemaVersion": "run-summary/v1",
                    "scenarioId": run.scenario_id,
                    "runId": run.run_id,
                    "completed": False,
                    "transportMode": run.transport_mode,
                    "fileHash": seed_result.parsed_link.file_hash if seed_result else None,
                    "fileName": seed_result.parsed_link.file_name if seed_result else run.file_name,
                    "fileSize": seed_result.parsed_link.file_size if seed_result else run.file_size,
                    "failedReason": failed_reason,
                    "finishedAtUtc": utc_now(),
                },
            )
