from __future__ import annotations

import copy
import ipaddress
import struct
import time
from pathlib import Path
from typing import Any

from overlord_tooling.scenarios import write_json
from tests.e2e.lib import ed2k, http
from tests.e2e.lib.agent import AgentRuntime, AgentSession
from tests.e2e.lib.artifacts import copy_if_exists, latest_file
from tests.e2e.lib.ed2k_private import (
    copy_agent_artifacts,
    copy_harness_artifacts,
    create_private_ed2k_run,
    run_identity,
    utc_now,
)
from tests.e2e.lib.emule_harness import EmuleHarnessRuntime, EmuleProfile, EmuleSession
from tests.e2e.lib.paths import WorkspacePaths
from tests.e2e.lib.payloads import write_deterministic_binary
from tests.e2e.lib.search_callbacks import (
    read_result_batches,
    start_search_callback_collector,
    stop_search_callback_collector,
    wait_for_search_event,
)
from tests.e2e.lib.waits import wait_path


BOOTSTRAP_READY_TIMEOUT_SECONDS = 180
HARNESS_EXPORT_TIMEOUT_SECONDS = 90
MANUAL_PUBLISH_TIMEOUT_SECONDS = 240
POST_START_SETTLE_SECONDS = 8
SEARCH_TIMEOUT_SECONDS = 180
HARNESS_PUBLISH_GATE_TIMEOUT_SECONDS = 360
HARNESS_PUBLISH_PROPAGATION_SECONDS = 20
POST_FLOW_FLUSH_SECONDS = 5
KADEMLIA_VERSION = 0x0A


def run_private_kad_harness_triplet_scenario(
    workspace_paths: WorkspacePaths,
    pytestconfig,
    *,
    scenario_id: str,
    manifest: dict[str, Any],
    source_manifest: dict[str, Any],
    artifact_scenario_id: str | None = None,
    run_slug: str | None = None,
    metadata: dict[str, Any] | None = None,
) -> None:
    parity = manifest.get("parity") or {}
    expected_branch = str(parity.get("expectedBranch") or "")
    transport_mode = "obfuscated" if _needs_sender_key_transport(expected_branch) else "plaintext"
    search_cfg = source_manifest.get("search") or {}
    search_kind = str(search_cfg.get("kind") or "keyword")
    agent_cfg = source_manifest["agent"]
    manual_publish = agent_cfg.get("manualPublish") or {}
    file_name = str(
        manual_publish.get("canonicalName")
        or search_cfg.get("query")
        or source_manifest.get("scenarioId")
        or "kad-private-triplet"
    )
    file_size = int(manual_publish.get("size") or 1)

    run = create_private_ed2k_run(
        workspace_paths,
        scenario_id=scenario_id,
        transport_mode=transport_mode,
        file_name=file_name,
        file_size=file_size,
        file_pattern="private-kad-harness-triplet",
        keep_sessions_running=bool(pytestconfig.getoption("--keep-sessions-running")),
        skip_build=bool(pytestconfig.getoption("--skip-runtime-build")),
        artifact_scenario_id=artifact_scenario_id,
        run_slug=run_slug,
        metadata=metadata,
    )

    emule = EmuleHarnessRuntime(workspace_paths)
    agent = AgentRuntime(workspace_paths)
    harness_sessions: dict[str, EmuleSession] = {}
    harness_links: dict[str, ed2k.Ed2kLink] = {}
    agent_session: AgentSession | None = None
    callback_session = None
    bootstrap_stats: dict[str, Any] | None = None
    publish_stats: dict[str, Any] | None = None
    search_job: dict[str, Any] | None = None
    result_batches: list[dict[str, Any]] = []
    failed_reason: str | None = None

    try:
        if not run.skip_build:
            emule.build()
            agent.build()

        harness_nodes = list(source_manifest["harnesses"])
        hook_config = parity.get("harnessHookConfig")
        for index, harness_cfg in enumerate(harness_nodes):
            harness_id = str(harness_cfg["id"])
            profile = _materialize_triplet_harness_profile(
                emule,
                run.artifact_root / "harnesses" / harness_id,
                harness_cfg,
                harness_nodes,
                hook_config=hook_config,
                public_ip=str(harness_cfg["bindAddr"])
                if _needs_sender_key_transport(expected_branch)
                else None,
            )
            emule.set_obfuscation_mode(profile, obfuscated_preferred=run.enable_obfuscation)
            seed_file_path = profile.incoming_root / str(harness_cfg["seedFileName"])
            write_deterministic_binary(
                seed_file_path,
                size_bytes=max(int(harness_cfg.get("seedRepeatCount") or 1), 1),
                pattern=str(harness_cfg.get("markerText") or harness_id),
            )
            export_link_path = run.artifact_root / "harness-links" / f"{harness_id}.ed2k"
            export_link_path.parent.mkdir(parents=True, exist_ok=True)
            session = emule.start_private_ed2k_session(
                profile=profile,
                seed_file_path=seed_file_path,
                export_link_path=export_link_path,
                export_source_ip=str(harness_cfg["bindAddr"]),
                bootstrap_peers=str(harness_cfg.get("bootstrapPeers") or ""),
                skip_build=True,
                kill_existing=index == 0,
            )
            wait_path(export_link_path, timeout_seconds=HARNESS_EXPORT_TIMEOUT_SECONDS)
            harness_sessions[harness_id] = session
            harness_links[harness_id] = ed2k.parse_ed2k_link_file(export_link_path)

        time.sleep(POST_START_SETTLE_SECONDS)
        agent_nodes_dat_path = run.artifact_root / "agent-nodes.dat"
        _write_agent_nodes_dat(
            agent_nodes_dat_path,
            _agent_bootstrap_nodes(harness_nodes, expected_branch),
            include_udp_keys=not _needs_sender_key_transport(expected_branch),
        )
        agent_session = agent.start_private_ed2k_session(
            scenario_root=run.artifact_root / "agt",
            control_port=int(agent_cfg["controlPort"]),
            kad_port=int(agent_cfg["kadPort"]),
            ed2k_port=int(agent_cfg["ed2kPort"]),
            p2p_bind_ip=_agent_bind_ip(agent_cfg, expected_branch),
            disable_kad=False,
            emule_harness_bootstrap_node=None,
            kad_bootstrap_ready_contacts=int(agent_cfg["bootstrapReadyContacts"]),
            nodes_dat_seed_path=agent_nodes_dat_path,
            probe_search_term=str(search_cfg.get("query") or file_name),
            enable_obfuscation=run.enable_obfuscation,
            enable_kad_notes_publish=bool(agent_cfg.get("seedNotesPublishEnabled") or False),
            kad_republish_interval_secs=3_600,
            kad_hello_intro_interval_secs=5,
            kad_hello_intro_fanout=3,
            kad_publish_max_outbound_pps=4,
            kad_synthetic_publish_interval_secs=3_600,
            skip_build=run.skip_build,
        )
        agent.wait_control_ready(agent_session, timeout_seconds=180)
        bootstrap_stats = http.wait_json_until(
            agent_session.stats_url,
            predicate=_kad_bootstrap_ready,
            timeout_seconds=BOOTSTRAP_READY_TIMEOUT_SECONDS,
            poll_seconds=2,
        )

        if _needs_manual_publish(expected_branch, search_kind):
            _post_seed_popular_after_bootstrap(agent, agent_session, manual_publish)
            publish_stats = http.wait_json_until(
                agent_session.stats_url,
                predicate=_manual_publish_observed,
                timeout_seconds=MANUAL_PUBLISH_TIMEOUT_SECONDS,
                poll_seconds=2,
            )

        if "search" in expected_branch:
            _wait_harness_publish_gates(harness_sessions)
            time.sleep(HARNESS_PUBLISH_PROPAGATION_SECONDS)
            callback_session = start_search_callback_collector(run.artifact_root / "callbacks")
            search_job, result_batches = _run_search_with_retries(
                agent,
                agent_session,
                callback_session.base_url,
                callback_session,
                search_cfg,
                manual_publish,
                harness_links,
            )

        if not run.keep_sessions_running:
            time.sleep(POST_FLOW_FLUSH_SECONDS)
            for harness_id, session in list(harness_sessions.items()):
                harness_sessions[harness_id] = emule.stop(session)
            agent.stop(agent_session)

        agent_udp_dump_path = _require_path(
            latest_file(agent_session.log_root, "agent-udp-dump-*.jsonl"),
            "agent Kad UDP dump",
        )
        evidence = _assert_branch_evidence(
            agent_udp_dump_path,
            expected_branch=expected_branch,
            search_kind=search_kind,
            manual_publish_used=_needs_manual_publish(expected_branch, search_kind),
        )
        harness_udp_dump_paths = {
            harness_id: str(session.udp_dump_path)
            for harness_id, session in harness_sessions.items()
            if session.udp_dump_path is not None and session.udp_dump_path.is_file()
        }
        if not harness_udp_dump_paths:
            raise AssertionError("no harness Kad UDP dump was produced")

        _copy_triplet_artifacts(
            agent_session,
            agent_udp_dump_path,
            harness_sessions,
            run,
        )

        write_json(
            run.run_summary_path,
            {
                "schemaVersion": "run-summary/v1",
                **run_identity(run),
                "completed": True,
                "cellScenarioId": scenario_id,
                "sourceScenarioId": source_manifest.get("scenarioId"),
                "expectedBranch": expected_branch,
                "searchKind": search_kind,
                "searchJobId": search_job["job_id"] if search_job else None,
                "searchResultBatchCount": len(result_batches),
                "searchResultCount": _result_count(result_batches),
                "harnessSeeds": _harness_seed_summary(harness_links),
                "manualPublish": manual_publish or None,
                "bootstrapStats": _bootstrap_summary(bootstrap_stats),
                "publishObservability": (
                    (publish_stats or {}).get("publish_observability")
                    if publish_stats is not None
                    else None
                ),
                "evidence": {
                    **evidence,
                    "agentUdpDumpPresent": True,
                    "harnessUdpDumpPaths": harness_udp_dump_paths,
                },
                "finishedAtUtc": utc_now(),
            },
        )
    except Exception as exc:
        failed_reason = str(exc)
        raise
    finally:
        if callback_session is not None:
            stop_search_callback_collector(callback_session)
        if not run.keep_sessions_running:
            for session in list(harness_sessions.values()):
                try:
                    emule.stop(session)
                except Exception:
                    pass
            if agent_session is not None:
                try:
                    agent.stop(agent_session)
                except Exception:
                    pass
        if agent_session is not None:
            _copy_triplet_artifacts(
                agent_session,
                latest_file(agent_session.log_root, "agent-udp-dump-*.jsonl"),
                harness_sessions,
                run,
            )
        if not run.run_summary_path.exists():
            write_json(
                run.run_summary_path,
                {
                    "schemaVersion": "run-summary/v1",
                    **run_identity(run),
                    "completed": False,
                    "cellScenarioId": scenario_id,
                    "sourceScenarioId": source_manifest.get("scenarioId"),
                    "expectedBranch": expected_branch,
                    "searchKind": search_kind,
                    "searchJobId": search_job["job_id"] if search_job else None,
                    "searchResultBatchCount": len(result_batches),
                    "searchResultCount": _result_count(result_batches),
                    "bootstrapStats": _bootstrap_summary(bootstrap_stats),
                    "failedReason": failed_reason,
                    "finishedAtUtc": utc_now(),
                },
            )


def _materialize_triplet_harness_profile(
    emule: EmuleHarnessRuntime,
    profile_root: Path,
    harness_cfg: dict[str, Any],
    harness_nodes: list[dict[str, Any]],
    *,
    hook_config: dict[str, Any] | None,
    public_ip: str | None,
) -> EmuleProfile:
    profile = emule.materialize_private_ed2k_profile(
        profile_root=profile_root,
        bind_addr=str(harness_cfg["bindAddr"]),
        tcp_port=int(harness_cfg["tcpPort"]),
        udp_port=int(harness_cfg["udpPort"]),
        server_udp_port=int(harness_cfg.get("serverUdpPort") or 0),
        web_port=int(harness_cfg["webPort"]),
        kad_udp_key=int(harness_cfg["kadUdpKey"]),
        enable_kademlia=True,
        enable_ed2k=False,
        enable_upnp=False,
        reset_transient_state=True,
    )
    _write_preferences_kad(
        profile.profile_root / "config" / "preferencesKad.dat",
        str(harness_cfg["kadIdHex"]),
        public_ip=public_ip,
    )
    _write_nodes_dat(profile.profile_root / "config" / "nodes.dat", harness_nodes)
    if hook_config:
        materialized_hook_config = copy.deepcopy(hook_config)
        materialized_hook_config["eventLogPath"] = str(
            (profile.logs_root / "parity-hook-events.jsonl").resolve()
        )
        write_json(profile.profile_root / "parity-hooks.v1.json", materialized_hook_config)
    return profile


def _write_preferences_kad(path: Path, kad_id_hex: str, *, public_ip: str | None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    kad_id = bytes.fromhex(kad_id_hex)
    if len(kad_id) != 16:
        raise ValueError(f"Kad ID must be 16 bytes: {kad_id_hex!r}")
    stored_ip = int(ipaddress.IPv4Address(public_ip)) if public_ip else 0
    path.write_bytes(struct.pack("<IH", stored_ip, 0) + kad_id + b"\x00")


def _write_nodes_dat(path: Path, harness_nodes: list[dict[str, Any]]) -> None:
    payload = bytearray()
    payload.extend(struct.pack("<III", 0, 2, len(harness_nodes)))
    for node in harness_nodes:
        payload.extend(bytes.fromhex(str(node["kadIdHex"])))
        payload.extend(struct.pack("<I", int(ipaddress.IPv4Address(str(node["bindAddr"])))))
        payload.extend(struct.pack("<HHB", int(node["udpPort"]), int(node["tcpPort"]), KADEMLIA_VERSION))
        payload.extend(struct.pack("<IIB", 0, 0, 1))
    path.write_bytes(bytes(payload))


def _write_agent_nodes_dat(
    path: Path,
    harness_nodes: list[dict[str, Any]],
    *,
    include_udp_keys: bool,
) -> None:
    payload = bytearray()
    payload.extend(struct.pack("<III", 0, 2, len(harness_nodes)))
    for node in harness_nodes:
        payload.extend(bytes.fromhex(str(node["kadIdHex"])))
        payload.extend(struct.pack("<I", int(ipaddress.IPv4Address(str(node["bindAddr"])))))
        udp_key = int(node["kadUdpKey"]) if include_udp_keys else 0
        payload.extend(
            struct.pack(
                "<HHBBII",
                int(node["udpPort"]),
                int(node["tcpPort"]),
                KADEMLIA_VERSION,
                2,
                0,
                udp_key,
            )
        )
    path.write_bytes(bytes(payload))


def _needs_manual_publish(expected_branch: str, search_kind: str) -> bool:
    return (
        "publish" in expected_branch
        or search_kind == "notes"
        or expected_branch in {"keyword-publish", "source-publish"}
    )


def _needs_sender_key_transport(expected_branch: str) -> bool:
    return "senderkey" in expected_branch or "hello_res_ack" in expected_branch


def _agent_bootstrap_nodes(
    harness_nodes: list[dict[str, Any]],
    expected_branch: str,
) -> list[dict[str, Any]]:
    if _needs_sender_key_transport(expected_branch):
        return harness_nodes[:1]
    return harness_nodes


def _agent_bind_ip(agent_cfg: dict[str, Any], expected_branch: str) -> str:
    if _needs_sender_key_transport(expected_branch):
        return str(agent_cfg.get("senderKeyP2pBindIp") or "127.0.1.10")
    return str(agent_cfg["p2pBindIp"])


def _post_seed_popular_after_bootstrap(
    agent: AgentRuntime,
    agent_session: AgentSession,
    manual_publish: dict[str, Any],
) -> list[dict[str, Any]]:
    deadline = time.monotonic() + MANUAL_PUBLISH_TIMEOUT_SECONDS
    last_error: RuntimeError | None = None
    while time.monotonic() < deadline:
        try:
            return agent.post_seed_popular(
                agent_session,
                file_hash=str(manual_publish["hash"]),
                canonical_name=str(manual_publish["canonicalName"]),
                file_size=int(manual_publish["size"]),
                source_count=int(manual_publish["sourceCount"]),
                timeout=60,
            )
        except RuntimeError as exc:
            if "kad node is not bootstrapped yet" not in str(exc):
                raise
            last_error = exc
            time.sleep(2)
    raise TimeoutError("agent did not accept manual Kad publish after bootstrap wait") from last_error


def _wait_harness_publish_gates(harness_sessions: dict[str, EmuleSession]) -> None:
    deadline = time.monotonic() + HARNESS_PUBLISH_GATE_TIMEOUT_SECONDS
    pending = set(harness_sessions)
    while time.monotonic() < deadline:
        for harness_id in list(pending):
            trace_log = harness_sessions[harness_id].trace_log_path
            if trace_log.is_file() and "event=publish_gate_ready" in trace_log.read_text(
                encoding="utf-8",
                errors="replace",
            ):
                pending.remove(harness_id)
        if not pending:
            return
        time.sleep(2)
    raise TimeoutError(
        "timed out waiting for harness publish gates: " + ", ".join(sorted(pending))
    )


def _run_search_with_retries(
    agent: AgentRuntime,
    agent_session: AgentSession,
    callback_url: str,
    callback_session,
    search_cfg: dict[str, Any],
    manual_publish: dict[str, Any],
    harness_links: dict[str, ed2k.Ed2kLink],
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    retry_count = max(int(search_cfg.get("retryCount") or 1), 1)
    last_error: AssertionError | None = None
    for attempt in range(retry_count):
        if attempt > 0:
            time.sleep(HARNESS_PUBLISH_PROPAGATION_SECONDS)
        search_job = _post_search_job(
            agent,
            agent_session,
            callback_url,
            search_cfg,
            manual_publish,
            harness_links,
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
            batch
            for batch in read_result_batches(callback_session)
            if str(batch.get("job_id")) == job_id
        ]
        try:
            _assert_search_results(search_cfg, result_batches, search_job)
            return search_job, result_batches
        except AssertionError as exc:
            last_error = exc
    if last_error is not None:
        raise last_error
    raise AssertionError("Kad search did not run")


def _post_search_job(
    agent: AgentRuntime,
    agent_session: AgentSession,
    callback_url: str,
    search_cfg: dict[str, Any],
    manual_publish: dict[str, Any],
    harness_links: dict[str, ed2k.Ed2kLink],
) -> dict[str, Any]:
    kind = str(search_cfg.get("kind") or "keyword")
    if kind == "keyword":
        return agent.post_search(
            agent_session,
            kind="keyword",
            query=str(search_cfg["query"]),
            callback_url=callback_url,
        )

    target_hash, target_size = _search_target(search_cfg, manual_publish, harness_links)
    return agent.post_search(
        agent_session,
        kind=kind,
        file_hash=target_hash,
        file_size=target_size,
        callback_url=callback_url,
    )


def _search_target(
    search_cfg: dict[str, Any],
    manual_publish: dict[str, Any],
    harness_links: dict[str, ed2k.Ed2kLink],
) -> tuple[str, int]:
    target_ref = str(search_cfg.get("targetRef") or "")
    if target_ref == "manualPublish":
        return str(manual_publish["hash"]).lower(), int(manual_publish["size"])
    if target_ref in harness_links:
        link = harness_links[target_ref]
        return link.file_hash, link.file_size
    raise ValueError(f"unsupported Kad search targetRef {target_ref!r}")


def _assert_search_results(
    search_cfg: dict[str, Any],
    result_batches: list[dict[str, Any]],
    search_job: dict[str, Any],
) -> None:
    expected_minimum = int(search_cfg.get("expectedMinimumResults") or 1)
    result_count = _result_count(result_batches)
    if result_count < expected_minimum:
        raise AssertionError(
            f"expected at least {expected_minimum} Kad {search_job['kind']} results, got {result_count}"
        )

    file_hash = search_job.get("file_hash")
    if isinstance(file_hash, dict) and file_hash.get("value"):
        expected_hash = str(file_hash["value"]).lower()
        if not _result_batches_have_hash(result_batches, expected_hash):
            raise AssertionError(f"Kad search results did not include expected ED2K hash {expected_hash}")

    required_names = [str(name) for name in search_cfg.get("requiredFileNames") or []]
    observed_names = _result_names(result_batches)
    missing_names = [
        name
        for name in required_names
        if observed_names and name not in observed_names
    ]
    if missing_names:
        raise AssertionError(f"Kad search results were missing required file names: {missing_names}")


def _assert_branch_evidence(
    agent_udp_dump_path: Path,
    *,
    expected_branch: str,
    search_kind: str,
    manual_publish_used: bool,
) -> dict[str, Any]:
    evidence = {
        "bootstrapObserved": _dump_has_state_id(
            agent_udp_dump_path,
            direction="send",
            state_id="kad.send.kademlia2_bootstrap_req",
        )
        and _dump_has_state_id(
            agent_udp_dump_path,
            direction="recv",
            state_id="kad.recv.kademlia2_bootstrap_res",
        ),
        "lookupObserved": _dump_has_state_id(
            agent_udp_dump_path,
            direction="send",
            state_id="kad.send.kademlia2_req",
        )
        and _dump_has_state_id(
            agent_udp_dump_path,
            direction="recv",
            state_id="kad.recv.kademlia2_res",
        ),
        "helloObserved": _dump_has_any_state_id(
            agent_udp_dump_path,
            state_ids=(
                "kad.send.kademlia2_hello_req",
                "kad.recv.kademlia2_hello_req",
                "kad.send.kademlia2_hello_res",
                "kad.recv.kademlia2_hello_res",
            ),
        ),
        "helloAckObserved": _dump_has_any_state_id(
            agent_udp_dump_path,
            state_ids=("kad.send.kademlia2_hello_res_ack", "kad.recv.kademlia2_hello_res_ack"),
        ),
        "publishKeyObserved": _dump_has_state_id(
            agent_udp_dump_path,
            direction="send",
            state_id="kad.send.kademlia2_publish_key_req",
        ),
        "publishSourceObserved": _dump_has_state_id(
            agent_udp_dump_path,
            direction="send",
            state_id="kad.send.kademlia2_publish_source_req",
        ),
        "publishNotesObserved": _dump_has_state_id(
            agent_udp_dump_path,
            direction="send",
            state_id="kad.send.kademlia2_publish_notes_req",
        ),
        "searchObserved": _search_evidence(agent_udp_dump_path, search_kind),
    }
    required: list[str] = ["bootstrapObserved"]
    if "lookup" in expected_branch:
        required.append("lookupObserved")
    if "hello" in expected_branch:
        required.append("helloObserved")
        if "ack" in expected_branch:
            required.append("helloAckObserved")
    if manual_publish_used or "keyword-publish" in expected_branch:
        required.append("publishKeyObserved")
    if manual_publish_used or "source-publish" in expected_branch:
        required.append("publishSourceObserved")
    if "notes" in expected_branch:
        required.append("publishNotesObserved")
    if "search" in expected_branch:
        required.append("searchObserved")

    missing = [key for key in required if not evidence[key]]
    if missing:
        raise AssertionError(f"Kad branch evidence missing {missing} in {agent_udp_dump_path}")
    return evidence


def _search_evidence(path: Path, search_kind: str) -> bool:
    state_id = {
        "keyword": "kad.send.kademlia2_search_key_req",
        "source": "kad.send.kademlia2_search_source_req",
        "notes": "kad.send.kademlia2_search_notes_req",
    }[search_kind]
    return _dump_has_state_id(path, direction="send", state_id=state_id) and _dump_has_state_id(
        path,
        direction="recv",
        state_id="kad.recv.kademlia2_search_res",
    )


def _kad_bootstrap_ready(response: dict[str, Any]) -> bool:
    return bool(response.get("kad_bootstrapped"))


def _manual_publish_observed(response: dict[str, Any]) -> bool:
    publish = response.get("publish_observability") or {}
    latest_keyword = publish.get("latest_keyword_batch") or {}
    latest_source = publish.get("latest_source_batch") or {}
    return (
        publish.get("last_seed_source") == "manual_api"
        and latest_keyword.get("seed_source") == "manual_api"
        and int(latest_keyword.get("published_items") or 0) >= 1
        and latest_source.get("seed_source") == "manual_api"
        and int(latest_source.get("published_items") or 0) >= 1
    )


def _dump_has_state_id(path: Path, *, direction: str, state_id: str) -> bool:
    return any(
        record.get("direction") == direction and record.get("state_id") == state_id
        for record in ed2k.dump_records(path)
    )


def _dump_has_any_state_id(path: Path, *, state_ids: tuple[str, ...]) -> bool:
    return any(record.get("state_id") in state_ids for record in ed2k.dump_records(path))


def _result_count(result_batches: list[dict[str, Any]]) -> int:
    return sum(len(batch.get("files") or []) for batch in result_batches)


def _result_batches_have_hash(result_batches: list[dict[str, Any]], expected_hash: str) -> bool:
    for batch in result_batches:
        for file_record in batch.get("files") or []:
            for hash_entry in file_record.get("hashes") or []:
                if (
                    isinstance(hash_entry, dict)
                    and hash_entry.get("kind") == "ed2k"
                    and str(hash_entry.get("value") or "").lower() == expected_hash
                ):
                    return True
    return False


def _result_names(result_batches: list[dict[str, Any]]) -> set[str]:
    names: set[str] = set()
    for batch in result_batches:
        for file_record in batch.get("files") or []:
            for name in file_record.get("names") or []:
                names.add(str(name))
    return names


def _harness_seed_summary(harness_links: dict[str, ed2k.Ed2kLink]) -> dict[str, dict[str, Any]]:
    return {
        harness_id: {
            "fileHash": link.file_hash,
            "fileName": link.file_name,
            "fileSize": link.file_size,
        }
        for harness_id, link in harness_links.items()
    }


def _bootstrap_summary(stats: dict[str, Any] | None) -> dict[str, Any] | None:
    if stats is None:
        return None
    return {
        "peersConnected": int(stats.get("peers_connected") or 0),
        "kadBootstrapped": bool(stats.get("kad_bootstrapped")),
    }


def _copy_triplet_artifacts(
    agent_session: AgentSession,
    agent_udp_dump_path: Path | None,
    harness_sessions: dict[str, EmuleSession],
    run,
) -> None:
    copy_agent_artifacts(agent_session, agent_udp_dump_path, run.agent_stage1_artifacts)
    for harness_id, session in harness_sessions.items():
        destination = run.seeder_artifacts / harness_id
        copy_harness_artifacts(session, destination)
        copy_if_exists(Path(session.profile_root) / "logs" / "parity-hook-events.jsonl", destination)
        copy_if_exists(Path(session.profile_root) / "parity-hooks.v1.json", destination)


def _require_path(path: Path | None, label: str) -> Path:
    if path is None or not path.is_file():
        raise AssertionError(f"{label} was not produced")
    return path
