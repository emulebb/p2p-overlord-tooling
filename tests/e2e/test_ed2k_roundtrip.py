from __future__ import annotations

import shutil
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import pytest

from tests.e2e.lib import ed2k
from tests.e2e.lib.agent import AgentRuntime, AgentSession
from tests.e2e.lib.artifacts import copy_if_exists, copy_if_small
from tests.e2e.lib.emule_harness import EmuleHarnessRuntime, EmuleProfile, EmuleSession
from tests.e2e.lib.goed2k import Goed2kRuntime, Goed2kSession
from tests.e2e.lib.manifests import load_manifest, write_json
from tests.e2e.lib.paths import WorkspacePaths
from tests.e2e.lib.payloads import write_deterministic_binary
from tests.e2e.lib.waits import wait_file_size, wait_path


SCENARIO_ID = "ed2k.server.emule-harness.agent.roundtrip.private.large.v1"
ED2K_PART_SIZE_BYTES = 9_728_000


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
    manifest = load_manifest(workspace_paths, SCENARIO_ID)
    enable_obfuscation = transport_mode == "obfuscated"
    file_size = int(pytestconfig.getoption("--file-size-bytes") or manifest["file"]["sizeBytes"])
    if file_size <= ED2K_PART_SIZE_BYTES:
        pytest.fail(
            f"{SCENARIO_ID} requires a payload larger than one ED2K part "
            f"({ED2K_PART_SIZE_BYTES} bytes) to validate AICH/hashset behavior"
        )
    file_name = str(manifest["file"]["name"])
    file_pattern = str(manifest["file"]["pattern"])
    keep_sessions_running = bool(pytestconfig.getoption("--keep-sessions-running"))
    skip_build = bool(pytestconfig.getoption("--skip-runtime-build"))

    run_id = f"{SCENARIO_ID}.{transport_mode}-{datetime.now().strftime('%Y%m%d-%H%M%S')}"
    artifact_root = workspace_paths.run_root(SCENARIO_ID, run_id)
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
            "scenarioId": SCENARIO_ID,
            "runId": run_id,
            "artifactRoot": str(artifact_root),
            "transportMode": transport_mode,
            "file": {"name": file_name, "sizeBytes": file_size, "pattern": file_pattern},
            "startedAtUtc": _utc_now(),
        },
    )

    emule = EmuleHarnessRuntime(workspace_paths)
    agent = AgentRuntime(workspace_paths)
    goed2k = Goed2kRuntime(workspace_paths)

    server_session: Goed2kSession | None = None
    seeder_profile: EmuleProfile | None = None
    downloader_profile: EmuleProfile | None = None
    seeder_session: EmuleSession | None = None
    downloader_session: EmuleSession | None = None
    agent_stage1_session: AgentSession | None = None
    agent_stage2_session: AgentSession | None = None
    parsed_link: ed2k.Ed2kLink | None = None
    failed_reason: str | None = None

    try:
        if not skip_build:
            emule.build()
            agent.build()

        server = manifest["server"]
        server_session = goed2k.start_private_session(
            scenario_root=artifact_root / "srv",
            listen_host=str(server["host"]),
            tcp_port=int(server["tcpPort"]),
            admin_port=int(server["adminPort"]),
            udp_port_offset=int(server["udpPortOffset"]),
            admin_token=str(server["adminToken"]),
            enable_obfuscation=enable_obfuscation,
            skip_build=skip_build,
        )

        seeder = manifest["harnessSeeder"]
        seeder_profile = emule.materialize_private_ed2k_profile(
            profile_root=artifact_root / "seed",
            bind_addr=str(server["host"]),
            tcp_port=int(seeder["tcpPort"]),
            udp_port=int(seeder["udpPort"]),
            server_udp_port=int(seeder["serverUdpPort"]),
            web_port=int(seeder["webPort"]),
            kad_udp_key=int(seeder["kadUdpKey"]),
            enable_kademlia=False,
            enable_ed2k=True,
            reset_transient_state=True,
        )
        ed2k.write_server_met(
            seeder_profile.profile_root / "config" / "server.met",
            server_ip=str(server["host"]),
            server_port=int(server["tcpPort"]),
        )
        emule.set_obfuscation_mode(seeder_profile, obfuscated_preferred=enable_obfuscation)

        seed_file_path = seeder_profile.incoming_root / file_name
        write_deterministic_binary(seed_file_path, size_bytes=file_size, pattern=file_pattern)
        seed_link_path = artifact_root / "seed.ed2k"
        seeder_session = emule.start_private_ed2k_session(
            profile=seeder_profile,
            seed_file_path=seed_file_path,
            export_link_path=seed_link_path,
            export_source_ip=str(server["host"]),
            skip_build=True,
        )
        wait_path(seed_link_path, timeout_seconds=_seed_export_timeout(file_size, int(manifest["timeouts"]["harnessReadySeconds"])))
        parsed_link = ed2k.parse_ed2k_link_file(seed_link_path)
        assert parsed_link.aich_root, "seeder export link did not include AICH"

        published = goed2k.wait_file_available(
            server_session,
            file_hash=parsed_link.file_hash,
            timeout_seconds=180,
        )

        _reset_agent_runtime_root(artifact_root / "agt")
        agent_cfg = manifest["agent"]
        agent_stage1_session = agent.start_private_ed2k_session(
            scenario_root=artifact_root / "agt",
            control_port=int(agent_cfg["controlPort"]),
            kad_port=int(agent_cfg["kadPort"]),
            ed2k_port=int(agent_cfg["ed2kPort"]),
            disable_kad=True,
            server_host=str(server["host"]),
            server_port=int(server["tcpPort"]),
            enable_obfuscation=enable_obfuscation,
            skip_build=True,
        )
        agent.wait_control_ready(agent_stage1_session, timeout_seconds=180)

        time.sleep(int(manifest["timeouts"]["initialPublishDelaySeconds"]))
        stage1_source = None if enable_obfuscation else (str(server["host"]), int(seeder["tcpPort"]))
        agent.post_enrich_download(
            agent_stage1_session,
            file_hash=parsed_link.file_hash,
            file_name=parsed_link.file_name,
            file_size=parsed_link.file_size,
            source_ip=stage1_source[0] if stage1_source else None,
            source_tcp_port=stage1_source[1] if stage1_source else None,
        )

        agent_manifest = agent.wait_transfer_manifest(
            agent_stage1_session,
            file_hash=parsed_link.file_hash,
            timeout_seconds=int(manifest["timeouts"]["agentDownloadSeconds"]),
        )
        assert agent_manifest.get("completed") is True
        assert agent_manifest.get("aich_hashset_acquired") is True
        assert agent_manifest.get("aich_root")
        assert agent_manifest.get("aich_hashset")
        agent.copy_transfer(agent_stage1_session, file_hash=parsed_link.file_hash, destination_root=agent_stage1_artifacts)

        if not keep_sessions_running and seeder_session:
            seeder_session = emule.stop(seeder_session)

        stage1_agent_dump = agent.latest_ed2k_dump(agent_stage1_session)
        stage1_seed_dump = seeder_session.ed2k_dump_path if seeder_session else None
        if stage1_seed_dump and stage1_seed_dump.is_file():
            stage1_evidence_dump = stage1_seed_dump
            stage1_evidence_source = "harness_seeder"
            stage1_request_direction = "recv"
            stage1_answer_direction = "send"
            stage1_compressed_direction = "send"
        else:
            stage1_evidence_dump = _require_dump(stage1_agent_dump, "agent stage1 ED2K dump")
            stage1_evidence_source = "agent_downloader"
            stage1_request_direction = "send"
            stage1_answer_direction = "recv"
            stage1_compressed_direction = "recv"
        stage1_request = ed2k.dump_record_hashset_evidence(
            stage1_evidence_dump,
            opcode_name="OP_HASHSETREQUEST2",
            direction=stage1_request_direction,
        )
        stage1_answer = ed2k.dump_record_hashset_evidence(
            stage1_evidence_dump,
            opcode_name="OP_HASHSETANSWER2",
            direction=stage1_answer_direction,
        )
        assert stage1_request["requestsAich"] is True
        assert stage1_answer["requestsAich"] is True
        assert ed2k.dump_has_opcode(
            stage1_evidence_dump,
            direction=stage1_compressed_direction,
            opcode_names=("OP_COMPRESSEDPART", "OP_COMPRESSEDPART_I64"),
        )
        stage1_transport_modes = ed2k.dump_transport_modes(stage1_evidence_dump)
        assert transport_mode in stage1_transport_modes

        _copy_agent_artifacts(agent_stage1_session, stage1_agent_dump, agent_stage1_artifacts)
        _copy_harness_artifacts(seeder_session, seeder_artifacts)
        if not keep_sessions_running and agent_stage1_session:
            agent.stop(agent_stage1_session)
            agent_stage1_session = None

        agent_stage2_session = agent.start_private_ed2k_session(
            scenario_root=artifact_root / "agt",
            control_port=int(agent_cfg["controlPort"]),
            kad_port=int(agent_cfg["kadPort"]),
            ed2k_port=int(agent_cfg["ed2kPort"]),
            disable_kad=True,
            server_host=str(server["host"]),
            server_port=int(server["tcpPort"]),
            enable_obfuscation=enable_obfuscation,
            skip_build=True,
        )
        agent.wait_control_ready(agent_stage2_session, timeout_seconds=180)
        time.sleep(int(manifest["timeouts"]["agentRepublishDelaySeconds"]))

        downloader = manifest["harnessDownloader"]
        downloader_profile = emule.materialize_private_ed2k_profile(
            profile_root=artifact_root / "down",
            bind_addr=str(server["host"]),
            tcp_port=int(downloader["tcpPort"]),
            udp_port=int(downloader["udpPort"]),
            server_udp_port=int(downloader["serverUdpPort"]),
            web_port=int(downloader["webPort"]),
            kad_udp_key=int(downloader["kadUdpKey"]),
            enable_kademlia=False,
            enable_ed2k=True,
            reset_transient_state=True,
        )
        ed2k.write_server_met(
            downloader_profile.profile_root / "config" / "server.met",
            server_ip=str(server["host"]),
            server_port=int(server["tcpPort"]),
        )
        emule.set_obfuscation_mode(downloader_profile, obfuscated_preferred=enable_obfuscation)

        harness_download_link = (
            parsed_link.link
            if enable_obfuscation
            else ed2k.add_plain_source(parsed_link.link, source_ip=str(server["host"]), source_tcp_port=int(agent_cfg["ed2kPort"]))
        )
        download_link_path = artifact_root / "download.ed2k"
        download_link_path.write_text(harness_download_link + "\n", encoding="utf-8", newline="\n")
        downloader_session = emule.start_private_ed2k_session(
            profile=downloader_profile,
            download_link_path=download_link_path,
            skip_build=True,
        )

        downloaded_file = wait_file_size(
            downloader_profile.incoming_root / parsed_link.file_name,
            expected_size=parsed_link.file_size,
            timeout_seconds=int(manifest["timeouts"]["harnessDownloadSeconds"]),
        )

        if not keep_sessions_running and downloader_session:
            downloader_session = emule.stop(downloader_session)

        stage2_agent_dump = agent.latest_ed2k_dump(agent_stage2_session)
        stage2_down_dump = downloader_session.ed2k_dump_path if downloader_session else None
        if stage2_down_dump and stage2_down_dump.is_file():
            stage2_evidence_dump = stage2_down_dump
            stage2_evidence_source = "harness_downloader"
            stage2_request_direction = "send"
            stage2_answer_direction = "recv"
            stage2_compressed_direction = "recv"
        else:
            stage2_evidence_dump = _require_dump(stage2_agent_dump, "agent stage2 ED2K dump")
            stage2_evidence_source = "agent_listener"
            stage2_request_direction = "recv"
            stage2_answer_direction = "send"
            stage2_compressed_direction = "send"
        stage2_request = ed2k.dump_record_hashset_evidence(
            stage2_evidence_dump,
            opcode_name="OP_HASHSETREQUEST2",
            direction=stage2_request_direction,
        )
        stage2_answer = ed2k.dump_record_hashset_evidence(
            stage2_evidence_dump,
            opcode_name="OP_HASHSETANSWER2",
            direction=stage2_answer_direction,
        )
        assert stage2_request["requestsAich"] is True
        assert stage2_answer["requestsAich"] is True
        assert ed2k.dump_has_opcode(
            stage2_evidence_dump,
            direction=stage2_compressed_direction,
            opcode_names=("OP_COMPRESSEDPART", "OP_COMPRESSEDPART_I64"),
        )
        stage2_transport_modes = ed2k.dump_transport_modes(stage2_evidence_dump)
        assert transport_mode in stage2_transport_modes

        assert _file_contains_text(downloader_session.verbose_log_path, "MD4: OK - AICH: OK")

        _copy_agent_artifacts(agent_stage2_session, stage2_agent_dump, agent_stage2_artifacts)
        _copy_harness_artifacts(downloader_session, downloader_artifacts)
        copy_if_small(downloaded_file, downloader_artifacts)
        _copy_server_artifacts(server_session, server_artifacts)

        summary = {
            "schemaVersion": "run-summary/v1",
            "scenarioId": SCENARIO_ID,
            "runId": run_id,
            "completed": True,
            "bindAddr": str(server["host"]),
            "fileHash": parsed_link.file_hash,
            "fileName": parsed_link.file_name,
            "fileSize": parsed_link.file_size,
            "serverAdminBaseUrl": server_session.admin_base_url,
            "serverPublishedName": published.get("name"),
            "serverPublishedSources": published.get("sources"),
            "transportMode": transport_mode,
            "sameHostTransferMode": {
                "enabled": True,
                "rationale": "local_server_source_search" if enable_obfuscation else "local_server_plus_loopback_source_hint",
                "agentSourceHint": stage1_source is not None,
                "harnessDownloadLink": harness_download_link,
            },
            "evidence": {
                "exportedLinkHasAich": bool(parsed_link.aich_root),
                "agentManifestAichAcquired": bool(agent_manifest.get("aich_hashset_acquired")),
                "stage1HashsetRequestAich": bool(stage1_request["requestsAich"]),
                "stage1HashsetAnswerAich": bool(stage1_answer["requestsAich"]),
                "stage1CompressedParts": True,
                "stage1TransportModes": stage1_transport_modes,
                "stage1EvidenceSource": stage1_evidence_source,
                "stage2HashsetRequestAich": bool(stage2_request["requestsAich"]),
                "stage2HashsetAnswerAich": bool(stage2_answer["requestsAich"]),
                "stage2CompressedParts": True,
                "stage2TransportModes": stage2_transport_modes,
                "stage2EvidenceSource": stage2_evidence_source,
                "harnessVerifierAichOk": True,
                "agentStage1Ed2kDumpPresent": stage1_agent_dump is not None,
                "agentStage2Ed2kDumpPresent": stage2_agent_dump is not None,
            },
            "finishedAtUtc": _utc_now(),
        }
        write_json(run_summary_path, summary)
    except Exception as exc:
        failed_reason = str(exc)
        raise
    finally:
        if not keep_sessions_running:
            if downloader_session is not None:
                emule.stop(downloader_session)
            if seeder_session is not None:
                emule.stop(seeder_session)
            if agent_stage2_session is not None:
                agent.stop(agent_stage2_session)
            if agent_stage1_session is not None:
                agent.stop(agent_stage1_session)
            if server_session is not None:
                goed2k.stop(server_session)
        if not run_summary_path.exists():
            write_json(
                run_summary_path,
                {
                    "schemaVersion": "run-summary/v1",
                    "scenarioId": SCENARIO_ID,
                    "runId": run_id,
                    "completed": False,
                    "transportMode": transport_mode,
                    "fileHash": parsed_link.file_hash if parsed_link else None,
                    "fileName": parsed_link.file_name if parsed_link else file_name,
                    "fileSize": parsed_link.file_size if parsed_link else file_size,
                    "failedReason": failed_reason,
                    "finishedAtUtc": _utc_now(),
                },
            )


def _copy_agent_artifacts(session: AgentSession, dump_path: Path | None, destination: Path) -> None:
    copy_if_exists(session.agent_log_path, destination)
    copy_if_exists(session.stdout_path, destination)
    copy_if_exists(session.stderr_path, destination)
    copy_if_exists(dump_path, destination)


def _copy_harness_artifacts(session: EmuleSession | None, destination: Path) -> None:
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


def _copy_server_artifacts(session: Goed2kSession, destination: Path) -> None:
    for path in (session.stdout_path, session.stderr_path, session.config_path, session.catalog_path):
        copy_if_exists(path, destination)


def _reset_agent_runtime_root(path: Path) -> None:
    for child in (path / "agent-state", path / "agent-logs"):
        if child.exists():
            shutil.rmtree(child)


def _require_dump(path: Path | None, label: str) -> Path:
    if path is None or not path.is_file():
        raise AssertionError(f"{label} was not produced")
    return path


def _file_contains_text(path: Path, needle: str) -> bool:
    raw = path.read_bytes()
    for encoding in ("utf-8", "utf-16", "utf-16-le"):
        try:
            if needle in raw.decode(encoding, errors="ignore"):
                return True
        except UnicodeError:
            continue
    return False


def _seed_export_timeout(file_size: int, base_timeout: int) -> int:
    gib = 1024 * 1024 * 1024
    size_gib = max(1, (file_size + gib - 1) // gib)
    return max(base_timeout, base_timeout + size_gib * 300)


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
