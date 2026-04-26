from __future__ import annotations

import shutil
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from tests.e2e.lib import ed2k
from tests.e2e.lib.agent import AgentRuntime, AgentSession
from tests.e2e.lib.artifacts import copy_if_exists, copy_if_small
from tests.e2e.lib.emule_harness import EmuleHarnessRuntime, EmuleProfile, EmuleSession
from tests.e2e.lib.goed2k import Goed2kRuntime, Goed2kSession
from overlord_tooling.scenarios import write_json
from tests.e2e.lib.paths import WorkspacePaths
from tests.e2e.lib.payloads import write_deterministic_binary
from tests.e2e.lib.waits import wait_file_size, wait_path


ED2K_PART_SIZE_BYTES = 9_728_000


@dataclass(frozen=True)
class PrivateEd2kRun:
    scenario_id: str
    artifact_scenario_id: str
    run_id: str
    transport_mode: str
    enable_obfuscation: bool
    keep_sessions_running: bool
    skip_build: bool
    file_name: str
    file_size: int
    file_pattern: str
    artifact_root: Path
    seeder_artifacts: Path
    downloader_artifacts: Path
    agent_stage1_artifacts: Path
    agent_stage2_artifacts: Path
    server_artifacts: Path
    run_manifest_path: Path
    run_summary_path: Path
    metadata: dict[str, Any]


@dataclass(frozen=True)
class HarnessSeederResult:
    profile: EmuleProfile
    session: EmuleSession
    parsed_link: ed2k.Ed2kLink


@dataclass(frozen=True)
class AgentDownloadResult:
    source_hint: tuple[str, int] | None
    transfer_manifest: dict[str, Any]
    agent_dump_path: Path | None
    evidence_dump_path: Path
    evidence_source: str
    transport_modes: list[str]


@dataclass(frozen=True)
class HarnessDownloadResult:
    profile: EmuleProfile
    session: EmuleSession
    downloaded_file: Path
    harness_download_link: str
    agent_dump_path: Path | None
    evidence_dump_path: Path
    evidence_source: str
    transport_modes: list[str]


@dataclass(frozen=True)
class AgentSeedResult:
    source_path: Path
    ingest_summary: dict[str, Any]
    parsed_link: ed2k.Ed2kLink


def create_private_ed2k_run(
    paths: WorkspacePaths,
    *,
    scenario_id: str,
    transport_mode: str,
    file_name: str,
    file_size: int,
    file_pattern: str,
    keep_sessions_running: bool,
    skip_build: bool,
    artifact_scenario_id: str | None = None,
    run_slug: str | None = None,
    metadata: dict[str, Any] | None = None,
) -> PrivateEd2kRun:
    artifact_namespace = artifact_scenario_id or scenario_id
    run_stem = run_slug or scenario_id
    run_id = f"{run_stem}.{transport_mode}-{datetime.now().strftime('%Y%m%d-%H%M%S')}"
    artifact_root = paths.run_root(artifact_namespace, run_id)
    seeder_artifacts = artifact_root / "seed-art"
    downloader_artifacts = artifact_root / "down-art"
    agent_stage1_artifacts = artifact_root / "agt1-art"
    agent_stage2_artifacts = artifact_root / "agt2-art"
    server_artifacts = artifact_root / "srv-art"
    for path in (
        artifact_root,
        seeder_artifacts,
        downloader_artifacts,
        agent_stage1_artifacts,
        agent_stage2_artifacts,
        server_artifacts,
    ):
        path.mkdir(parents=True, exist_ok=True)

    run_manifest_path = artifact_root / "run-manifest.json"
    run_summary_path = artifact_root / "run-summary.json"
    write_json(
        run_manifest_path,
        {
            "schemaVersion": "run-manifest/v1",
            **run_identity_fields(
                scenario_id=scenario_id,
                artifact_scenario_id=artifact_namespace,
                run_id=run_id,
                metadata=metadata or {},
            ),
            "artifactRoot": str(artifact_root),
            "transportMode": transport_mode,
            "file": {"name": file_name, "sizeBytes": file_size, "pattern": file_pattern},
            "startedAtUtc": utc_now(),
        },
    )

    return PrivateEd2kRun(
        scenario_id=scenario_id,
        artifact_scenario_id=artifact_namespace,
        run_id=run_id,
        transport_mode=transport_mode,
        enable_obfuscation=transport_mode == "obfuscated",
        keep_sessions_running=keep_sessions_running,
        skip_build=skip_build,
        file_name=file_name,
        file_size=file_size,
        file_pattern=file_pattern,
        artifact_root=artifact_root,
        seeder_artifacts=seeder_artifacts,
        downloader_artifacts=downloader_artifacts,
        agent_stage1_artifacts=agent_stage1_artifacts,
        agent_stage2_artifacts=agent_stage2_artifacts,
        server_artifacts=server_artifacts,
        run_manifest_path=run_manifest_path,
        run_summary_path=run_summary_path,
        metadata=metadata or {},
    )


def run_identity_fields(
    *,
    scenario_id: str,
    artifact_scenario_id: str,
    run_id: str,
    metadata: dict[str, Any],
) -> dict[str, Any]:
    fields: dict[str, Any] = {
        "scenarioId": scenario_id,
        "artifactScenarioId": artifact_scenario_id,
        "runId": run_id,
    }
    fields.update(metadata)
    return fields


def run_identity(run: PrivateEd2kRun) -> dict[str, Any]:
    return run_identity_fields(
        scenario_id=run.scenario_id,
        artifact_scenario_id=run.artifact_scenario_id,
        run_id=run.run_id,
        metadata=run.metadata,
    )


def start_private_server(
    goed2k: Goed2kRuntime,
    run: PrivateEd2kRun,
    server_cfg: dict[str, Any],
) -> Goed2kSession:
    return goed2k.start_private_session(
        scenario_root=run.artifact_root / "srv",
        listen_host=str(server_cfg["host"]),
        tcp_port=int(server_cfg["tcpPort"]),
        admin_port=int(server_cfg["adminPort"]),
        udp_port_offset=int(server_cfg["udpPortOffset"]),
        admin_token=str(server_cfg["adminToken"]),
        enable_obfuscation=run.enable_obfuscation,
        skip_build=run.skip_build,
    )


def start_private_harness_seeder(
    emule: EmuleHarnessRuntime,
    run: PrivateEd2kRun,
    server_cfg: dict[str, Any],
    seeder_cfg: dict[str, Any],
    timeouts_cfg: dict[str, Any],
) -> HarnessSeederResult:
    profile = materialize_private_harness_profile(
        emule,
        profile_root=run.artifact_root / "seed",
        server_cfg=server_cfg,
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
        export_source_ip=str(server_cfg["host"]),
        skip_build=True,
    )
    wait_path(
        seed_link_path,
        timeout_seconds=seed_export_timeout(run.file_size, int(timeouts_cfg["harnessReadySeconds"])),
    )
    parsed_link = ed2k.parse_ed2k_link_file(seed_link_path)
    if not parsed_link.aich_root:
        raise AssertionError("seeder export link did not include AICH")
    return HarnessSeederResult(profile=profile, session=session, parsed_link=parsed_link)


def start_private_agent_session(
    agent: AgentRuntime,
    run: PrivateEd2kRun,
    agent_cfg: dict[str, Any],
    server_cfg: dict[str, Any] | None,
    *,
    reset_runtime_root: bool,
    disable_kad: bool = True,
    emule_harness_bootstrap_node: str | None = None,
    kad_bootstrap_ready_contacts: int = 10,
) -> AgentSession:
    scenario_root = run.artifact_root / "agt"
    if reset_runtime_root:
        reset_agent_runtime_root(scenario_root)
    server_host = str(server_cfg["host"]) if server_cfg is not None else None
    server_port = int(server_cfg["tcpPort"]) if server_cfg is not None else 0
    session = agent.start_private_ed2k_session(
        scenario_root=scenario_root,
        control_port=int(agent_cfg["controlPort"]),
        kad_port=int(agent_cfg["kadPort"]),
        ed2k_port=int(agent_cfg["ed2kPort"]),
        disable_kad=disable_kad,
        emule_harness_bootstrap_node=emule_harness_bootstrap_node,
        kad_bootstrap_ready_contacts=kad_bootstrap_ready_contacts,
        server_host=server_host,
        server_port=server_port,
        enable_obfuscation=run.enable_obfuscation,
        skip_build=run.skip_build,
    )
    agent.wait_control_ready(session, timeout_seconds=180)
    return session


def run_harness_to_agent_stage(
    agent: AgentRuntime,
    run: PrivateEd2kRun,
    agent_session: AgentSession,
    parsed_link: ed2k.Ed2kLink,
    *,
    seeder_session: EmuleSession | None,
    server_cfg: dict[str, Any],
    seeder_cfg: dict[str, Any],
    timeouts_cfg: dict[str, Any],
    use_plaintext_loopback_source_hint: bool = True,
) -> AgentDownloadResult:
    time.sleep(int(timeouts_cfg["initialPublishDelaySeconds"]))
    source_hint = None
    if use_plaintext_loopback_source_hint and not run.enable_obfuscation:
        source_hint = (str(server_cfg["host"]), int(seeder_cfg["tcpPort"]))
    agent.post_enrich_download(
        agent_session,
        file_hash=parsed_link.file_hash,
        file_name=parsed_link.file_name,
        file_size=parsed_link.file_size,
        source_ip=source_hint[0] if source_hint else None,
        source_tcp_port=source_hint[1] if source_hint else None,
    )

    transfer_manifest = agent.wait_transfer_manifest(
        agent_session,
        file_hash=parsed_link.file_hash,
        timeout_seconds=int(timeouts_cfg["agentDownloadSeconds"]),
    )
    assert transfer_manifest.get("completed") is True
    assert transfer_manifest.get("aich_hashset_acquired") is True
    assert transfer_manifest.get("aich_root")
    assert transfer_manifest.get("aich_hashset")

    agent_dump_path = agent.latest_ed2k_dump(agent_session)
    seed_dump_path = seeder_session.ed2k_dump_path if seeder_session else None
    if seed_dump_path and seed_dump_path.is_file():
        evidence_dump_path = seed_dump_path
        evidence_source = "harness_seeder"
        request_direction = "recv"
        answer_direction = "send"
        compressed_direction = "send"
    else:
        evidence_dump_path = require_dump(agent_dump_path, "agent stage1 ED2K dump")
        evidence_source = "agent_downloader"
        request_direction = "send"
        answer_direction = "recv"
        compressed_direction = "recv"

    request = ed2k.dump_record_hashset_evidence(
        evidence_dump_path,
        opcode_name="OP_HASHSETREQUEST2",
        direction=request_direction,
    )
    answer = ed2k.dump_record_hashset_evidence(
        evidence_dump_path,
        opcode_name="OP_HASHSETANSWER2",
        direction=answer_direction,
    )
    assert request["requestsAich"] is True
    assert answer["requestsAich"] is True
    assert ed2k.dump_has_opcode(
        evidence_dump_path,
        direction=compressed_direction,
        opcode_names=ed2k.PART_PAYLOAD_OPCODE_NAMES,
    )
    transport_modes = ed2k.dump_transport_modes(evidence_dump_path)
    assert run.transport_mode in transport_modes

    return AgentDownloadResult(
        source_hint=source_hint,
        transfer_manifest=transfer_manifest,
        agent_dump_path=agent_dump_path,
        evidence_dump_path=evidence_dump_path,
        evidence_source=evidence_source,
        transport_modes=transport_modes,
    )


def run_agent_to_harness_stage(
    emule: EmuleHarnessRuntime,
    agent: AgentRuntime,
    run: PrivateEd2kRun,
    agent_session: AgentSession,
    parsed_link: ed2k.Ed2kLink,
    *,
    server_cfg: dict[str, Any],
    downloader_cfg: dict[str, Any],
    agent_cfg: dict[str, Any],
    timeouts_cfg: dict[str, Any],
    download_link_override: str | None = None,
) -> HarnessDownloadResult:
    time.sleep(int(timeouts_cfg["agentRepublishDelaySeconds"]))
    profile = materialize_private_harness_profile(
        emule,
        profile_root=run.artifact_root / "down",
        server_cfg=server_cfg,
        harness_cfg=downloader_cfg,
        enable_obfuscation=run.enable_obfuscation,
    )
    if download_link_override is not None:
        harness_download_link = download_link_override
    else:
        harness_download_link = (
            parsed_link.link
            if run.enable_obfuscation
            else ed2k.add_plain_source(
                parsed_link.link,
                source_ip=str(server_cfg["host"]),
                source_tcp_port=int(agent_cfg["ed2kPort"]),
            )
        )
    download_link_path = run.artifact_root / "download.ed2k"
    download_link_path.write_text(harness_download_link + "\n", encoding="utf-8", newline="\n")
    session = emule.start_private_ed2k_session(
        profile=profile,
        download_link_path=download_link_path,
        skip_build=True,
    )
    downloaded_file = wait_file_size(
        profile.incoming_root / parsed_link.file_name,
        expected_size=parsed_link.file_size,
        timeout_seconds=int(timeouts_cfg["harnessDownloadSeconds"]),
    )

    agent_dump_path = agent.latest_ed2k_dump(agent_session)
    down_dump_path = session.ed2k_dump_path
    if down_dump_path and down_dump_path.is_file():
        evidence_dump_path = down_dump_path
        evidence_source = "harness_downloader"
        request_direction = "send"
        answer_direction = "recv"
        compressed_direction = "recv"
    else:
        evidence_dump_path = require_dump(agent_dump_path, "agent stage2 ED2K dump")
        evidence_source = "agent_listener"
        request_direction = "recv"
        answer_direction = "send"
        compressed_direction = "send"

    request = ed2k.dump_record_hashset_evidence(
        evidence_dump_path,
        opcode_name="OP_HASHSETREQUEST2",
        direction=request_direction,
    )
    answer = ed2k.dump_record_hashset_evidence(
        evidence_dump_path,
        opcode_name="OP_HASHSETANSWER2",
        direction=answer_direction,
    )
    assert request["requestsAich"] is True
    assert answer["requestsAich"] is True
    assert ed2k.dump_has_opcode(
        evidence_dump_path,
        direction=compressed_direction,
        opcode_names=ed2k.PART_PAYLOAD_OPCODE_NAMES,
    )
    transport_modes = ed2k.dump_transport_modes(evidence_dump_path)
    assert run.transport_mode in transport_modes
    assert file_contains_text(session.verbose_log_path, "MD4: OK - AICH: OK")

    return HarnessDownloadResult(
        profile=profile,
        session=session,
        downloaded_file=downloaded_file,
        harness_download_link=harness_download_link,
        agent_dump_path=agent_dump_path,
        evidence_dump_path=evidence_dump_path,
        evidence_source=evidence_source,
        transport_modes=transport_modes,
    )


def ingest_local_file_via_agent(
    agent: AgentRuntime,
    run: PrivateEd2kRun,
    agent_session: AgentSession,
) -> AgentSeedResult:
    source_path = run.artifact_root / "agent-seed" / run.file_name
    write_deterministic_binary(source_path, size_bytes=run.file_size, pattern=run.file_pattern)
    ingest_summary = agent.post_ingest_local_file(
        agent_session,
        source_path=source_path,
        canonical_name=run.file_name,
    )
    parsed_link = build_ed2k_link(
        file_name=str(ingest_summary["canonicalName"]),
        file_size=int(ingest_summary["fileSize"]),
        file_hash=str(ingest_summary["fileHash"]),
        aich_root=str(ingest_summary["aichRoot"]) if ingest_summary.get("aichRoot") else None,
    )
    return AgentSeedResult(
        source_path=source_path,
        ingest_summary=ingest_summary,
        parsed_link=parsed_link,
    )


def materialize_private_harness_profile(
    emule: EmuleHarnessRuntime,
    *,
    profile_root: Path,
    server_cfg: dict[str, Any],
    harness_cfg: dict[str, Any],
    enable_obfuscation: bool,
) -> EmuleProfile:
    profile = emule.materialize_private_ed2k_profile(
        profile_root=profile_root,
        bind_addr=str(server_cfg["host"]),
        tcp_port=int(harness_cfg["tcpPort"]),
        udp_port=int(harness_cfg["udpPort"]),
        server_udp_port=int(harness_cfg["serverUdpPort"]),
        web_port=int(harness_cfg["webPort"]),
        kad_udp_key=int(harness_cfg["kadUdpKey"]),
        enable_kademlia=False,
        enable_ed2k=True,
        reset_transient_state=True,
    )
    ed2k.write_server_met(
        profile.profile_root / "config" / "server.met",
        server_ip=str(server_cfg["host"]),
        server_port=int(server_cfg["tcpPort"]),
    )
    emule.set_obfuscation_mode(profile, obfuscated_preferred=enable_obfuscation)
    return profile


def copy_agent_artifacts(session: AgentSession, dump_path: Path | None, destination: Path) -> None:
    copy_if_exists(session.config_path, destination)
    copy_if_exists(session.config_backup_path, destination)
    copy_if_exists(session.session_dir / "agent-session.json", destination)
    copy_if_exists(session.agent_log_path, destination)
    copy_if_exists(session.stdout_path, destination)
    copy_if_exists(session.stderr_path, destination)
    copy_if_exists(dump_path, destination)


def copy_harness_artifacts(session: EmuleSession | None, destination: Path) -> None:
    if session is None:
        return
    for path in (
        session.export_link_path,
        session.export_aich_path,
        session.trace_log_path,
        session.verbose_log_path,
        session.status_log_path,
        session.stdout_path,
        session.stderr_path,
        session.udp_dump_path,
        session.ed2k_dump_path,
    ):
        copy_if_exists(path, destination)


def copy_server_artifacts(session: Goed2kSession, destination: Path) -> None:
    for path in (session.stdout_path, session.stderr_path, session.config_path, session.catalog_path):
        copy_if_exists(path, destination)


def copy_small_download(path: Path | None, destination: Path) -> None:
    copy_if_small(path, destination)


def reset_agent_runtime_root(path: Path) -> None:
    for child in (path / "agent-state", path / "agent-logs"):
        if child.exists():
            shutil.rmtree(child)


def require_dump(path: Path | None, label: str) -> Path:
    if path is None or not path.is_file():
        raise AssertionError(f"{label} was not produced")
    return path


def file_contains_text(path: Path, needle: str) -> bool:
    raw = path.read_bytes()
    for encoding in ("utf-8", "utf-16", "utf-16-le"):
        try:
            if needle in raw.decode(encoding, errors="ignore"):
                return True
        except UnicodeError:
            continue
    return False


def seed_export_timeout(file_size: int, base_timeout: int) -> int:
    gib = 1024 * 1024 * 1024
    size_gib = max(1, (file_size + gib - 1) // gib)
    return max(base_timeout, base_timeout + size_gib * 300)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def build_ed2k_link(*, file_name: str, file_size: int, file_hash: str, aich_root: str | None) -> ed2k.Ed2kLink:
    normalized_hash = file_hash.lower()
    parts = [f"ed2k://|file|{file_name}|{file_size}|{normalized_hash}|"]
    normalized_aich_root = None
    if aich_root:
        normalized_aich_root = ed2k.encode_aich_root_for_link(aich_root)
        parts.append(f"h={normalized_aich_root}|")
    parts.append("/")
    return ed2k.Ed2kLink(
        link="".join(parts),
        file_name=file_name,
        file_size=file_size,
        file_hash=normalized_hash,
        aich_root=normalized_aich_root,
    )
