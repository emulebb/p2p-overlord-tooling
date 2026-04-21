from __future__ import annotations

import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Mapping, Sequence


CREATE_FLAGS = 0
if os.name == "nt":
    CREATE_FLAGS = subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.CREATE_NO_WINDOW


def run_checked(
    args: Sequence[str | os.PathLike[str]],
    *,
    cwd: Path | None = None,
    env: Mapping[str, str] | None = None,
    timeout: int | None = None,
) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        [str(arg) for arg in args],
        cwd=str(cwd) if cwd else None,
        env=_merged_env(env),
        timeout=timeout,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError(
            "command failed with exit code "
            f"{completed.returncode}: {' '.join(str(arg) for arg in args)}\n"
            f"stdout:\n{completed.stdout}\n\nstderr:\n{completed.stderr}"
        )
    return completed


def start_process(
    args: Sequence[str | os.PathLike[str]],
    *,
    cwd: Path | None,
    stdout_path: Path,
    stderr_path: Path,
    env: Mapping[str, str] | None = None,
) -> subprocess.Popen[bytes]:
    stdout_path.parent.mkdir(parents=True, exist_ok=True)
    stderr_path.parent.mkdir(parents=True, exist_ok=True)
    stdout = stdout_path.open("ab")
    stderr = stderr_path.open("ab")
    try:
        return subprocess.Popen(
            [str(arg) for arg in args],
            cwd=str(cwd) if cwd else None,
            env=_merged_env(env),
            stdout=stdout,
            stderr=stderr,
            creationflags=CREATE_FLAGS,
        )
    finally:
        stdout.close()
        stderr.close()


def stop_process_tree(pid: int, *, timeout_seconds: int = 15) -> None:
    if pid <= 0:
        return
    if os.name == "nt":
        subprocess.run(
            ["taskkill", "/PID", str(pid), "/T", "/F"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
    else:
        subprocess.run(["kill", "-TERM", str(pid)], check=False)

    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        if not process_exists(pid):
            return
        time.sleep(0.25)
    if process_exists(pid):
        if os.name == "nt":
            subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"], check=False)
        else:
            subprocess.run(["kill", "-KILL", str(pid)], check=False)


def kill_processes_by_name(names: Sequence[str]) -> None:
    if not names:
        return
    if os.name == "nt":
        for name in names:
            image = name if name.lower().endswith(".exe") else f"{name}.exe"
            subprocess.run(
                ["taskkill", "/IM", image, "/T", "/F"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )
        return
    subprocess.run(["pkill", "-f", "|".join(names)], check=False)


def process_exists(pid: int) -> bool:
    if pid <= 0:
        return False
    if os.name == "nt":
        result = subprocess.run(
            ["tasklist", "/FI", f"PID eq {pid}", "/FO", "CSV", "/NH"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        return str(pid) in result.stdout
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def python_executable() -> str:
    return sys.executable


def _merged_env(extra: Mapping[str, str] | None) -> dict[str, str]:
    merged = os.environ.copy()
    if extra:
        merged.update({key: str(value) for key, value in extra.items()})
    return merged
