from __future__ import annotations

import json
import os
import shlex
import sys
import time
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path

from tests.e2e.lib.artifacts import latest_file
from tests.e2e.lib.paths import WorkspacePaths
from tests.e2e.lib.processes import (
    kill_processes_by_name,
    run_checked,
    start_process,
    stop_process_tree,
    stop_processes_by_command_line_fragment,
)

# eMule persists MaxDownload/MaxUpload in KiB/s, not Kb/s.
# Keep local parity runs effectively uncapped without relying on a magic literal.
PRIVATE_HARNESS_RATE_LIMIT_BITS_PER_SEC = 10_000_000_000
PRIVATE_HARNESS_RATE_LIMIT_KIB_PER_SEC = PRIVATE_HARNESS_RATE_LIMIT_BITS_PER_SEC // 8 // 1024
_HARNESS_APP_DIR_CANDIDATES = (
    "eMule-v0.72a-tracing-harness-community",
    "eMule-v0.72a-tracing-harness",
)
_RUNTIME_EXE_CANDIDATES = (
    "eMule_v072a_parity.exe",
    "emule.exe",
)
_EMULEBB_TESTS_REPO_KEY = "tests"
_EMULEBB_SEED_CONFIG_RELATIVE = Path("manifests") / "live-profile-seed" / "config"


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
        preferred_dirs = [
            (
                workspace
                / "workspaces"
                / "v0.72a"
                / "app"
                / harness_dir
                / "srchybrid"
                / "x64"
                / "Debug"
            )
            for harness_dir in _HARNESS_APP_DIR_CANDIDATES
        ]
        for preferred in preferred_dirs:
            if preferred.exists():
                return preferred

        matches: list[Path] = []
        for harness_dir in _HARNESS_APP_DIR_CANDIDATES:
            matches.extend(
                workspace.glob(
                    f"workspaces/*/app/{harness_dir}/srchybrid/x64/Debug",
                )
            )
        unique_matches = sorted({match.resolve() for match in matches})
        if len(unique_matches) == 1:
            return unique_matches[0]
        if unique_matches:
            raise RuntimeError(
                "multiple eMule tracing-harness debug dirs found under "
                f"{workspace}: {', '.join(str(match) for match in unique_matches)}"
            )
        raise RuntimeError(f"could not resolve eMule tracing-harness debug dir under {workspace}")

    def runtime_exe_path(self) -> Path:
        debug_dir = self.resolve_debug_dir()
        for exe_name in _RUNTIME_EXE_CANDIDATES:
            exe_path = debug_dir / exe_name
            if exe_path.is_file():
                return exe_path
        return debug_dir / _RUNTIME_EXE_CANDIDATES[0]

    def _built_exe_path(self, debug_dir: Path) -> Path:
        for exe_name in _RUNTIME_EXE_CANDIDATES:
            exe_path = debug_dir / exe_name
            if exe_path.is_file():
                return exe_path
        raise FileNotFoundError(
            "built eMule executable not found; checked "
            f"{', '.join(str(debug_dir / name) for name in _RUNTIME_EXE_CANDIDATES)}"
        )

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
        return self._built_exe_path(debug_dir)

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
        shared_profiles = _load_shared_live_profiles(self.paths)
        profile = shared_profiles.materialize_private_harness_profile(
            shared_profiles.PrivateHarnessProfileSpec(
                seed_config_dir=_shared_seed_config_dir(self.paths),
                profile_root=profile_root,
                bind_addr=bind_addr,
                tcp_port=tcp_port,
                udp_port=udp_port,
                server_udp_port=server_udp_port,
                web_port=web_port,
                kad_udp_key=kad_udp_key,
                enable_kademlia=enable_kademlia,
                enable_ed2k=enable_ed2k,
                enable_upnp=enable_upnp,
                reset_transient_state=reset_transient_state,
            )
        )

        return EmuleProfile(
            profile_root=Path(profile["profile_root"]).resolve(),
            preferences_path=Path(profile["preferences_path"]).resolve(),
            logs_root=Path(profile["logs_root"]).resolve(),
            incoming_root=Path(profile["incoming_root"]).resolve(),
            temp_root=Path(profile["temp_root"]).resolve(),
        )

    def set_obfuscation_mode(self, profile: EmuleProfile, *, obfuscated_preferred: bool) -> None:
        shared_profiles = _load_shared_live_profiles(self.paths)
        shared_profiles.apply_private_harness_obfuscation(
            profile.profile_root / "config",
            obfuscated_preferred,
        )

    def start_private_ed2k_session(
        self,
        *,
        profile: EmuleProfile,
        seed_file_path: Path | None = None,
        export_link_path: Path | None = None,
        export_aich_path: Path | None = None,
        export_source_ip: str | None = None,
        download_link_path: Path | None = None,
        bootstrap_peers: str | None = None,
        skip_build: bool = False,
        kill_existing: bool = True,
    ) -> EmuleSession:
        if kill_existing:
            kill_processes_by_name(["eMule_v072a_parity"])
            stop_processes_by_command_line_fragment(str(profile.profile_root))
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
        if bootstrap_peers:
            args.append(f"-bootstrap={bootstrap_peers}")
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
        stop_processes_by_command_line_fragment(str(session.profile_root))
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

    def _wait_ready(self, ready_file: Path, *, process_pid: int, timeout_seconds: int = 300) -> dict[str, str]:
        deadline = time.monotonic() + timeout_seconds
        last_state: dict[str, str] | None = None
        while time.monotonic() < deadline:
            if ready_file.is_file():
                state = _read_ready_file(ready_file)
                last_state = state
                if state.get("state") == "ready" and int(state.get("pid", "0")) == process_pid:
                    return state
            time.sleep(0.25)
        raise TimeoutError(
            f"timed out waiting for eMule harness ready file {ready_file}; "
            f"last_state={last_state}"
        )


def _shared_tests_root(paths: WorkspacePaths) -> Path:
    workspace = paths.emule_workspace_root
    if workspace is not None:
        deps_path = workspace / "workspaces" / "workspace" / "deps.json"
        if deps_path.is_file():
            deps = json.loads(deps_path.read_text(encoding="utf-8"))
            repo_path = deps.get("workspace", {}).get("repos", {}).get(_EMULEBB_TESTS_REPO_KEY)
            if repo_path:
                deps_candidate = (deps_path.parent / str(repo_path)).resolve()
                if deps_candidate.is_dir():
                    return deps_candidate
        workspace_candidate = workspace / "repos" / "emulebb-build-tests"
        if workspace_candidate.is_dir():
            return workspace_candidate.resolve()

    sibling_candidate = paths.tooling_root.parent / "emulebb-build-tests"
    if sibling_candidate.is_dir():
        return sibling_candidate.resolve()
    raise RuntimeError("could not resolve emulebb-build-tests from workspace deps or repo siblings")


def _shared_seed_config_dir(paths: WorkspacePaths) -> Path:
    seed_config_dir = _shared_tests_root(paths) / _EMULEBB_SEED_CONFIG_RELATIVE
    if not seed_config_dir.is_dir():
        raise RuntimeError(f"eMule live-profile seed config not found at {seed_config_dir}")
    return seed_config_dir


def _load_shared_live_profiles(paths: WorkspacePaths):
    tests_root = _shared_tests_root(paths)
    if str(tests_root) not in sys.path:
        sys.path.insert(0, str(tests_root))
    from emule_test_harness import live_profiles

    return live_profiles


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
