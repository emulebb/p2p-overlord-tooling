from __future__ import annotations

import re
import time
from pathlib import Path
from typing import Any

from tests.e2e.lib.agent import AgentSession
from tests.e2e.lib.ed2k_private import PrivateEd2kRun
from tests.e2e.lib.emule_harness import EmuleSession
from tests.e2e.lib.live_runtime import LiveScenarioPrerequisites
from tests.e2e.lib.live_servers import LiveEd2kServerEntry, parse_server_met


_HARNESS_SERVER_ESTABLISHED_RE = re.compile(
    r"Connection established on:\s*(?P<name>.*?)\s*"
    r"\((?P<host>\d{1,3}(?:\.\d{1,3}){3}):(?P<port>\d{1,5})\)",
    re.IGNORECASE,
)
_HARNESS_SERVER_CONNECTED_RE = re.compile(
    r"Connected to\s+(?P<name>.*?)\s*"
    r"\((?P<host>\d{1,3}(?:\.\d{1,3}){3}):(?P<port>\d{1,5})\)",
    re.IGNORECASE,
)
_AGENT_SOURCE_ATTEMPT_RE = re.compile(
    r"ED2K (?P<transport>UDP )?source search attempt=\d+/\d+ "
    r"endpoint=(?P<endpoint>\S+) .*file_hash=(?P<file_hash>[0-9a-fA-F]{32})"
)
_AGENT_BACKGROUND_SOURCE_RE = re.compile(
    r"completed ED2K background source search file_hash=(?P<file_hash>[0-9a-fA-F]{32}) "
    r"endpoint=(?P<endpoint>\S+) .*source_count=(?P<count>\d+)"
)
_AGENT_BACKGROUND_SOURCE_SENT_RE = re.compile(
    r"sent ED2K background source search file_hash=(?P<file_hash>[0-9a-fA-F]{32}) "
    r"endpoint=(?P<endpoint>\S+)"
)
_AGENT_SOURCE_COMPLETED_RE = re.compile(
    r"native ED2K download source acquisition completed "
    r"file_hash=(?P<file_hash>[0-9a-fA-F]{32}) "
    r"aggregated_source_count=(?P<count>\d+)"
)
_AGENT_ACTIVE_SOURCE_COMPLETED_RE = re.compile(
    r"native ED2K download active source acquisition completed "
    r"file_hash=(?P<file_hash>[0-9a-fA-F]{32}) "
    r"source_count=(?P<count>\d+) aggregated_source_count=(?P<aggregate>\d+)"
)


def wait_harness_connected_server(
    session: EmuleSession,
    *,
    timeout_seconds: int,
) -> dict[str, Any] | None:
    deadline = time.monotonic() + timeout_seconds
    last_connected: dict[str, Any] | None = None
    while time.monotonic() < deadline:
        established, connected = extract_harness_server_evidence(session)
        if established is not None:
            return established
        if connected is not None:
            last_connected = connected
        time.sleep(1)
    return last_connected


def extract_harness_server_evidence(session: EmuleSession) -> tuple[dict[str, Any] | None, dict[str, Any] | None]:
    established: dict[str, Any] | None = None
    connected: dict[str, Any] | None = None
    for source_name, path in harness_server_evidence_paths(session):
        if not path.is_file():
            continue
        for line in read_harness_text(path).splitlines():
            established_match = _HARNESS_SERVER_ESTABLISHED_RE.search(line)
            if established_match:
                established = _server_match_summary(
                    established_match,
                    source_name=source_name,
                    confidence="login_established",
                )
                continue
            connected_match = _HARNESS_SERVER_CONNECTED_RE.search(line)
            if connected_match:
                connected = _server_match_summary(
                    connected_match,
                    source_name=source_name,
                    confidence="tcp_connected",
                )
    return established, connected


def read_harness_text(path: Path) -> str:
    raw = path.read_bytes()
    for encoding in ("utf-8", "utf-16", "utf-16-le"):
        try:
            text = raw.decode(encoding)
        except UnicodeError:
            continue
        if "\x00" not in text[:200]:
            return text
    return raw.decode("utf-8", errors="replace")


def harness_server_evidence_paths(session: EmuleSession) -> list[tuple[str, Path]]:
    return [
        ("harness_log", session.profile_root / "logs" / "eMule.log"),
        ("harness_verbose_log", session.verbose_log_path),
        ("harness_status_log", session.status_log_path),
        ("harness_stdout", session.stdout_path),
        ("harness_stderr", session.stderr_path),
    ]


def _server_match_summary(match: re.Match[str], *, source_name: str, confidence: str) -> dict[str, Any]:
    host = match.group("host")
    port = int(match.group("port"))
    return {
        "endpoint": f"{host}:{port}",
        "host": host,
        "port": port,
        "name": match.group("name").strip(),
        "evidenceSource": source_name,
        "confidence": confidence,
    }


def prioritized_live_server_entries(
    prerequisites: LiveScenarioPrerequisites,
    preferred_server: dict[str, Any] | None,
) -> list[LiveEd2kServerEntry]:
    selected = list(prerequisites.server_entries)
    if preferred_server is None:
        return selected
    host = str(preferred_server.get("host") or "")
    port = int(preferred_server.get("port") or 0)
    if not host or port <= 0:
        return selected
    for index, entry in enumerate(selected):
        if entry.host == host and entry.port == port:
            preferred = selected.pop(index)
            return [preferred, *selected]
    for entry in parse_server_met(prerequisites.seed_bundle.server_met_path):
        if entry.host == host and entry.port == port:
            return [entry, *selected]
    return [
        LiveEd2kServerEntry(
            host=host,
            port=port,
            name=str(preferred_server.get("name") or ""),
        ),
        *selected,
    ]


def live_server_entry_for_agent(entry: LiveEd2kServerEntry) -> dict[str, Any]:
    return {
        "host": entry.host,
        "port": entry.port,
        "name": entry.name or "",
        "description": entry.description or "",
        "udp_flags": entry.udp_flags,
        "udp_key": entry.udp_key,
        "udp_key_ip": entry.udp_key_ip,
        "obfuscation_port_tcp": entry.obfuscation_port_tcp,
        "obfuscation_port_udp": entry.obfuscation_port_udp,
    }


def same_server_mode_summary(
    connected_server: dict[str, Any] | None,
    *,
    stage2_harness_download_link: str | None = None,
) -> dict[str, Any]:
    return {
        "enabled": connected_server is not None,
        "rationale": "realnet_same_server_source_discovery" if connected_server else "harness_server_not_observed",
        "agentSourceHint": False,
        "harnessConnectedServer": sanitize_connected_server(connected_server),
        "harnessDownloadLink": stage2_harness_download_link,
    }


def sanitize_connected_server(connected_server: dict[str, Any] | None) -> dict[str, Any] | None:
    if connected_server is None:
        return None
    return {
        "endpoint": connected_server.get("endpoint"),
        "host": connected_server.get("host"),
        "port": connected_server.get("port"),
        "name": connected_server.get("name"),
        "evidenceSource": connected_server.get("evidenceSource"),
        "confidence": connected_server.get("confidence"),
    }


def summarize_same_server_source_discovery(
    agent_session: AgentSession | None,
    run: PrivateEd2kRun,
    *,
    file_hash: str | None,
    connected_server: dict[str, Any] | None,
) -> dict[str, Any]:
    endpoint = str((connected_server or {}).get("endpoint") or "")
    summary: dict[str, Any] = {
        "enabled": connected_server is not None,
        "sameServerEndpoint": endpoint or None,
        "sameServerName": (connected_server or {}).get("name"),
        "status": "failed_before_search",
        "reason": None,
        "agentLogPresent": False,
        "transferManifestPresent": False,
        "sourceSearchAttempted": False,
        "sameServerSearchAttempted": False,
        "foundSourceCount": None,
    }
    if connected_server is None:
        summary["reason"] = "harness_connected_server_not_observed"
        return summary
    if agent_session is None:
        summary["reason"] = "agent_stage1_not_started"
        return summary
    if not file_hash:
        summary["reason"] = "file_hash_not_available"
        return summary

    normalized_hash = file_hash.lower()
    manifest_path = agent_session.transfer_root / normalized_hash / "resume-manifest.json"
    manifest_source_count = _transfer_manifest_source_count(manifest_path)
    if manifest_source_count is not None:
        summary["transferManifestPresent"] = True
        summary["foundSourceCount"] = manifest_source_count

    log_path = agent_session.agent_log_path
    if not log_path.is_file():
        summary["reason"] = "agent_log_not_available"
        _classify_same_server_status(summary)
        return summary
    summary["agentLogPresent"] = True
    for line in log_path.read_text(encoding="utf-8", errors="replace").splitlines():
        _merge_source_discovery_log_line(summary, line, normalized_hash, endpoint)
    _classify_same_server_status(summary)
    return summary


def _transfer_manifest_source_count(path: Path) -> int | None:
    if not path.is_file():
        return None
    try:
        import json

        value = json.loads(path.read_text(encoding="utf-8"))
    except Exception:  # noqa: BLE001 - summary evidence must be best-effort.
        return None
    if not isinstance(value, dict):
        return None
    sources = value.get("sources")
    return len(sources) if isinstance(sources, list) else None


def _merge_source_discovery_log_line(
    summary: dict[str, Any],
    line: str,
    file_hash: str,
    same_server_endpoint: str,
) -> None:
    attempt = _AGENT_SOURCE_ATTEMPT_RE.search(line)
    if attempt and attempt.group("file_hash").lower() == file_hash:
        summary["sourceSearchAttempted"] = True
        if attempt.group("endpoint") == same_server_endpoint:
            summary["sameServerSearchAttempted"] = True

    background = _AGENT_BACKGROUND_SOURCE_RE.search(line)
    if background and background.group("file_hash").lower() == file_hash:
        summary["sourceSearchAttempted"] = True
        if background.group("endpoint") == same_server_endpoint:
            summary["sameServerSearchAttempted"] = True
        _merge_found_source_count(summary, int(background.group("count")))

    background_sent = _AGENT_BACKGROUND_SOURCE_SENT_RE.search(line)
    if background_sent and background_sent.group("file_hash").lower() == file_hash:
        summary["sourceSearchAttempted"] = True
        if background_sent.group("endpoint") == same_server_endpoint:
            summary["sameServerSearchAttempted"] = True

    active = _AGENT_ACTIVE_SOURCE_COMPLETED_RE.search(line)
    if active and active.group("file_hash").lower() == file_hash:
        summary["sourceSearchAttempted"] = True
        _merge_found_source_count(summary, int(active.group("aggregate")))

    completed = _AGENT_SOURCE_COMPLETED_RE.search(line)
    if completed and completed.group("file_hash").lower() == file_hash:
        summary["sourceSearchAttempted"] = True
        _merge_found_source_count(summary, int(completed.group("count")))


def _merge_found_source_count(summary: dict[str, Any], count: int) -> None:
    previous = summary.get("foundSourceCount")
    summary["foundSourceCount"] = max(int(previous or 0), count)


def _classify_same_server_status(summary: dict[str, Any]) -> None:
    count = summary.get("foundSourceCount")
    if isinstance(count, int) and count > 0:
        summary["status"] = "found_sources"
        summary["reason"] = None
    elif summary.get("sourceSearchAttempted"):
        summary["status"] = "no_sources"
        if not summary.get("sameServerSearchAttempted"):
            summary["reason"] = "source_search_did_not_reach_same_server"
        else:
            summary["reason"] = None
    else:
        summary["status"] = "failed_before_search"
        summary["reason"] = summary.get("reason") or "source_search_not_attempted"
