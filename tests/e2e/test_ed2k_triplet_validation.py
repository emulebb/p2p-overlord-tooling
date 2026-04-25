from __future__ import annotations

from pathlib import Path

import pytest

from tests.e2e.lib import http
from tests.e2e.lib.agent import AgentRuntime, AgentSession
from tests.e2e.lib.ed2k_private import (
    copy_agent_artifacts,
    copy_server_artifacts,
    create_private_ed2k_run,
    file_contains_text,
    run_identity,
    start_private_agent_session,
    utc_now,
)
from tests.e2e.lib.goed2k import Goed2kRuntime, Goed2kSession
from tests.e2e.lib.manifests import load_manifest, write_json
from tests.e2e.lib.paths import WorkspacePaths


SCENARIO_ID = "ed2k.server.triplet.validation.v1"
RUNTIME_CONFIG_SCENARIO_ID = "ed2k.server.emule-harness.agent.private.v1"
CALLBACK_CASE_ID = "callback-limit"
CALLBACK_LOW_ID_HOST = "1.0.0.0"
CALLBACK_TCP_PORT = 4662
CALLBACK_MANIFEST_TIMEOUT_SECONDS = 150
CALLBACK_STATS_TIMEOUT_SECONDS = 60


@pytest.mark.e2e
@pytest.mark.local
@pytest.mark.ed2k
@pytest.mark.slow
def test_private_ed2k_server_triplet_callback_limit(
    workspace_paths: WorkspacePaths,
    pytestconfig: pytest.Config,
) -> None:
    run_private_ed2k_server_triplet_callback_limit_scenario(
        workspace_paths,
        pytestconfig,
        scenario_id=SCENARIO_ID,
    )


def run_private_ed2k_server_triplet_callback_limit_scenario(
    workspace_paths: WorkspacePaths,
    pytestconfig: pytest.Config,
    *,
    scenario_id: str,
    artifact_scenario_id: str | None = None,
    run_slug: str | None = None,
    metadata: dict[str, object] | None = None,
) -> None:
    manifest = load_manifest(workspace_paths, SCENARIO_ID)
    runtime_manifest = load_manifest(workspace_paths, RUNTIME_CONFIG_SCENARIO_ID)
    file_hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    file_name = "callback-only-private-source.bin"
    file_size = int(pytestconfig.getoption("--file-size-bytes"))

    run = create_private_ed2k_run(
        workspace_paths,
        scenario_id=scenario_id,
        transport_mode="plaintext",
        file_name=file_name,
        file_size=file_size,
        file_pattern="ed2k-triplet-callback-only",
        keep_sessions_running=bool(pytestconfig.getoption("--keep-sessions-running")),
        skip_build=bool(pytestconfig.getoption("--skip-runtime-build")),
        artifact_scenario_id=artifact_scenario_id,
        run_slug=run_slug,
        metadata=metadata,
    )

    agent = AgentRuntime(workspace_paths)
    goed2k = Goed2kRuntime(workspace_paths)

    server_cfg = runtime_manifest["server"]
    agent_cfg = runtime_manifest["agent"]
    source_catalog_path = _write_callback_only_catalog(
        run.artifact_root / "callback-only-catalog.json",
        file_hash=file_hash,
        file_name=file_name,
        file_size=file_size,
    )

    server_session: Goed2kSession | None = None
    agent_session: AgentSession | None = None
    transfer_manifest: dict | None = None
    server_stats: dict | None = None
    failed_reason: str | None = None

    try:
        if not run.skip_build:
            agent.build()

        server_session = goed2k.start_private_session(
            scenario_root=run.artifact_root / "srv",
            listen_host=str(server_cfg["host"]),
            tcp_port=int(server_cfg["tcpPort"]),
            admin_port=int(server_cfg["adminPort"]),
            udp_port_offset=int(server_cfg["udpPortOffset"]),
            admin_token=str(server_cfg["adminToken"]),
            source_catalog_path=source_catalog_path,
            enable_obfuscation=False,
            skip_build=run.skip_build,
        )
        agent_session = start_private_agent_session(
            agent,
            run,
            agent_cfg,
            server_cfg,
            reset_runtime_root=True,
        )

        agent.post_enrich_download(
            agent_session,
            file_hash=file_hash,
            file_name=file_name,
            file_size=file_size,
        )

        transfer_manifest = agent.wait_transfer_manifest(
            agent_session,
            file_hash=file_hash,
            timeout_seconds=CALLBACK_MANIFEST_TIMEOUT_SECONDS,
        )
        assert transfer_manifest.get("completed") is False

        stats_response = http.wait_json_until(
            f"{server_session.admin_base_url}/api/stats",
            predicate=_has_callback_and_source_requests,
            timeout_seconds=CALLBACK_STATS_TIMEOUT_SECONDS,
            poll_seconds=2,
            headers={"X-Admin-Token": server_session.admin_token},
        )
        assert stats_response["ok"] is True
        server_stats = stats_response["data"]
        assert int(server_stats["callback_requests"]) >= 1
        assert int(server_stats["source_requests"]) >= 1

        assert file_contains_text(
            agent_session.agent_log_path,
            "native ED2K download requesting server callback",
        )
        assert file_contains_text(
            agent_session.agent_log_path,
            "native ED2K download source filtering left no direct-dialable sources",
        )

        transfer_dir = agent_session.transfer_root / file_hash.lower()
        if transfer_dir.is_dir():
            agent.copy_transfer(
                agent_session,
                file_hash=file_hash,
                destination_root=run.agent_stage1_artifacts,
            )
        copy_agent_artifacts(
            agent_session,
            agent.latest_ed2k_dump(agent_session),
            run.agent_stage1_artifacts,
        )
        copy_server_artifacts(server_session, run.server_artifacts)

        write_json(
            run.run_summary_path,
            {
                "schemaVersion": "run-summary/v1",
                **run_identity(run),
                "completed": True,
                "transportMode": run.transport_mode,
                "casesValidated": [CALLBACK_CASE_ID],
                "fileHash": file_hash,
                "fileName": file_name,
                "fileSize": file_size,
                "serverAdminBaseUrl": server_session.admin_base_url,
                "callbackOnlySource": {
                    "host": CALLBACK_LOW_ID_HOST,
                    "tcpPort": CALLBACK_TCP_PORT,
                },
                "serverStats": {
                    "callbackRequests": server_stats["callback_requests"],
                    "sourceRequests": server_stats["source_requests"],
                },
                "transferManifest": {
                    "completed": transfer_manifest.get("completed"),
                    "md4HashsetAcquired": transfer_manifest.get("md4_hashset_acquired"),
                    "aichHashsetAcquired": transfer_manifest.get("aich_hashset_acquired"),
                },
                "evidence": {
                    "callbackRequestIssued": True,
                    "callbackOnlySourceObserved": True,
                    "directDialSuppressed": True,
                },
                "finishedAtUtc": utc_now(),
            },
        )
    except Exception as exc:
        failed_reason = str(exc)
        raise
    finally:
        if not run.keep_sessions_running:
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
                    "casesValidated": [CALLBACK_CASE_ID],
                    "fileHash": file_hash,
                    "fileName": file_name,
                    "fileSize": file_size,
                    "failedReason": failed_reason,
                    "finishedAtUtc": utc_now(),
                },
            )


def _write_callback_only_catalog(
    path: Path,
    *,
    file_hash: str,
    file_name: str,
    file_size: int,
) -> Path:
    write_json(
        path,
        {
            "files": [
                {
                    "hash": file_hash.upper(),
                    "name": file_name,
                    "size": file_size,
                    "file_type": "Program",
                    "extension": "bin",
                    "sources": 1,
                    "complete_sources": 1,
                    "endpoints": [
                        {
                            "host": CALLBACK_LOW_ID_HOST,
                            "port": CALLBACK_TCP_PORT,
                        }
                    ],
                }
            ]
        },
    )
    return path


def _has_callback_and_source_requests(response: object) -> bool:
    if not isinstance(response, dict) or response.get("ok") is not True:
        return False
    data = response.get("data")
    if not isinstance(data, dict):
        return False
    return int(data.get("callback_requests", 0)) >= 1 and int(data.get("source_requests", 0)) >= 1
