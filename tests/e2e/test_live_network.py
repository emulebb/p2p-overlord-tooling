from __future__ import annotations

from pathlib import Path

import pytest

from tests.e2e.lib.live_network import (
    WINDOWS_IPV4_QUERY,
    choose_bind_ip_for_interface,
    normalize_interface_candidates,
    resolve_live_interface_binding,
)
from tests.e2e.lib.paths import WorkspacePaths


def test_normalize_interface_candidates_accepts_dict_or_list() -> None:
    single = normalize_interface_candidates(
        {
            "InterfaceAlias": "hide.me",
            "IPAddress": "10.9.0.5",
            "SkipAsSource": False,
            "AddressState": "Preferred",
        }
    )
    many = normalize_interface_candidates(
        [
            {
                "InterfaceAlias": "hide.me",
                "IPAddress": "10.9.0.5",
                "SkipAsSource": False,
                "AddressState": "Preferred",
            }
        ]
    )

    assert single == many
    assert single == [
        {
            "interface_alias": "hide.me",
            "ip_address": "10.9.0.5",
            "skip_as_source": False,
            "address_state": "Preferred",
        }
    ]


def test_choose_bind_ip_for_interface_prefers_preferred_non_skip_source() -> None:
    bind_ip = choose_bind_ip_for_interface(
        [
            {
                "interface_alias": "hide.me",
                "ip_address": "10.9.0.9",
                "skip_as_source": True,
                "address_state": "Preferred",
            },
            {
                "interface_alias": "hide.me",
                "ip_address": "10.9.0.5",
                "skip_as_source": False,
                "address_state": "Preferred",
            },
            {
                "interface_alias": "Wi-Fi",
                "ip_address": "192.168.1.20",
                "skip_as_source": False,
                "address_state": "Preferred",
            },
        ],
        interface_alias="hide.me",
    )

    assert bind_ip == "10.9.0.5"


def test_resolve_live_interface_binding_honors_env_override(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("OVERLORD_LIVE_BIND_IP", "10.8.0.44")

    class _Completed:
        def __init__(self, stdout: str) -> None:
            self.stdout = stdout

    binding = resolve_live_interface_binding(
        _workspace_paths(tmp_path),
        command_runner=lambda *args, **kwargs: _Completed(
            '[{"InterfaceAlias":"hide.me","IPAddress":"10.8.0.44","SkipAsSource":false,"AddressState":"Preferred"}]'
        ),
    )

    assert binding.interface_alias == "hide.me"
    assert binding.bind_ip == "10.8.0.44"


def test_resolve_live_interface_binding_rejects_stale_env_override(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("OVERLORD_LIVE_BIND_IP", "10.8.0.44")

    class _Completed:
        def __init__(self, stdout: str) -> None:
            self.stdout = stdout

    with pytest.raises(RuntimeError, match="not assigned"):
        resolve_live_interface_binding(
            _workspace_paths(tmp_path),
            command_runner=lambda *args, **kwargs: _Completed(
                '[{"InterfaceAlias":"hide.me","IPAddress":"10.8.0.45","SkipAsSource":false,"AddressState":"Preferred"}]'
            ),
        )


def _workspace_paths(tmp_path: Path) -> WorkspacePaths:
    return WorkspacePaths(
            project_root=tmp_path,
            tooling_root=tmp_path / "tooling",
            agents_root=tmp_path / "agents",
            be_root=tmp_path / "be",
            tmp_dir=tmp_path / "tmp",
            log_dir=tmp_path / "logs",
            emule_workspace_root=None,
        )


def test_resolve_live_interface_binding_honors_interface_alias_override(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.delenv("OVERLORD_LIVE_BIND_IP", raising=False)
    monkeypatch.setenv("OVERLORD_LIVE_INTERFACE_ALIAS", "Wi-Fi")

    class _Completed:
        def __init__(self, stdout: str) -> None:
            self.stdout = stdout

    binding = resolve_live_interface_binding(
        WorkspacePaths(
            project_root=tmp_path,
            tooling_root=tmp_path / "tooling",
            agents_root=tmp_path / "agents",
            be_root=tmp_path / "be",
            tmp_dir=tmp_path / "tmp",
            log_dir=tmp_path / "logs",
            emule_workspace_root=None,
        ),
        command_runner=lambda *args, **kwargs: _Completed(
            '[{"InterfaceAlias":"Wi-Fi","IPAddress":"10.8.0.45","SkipAsSource":false,"AddressState":"Preferred"}]'
        ),
    )

    assert binding.interface_alias == "Wi-Fi"
    assert binding.bind_ip == "10.8.0.45"


def test_resolve_live_interface_binding_reads_powershell_candidates(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("OVERLORD_LIVE_BIND_IP", raising=False)
    monkeypatch.delenv("OVERLORD_LIVE_INTERFACE_ALIAS", raising=False)

    class _Completed:
        def __init__(self, stdout: str) -> None:
            self.stdout = stdout

    def fake_runner(args: list[str], *, cwd: Path, timeout: int):
        assert args == ["powershell", "-NoProfile", "-Command", WINDOWS_IPV4_QUERY]
        assert cwd == tmp_path
        assert timeout == 30
        return _Completed(
            '[{"InterfaceAlias":"Wi-Fi","IPAddress":"192.168.1.20","SkipAsSource":false,"AddressState":"Preferred"},'
            '{"InterfaceAlias":"hide.me","IPAddress":"10.9.0.5","SkipAsSource":false,"AddressState":"Preferred"}]'
        )

    binding = resolve_live_interface_binding(
        WorkspacePaths(
            project_root=tmp_path,
            tooling_root=tmp_path / "tooling",
            agents_root=tmp_path / "agents",
            be_root=tmp_path / "be",
            tmp_dir=tmp_path / "tmp",
            log_dir=tmp_path / "logs",
            emule_workspace_root=None,
        ),
        command_runner=fake_runner,
    )

    assert binding.interface_alias == "hide.me"
    assert binding.bind_ip == "10.9.0.5"


def test_choose_bind_ip_for_interface_reports_available_aliases() -> None:
    with pytest.raises(RuntimeError, match="Wi-Fi"):
        choose_bind_ip_for_interface(
            [{"interface_alias": "Wi-Fi", "ip_address": "10.8.0.45"}],
            interface_alias="hide.me",
        )
