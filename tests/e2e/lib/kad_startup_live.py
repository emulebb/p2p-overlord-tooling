from __future__ import annotations

import time
from pathlib import Path
from typing import Any

from tests.e2e.lib import ed2k, http
from tests.e2e.lib.agent import AgentRuntime, AgentSession
from tests.e2e.lib.artifacts import latest_file
from tests.e2e.lib.ed2k_live import materialize_live_seed_bundle_to_harness_profile
from tests.e2e.lib.ed2k_private import (
    copy_agent_artifacts,
    copy_harness_artifacts,
    create_private_ed2k_run,
    utc_now,
)
from tests.e2e.lib.emule_harness import EmuleHarnessRuntime, EmuleProfile, EmuleSession
from tests.e2e.lib.live_runtime import resolve_live_scenario_prerequisites
from tests.e2e.lib.manifests import write_json
from tests.e2e.lib.paths import WorkspacePaths


DEFAULT_AGENT_CFG = {
    "controlPort": 13301,
    "kadPort": 41000,
    "ed2kPort": 41001,
}
MANUAL_PUBLISH_TIMEOUT_SECONDS = 180
POST_PUBLISH_FLUSH_SECONDS = 5


def run_live_kad_startup_publish_scenario(
    workspace_paths: WorkspacePaths,
    pytestconfig,
    *,
    scenario_id: str,
    manifest: dict[str, Any],
) -> None:
    prerequisites = resolve_live_scenario_prerequisites(workspace_paths, manifest)
    seed_request = dict(manifest["agent"]["seedRequest"])
    run = create_private_ed2k_run(
        workspace_paths,
        scenario_id=scenario_id,
        transport_mode="plaintext",
        file_name=str(seed_request["canonicalName"]),
        file_size=int(seed_request["size"]),
        file_pattern="live-kad-startup-publish",
        keep_sessions_running=bool(pytestconfig.getoption("--keep-sessions-running")),
        skip_build=bool(pytestconfig.getoption("--skip-runtime-build")),
    )

    emule = EmuleHarnessRuntime(workspace_paths)
    agent = AgentRuntime(workspace_paths)
    harness_profile: EmuleProfile | None = None
    harness_session: EmuleSession | None = None
    agent_session: AgentSession | None = None
    stats_response: dict[str, Any] | None = None
    failed_reason: str | None = None

    try:
        if not run.skip_build:
            emule.build()
            agent.build()

        harness_cfg = manifest["emuleHarness"]["seededPreferenceDefaults"]["eMule"]
        harness_profile = emule.materialize_private_ed2k_profile(
            profile_root=run.artifact_root / "seed",
            bind_addr=prerequisites.interface_binding.bind_ip,
            tcp_port=int(harness_cfg["Port"]),
            udp_port=int(harness_cfg["UDPPort"]),
            server_udp_port=int(harness_cfg["ServerUDPPort"]),
            web_port=47_101,
            kad_udp_key=int(harness_cfg["KadUDPKey"]),
            enable_kademlia=True,
            enable_ed2k=False,
            enable_upnp=True,
            reset_transient_state=True,
        )
        materialize_live_seed_bundle_to_harness_profile(harness_profile, prerequisites)
        emule.set_obfuscation_mode(harness_profile, obfuscated_preferred=False)
        harness_session = emule.start_private_ed2k_session(
            profile=harness_profile,
            skip_build=True,
        )

        agent_session = agent.start_private_ed2k_session(
            scenario_root=run.artifact_root / "agt",
            control_port=int(DEFAULT_AGENT_CFG["controlPort"]),
            kad_port=int(DEFAULT_AGENT_CFG["kadPort"]),
            ed2k_port=int(DEFAULT_AGENT_CFG["ed2kPort"]),
            p2p_bind_ip=prerequisites.interface_binding.bind_ip,
            disable_kad=False,
            kad_bootstrap_ready_contacts=1,
            probe_search_term=str(seed_request["canonicalName"]),
            nodes_dat_seed_path=prerequisites.seed_bundle.nodes_dat_path,
            kad_republish_interval_secs=3_600,
            kad_hello_intro_interval_secs=5,
            kad_hello_intro_fanout=2,
            kad_synthetic_publish_interval_secs=3_600,
            skip_build=run.skip_build,
        )
        agent.wait_control_ready(agent_session, timeout_seconds=180)

        seed_payload = agent.post_seed_popular(
            agent_session,
            file_hash=str(seed_request["hash"]),
            canonical_name=str(seed_request["canonicalName"]),
            file_size=int(seed_request["size"]),
            source_count=int(seed_request["sourceCount"]),
        )
        stats_response = http.wait_json_until(
            agent_session.stats_url,
            predicate=_manual_publish_observed,
            timeout_seconds=MANUAL_PUBLISH_TIMEOUT_SECONDS,
            poll_seconds=2,
        )

        if not run.keep_sessions_running:
            time.sleep(POST_PUBLISH_FLUSH_SECONDS)
            harness_session = emule.stop(harness_session)
            agent.stop(agent_session)
            copy_harness_artifacts(harness_session, run.seeder_artifacts)
            copy_agent_artifacts(
                agent_session,
                latest_file(agent_session.log_root, "agent-udp-dump-*.jsonl"),
                run.agent_stage1_artifacts,
            )

        agent_udp_dump_path = _require_path(
            latest_file(agent_session.log_root, "agent-udp-dump-*.jsonl"),
            "agent Kad UDP dump",
        )
        harness_udp_dump_path = _require_path(
            harness_session.udp_dump_path
            or latest_file(harness_profile.logs_root, "emule-harness-udp-dump-*.jsonl"),
            "harness Kad UDP dump",
        )
        assert _dump_has_state_id(
            agent_udp_dump_path,
            direction="send",
            state_id="kad.send.kademlia2_bootstrap_req",
        )
        assert _dump_has_state_id(
            agent_udp_dump_path,
            direction="recv",
            state_id="kad.recv.kademlia2_bootstrap_res",
        )
        assert _dump_has_one_of_state_ids(
            agent_udp_dump_path,
            direction="send",
            state_ids=("kad.send.kademlia2_hello_req", "kad.send.kademlia2_hello_res"),
        ) or _dump_has_one_of_state_ids(
            agent_udp_dump_path,
            direction="recv",
            state_ids=("kad.recv.kademlia2_hello_req", "kad.recv.kademlia2_hello_res"),
        )
        assert _dump_has_state_id(
            agent_udp_dump_path,
            direction="send",
            state_id="kad.send.kademlia2_publish_key_req",
        )
        assert _dump_has_state_id(
            agent_udp_dump_path,
            direction="send",
            state_id="kad.send.kademlia2_publish_source_req",
        )
        assert harness_session.trace_log_path.is_file()
        assert harness_udp_dump_path.is_file()

        publish_observability = stats_response["publish_observability"]
        write_json(
            run.run_summary_path,
            {
                "schemaVersion": "run-summary/v1",
                "scenarioId": run.scenario_id,
                "runId": run.run_id,
                "completed": True,
                "bindIp": prerequisites.interface_binding.bind_ip,
                "interfaceAlias": prerequisites.interface_binding.interface_alias,
                "seedPopularRequest": seed_payload[0],
                "publishObservability": publish_observability,
                "evidence": {
                    "manualPublishObserved": True,
                    "bootstrapObserved": True,
                    "helloObserved": True,
                    "publishKeyObserved": True,
                    "publishSourceObserved": True,
                    "agentUdpDumpPresent": True,
                    "harnessUdpDumpPresent": True,
                    "harnessTraceLogPresent": True,
                },
                "finishedAtUtc": utc_now(),
            },
        )
    except Exception as exc:
        failed_reason = str(exc)
        raise
    finally:
        if not run.keep_sessions_running:
            if harness_session is not None and harness_session.pid:
                try:
                    emule.stop(harness_session)
                except Exception:
                    pass
            if agent_session is not None:
                try:
                    agent.stop(agent_session)
                except Exception:
                    pass
        if not run.run_summary_path.exists():
            write_json(
                run.run_summary_path,
                {
                    "schemaVersion": "run-summary/v1",
                    "scenarioId": run.scenario_id,
                    "runId": run.run_id,
                    "completed": False,
                    "bindIp": prerequisites.interface_binding.bind_ip,
                    "failedReason": failed_reason,
                    "finishedAtUtc": utc_now(),
                },
            )


def _manual_publish_observed(response: dict[str, Any]) -> bool:
    publish = response.get("publish_observability") or {}
    if publish.get("last_seed_source") != "manual_api":
        return False
    latest_keyword = publish.get("latest_keyword_batch") or {}
    latest_source = publish.get("latest_source_batch") or {}
    return (
        latest_keyword.get("seed_source") == "manual_api"
        and int(latest_keyword.get("published_items") or 0) >= 1
        and latest_source.get("seed_source") == "manual_api"
        and int(latest_source.get("published_items") or 0) >= 1
    )


def _dump_has_state_id(path: Path, *, direction: str, state_id: str) -> bool:
    return any(
        record.get("direction") == direction and record.get("state_id") == state_id
        for record in ed2k.dump_records(path)
    )


def _dump_has_one_of_state_ids(path: Path, *, direction: str, state_ids: tuple[str, ...]) -> bool:
    return any(
        record.get("direction") == direction and record.get("state_id") in state_ids
        for record in ed2k.dump_records(path)
    )


def _require_path(path: Path | None, label: str) -> Path:
    if path is None or not path.is_file():
        raise AssertionError(f"{label} was not produced")
    return path
