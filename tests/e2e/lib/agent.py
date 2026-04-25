from __future__ import annotations

import json
import os
import shutil
import time
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from uuid import uuid4

from tests.e2e.lib import http
from tests.e2e.lib.artifacts import latest_file
from tests.e2e.lib.paths import WorkspacePaths
from tests.e2e.lib.processes import kill_processes_by_name, run_checked, start_process, stop_process_tree


@dataclass
class AgentSession:
    session_dir: Path
    session_name: str
    state_root: Path
    log_root: Path
    config_path: Path
    config_backup_path: Path | None
    stdout_path: Path
    stderr_path: Path
    agent_log_path: Path
    control_url: str
    stats_url: str
    transfer_root: Path
    control_port: int
    kad_port: int
    ed2k_port: int
    bind_ip: str
    pid: int
    started_at_utc: str

    def write_metadata(self) -> None:
        payload = asdict(self)
        for key, value in list(payload.items()):
            if isinstance(value, Path):
                payload[key] = str(value)
        (self.session_dir / "agent-session.json").write_text(
            json.dumps(payload, indent=2) + "\n",
            encoding="utf-8",
        )


class AgentRuntime:
    def __init__(self, paths: WorkspacePaths) -> None:
        self.paths = paths

    @property
    def config_path(self) -> Path:
        return self.paths.tmp_dir / "agent-real-miniupnpc.toml"

    @property
    def executable_path(self) -> Path:
        return self.paths.agents_root / "target" / "debug" / "overlord-agent-emule.exe"

    def build(self) -> None:
        run_checked(
            ["cargo", "build", "-p", "overlord-agent-emule", "--bin", "overlord-agent-emule"],
            cwd=self.paths.agents_root,
        )
        if not self.executable_path.is_file():
            raise RuntimeError(f"agent executable not found at {self.executable_path}")

    def write_private_local_config(
        self,
        *,
        scenario_root: Path,
        control_port: int,
        kad_port: int,
        ed2k_port: int,
        p2p_bind_ip: str,
        emule_harness_bootstrap_node: str | None = None,
        kad_bootstrap_ready_contacts: int = 10,
        disable_kad: bool = False,
        server_host: str | None = None,
        server_port: int = 0,
        server_entries: list[dict[str, Any]] | None = None,
        server_udp_flags: int = 0,
        server_udp_key: int = 0,
        server_udp_key_ip: int = 0,
        server_obfuscation_port_tcp: int = 0,
        server_obfuscation_port_udp: int = 0,
        server_connect_timeout_seconds: int = 8,
        server_reconnect_interval_seconds: int = 5,
        server_session_rotation_seconds: int = 45,
        probe_search_term: str = "ubuntu linux",
        enable_obfuscation: bool = False,
        enable_kad_notes_publish: bool = False,
        kad_republish_interval_secs: int = 18_000,
        kad_publish_contact_fanout: int = 4,
        kad_hello_intro_interval_secs: int = 300,
        kad_hello_intro_fanout: int = 2,
        kad_publish_max_outbound_pps: int = 1,
        kad_synthetic_publish_interval_secs: int = 120,
        kad_synthetic_publish_batch_items: int = 1,
        kad_synthetic_publish_contact_fanout: int = 1,
        nodes_dat_seed_path: Path | None = None,
    ) -> dict[str, Path | int | str | None]:
        state_root = scenario_root / "agent-state"
        log_root = scenario_root / "agent-logs"
        state_root.mkdir(parents=True, exist_ok=True)
        log_root.mkdir(parents=True, exist_ok=True)
        self.config_path.parent.mkdir(parents=True, exist_ok=True)

        backup_path: Path | None = None
        if self.config_path.exists():
            backup_path = scenario_root / "agent-real-miniupnpc.backup.toml"
            shutil.copy2(self.config_path, backup_path)

        if nodes_dat_seed_path is not None:
            shutil.copy2(nodes_dat_seed_path, state_root / "overlord-kad.nodes.dat")

        bootstrap_nodes = "[]"
        if not disable_kad and emule_harness_bootstrap_node:
            bootstrap_nodes = f'["{emule_harness_bootstrap_node}"]'

        server_endpoints = "[]"
        server_entries_toml = "[]"
        configured_server_entries = list(server_entries or [])
        if configured_server_entries:
            server_endpoints = _toml_string_list(
                [
                    f'{str(entry["host"])}:{int(entry["port"])}'
                    for entry in configured_server_entries
                ]
            )
            server_entries_toml = _toml_inline_server_entries(configured_server_entries)
        elif server_host and server_port > 0:
            server_endpoints = _toml_string_list([f"{server_host}:{server_port}"])
            server_entries_toml = _toml_inline_server_entries(
                [
                    {
                        "host": server_host,
                        "port": server_port,
                        "name": "",
                        "description": "",
                        "udp_flags": server_udp_flags,
                        "udp_key": server_udp_key,
                        "udp_key_ip": server_udp_key_ip,
                        "obfuscation_port_tcp": server_obfuscation_port_tcp,
                        "obfuscation_port_udp": server_obfuscation_port_udp,
                    }
                ]
            )

        sanitized_probe_search_term = probe_search_term.replace('"', "")
        config = f"""
[coordinator]
url = "http://127.0.0.1:13300"

[agent]
indexer_id_path = "{_toml_path(state_root)}/overlord-agent-emule.indexer-id"
state_dir = "{_toml_path(state_root)}"
hostname = "localhost"
version = "0.1.0"

[control]
bind_iface = ""
bind_ip = "127.0.0.1"
selection_confirmed = true
listen_port = {control_port}

[p2p]
bind_iface = ""
bind_ip = "{p2p_bind_ip}"
selection_confirmed = true

[p2p.kad]
listen_port = {kad_port}
nodes_dat_path = "{_toml_path(state_root)}/overlord-kad.nodes.dat"
bootstrap_nodes = {bootstrap_nodes}
bootstrap_min_routing_contacts = {kad_bootstrap_ready_contacts}
search_timeout_secs = 45
store_timeout_secs = 140
republish_interval_secs = {kad_republish_interval_secs}
publish_contact_fanout = {kad_publish_contact_fanout}
routing_refresh_interval_secs = 900
hello_intro_interval_secs = {kad_hello_intro_interval_secs}
hello_intro_fanout = {kad_hello_intro_fanout}
nodes_dat_refresh_interval_secs = 300
udp_firewall_check_enabled = false
udp_firewall_recheck_interval_secs = 1800
udp_firewall_check_timeout_secs = 20
udp_firewall_check_contact_count = 2
local_store_enabled = true
local_store_keyword_ttl_secs = 86400
local_store_source_ttl_secs = 21600
local_store_notes_ttl_secs = 86400
local_store_keyword_capacity = 20000
local_store_source_capacity = 20000
local_store_notes_capacity = 5000
max_outbound_pps = 8
interactive_max_outbound_pps = 4
harvest_max_outbound_pps = 1
maintenance_max_outbound_pps = 1
publish_max_outbound_pps = {kad_publish_max_outbound_pps}
search_phase2_fanout = 50
keyword_result_cap = 5000
source_result_cap = 1000
notes_result_cap = 1000
synthetic_publish_interval_secs = {kad_synthetic_publish_interval_secs}
synthetic_publish_batch_items = {kad_synthetic_publish_batch_items}
synthetic_publish_contact_fanout = {kad_synthetic_publish_contact_fanout}
seed_notes_publish_enabled = {_bool(enable_kad_notes_publish)}
obfuscation_enabled = {_bool(enable_obfuscation)}
enable_mock_results = false

[p2p.ed2k]
listen_port = {ed2k_port}
server_entries = {server_entries_toml}
server_endpoints = {server_endpoints}
obfuscation_enabled = {_bool(enable_obfuscation)}
probe_search_term = "{sanitized_probe_search_term}"
connect_timeout_secs = {server_connect_timeout_seconds}
reconnect_interval_secs = {server_reconnect_interval_seconds}
keepalive_secs = 60
session_rotation_secs = {server_session_rotation_seconds}
max_concurrent_downloads = 1
max_parallel_download_peers = 2
keyword_server_attempt_budget = 3
exact_hash_keyword_server_attempt_budget = 4
source_server_attempt_budget = 3
kad_source_supplement_max_existing_sources = 2

[p2p.snoop_queue]
dedup_window_secs = 28800
general_max_queries_per_600s = 24
general_drain_cooldown_secs = 900
source_max_queries_per_600s = 60
source_drain_cooldown_secs = 300
source_stop_after_results = 2

[nat.p2p]
enabled = false
backend_order = []
igd_ip = ""
minissdpd_socket = ""
ssdp_local_port = 0
discovery_timeout_secs = 5
lease_duration_secs = 3600
renew_margin_secs = 300
external_ip_override = ""

[log]
level = "info"
dir = "{_toml_path(log_root)}"
rotation = "daily"
max_files = 7
""".lstrip()
        self.config_path.write_text(config, encoding="utf-8", newline="\n")
        return {
            "config_path": self.config_path,
            "backup_path": backup_path,
            "state_root": state_root,
            "log_root": log_root,
        }

    def start_private_ed2k_session(
        self,
        *,
        scenario_root: Path,
        control_port: int,
        kad_port: int,
        ed2k_port: int,
        p2p_bind_ip: str = "127.0.0.1",
        disable_kad: bool = True,
        emule_harness_bootstrap_node: str | None = None,
        kad_bootstrap_ready_contacts: int = 10,
        server_host: str | None = None,
        server_port: int = 0,
        server_entries: list[dict[str, Any]] | None = None,
        server_connect_timeout_seconds: int = 8,
        probe_search_term: str = "ubuntu linux",
        nodes_dat_seed_path: Path | None = None,
        enable_obfuscation: bool = False,
        kad_republish_interval_secs: int = 18_000,
        kad_publish_contact_fanout: int = 4,
        kad_hello_intro_interval_secs: int = 300,
        kad_hello_intro_fanout: int = 2,
        kad_publish_max_outbound_pps: int = 1,
        kad_synthetic_publish_interval_secs: int = 120,
        kad_synthetic_publish_batch_items: int = 1,
        kad_synthetic_publish_contact_fanout: int = 1,
        enable_kad_notes_publish: bool = False,
        skip_build: bool = False,
    ) -> AgentSession:
        kill_processes_by_name(["overlord-agent-emule"])
        config = self.write_private_local_config(
            scenario_root=scenario_root,
            control_port=control_port,
            kad_port=kad_port,
            ed2k_port=ed2k_port,
            p2p_bind_ip=p2p_bind_ip,
            emule_harness_bootstrap_node=emule_harness_bootstrap_node,
            kad_bootstrap_ready_contacts=kad_bootstrap_ready_contacts,
            disable_kad=disable_kad,
            server_host=server_host,
            server_port=server_port,
            server_entries=server_entries,
            server_connect_timeout_seconds=server_connect_timeout_seconds,
            probe_search_term=probe_search_term,
            server_session_rotation_seconds=0,
            enable_obfuscation=enable_obfuscation,
            kad_republish_interval_secs=kad_republish_interval_secs,
            kad_publish_contact_fanout=kad_publish_contact_fanout,
            kad_hello_intro_interval_secs=kad_hello_intro_interval_secs,
            kad_hello_intro_fanout=kad_hello_intro_fanout,
            kad_publish_max_outbound_pps=kad_publish_max_outbound_pps,
            kad_synthetic_publish_interval_secs=kad_synthetic_publish_interval_secs,
            kad_synthetic_publish_batch_items=kad_synthetic_publish_batch_items,
            kad_synthetic_publish_contact_fanout=kad_synthetic_publish_contact_fanout,
            enable_kad_notes_publish=enable_kad_notes_publish,
            nodes_dat_seed_path=nodes_dat_seed_path,
        )
        if not skip_build or not self.executable_path.is_file():
            self.build()

        session_name = f"private-agent-{_stamp()}"
        session_dir = self.paths.tmp_dir / session_name
        session_dir.mkdir(parents=True, exist_ok=True)
        stdout_path = session_dir / "agent-stdout.log"
        stderr_path = session_dir / "agent-stderr.log"
        process = start_process(
            [self.executable_path, "--config", self.config_path],
            cwd=self.paths.agents_root,
            stdout_path=stdout_path,
            stderr_path=stderr_path,
            env={"RUST_BACKTRACE": "1", "OVERLORD_LOG_DIR": str(config["log_root"])},
        )
        session = AgentSession(
            session_dir=session_dir,
            session_name=session_name,
            state_root=Path(config["state_root"]),
            log_root=Path(config["log_root"]),
            config_path=Path(config["config_path"]),
            config_backup_path=Path(config["backup_path"]) if config["backup_path"] else None,
            stdout_path=stdout_path,
            stderr_path=stderr_path,
            agent_log_path=Path(config["log_root"]) / "overlord-agent-emule.log",
            control_url=f"http://127.0.0.1:{control_port}",
            stats_url=f"http://127.0.0.1:{control_port}/api/internal/stats",
            transfer_root=Path(config["state_root"]) / "overlord-ed2k-transfer",
            control_port=control_port,
            kad_port=kad_port,
            ed2k_port=ed2k_port,
            bind_ip=p2p_bind_ip,
            pid=process.pid,
            started_at_utc=datetime.now(timezone.utc).isoformat(),
        )
        session.write_metadata()
        return session

    def stop(self, session: AgentSession, *, flush_wait_seconds: int = 5) -> None:
        stop_process_tree(session.pid)
        time.sleep(max(flush_wait_seconds, 1))

    def wait_control_ready(self, session: AgentSession, *, timeout_seconds: int = 180) -> Any:
        deadline = time.monotonic() + timeout_seconds
        last_response: Any = None
        expected_log_path = str(session.agent_log_path.resolve()).replace("\\", "/")
        while time.monotonic() < deadline:
            response = http.wait_json(session.stats_url, timeout_seconds=10, poll_seconds=1)
            last_response = response
            observed_log_path = (
                response.get("publish_observability", {})
                .get("log_file", {})
                .get("path")
            )
            if isinstance(observed_log_path, str):
                normalized_observed = str(Path(observed_log_path).resolve()).replace("\\", "/")
                if normalized_observed == expected_log_path:
                    return response
            time.sleep(1)
        raise TimeoutError(
            f"{session.stats_url} did not report the expected agent log path {expected_log_path} "
            f"within {timeout_seconds}s; last_response={last_response}"
        )

    def post_enrich_download(
        self,
        session: AgentSession,
        *,
        file_hash: str,
        file_name: str,
        file_size: int,
        source_ip: str | None = None,
        source_tcp_port: int | None = None,
        source_user_hash: str | None = None,
        source_obfuscation_options: int | None = None,
    ) -> Any:
        sources: list[dict[str, Any]] = []
        if source_ip:
            if not source_tcp_port:
                raise ValueError("source_tcp_port is required when source_ip is set")
            source: dict[str, Any] = {"ip": source_ip, "tcpPort": source_tcp_port}
            if source_user_hash:
                source["userHash"] = source_user_hash
            if source_obfuscation_options is not None:
                source["obfuscationOptions"] = int(source_obfuscation_options)
            sources.append(source)

        payload = {
            "kind": "ed2k_download",
            "fileHash": file_hash.lower(),
            "fileName": file_name,
            "fileSize": file_size,
            "sources": sources,
        }
        return http.post_json(f"{session.control_url}/api/internal/enrich", payload)

    def post_ingest_local_file(
        self,
        session: AgentSession,
        *,
        source_path: Path,
        canonical_name: str,
    ) -> Any:
        payload = {
            "sourcePath": str(source_path),
            "canonicalName": canonical_name,
        }
        return http.post_json(f"{session.control_url}/api/internal/ingest-local-file", payload)

    def post_search_keyword(
        self,
        session: AgentSession,
        *,
        query: str,
        callback_url: str,
        protocol: str = "kad2",
        job_id: str | None = None,
    ) -> dict[str, Any]:
        return self.post_search(
            session,
            kind="keyword",
            query=query,
            callback_url=callback_url,
            protocol=protocol,
            job_id=job_id,
        )

    def post_search(
        self,
        session: AgentSession,
        *,
        kind: str,
        callback_url: str,
        protocol: str = "kad2",
        query: str | None = None,
        file_hash: str | None = None,
        file_size: int | None = None,
        job_id: str | None = None,
    ) -> dict[str, Any]:
        normalized_hash = file_hash.lower() if file_hash else None
        payload = {
            "job_id": job_id or str(uuid4()),
            "protocol": protocol,
            "kind": kind,
            "query": query,
            "file_hash": (
                {"kind": "ed2k", "value": normalized_hash}
                if normalized_hash is not None
                else None
            ),
            "file_size": int(file_size) if file_size is not None else None,
            "callback_url": callback_url,
        }
        http.post_json(f"{session.control_url}/api/internal/search", payload)
        return payload

    def post_seed_popular(
        self,
        session: AgentSession,
        *,
        file_hash: str,
        canonical_name: str,
        file_size: int,
        source_count: int,
        timeout: int = 30,
    ) -> list[dict[str, Any]]:
        payload = [
            {
                "hash": {
                    "kind": "ed2k",
                    "value": file_hash.lower(),
                },
                "canonical_name": canonical_name,
                "size": int(file_size),
                "source_count": int(source_count),
            }
        ]
        http.post_json(
            f"{session.control_url}/api/internal/seed-popular",
            payload,
            timeout=timeout,
        )
        return payload

    def latest_ed2k_dump(self, session: AgentSession) -> Path | None:
        return latest_file(session.log_root, "agent-ed2k-tcp-dump-*.jsonl")

    def wait_transfer_manifest(
        self,
        session: AgentSession,
        *,
        file_hash: str,
        timeout_seconds: int,
    ) -> dict[str, Any]:
        manifest_path = session.transfer_root / file_hash.lower() / "resume-manifest.json"
        deadline = time.monotonic() + timeout_seconds
        latest: dict[str, Any] | None = None
        while time.monotonic() < deadline:
            snapshot = _read_json_if_stable(manifest_path)
            if snapshot is not None and "completed" in snapshot:
                latest = snapshot
                if snapshot.get("completed") is True:
                    return snapshot
            time.sleep(2)
        if latest is not None:
            return latest
        raise TimeoutError(f"transfer manifest did not appear at {manifest_path}")

    def copy_transfer(self, session: AgentSession, *, file_hash: str, destination_root: Path) -> Path:
        transfer_dir = session.transfer_root / file_hash.lower()
        if not transfer_dir.is_dir():
            raise FileNotFoundError(f"transfer directory not found at {transfer_dir}")
        destination_root.mkdir(parents=True, exist_ok=True)
        destination = destination_root / transfer_dir.name
        if destination.exists():
            shutil.rmtree(destination)
        shutil.copytree(transfer_dir, destination)
        return destination


def _read_json_if_stable(path: Path) -> dict[str, Any] | None:
    if not path.is_file():
        return None
    try:
        raw = path.read_text(encoding="utf-8")
        if not raw.strip():
            return None
        value = json.loads(raw)
        return value if isinstance(value, dict) else None
    except (OSError, json.JSONDecodeError):
        return None


def _bool(value: bool) -> str:
    return "true" if value else "false"


def _toml_inline_server_entries(entries: list[dict[str, Any]]) -> str:
    serialized: list[str] = []
    for entry in entries:
        serialized.append(
            "{ "
            f'host = {_toml_string(str(entry["host"]))}, '
            f'port = {int(entry["port"])}, '
            f'name = {_toml_string(str(entry.get("name") or ""))}, '
            f'description = {_toml_string(str(entry.get("description") or ""))}, '
            f'udp_flags = {int(entry.get("udp_flags") or 0)}, '
            f'udp_key = {int(entry.get("udp_key") or 0)}, '
            f'udp_key_ip = {int(entry.get("udp_key_ip") or 0)}, '
            f'obfuscation_port_tcp = {int(entry.get("obfuscation_port_tcp") or 0)}, '
            f'obfuscation_port_udp = {int(entry.get("obfuscation_port_udp") or 0)} '
            "}"
        )
    return "[" + ", ".join(serialized) + "]"


def _toml_string_list(values: list[str]) -> str:
    return "[" + ", ".join(_toml_string(value) for value in values) + "]"


def _toml_string(value: str) -> str:
    return json.dumps(value)


def _toml_path(path: Path) -> str:
    return str(path.resolve()).replace("\\", "/")


def _stamp() -> str:
    return datetime.now().strftime("%Y%m%d-%H%M%S")
