from __future__ import annotations

from pathlib import Path

import pytest

from tests.e2e.lib import ed2k
from tests.e2e.lib.agent import AgentRuntime, AgentSession
from tests.e2e.lib.artifacts import latest_file
from tests.e2e.lib.ed2k_private import (
    copy_agent_artifacts,
    copy_harness_artifacts,
    create_private_ed2k_run,
    file_contains_text,
    require_dump,
    run_identity,
    start_private_agent_session,
    utc_now,
)
from tests.e2e.lib.emule_harness import EmuleHarnessRuntime, EmuleProfile, EmuleSession
from tests.e2e.lib.manifests import load_manifest, write_json
from tests.e2e.lib.paths import WorkspacePaths
from tests.e2e.lib.payloads import write_deterministic_binary
from tests.e2e.lib.waits import wait_path


SCENARIO_ID = "kad.emule-harness.ed2k.download.private.v1"
DEFAULT_FILE_PATTERN = "ubuntu-linux-ed2k-kad-private"
DEFAULT_AGENT_DOWNLOAD_SECONDS = 180
DEFAULT_HARNESS_READY_SECONDS = 60


def run_private_kad_ed2k_download_to_agent_scenario(
    workspace_paths: WorkspacePaths,
    pytestconfig: pytest.Config,
    *,
    scenario_id: str,
    config_scenario_id: str | None = None,
    artifact_scenario_id: str | None = None,
    run_slug: str | None = None,
    metadata: dict[str, object] | None = None,
) -> None:
    manifest = load_manifest(workspace_paths, config_scenario_id or scenario_id)
    harness_cfg = manifest["emuleHarness"]
    agent_cfg = manifest["agent"]

    run = create_private_ed2k_run(
        workspace_paths,
        scenario_id=scenario_id,
        transport_mode="plaintext",
        file_name=str(harness_cfg["seedFileName"]),
        file_size=int(pytestconfig.getoption("--file-size-bytes")),
        file_pattern=DEFAULT_FILE_PATTERN,
        keep_sessions_running=bool(pytestconfig.getoption("--keep-sessions-running")),
        skip_build=bool(pytestconfig.getoption("--skip-runtime-build")),
        artifact_scenario_id=artifact_scenario_id,
        run_slug=run_slug,
        metadata=metadata,
    )

    emule = EmuleHarnessRuntime(workspace_paths)
    agent = AgentRuntime(workspace_paths)

    profile: EmuleProfile | None = None
    seeder_session: EmuleSession | None = None
    agent_session: AgentSession | None = None
    parsed_link: ed2k.Ed2kLink | None = None
    transfer_manifest: dict | None = None
    agent_udp_dump_path: Path | None = None
    agent_dump_path: Path | None = None
    failed_reason: str | None = None

    try:
        if not run.skip_build:
            emule.build()
            agent.build()

        profile = emule.materialize_private_ed2k_profile(
            profile_root=run.artifact_root / "seed",
            bind_addr=str(harness_cfg["bindAddr"]),
            tcp_port=int(harness_cfg["tcpPort"]),
            udp_port=int(harness_cfg["udpPort"]),
            server_udp_port=int(harness_cfg["serverUdpPort"]),
            web_port=int(harness_cfg["webPort"]),
            kad_udp_key=int(harness_cfg["kadUdpKey"]),
            enable_kademlia=True,
            enable_ed2k=True,
            reset_transient_state=True,
        )
        seed_file_path = profile.incoming_root / run.file_name
        write_deterministic_binary(seed_file_path, size_bytes=run.file_size, pattern=run.file_pattern)
        export_link_path = run.artifact_root / "seed.ed2k"
        seeder_session = emule.start_private_ed2k_session(
            profile=profile,
            seed_file_path=seed_file_path,
            export_link_path=export_link_path,
            skip_build=True,
        )
        wait_path(export_link_path, timeout_seconds=DEFAULT_HARNESS_READY_SECONDS)
        parsed_link = ed2k.parse_ed2k_link_file(export_link_path)

        agent_session = start_private_agent_session(
            agent,
            run,
            agent_cfg,
            None,
            reset_runtime_root=True,
            disable_kad=False,
            emule_harness_bootstrap_node=f"{harness_cfg['bindAddr']}:{harness_cfg['udpPort']}",
            kad_bootstrap_ready_contacts=1,
        )

        agent.post_enrich_download(
            agent_session,
            file_hash=parsed_link.file_hash,
            file_name=parsed_link.file_name,
            file_size=parsed_link.file_size,
        )
        transfer_manifest = agent.wait_transfer_manifest(
            agent_session,
            file_hash=parsed_link.file_hash,
            timeout_seconds=DEFAULT_AGENT_DOWNLOAD_SECONDS,
        )
        assert transfer_manifest.get("completed") is True
        assert transfer_manifest.get("aich_root")
        assert transfer_manifest.get("sources")
        assert transfer_manifest["sources"][0]["ip"] == str(harness_cfg["bindAddr"])
        assert int(transfer_manifest["sources"][0]["tcp_port"]) == int(harness_cfg["tcpPort"])

        agent_dump_path = require_dump(agent.latest_ed2k_dump(agent_session), "agent Kad-assisted ED2K dump")
        agent_udp_dump_path = require_dump(
            latest_file(agent_session.log_root, "agent-udp-dump-*.jsonl"),
            "agent Kad UDP dump",
        )
        assert _dump_has_state_id(
            agent_udp_dump_path,
            direction="send",
            state_id="kad.send.kademlia2_search_source_req",
        )
        assert _dump_has_state_id(
            agent_udp_dump_path,
            direction="recv",
            state_id="kad.recv.kademlia2_search_res",
        )
        assert ed2k.dump_has_opcode(agent_dump_path, direction="send", opcode_names=("OP_HELLO",))
        assert ed2k.dump_has_opcode(agent_dump_path, direction="recv", opcode_names=("OP_HELLOANSWER",))
        assert ed2k.dump_has_opcode(agent_dump_path, direction="send", opcode_names=("OP_STARTUPLOADREQ",))
        assert ed2k.dump_has_opcode(
            agent_dump_path,
            direction="recv",
            opcode_names=("OP_COMPRESSEDPART", "OP_COMPRESSEDPART_I64"),
        )
        assert "plaintext" in ed2k.dump_transport_modes(agent_dump_path)

        assert file_contains_text(
            agent_session.agent_log_path,
            "bootstrap complete - routing table has 1 contacts",
        )
        assert file_contains_text(
            agent_session.agent_log_path,
            "native ED2K download Kad source fallback produced",
        )
        assert file_contains_text(
            agent_session.agent_log_path,
            "native ED2K download source acquisition completed",
        )

        if not run.keep_sessions_running and seeder_session is not None:
            seeder_session = emule.stop(seeder_session)
        agent.copy_transfer(
            agent_session,
            file_hash=parsed_link.file_hash,
            destination_root=run.agent_stage1_artifacts,
        )
        copy_agent_artifacts(agent_session, agent_dump_path, run.agent_stage1_artifacts)
        copy_harness_artifacts(seeder_session, run.seeder_artifacts)
        if not run.keep_sessions_running:
            seeder_session = None

        write_json(
            run.run_summary_path,
            {
                "schemaVersion": "run-summary/v1",
                **run_identity(run),
                "completed": True,
                "transportMode": run.transport_mode,
                "fileHash": parsed_link.file_hash,
                "fileName": parsed_link.file_name,
                "fileSize": parsed_link.file_size,
                "evidence": {
                    "agentBootstrapComplete": True,
                    "agentKadFallbackUsed": True,
                    "agentKadSearchObserved": True,
                    "agentHelloBranchObserved": True,
                    "agentStage1TransportModes": ed2k.dump_transport_modes(agent_dump_path),
                    "agentEd2kDumpPresent": True,
                    "agentUdpDumpPresent": True,
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
        if not run.run_summary_path.exists():
            write_json(
                run.run_summary_path,
                {
                    "schemaVersion": "run-summary/v1",
                    **run_identity(run),
                    "completed": False,
                    "transportMode": run.transport_mode,
                    "fileHash": parsed_link.file_hash if parsed_link else None,
                    "fileName": parsed_link.file_name if parsed_link else run.file_name,
                    "fileSize": parsed_link.file_size if parsed_link else run.file_size,
                    "failedReason": failed_reason,
                    "finishedAtUtc": utc_now(),
                },
            )


@pytest.mark.e2e
@pytest.mark.local
@pytest.mark.ed2k
@pytest.mark.slow
@pytest.mark.harness_to_agent
def test_private_kad_ed2k_download_to_agent(
    workspace_paths: WorkspacePaths,
    pytestconfig: pytest.Config,
) -> None:
    run_private_kad_ed2k_download_to_agent_scenario(
        workspace_paths,
        pytestconfig,
        scenario_id=SCENARIO_ID,
    )


def _dump_has_state_id(path: Path, *, direction: str, state_id: str) -> bool:
    return any(
        record.get("direction") == direction and record.get("state_id") == state_id
        for record in ed2k.dump_records(path)
    )
