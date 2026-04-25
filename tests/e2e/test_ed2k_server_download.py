from __future__ import annotations

import pytest

from tests.e2e.lib.agent import AgentRuntime, AgentSession
from tests.e2e.lib.ed2k_private import (
    AgentDownloadResult,
    HarnessSeederResult,
    copy_agent_artifacts,
    copy_harness_artifacts,
    copy_server_artifacts,
    create_private_ed2k_run,
    run_identity,
    run_harness_to_agent_stage,
    start_private_agent_session,
    start_private_harness_seeder,
    start_private_server,
    utc_now,
)
from tests.e2e.lib.emule_harness import EmuleHarnessRuntime, EmuleSession
from tests.e2e.lib.goed2k import Goed2kRuntime, Goed2kSession
from tests.e2e.lib.manifests import load_manifest, write_json
from tests.e2e.lib.paths import WorkspacePaths


SCENARIO_ID = "ed2k.server.emule-harness.agent.private.v1"
DEFAULT_FILE_PATTERN = "ubuntu-linux-ed2k-private-server"
DEFAULT_SERVER_PUBLISH_SECONDS = 180
DEFAULT_AGENT_DOWNLOAD_SECONDS = 300
DEFAULT_HARNESS_READY_SECONDS = 60


def run_private_ed2k_server_download_to_agent_scenario(
    workspace_paths: WorkspacePaths,
    pytestconfig: pytest.Config,
    *,
    scenario_id: str,
    transport_mode: str,
    config_scenario_id: str | None = None,
    use_plaintext_loopback_source_hint: bool = False,
    artifact_scenario_id: str | None = None,
    run_slug: str | None = None,
    metadata: dict[str, object] | None = None,
) -> None:
    manifest = load_manifest(workspace_paths, config_scenario_id or scenario_id)
    harness_cfg = manifest["emuleHarness"]
    run = create_private_ed2k_run(
        workspace_paths,
        scenario_id=scenario_id,
        transport_mode=transport_mode,
        file_name=str(harness_cfg["seedFileName"]),
        file_size=int(pytestconfig.getoption("--file-size-bytes")),
        file_pattern=DEFAULT_FILE_PATTERN,
        keep_sessions_running=bool(pytestconfig.getoption("--keep-sessions-running")),
        skip_build=bool(pytestconfig.getoption("--skip-runtime-build")),
        artifact_scenario_id=artifact_scenario_id,
        run_slug=run_slug,
        metadata=metadata,
    )

    timeouts_cfg = {
        "initialPublishDelaySeconds": 0,
        "agentDownloadSeconds": DEFAULT_AGENT_DOWNLOAD_SECONDS,
        "harnessReadySeconds": DEFAULT_HARNESS_READY_SECONDS,
    }

    emule = EmuleHarnessRuntime(workspace_paths)
    agent = AgentRuntime(workspace_paths)
    goed2k = Goed2kRuntime(workspace_paths)

    server_session: Goed2kSession | None = None
    seeder_session: EmuleSession | None = None
    agent_session: AgentSession | None = None
    seeder_result: HarnessSeederResult | None = None
    download_result: AgentDownloadResult | None = None
    failed_reason: str | None = None

    try:
        if not run.skip_build:
            emule.build()
            agent.build()

        server = manifest["server"]
        agent_cfg = manifest["agent"]
        server_session = start_private_server(goed2k, run, server)
        seeder_result = start_private_harness_seeder(emule, run, server, harness_cfg, timeouts_cfg)
        seeder_session = seeder_result.session
        published = goed2k.wait_file_available(
            server_session,
            file_hash=seeder_result.parsed_link.file_hash,
            timeout_seconds=DEFAULT_SERVER_PUBLISH_SECONDS,
        )

        agent_session = start_private_agent_session(
            agent,
            run,
            agent_cfg,
            server,
            reset_runtime_root=True,
        )
        download_result = run_harness_to_agent_stage(
            agent,
            run,
            agent_session,
            seeder_result.parsed_link,
            seeder_session=seeder_session,
            server_cfg=server,
            seeder_cfg=harness_cfg,
            timeouts_cfg=timeouts_cfg,
            use_plaintext_loopback_source_hint=use_plaintext_loopback_source_hint,
        )
        agent.copy_transfer(
            agent_session,
            file_hash=seeder_result.parsed_link.file_hash,
            destination_root=run.agent_stage1_artifacts,
        )

        if not run.keep_sessions_running and seeder_session:
            seeder_session = emule.stop(seeder_session)
        copy_agent_artifacts(agent_session, download_result.agent_dump_path, run.agent_stage1_artifacts)
        copy_harness_artifacts(seeder_session, run.seeder_artifacts)
        if not run.keep_sessions_running:
            seeder_session = None
        copy_server_artifacts(server_session, run.server_artifacts)

        write_json(
            run.run_summary_path,
            {
                "schemaVersion": "run-summary/v1",
                **run_identity(run),
                "completed": True,
                "bindAddr": str(server["host"]),
                "fileHash": seeder_result.parsed_link.file_hash,
                "fileName": seeder_result.parsed_link.file_name,
                "fileSize": seeder_result.parsed_link.file_size,
                "transportMode": run.transport_mode,
                "serverAdminBaseUrl": server_session.admin_base_url,
                "serverPublishedName": published.get("name"),
                "serverPublishedSources": published.get("sources"),
                "evidence": {
                    "exportedLinkHasAich": bool(seeder_result.parsed_link.aich_root),
                    "agentManifestAichAcquired": bool(download_result.transfer_manifest.get("aich_hashset_acquired")),
                    "stage1HashsetRequestAich": True,
                    "stage1HashsetAnswerAich": True,
                    "stage1CompressedParts": True,
                    "stage1TransportModes": download_result.transport_modes,
                    "stage1EvidenceSource": download_result.evidence_source,
                    "agentStage1Ed2kDumpPresent": download_result.agent_dump_path is not None,
                    "usedSourceHint": download_result.source_hint is not None,
                },
                "finishedAtUtc": utc_now(),
            },
        )
    except Exception as exc:
        failed_reason = str(exc)
        raise
    finally:
        if not run.keep_sessions_running:
            if seeder_session is not None:
                emule.stop(seeder_session)
            if agent_session is not None:
                agent.stop(agent_session)
            if server_session is not None:
                goed2k.stop(server_session)
        if not run.run_summary_path.exists():
            write_json(
                run.run_summary_path,
                {
                    "schemaVersion": "run-summary/v1",
                    **run_identity(run),
                    "completed": False,
                    "transportMode": run.transport_mode,
                    "fileHash": seeder_result.parsed_link.file_hash if seeder_result else None,
                    "fileName": seeder_result.parsed_link.file_name if seeder_result else run.file_name,
                    "fileSize": seeder_result.parsed_link.file_size if seeder_result else run.file_size,
                    "failedReason": failed_reason,
                    "finishedAtUtc": utc_now(),
                },
            )


@pytest.mark.e2e
@pytest.mark.local
@pytest.mark.ed2k
@pytest.mark.harness_to_agent
def test_private_ed2k_server_download_to_agent(
    workspace_paths: WorkspacePaths,
    pytestconfig: pytest.Config,
    transport_mode: str,
) -> None:
    run_private_ed2k_server_download_to_agent_scenario(
        workspace_paths,
        pytestconfig,
        scenario_id=SCENARIO_ID,
        transport_mode=transport_mode,
    )
