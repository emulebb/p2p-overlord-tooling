from __future__ import annotations

import ipaddress
import json
import re
import struct
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


@dataclass(frozen=True)
class Ed2kLink:
    link: str
    file_name: str
    file_size: int
    file_hash: str
    aich_root: str | None


def parse_ed2k_link_file(path: Path) -> Ed2kLink:
    link = path.read_text(encoding="utf-8").strip()
    match = re.match(r"^ed2k://\|file\|(?P<name>[^|]+)\|(?P<size>\d+)\|(?P<hash>[0-9A-Fa-f]{32})\|", link)
    if not match:
        raise ValueError(f"ED2K link at {path} is not in the expected file-link format")
    aich_match = re.search(r"\|h=(?P<aich>[A-Za-z2-7]+)\|", link)
    return Ed2kLink(
        link=link,
        file_name=match.group("name"),
        file_size=int(match.group("size")),
        file_hash=match.group("hash").lower(),
        aich_root=aich_match.group("aich") if aich_match else None,
    )


def add_plain_source(link: str, *, source_ip: str, source_tcp_port: int) -> str:
    trimmed = re.sub(r"\|sources,[^|]*\|/$", "|/", link.strip())
    if not trimmed.endswith("|/"):
        raise ValueError(f"ED2K link does not end with '|/': {trimmed}")
    return re.sub(r"\|/$", f"|sources,{source_ip}:{source_tcp_port}|/", trimmed)


def add_extended_source(
    link: str,
    *,
    source_ip: str,
    source_tcp_port: int,
    source_user_hash: str,
    source_obfuscation_options: int,
) -> str:
    if not re.match(r"^[0-9A-Fa-f]{32}$", source_user_hash):
        raise ValueError("source_user_hash must be 32 hex characters")
    trimmed = re.sub(r"\|sourcesx,[^|]*\|/$", "|/", link.strip())
    if not trimmed.endswith("|/"):
        raise ValueError(f"ED2K link does not end with '|/': {trimmed}")
    extension = f"|/|sourcesx,{source_ip}:{source_tcp_port}:{source_user_hash.lower()}:{source_obfuscation_options}|/"
    return re.sub(r"\|/$", extension, trimmed)


def write_server_met(
    destination: Path,
    *,
    server_ip: str,
    server_port: int,
    udp_flags: int = 0,
    udp_key: int = 0,
    udp_key_ip: int = 0,
    tcp_obfuscation_port: int = 0,
    udp_obfuscation_port: int = 0,
) -> Path:
    destination.parent.mkdir(parents=True, exist_ok=True)
    ip_bytes = ipaddress.IPv4Address(server_ip).packed
    tags: list[bytes] = []
    if udp_flags:
        tags.append(_short_uint32_tag(0x92, udp_flags))
    if udp_key:
        tags.append(_short_uint32_tag(0x95, udp_key))
    if udp_key_ip:
        tags.append(_short_uint32_tag(0x96, udp_key_ip))
    if tcp_obfuscation_port:
        tags.append(_short_uint16_tag(0x97, tcp_obfuscation_port))
    if udp_obfuscation_port:
        tags.append(_short_uint16_tag(0x98, udp_obfuscation_port))

    payload = bytearray()
    payload.append(0xE0)
    payload.extend(struct.pack("<I", 1))
    payload.extend(ip_bytes)
    payload.extend(struct.pack("<H", server_port))
    payload.extend(struct.pack("<I", len(tags)))
    for tag in tags:
        payload.extend(tag)
    destination.write_bytes(bytes(payload))
    return destination


def dump_records(path: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            stripped = line.strip()
            if stripped:
                records.append(json.loads(stripped))
    return records


def dump_has_opcode(path: Path, *, direction: str, opcode_names: Iterable[str]) -> bool:
    names = set(opcode_names)
    return any(
        record.get("direction") == direction and record.get("opcode_name") in names
        for record in dump_records(path)
    )


def dump_transport_modes(path: Path, *, direction: str | None = None) -> list[str]:
    observed: list[str] = []
    for record in dump_records(path):
        if direction and record.get("direction") != direction:
            continue
        if record.get("direction") == "meta":
            continue
        mode = str(record.get("transport_mode") or "")
        if not mode:
            continue
        normalized = "obfuscated" if mode == "user_hash" else mode
        if normalized not in observed:
            observed.append(normalized)
    return observed


def dump_record_hashset_evidence(path: Path, *, opcode_name: str, direction: str) -> dict[str, Any]:
    for record in dump_records(path):
        if record.get("opcode_name") != opcode_name or record.get("direction") != direction:
            continue
        options = hashset_options_from_payload_hex(str(record.get("payload_hex") or ""))
        return {
            "eventSeq": record.get("event_seq"),
            "remoteAddr": record.get("remote_addr"),
            "direction": direction,
            "opcodeName": opcode_name,
            **options,
        }
    raise AssertionError(f"did not find {direction} {opcode_name} in {path}")


def hashset_options_from_payload_hex(payload_hex: str) -> dict[str, Any]:
    payload = bytes.fromhex(payload_hex)
    identifier_length = file_identifier_length(payload)
    if len(payload) <= identifier_length:
        raise ValueError(f"short hashset payload length {len(payload)} missing options byte")
    raw_options = payload[identifier_length]
    return {
        "rawOptions": raw_options,
        "requestsMd4": bool(raw_options & 0x01),
        "requestsAich": bool(raw_options & 0x02),
    }


def file_identifier_length(payload: bytes) -> int:
    if len(payload) < 17:
        raise ValueError(f"short FileIdentifier payload length {len(payload)}")
    descriptor = payload[0]
    if descriptor & 0xF8:
        raise ValueError(f"unsupported FileIdentifier descriptor 0x{descriptor:02X}")
    if not descriptor & 0x01:
        raise ValueError(f"FileIdentifier descriptor 0x{descriptor:02X} missing MD4 bit")
    length = 1 + 16
    if descriptor & 0x02:
        length += 8
    if descriptor & 0x04:
        length += 20
    return length


def _short_uint32_tag(tag_id: int, value: int) -> bytes:
    return bytes([0x83, tag_id]) + struct.pack("<I", value)


def _short_uint16_tag(tag_id: int, value: int) -> bytes:
    return bytes([0x88, tag_id]) + struct.pack("<H", value)
