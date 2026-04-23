from __future__ import annotations

import json
import os
import re
import shlex
import shutil
import time
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path

from tests.e2e.lib.artifacts import latest_file
from tests.e2e.lib.paths import WorkspacePaths
from tests.e2e.lib.processes import kill_processes_by_name, run_checked, start_process, stop_process_tree

PRIVATE_HARNESS_RATE_LIMIT_KIB_PER_SEC = 12_207


@dataclass
class EmuleProfile:
    profile_root: Path
    preferences_path: Path
    logs_root: Path
    incoming_root: Path
    temp_root: Path


@dataclass
class EmuleSession:
    session_dir: Path
    session_name: str
    profile_root: Path
    ready_file: Path
    status_log_path: Path
    trace_log_path: Path
    verbose_log_path: Path
    stdout_path: Path
    stderr_path: Path
    export_link_path: Path | None
    export_aich_path: Path | None
    download_link_path: Path | None
    udp_dump_path: Path | None
    ed2k_dump_path: Path | None
    pid: int
    started_at_utc: str
    started_at_timestamp: float

    def write_metadata(self) -> None:
        payload = asdict(self)
        for key, value in list(payload.items()):
            if isinstance(value, Path):
                payload[key] = str(value)
        (self.session_dir / "emule-harness-session.json").write_text(
            json.dumps(payload, indent=2) + "\n",
            encoding="utf-8",
        )


class EmuleHarnessRuntime:
    def __init__(self, paths: WorkspacePaths) -> None:
        self.paths = paths

    def resolve_debug_dir(self) -> Path:
        workspace = self.paths.require_emule_workspace()
        preferred = (
            workspace
            / "workspaces"
            / "v0.72a"
            / "app"
            / "eMule-v0.72a-tracing-harness"
            / "srchybrid"
            / "x64"
            / "Debug"
        )
        if preferred.exists():
            return preferred

        matches = list(workspace.glob("workspaces/*/app/eMule-v0.72a-tracing-harness/srchybrid/x64/Debug"))
        if len(matches) == 1:
            return matches[0]
        raise RuntimeError(f"could not resolve eMule tracing-harness debug dir under {workspace}")

    def runtime_exe_path(self) -> Path:
        return self.resolve_debug_dir() / "eMule_v072a_parity.exe"

    def build(self) -> Path:
        workspace = self.paths.require_emule_workspace()
        build_command = os.environ.get("EMULE_HARNESS_BUILD_COMMAND", "").strip()
        if not build_command:
            raise RuntimeError(
                "EMULE_HARNESS_BUILD_COMMAND is not set. Build the tracing harness outside p2p-overlord "
                "or rerun with --skip-runtime-build when the runtime exe already exists."
            )
        run_checked(shlex.split(build_command), cwd=workspace, timeout=3600)
        debug_dir = self.resolve_debug_dir()
        built_exe = debug_dir / "emule.exe"
        runtime_exe = debug_dir / "eMule_v072a_parity.exe"
        if not built_exe.is_file():
            raise FileNotFoundError(f"built eMule executable not found at {built_exe}")
        shutil.copy2(built_exe, runtime_exe)
        built_pdb = debug_dir / "emule.pdb"
        if built_pdb.exists():
            shutil.copy2(built_pdb, debug_dir / "eMule_v072a_parity.pdb")
        return runtime_exe

    def materialize_private_ed2k_profile(
        self,
        *,
        profile_root: Path,
        bind_addr: str,
        tcp_port: int,
        udp_port: int,
        server_udp_port: int = 0,
        web_port: int = 47101,
        kad_udp_key: int = 4_206_201,
        enable_kademlia: bool = False,
        enable_ed2k: bool = True,
        enable_upnp: bool = False,
        reset_transient_state: bool = True,
    ) -> EmuleProfile:
        config_root = profile_root / "config"
        logs_root = profile_root / "logs"
        incoming_root = profile_root / "Incoming"
        temp_root = profile_root / "Temp"
        for path in (profile_root, config_root, logs_root, incoming_root, temp_root):
            path.mkdir(parents=True, exist_ok=True)

        preferences_path = config_root / "preferences.ini"
        preferences_path.write_text(
            _preferences_content(
                bind_addr=bind_addr,
                tcp_port=tcp_port,
                udp_port=udp_port,
                server_udp_port=server_udp_port,
                web_port=web_port,
                kad_udp_key=kad_udp_key,
                enable_kademlia=enable_kademlia,
                enable_ed2k=enable_ed2k,
                enable_upnp=enable_upnp,
            ),
            encoding="ascii",
            newline="\n",
        )

        if reset_transient_state:
            for path in (logs_root, incoming_root, temp_root):
                if path.exists():
                    shutil.rmtree(path)
                path.mkdir(parents=True, exist_ok=True)
            for item in config_root.iterdir():
                if item.name in {
                    "preferences.ini",
                    "preferences.dat",
                    "preferencesKad.dat",
                    "cryptkey.dat",
                    "collectioncryptkey.dat",
                }:
                    continue
                if item.is_dir():
                    shutil.rmtree(item)
                else:
                    item.unlink(missing_ok=True)
            for marker in ("harness.ready", "status.log", "seed.ed2k"):
                (profile_root / marker).unlink(missing_ok=True)

        return EmuleProfile(
            profile_root=profile_root.resolve(),
            preferences_path=preferences_path.resolve(),
            logs_root=logs_root.resolve(),
            incoming_root=incoming_root.resolve(),
            temp_root=temp_root.resolve(),
        )

    def set_obfuscation_mode(self, profile: EmuleProfile, *, obfuscated_preferred: bool) -> None:
        desired = {
            "CryptLayerRequested": "1" if obfuscated_preferred else "0",
            "CryptLayerRequired": "0",
            "CryptLayerSupported": "1" if obfuscated_preferred else "0",
        }
        content = profile.preferences_path.read_text(encoding="ascii")
        for key, value in desired.items():
            pattern = re.compile(rf"(?m)^{re.escape(key)}=.*$")
            replacement = f"{key}={value}"
            if pattern.search(content):
                content = pattern.sub(replacement, content)
            else:
                content = content.rstrip("\r\n") + f"\n{replacement}\n"
        profile.preferences_path.write_text(content, encoding="ascii", newline="\n")

    def start_private_ed2k_session(
        self,
        *,
        profile: EmuleProfile,
        seed_file_path: Path | None = None,
        export_link_path: Path | None = None,
        export_aich_path: Path | None = None,
        export_source_ip: str | None = None,
        download_link_path: Path | None = None,
        skip_build: bool = False,
    ) -> EmuleSession:
        kill_processes_by_name(["eMule_v072a_parity"])
        runtime_exe = self.runtime_exe_path()
        if not skip_build or not runtime_exe.is_file():
            runtime_exe = self.build()
        if not runtime_exe.is_file():
            raise FileNotFoundError(f"eMule harness runtime exe not found at {runtime_exe}")

        ready_file = profile.profile_root / "harness.ready"
        status_log_path = profile.profile_root / "status.log"
        trace_log_path = profile.logs_root / "emule-harness-kad-trace.log"
        verbose_log_path = profile.logs_root / "eMule_Verbose.log"
        for path in (ready_file, status_log_path):
            path.unlink(missing_ok=True)
        for path in (export_link_path, export_aich_path):
            if path:
                path.unlink(missing_ok=True)

        session_name = f"private-emule-harness-{_stamp()}"
        session_dir = self.paths.tmp_dir / session_name
        session_dir.mkdir(parents=True, exist_ok=True)
        stdout_path = session_dir / "emule-harness-stdout.log"
        stderr_path = session_dir / "emule-harness-stderr.log"

        args: list[str | Path] = [
            runtime_exe,
            "-AutoStart",
            f"-configdir={profile.profile_root}",
            f"-readyfile={ready_file}",
            "-ignoreinstances",
        ]
        if seed_file_path:
            args.append(f"-sharefile={seed_file_path}")
        if export_link_path:
            args.append(f"-exportlinkfile={export_link_path}")
        if export_aich_path:
            args.append(f"-exportaichfile={export_aich_path}")
        if export_source_ip:
            args.append(f"-exportsourceip={export_source_ip}")
        if download_link_path:
            args.append(f"-downloadlinkfile={download_link_path}")
        parity_hook_config = profile.profile_root / "parity-hooks.v1.json"
        if parity_hook_config.is_file():
            args.append(f"-hookconfigfile={parity_hook_config}")

        started_at_timestamp = time.time()
        process = start_process(
            args,
            cwd=runtime_exe.parent,
            stdout_path=stdout_path,
            stderr_path=stderr_path,
        )
        self._wait_ready(ready_file, process_pid=process.pid)
        session = EmuleSession(
            session_dir=session_dir,
            session_name=session_name,
            profile_root=profile.profile_root,
            ready_file=ready_file,
            status_log_path=status_log_path,
            trace_log_path=trace_log_path,
            verbose_log_path=verbose_log_path,
            stdout_path=stdout_path,
            stderr_path=stderr_path,
            export_link_path=export_link_path,
            export_aich_path=export_aich_path,
            download_link_path=download_link_path,
            udp_dump_path=latest_file(profile.logs_root, "emule-harness-udp-dump-*.jsonl", since_timestamp=started_at_timestamp - 5),
            ed2k_dump_path=latest_file(profile.logs_root, "emule-harness-ed2k-tcp-dump-*.jsonl", since_timestamp=started_at_timestamp - 5),
            pid=process.pid,
            started_at_utc=datetime.now(timezone.utc).isoformat(),
            started_at_timestamp=started_at_timestamp,
        )
        session.write_metadata()
        return session

    def stop(self, session: EmuleSession, *, flush_wait_seconds: int = 5) -> EmuleSession:
        stop_process_tree(session.pid)
        time.sleep(max(flush_wait_seconds, 1))
        session.udp_dump_path = latest_file(
            session.profile_root / "logs",
            "emule-harness-udp-dump-*.jsonl",
            since_timestamp=session.started_at_timestamp - 5,
        )
        session.ed2k_dump_path = latest_file(
            session.profile_root / "logs",
            "emule-harness-ed2k-tcp-dump-*.jsonl",
            since_timestamp=session.started_at_timestamp - 5,
        )
        session.write_metadata()
        return session

    def _wait_ready(self, ready_file: Path, *, process_pid: int, timeout_seconds: int = 90) -> dict[str, str]:
        deadline = time.monotonic() + timeout_seconds
        while time.monotonic() < deadline:
            if ready_file.is_file():
                state = _read_ready_file(ready_file)
                if state.get("state") != "ready":
                    raise RuntimeError(f"eMule harness ready file has state={state.get('state')!r}")
                if int(state.get("pid", "0")) != process_pid:
                    raise RuntimeError(f"eMule harness ready pid mismatch: {state.get('pid')} != {process_pid}")
                return state
            time.sleep(0.25)
        raise TimeoutError(f"timed out waiting for eMule harness ready file {ready_file}")


def _preferences_content(
    *,
    bind_addr: str,
    tcp_port: int,
    udp_port: int,
    server_udp_port: int,
    web_port: int,
    kad_udp_key: int,
    enable_kademlia: bool,
    enable_ed2k: bool,
    enable_upnp: bool,
) -> str:
    return f"""[eMule]
AppVersion=0.72a
Port={tcp_port}
UDPPort={udp_port}
ServerUDPPort={server_udp_port}
BindAddr={bind_addr}
AllowLocalHostIP=1
FilterBadIPs=0
Autoconnect=1
StartupMinimized=1
MinToTray=1
BringToFront=0
Splashscreen=0
SaveLogToDisk=1
SaveDebugToDisk=1
Verbose=1
OnlineSignature=0
AutoTakeED2KLinks=0
AutoConnectStaticOnly=0
Serverlist=0
AddServersFromServer=0
AddServersFromClient=0
NetworkKademlia={1 if enable_kademlia else 0}
NetworkED2K={1 if enable_ed2k else 0}
OpenPortsOnStartUp={1 if enable_upnp else 0}
EnableScheduler=0
KadUDPKey={kad_udp_key}
MaxDownload={PRIVATE_HARNESS_RATE_LIMIT_KIB_PER_SEC}
MaxUpload={PRIVATE_HARNESS_RATE_LIMIT_KIB_PER_SEC}
CreateCrashDump=0
Nick=eMule harness
CryptLayerRequested=0
CryptLayerRequired=0
CryptLayerSupported=0

[WebServer]
Enabled=0
Port={web_port}
WebUseUPnP={1 if enable_upnp else 0}

[UPnP]
EnableUPnP={1 if enable_upnp else 0}
CloseUPnPOnExit={1 if enable_upnp else 0}
"""


def _read_ready_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def _stamp() -> str:
    return datetime.now().strftime("%Y%m%d-%H%M%S")
