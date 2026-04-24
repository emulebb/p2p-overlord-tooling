from __future__ import annotations

from pathlib import Path
from typing import Any

from tests.e2e.lib import ed2k, http
from tests.e2e.lib.agent import AgentRuntime, AgentSession
from tests.e2e.lib.artifacts import latest_file
from tests.e2e.lib.ed2k_live import start_live_agent_session
from tests.e2e.lib.ed2k_private import copy_agent_artifacts, create_private_ed2k_run, utc_now
from tests.e2e.lib.live_runtime import resolve_live_scenario_prerequisites
from tests.e2e.lib.manifests import write_json
from tests.e2e.lib.paths import WorkspacePaths
from tests.e2e.lib.search_callbacks import (
    read_result_batches,
    select_ed2k_keyword_candidate,
    start_search_callback_collector,
    stop_search_callback_collector,
    wait_for_search_event,
)


DEFAULT_AGENT_CFG = {
    "controlPort": 13301,
    "kadPort": 41000,
    "ed2kPort": 41001,
}
SEARCH_TIMEOUT_SECONDS = 180
DOWNLOAD_TIMEOUT_SECONDS = 900
BOOTSTRAP_READY_TIMEOUT_SECONDS = 180


def run_live_kad_search_download_to_agent_scenario(
    workspace_paths: WorkspacePaths,
    pytestconfig,
    *,
    scenario_id: str,
    manifest: dict[str, Any],
    transport_mode: str,
) -> None:
    prerequisites = resolve_live_scenario_prerequisites(workspace_paths, manifest)
    query = str(manifest["search"]["query"])
    run = create_private_ed2k_run(
        workspace_paths,
        scenario_id=scenario_id,
        transport_mode=transport_mode,
        file_name=f"{query.replace(' ', '-')}-{transport_mode}.candidate",
        file_size=1,
        file_pattern="live-kad-search-download",
        keep_sessions_running=bool(pytestconfig.getoption("--keep-sessions-running")),
        skip_build=bool(pytestconfig.getoption("--skip-runtime-build")),
    )

    agent = AgentRuntime(workspace_paths)
    callback_session = start_search_callback_collector(run.artifact_root / "callbacks")
    agent_session: AgentSession | None = None
    candidate: dict[str, object] | None = None
    transfer_manifest: dict | None = None
    agent_udp_dump_path: Path | None = None
    agent_dump_path: Path | None = None
    failed_reason: str | None = None
    search_job: dict[str, object] | None = None

    try:
        if not run.skip_build:
            agent.build()

        agent_session = start_live_agent_session(
            agent,
            run,
            prerequisites,
            DEFAULT_AGENT_CFG,
            {"serverSelection": {"connectTimeoutMilliseconds": 5_000}},
            reset_runtime_root=True,
            disable_kad=False,
            probe_search_term=query,
        )
        bootstrap_stats = http.wait_json_until(
            agent_session.stats_url,
            predicate=_kad_bootstrap_ready,
            timeout_seconds=BOOTSTRAP_READY_TIMEOUT_SECONDS,
            poll_seconds=2,
        )

        search_job = agent.post_search_keyword(
            agent_session,
            query=query,
            callback_url=callback_session.base_url,
        )
        job_id = str(search_job["job_id"])
        wait_for_search_event(
            callback_session,
            job_id=job_id,
            status="started",
            timeout_seconds=SEARCH_TIMEOUT_SECONDS,
        )
        wait_for_search_event(
            callback_session,
            job_id=job_id,
            status="completed",
            timeout_seconds=SEARCH_TIMEOUT_SECONDS,
        )
        result_batches = [
            batch for batch in read_result_batches(callback_session) if str(batch.get("job_id")) == job_id
        ]
        candidate = select_ed2k_keyword_candidate(result_batches, query=query)

        agent.post_enrich_download(
            agent_session,
            file_hash=str(candidate["file_hash"]),
            file_name=str(candidate["file_name"]),
            file_size=int(candidate["file_size"]),
        )
        transfer_manifest = agent.wait_transfer_manifest(
            agent_session,
            file_hash=str(candidate["file_hash"]),
            timeout_seconds=DOWNLOAD_TIMEOUT_SECONDS,
        )
        if transfer_manifest.get("completed") is not True:
            raise AssertionError(
                "transfer did not complete "
                f"file_hash={candidate['file_hash']} "
                f"sources={len(transfer_manifest.get('sources') or [])} "
                f"aich_root={transfer_manifest.get('aich_root')!r}"
            )
        assert transfer_manifest.get("aich_root")
        assert transfer_manifest.get("sources")

        agent_dump_path = agent.latest_ed2k_dump(agent_session)
        assert agent_dump_path is not None
        agent_udp_dump_path = latest_file(agent_session.log_root, "agent-udp-dump-*.jsonl")
        assert agent_udp_dump_path is not None
        assert _dump_has_state_id(agent_udp_dump_path, direction="send", state_id="kad.send.kademlia2_search_key_req")
        assert _dump_has_state_id(agent_udp_dump_path, direction="recv", state_id="kad.recv.kademlia2_search_res")
        assert ed2k.dump_has_opcode(agent_dump_path, direction="send", opcode_names=("OP_HELLO",))
        assert ed2k.dump_has_opcode(agent_dump_path, direction="recv", opcode_names=("OP_HELLOANSWER",))
        assert ed2k.dump_has_opcode(agent_dump_path, direction="send", opcode_names=("OP_STARTUPLOADREQ",))
        assert ed2k.dump_has_opcode(
            agent_dump_path,
            direction="recv",
            opcode_names=("OP_COMPRESSEDPART", "OP_COMPRESSEDPART_I64"),
        )
        assert transport_mode in ed2k.dump_transport_modes(agent_dump_path)

        agent.copy_transfer(
            agent_session,
            file_hash=str(candidate["file_hash"]),
            destination_root=run.agent_stage1_artifacts,
        )
        copy_agent_artifacts(agent_session, agent_dump_path, run.agent_stage1_artifacts)

        write_json(
            run.run_summary_path,
            {
                "schemaVersion": "run-summary/v1",
                "scenarioId": run.scenario_id,
                "runId": run.run_id,
                "completed": True,
                "query": query,
                "searchJobId": job_id,
                "transportMode": run.transport_mode,
                "candidate": {
                    "fileHash": candidate["file_hash"],
                    "fileName": candidate["file_name"],
                    "fileSize": candidate["file_size"],
                },
                "transferManifest": transfer_manifest,
                "selectedServerCount": len(prerequisites.server_entries),
                "bootstrapStats": {
                    "peersConnected": int(
                        bootstrap_stats.get("peers_connected") or 0
                    ),
                },
                "evidence": {
                    "bootstrapStatsObserved": True,
                    "searchStarted": True,
                    "searchCompleted": True,
                    "searchResultBatchCount": len(result_batches),
                    "kadKeywordSearchObserved": True,
                    "transferCompleted": True,
                    "transportModes": ed2k.dump_transport_modes(agent_dump_path),
                    "agentEd2kDumpPresent": agent_dump_path is not None,
                    "agentUdpDumpPresent": agent_udp_dump_path is not None,
                },
                "finishedAtUtc": utc_now(),
            },
        )
    except Exception as exc:
        failed_reason = str(exc)
        raise
    finally:
        if not run.keep_sessions_running and agent_session is not None:
            agent.stop(agent_session)
        stop_search_callback_collector(callback_session)
        if not run.run_summary_path.exists():
            write_json(
                run.run_summary_path,
                {
                    "schemaVersion": "run-summary/v1",
                    "scenarioId": run.scenario_id,
                    "runId": run.run_id,
                    "completed": False,
                    "transportMode": run.transport_mode,
                    "query": query,
                    "searchJobId": search_job["job_id"] if search_job else None,
                    "candidate": candidate,
                    "transferManifest": transfer_manifest,
                    "failedReason": failed_reason,
                    "finishedAtUtc": utc_now(),
                },
            )


def _dump_has_state_id(path: Path, *, direction: str, state_id: str) -> bool:
    return any(
        record.get("direction") == direction and record.get("state_id") == state_id
        for record in ed2k.dump_records(path)
    )


def _kad_bootstrap_ready(response: dict[str, Any]) -> bool:
    return bool(response.get("kad_bootstrapped"))
