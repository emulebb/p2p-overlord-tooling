from __future__ import annotations

import ipaddress
import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

from tests.e2e.lib.paths import WorkspacePaths
from tests.e2e.lib.processes import run_checked


WINDOWS_IPV4_QUERY = (
    "Get-NetIPAddress -AddressFamily IPv4 "
    "| Select-Object InterfaceAlias,IPAddress,SkipAsSource,AddressState "
    "| ConvertTo-Json -Compress"
)


@dataclass(frozen=True)
class LiveInterfaceBinding:
    interface_alias: str
    bind_ip: str


def resolve_live_interface_binding(
    paths: WorkspacePaths,
    *,
    interface_alias: str = "hide.me",
    command_runner: Callable[..., Any] | None = None,
) -> LiveInterfaceBinding:
    override_ip = os.environ.get("OVERLORD_LIVE_BIND_IP", "").strip()
    if override_ip:
        _validate_ipv4(override_ip)
        return LiveInterfaceBinding(interface_alias=interface_alias, bind_ip=override_ip)

    override_alias = os.environ.get("OVERLORD_LIVE_INTERFACE_ALIAS", "").strip()
    if override_alias:
        interface_alias = override_alias

    runner = command_runner or run_checked
    completed = runner(
        ["powershell", "-NoProfile", "-Command", WINDOWS_IPV4_QUERY],
        cwd=paths.project_root,
        timeout=30,
    )
    payload = json.loads(completed.stdout or "[]")
    candidates = normalize_interface_candidates(payload)
    bind_ip = choose_bind_ip_for_interface(candidates, interface_alias=interface_alias)
    return LiveInterfaceBinding(interface_alias=interface_alias, bind_ip=bind_ip)


def normalize_interface_candidates(payload: object) -> list[dict[str, Any]]:
    if isinstance(payload, dict):
        items = [payload]
    elif isinstance(payload, list):
        items = [item for item in payload if isinstance(item, dict)]
    else:
        return []

    normalized: list[dict[str, Any]] = []
    for item in items:
        alias = str(item.get("InterfaceAlias") or "").strip()
        ip = str(item.get("IPAddress") or "").strip()
        if not alias or not ip:
            continue
        normalized.append(
            {
                "interface_alias": alias,
                "ip_address": ip,
                "skip_as_source": bool(item.get("SkipAsSource")),
                "address_state": str(item.get("AddressState") or "").strip(),
            }
        )
    return normalized


def choose_bind_ip_for_interface(candidates: list[dict[str, Any]], *, interface_alias: str) -> str:
    matching = [
        candidate
        for candidate in candidates
        if str(candidate.get("interface_alias", "")).casefold() == interface_alias.casefold()
    ]
    if not matching:
        available_aliases = sorted(
            {
                str(candidate.get("interface_alias", "")).strip()
                for candidate in candidates
                if str(candidate.get("interface_alias", "")).strip()
            }
        )
        raise RuntimeError(
            f"no IPv4 addresses found for interface alias {interface_alias!r}; "
            f"available aliases: {available_aliases}"
        )

    ranked = sorted(matching, key=_candidate_rank)
    selected_ip = str(ranked[0]["ip_address"])
    _validate_ipv4(selected_ip)
    return selected_ip


def _candidate_rank(candidate: dict[str, Any]) -> tuple[int, int, str]:
    ip = str(candidate.get("ip_address", ""))
    skip_as_source = bool(candidate.get("skip_as_source"))
    address_state = str(candidate.get("address_state", "")).casefold()
    return (
        0 if address_state == "preferred" else 1,
        1 if skip_as_source else 0,
        ip,
    )


def _validate_ipv4(value: str) -> None:
    parsed = ipaddress.ip_address(value)
    if parsed.version != 4:
        raise ValueError(f"{value!r} is not an IPv4 address")
