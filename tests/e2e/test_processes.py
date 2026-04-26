from __future__ import annotations

import subprocess

from tests.e2e.lib import processes


def test_stop_processes_by_command_line_fragment_uses_profile_scoped_windows_query(
    monkeypatch,
) -> None:
    calls: list[list[str]] = []

    def fake_run(args, **_kwargs):  # noqa: ANN001 - subprocess.run-compatible test stub.
        calls.append(list(args))
        return subprocess.CompletedProcess(args, 0)

    monkeypatch.setattr(processes.os, "name", "nt")
    monkeypatch.setattr(processes.subprocess, "run", fake_run)

    processes.stop_processes_by_command_line_fragment(r"C:\tmp\overlord\seed-profile")

    assert calls
    assert calls[0][:3] == ["powershell", "-NoProfile", "-Command"]
    assert calls[0][-1] == r"C:\tmp\overlord\seed-profile"
    assert "CommandLine.Contains($needle)" in calls[0][3]


def test_stop_processes_by_command_line_fragment_ignores_empty_fragments(
    monkeypatch,
) -> None:
    calls: list[list[str]] = []

    def fake_run(args, **_kwargs):  # noqa: ANN001 - subprocess.run-compatible test stub.
        calls.append(list(args))
        return subprocess.CompletedProcess(args, 0)

    monkeypatch.setattr(processes.subprocess, "run", fake_run)

    processes.stop_processes_by_command_line_fragment("  ")

    assert calls == []
