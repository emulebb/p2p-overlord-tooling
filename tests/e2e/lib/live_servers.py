from __future__ import annotations

import ipaddress
import struct
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from tests.e2e.lib.live_seeds import EmuleHarnessSeedBundle

TAGTYPE_STRING = 0x02
TAGTYPE_UINT32 = 0x03
TAGTYPE_UINT16 = 0x08
TAGTYPE_UINT8 = 0x09
TAGTYPE_STR1 = 0x11
TAGTYPE_STR22 = 0x26

ST_SERVERNAME = 0x01
ST_DESCRIPTION = 0x0B
ST_UDPFLAGS = 0x92
ST_UDPKEY = 0x95
ST_UDPKEYIP = 0x96
ST_TCPPORTOBFUSCATION = 0x97
ST_UDPPORTOBFUSCATION = 0x98


@dataclass(frozen=True)
class LiveEd2kServerEntry:
    host: str
    port: int
    name: str | None = None
    description: str | None = None
    udp_flags: int = 0
    udp_key: int = 0
    udp_key_ip: int = 0
    obfuscation_port_tcp: int = 0
    obfuscation_port_udp: int = 0


def parse_server_met(path: Path) -> list[LiveEd2kServerEntry]:
    payload = path.read_bytes()
    if len(payload) < 5:
        raise ValueError(f"server.met at {path} is too short")

    entry_count = _read_uint32(payload, 1)
    cursor = 5
    entries: list[LiveEd2kServerEntry] = []
    for entry_index in range(entry_count):
        if cursor + 10 > len(payload):
            raise ValueError(
                f"server.met at {path} is truncated while reading entry {entry_index}"
            )
        host = str(ipaddress.IPv4Address(payload[cursor : cursor + 4]))
        cursor += 4
        port = _read_uint16(payload, cursor)
        cursor += 2
        tag_count = _read_uint32(payload, cursor)
        cursor += 4

        fields: dict[str, Any] = {
            "host": host,
            "port": port,
            "name": None,
            "description": None,
            "udp_flags": 0,
            "udp_key": 0,
            "udp_key_ip": 0,
            "obfuscation_port_tcp": 0,
            "obfuscation_port_udp": 0,
        }
        for _ in range(tag_count):
            tag_id, value, cursor = _parse_tag(payload, cursor, path=path)
            if tag_id == ST_SERVERNAME and isinstance(value, str):
                fields["name"] = value
            elif tag_id == ST_DESCRIPTION and isinstance(value, str):
                fields["description"] = value
            elif tag_id == ST_UDPFLAGS and isinstance(value, int):
                fields["udp_flags"] = value
            elif tag_id == ST_UDPKEY and isinstance(value, int):
                fields["udp_key"] = value
            elif tag_id == ST_UDPKEYIP and isinstance(value, int):
                fields["udp_key_ip"] = value
            elif tag_id == ST_TCPPORTOBFUSCATION and isinstance(value, int):
                fields["obfuscation_port_tcp"] = value
            elif tag_id == ST_UDPPORTOBFUSCATION and isinstance(value, int):
                fields["obfuscation_port_udp"] = value

        entries.append(LiveEd2kServerEntry(**fields))
    if cursor != len(payload):
        raise ValueError(f"server.met at {path} has trailing bytes after {entry_count} entries")
    return entries


def select_live_server_entries(
    entries: list[LiveEd2kServerEntry],
    *,
    max_candidates: int | None = None,
) -> list[LiveEd2kServerEntry]:
    if max_candidates is None:
        return list(entries)
    if max_candidates <= 0:
        raise ValueError("max_candidates must be positive when specified")
    return list(entries[:max_candidates])


def resolve_live_server_entries(
    seed_bundle: EmuleHarnessSeedBundle,
    manifest: dict[str, Any],
) -> list[LiveEd2kServerEntry]:
    max_candidates = _manifest_server_candidate_limit(manifest)
    return select_live_server_entries(
        parse_server_met(seed_bundle.server_met_path),
        max_candidates=max_candidates,
    )


def _manifest_server_candidate_limit(manifest: dict[str, Any]) -> int | None:
    server_selection = manifest.get("serverSelection")
    if not isinstance(server_selection, dict):
        return None
    raw_limit = server_selection.get("maxCandidates")
    if raw_limit is None:
        return None
    max_candidates = int(raw_limit)
    if max_candidates <= 0:
        raise ValueError("manifest serverSelection.maxCandidates must be positive")
    return max_candidates


def _parse_tag(payload: bytes, cursor: int, *, path: Path) -> tuple[int | None, Any, int]:
    if cursor >= len(payload):
        raise ValueError(f"server.met at {path} is truncated while reading a tag")

    raw_type = payload[cursor]
    cursor += 1
    uses_short_id = bool(raw_type & 0x80)
    tag_type = raw_type & 0x7F

    tag_id: int | None
    if uses_short_id:
        if cursor >= len(payload):
            raise ValueError(f"server.met at {path} is truncated while reading a short tag id")
        tag_id = payload[cursor]
        cursor += 1
    else:
        if cursor + 2 > len(payload):
            raise ValueError(f"server.met at {path} is truncated while reading a tag name length")
        name_length = _read_uint16(payload, cursor)
        cursor += 2
        if cursor + name_length > len(payload):
            raise ValueError(f"server.met at {path} is truncated while reading a tag name")
        name_bytes = payload[cursor : cursor + name_length]
        cursor += name_length
        tag_id = name_bytes[0] if name_length == 1 else None

    value, cursor = _parse_tag_value(payload, cursor, tag_type=tag_type, path=path)
    return tag_id, value, cursor


def _parse_tag_value(payload: bytes, cursor: int, *, tag_type: int, path: Path) -> tuple[Any, int]:
    if tag_type == TAGTYPE_STRING:
        if cursor + 2 > len(payload):
            raise ValueError(f"server.met at {path} is truncated while reading a string length")
        length = _read_uint16(payload, cursor)
        cursor += 2
        if cursor + length > len(payload):
            raise ValueError(f"server.met at {path} is truncated while reading a string value")
        return payload[cursor : cursor + length].decode("utf-8", errors="replace"), cursor + length
    if TAGTYPE_STR1 <= tag_type <= TAGTYPE_STR22:
        length = tag_type - TAGTYPE_STR1 + 1
        if cursor + length > len(payload):
            raise ValueError(f"server.met at {path} is truncated while reading a short string value")
        return payload[cursor : cursor + length].decode("utf-8", errors="replace"), cursor + length
    if tag_type == TAGTYPE_UINT32:
        if cursor + 4 > len(payload):
            raise ValueError(f"server.met at {path} is truncated while reading a uint32 value")
        return _read_uint32(payload, cursor), cursor + 4
    if tag_type == TAGTYPE_UINT16:
        if cursor + 2 > len(payload):
            raise ValueError(f"server.met at {path} is truncated while reading a uint16 value")
        return _read_uint16(payload, cursor), cursor + 2
    if tag_type == TAGTYPE_UINT8:
        if cursor >= len(payload):
            raise ValueError(f"server.met at {path} is truncated while reading a uint8 value")
        return payload[cursor], cursor + 1
    raise ValueError(f"server.met at {path} uses unsupported tag type 0x{tag_type:02X}")


def _read_uint32(payload: bytes, cursor: int) -> int:
    return struct.unpack_from("<I", payload, cursor)[0]


def _read_uint16(payload: bytes, cursor: int) -> int:
    return struct.unpack_from("<H", payload, cursor)[0]
