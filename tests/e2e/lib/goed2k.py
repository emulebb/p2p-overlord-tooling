from __future__ import annotations

import json
import time
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from tests.e2e.lib import http
from tests.e2e.lib.paths import WorkspacePaths
from tests.e2e.lib.processes import kill_processes_by_name, run_checked, start_process, stop_process_tree
from tests.e2e.lib.waits import wait_tcp


@dataclass
class Goed2kSession:
    session_dir: Path
    session_name: str
    repo_root: Path
    runtime_root: Path
    config_path: Path
    catalog_path: Path
    source_catalog_path: Path
    log_root: Path
    stdout_path: Path
    stderr_path: Path
    health_url: str
    admin_base_url: str
    admin_token: str
    listen_host: str
    tcp_port: int
    udp_port: int
    admin_port: int
    udp_port_offset: int
    pid: int
    started_at_utc: str

    def write_metadata(self) -> None:
        payload = asdict(self)
        for key, value in list(payload.items()):
            if isinstance(value, Path):
                payload[key] = str(value)
        (self.session_dir / "goed2k-session.json").write_text(
            json.dumps(payload, indent=2) + "\n",
            encoding="utf-8",
        )


class Goed2kRuntime:
    def __init__(self, paths: WorkspacePaths) -> None:
        self.paths = paths

    @property
    def repo_root(self) -> Path:
        return self.paths.project_root / "ext-deps" / "goed2k-server"

    def write_private_config(
        self,
        *,
        scenario_root: Path,
        listen_host: str,
        tcp_port: int,
        admin_port: int,
        udp_port_offset: int,
        admin_token: str,
        source_catalog_path: Path | None,
        enable_obfuscation: bool,
    ) -> dict[str, Any]:
        runtime_root = scenario_root / "goed2k-server"
        log_root = runtime_root / "logs"
        config_path = runtime_root / "config.json"
        catalog_path = runtime_root / "catalog.json"
        source_catalog = source_catalog_path or self.repo_root / "testdata" / "catalog.json"
        if not source_catalog.is_file():
            raise FileNotFoundError(f"goed2k source catalog not found at {source_catalog}")
        runtime_root.mkdir(parents=True, exist_ok=True)
        log_root.mkdir(parents=True, exist_ok=True)
        catalog_path.write_bytes(source_catalog.read_bytes())

        server_tcp_obfuscation_flag = 0x00000400
        config = {
            "listen_address": f"{listen_host}:{tcp_port}",
            "admin_listen_address": f"{listen_host}:{admin_port}",
            "admin_token": admin_token,
            "server_name": "overlord-local-goed2k",
            "server_description": "Local Overlord ED2K test server",
            "message": "Welcome to local goed2k-server",
            "storage_backend": "json",
            "catalog_path": str(catalog_path),
            "database_dsn": "",
            "database_table": "shared_files",
            "search_batch_size": 25,
            "tcp_flags": server_tcp_obfuscation_flag if enable_obfuscation else 0,
            "aux_port": tcp_port if enable_obfuscation else 0,
            "server_udp": True,
            "udp_port_offset": udp_port_offset,
            "soft_files_limit": 5000,
            "hard_files_limit": 200000,
            "max_users_advertised": 500000,
        }
        config_path.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
        return {
            "runtime_root": runtime_root,
            "config_path": config_path,
            "catalog_path": catalog_path,
            "source_catalog_path": source_catalog,
            "log_root": log_root,
        }

    def start_private_session(
        self,
        *,
        scenario_root: Path,
        listen_host: str = "127.0.0.1",
        tcp_port: int = 42161,
        admin_port: int = 42180,
        udp_port_offset: int = 4,
        admin_token: str = "local-goed2k-token",
        source_catalog_path: Path | None = None,
        enable_obfuscation: bool = False,
        skip_build: bool = False,
        launch_timeout_seconds: int = 120,
    ) -> Goed2kSession:
        kill_processes_by_name(["goed2k-server"])
        config = self.write_private_config(
            scenario_root=scenario_root,
            listen_host=listen_host,
            tcp_port=tcp_port,
            admin_port=admin_port,
            udp_port_offset=udp_port_offset,
            admin_token=admin_token,
            source_catalog_path=source_catalog_path,
            enable_obfuscation=enable_obfuscation,
        )
        binary_path = Path(config["runtime_root"]) / "goed2k-server.exe"
        if not skip_build or not binary_path.is_file():
            run_checked(["go", "build", "-o", binary_path, ".\\cmd\\goed2k-server"], cwd=self.repo_root)

        session_name = f"private-goed2k-{_stamp()}"
        session_dir = self.paths.tmp_dir / session_name
        session_dir.mkdir(parents=True, exist_ok=True)
        stdout_path = Path(config["log_root"]) / "goed2k-server.stdout.log"
        stderr_path = Path(config["log_root"]) / "goed2k-server.stderr.log"
        process = start_process(
            [binary_path, "-config", Path(config["config_path"])],
            cwd=self.repo_root,
            stdout_path=stdout_path,
            stderr_path=stderr_path,
        )
        wait_tcp(listen_host, tcp_port, timeout_seconds=launch_timeout_seconds)
        health_url = f"http://{listen_host}:{admin_port}/healthz"
        http.wait_json(health_url, timeout_seconds=launch_timeout_seconds, poll_seconds=0.5)

        session = Goed2kSession(
            session_dir=session_dir,
            session_name=session_name,
            repo_root=self.repo_root,
            runtime_root=Path(config["runtime_root"]),
            config_path=Path(config["config_path"]),
            catalog_path=Path(config["catalog_path"]),
            source_catalog_path=Path(config["source_catalog_path"]),
            log_root=Path(config["log_root"]),
            stdout_path=stdout_path,
            stderr_path=stderr_path,
            health_url=health_url,
            admin_base_url=f"http://{listen_host}:{admin_port}",
            admin_token=admin_token,
            listen_host=listen_host,
            tcp_port=tcp_port,
            udp_port=tcp_port + udp_port_offset,
            admin_port=admin_port,
            udp_port_offset=udp_port_offset,
            pid=process.pid,
            started_at_utc=datetime.now(timezone.utc).isoformat(),
        )
        session.write_metadata()
        return session

    def stop(self, session: Goed2kSession, *, flush_wait_seconds: int = 5) -> None:
        stop_process_tree(session.pid)
        time.sleep(max(flush_wait_seconds, 1))

    def wait_file_available(
        self,
        session: Goed2kSession,
        *,
        file_hash: str,
        timeout_seconds: int,
    ) -> dict[str, Any]:
        deadline = time.monotonic() + timeout_seconds
        last_error: Exception | None = None
        url = f"{session.admin_base_url}/api/files/{file_hash.upper()}"
        while time.monotonic() < deadline:
            try:
                response = http.get_json(url, headers={"X-Admin-Token": session.admin_token}, timeout=10)
                if response and response.get("ok") and response.get("data") is not None:
                    return response["data"]
            except Exception as exc:  # noqa: BLE001 - admin readiness polling records any failure.
                last_error = exc
            time.sleep(2)
        raise TimeoutError(f"goed2k-server did not expose file {file_hash}") from last_error


def _stamp() -> str:
    return datetime.now().strftime("%Y%m%d-%H%M%S")
