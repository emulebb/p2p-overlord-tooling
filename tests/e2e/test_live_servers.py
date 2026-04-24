from __future__ import annotations

import ipaddress
import struct
from pathlib import Path

import pytest

from tests.e2e.lib.live_seeds import resolve_emule_harness_seed_bundle
from tests.e2e.lib.live_servers import (
    LiveEd2kServerEntry,
    parse_server_met,
    resolve_live_server_entries,
    select_live_server_entries,
)
from tests.e2e.lib.paths import WorkspacePaths


def test_parse_server_met_reads_synthetic_entry_from_private_writer(tmp_path: Path) -> None:
    server_met = tmp_path / "server.met"
    server_met.write_bytes(
        _encode_server_met(
            [
                LiveEd2kServerEntry(
                    host="10.20.30.40",
                    port=4661,
                    udp_flags=0x51,
                    udp_key=0x12345678,
                    udp_key_ip=0x01020304,
                    obfuscation_port_tcp=4662,
                    obfuscation_port_udp=4672,
                )
            ]
        )
    )

    entries = parse_server_met(server_met)

    assert entries == [
        LiveEd2kServerEntry(
            host="10.20.30.40",
            port=4661,
            udp_flags=0x51,
            udp_key=0x12345678,
            udp_key_ip=0x01020304,
            obfuscation_port_tcp=4662,
            obfuscation_port_udp=4672,
        )
    ]


def test_parse_server_met_reads_name_description_and_preserves_order(tmp_path: Path) -> None:
    server_met = tmp_path / "server.met"
    server_met.write_bytes(
        _encode_server_met(
            [
                LiveEd2kServerEntry(
                    host="1.2.3.4",
                    port=4661,
                    name="alpha",
                    description="primary server",
                    udp_flags=0x91,
                ),
                LiveEd2kServerEntry(
                    host="5.6.7.8",
                    port=4665,
                    name="beta",
                    description="backup",
                    obfuscation_port_tcp=4477,
                ),
            ]
        )
    )

    entries = parse_server_met(server_met)

    assert [entry.host for entry in entries] == ["1.2.3.4", "5.6.7.8"]
    assert entries[0].name == "alpha"
    assert entries[0].description == "primary server"
    assert entries[0].udp_flags == 0x91
    assert entries[1].name == "beta"
    assert entries[1].description == "backup"
    assert entries[1].obfuscation_port_tcp == 4477


def test_select_live_server_entries_applies_manifest_budget() -> None:
    entries = [
        LiveEd2kServerEntry(host="1.1.1.1", port=4661),
        LiveEd2kServerEntry(host="2.2.2.2", port=4662),
        LiveEd2kServerEntry(host="3.3.3.3", port=4663),
    ]

    selected = select_live_server_entries(entries, max_candidates=2)

    assert selected == entries[:2]


def test_resolve_live_server_entries_reads_seed_bundle_and_limits_candidates(
    tmp_path: Path,
) -> None:
    tooling_root = tmp_path / "tooling"
    seed_root = tooling_root / ".local" / "emule-harness-seeds" / "canonical"
    seed_root.mkdir(parents=True, exist_ok=True)
    (seed_root / "nodes.dat").write_bytes(b"nodes")
    (seed_root / "server.met").write_bytes(
        _encode_server_met(
            [
                LiveEd2kServerEntry(host="11.0.0.1", port=4661, name="alpha"),
                LiveEd2kServerEntry(host="11.0.0.2", port=4662, name="beta"),
            ]
        )
    )
    (seed_root / "seed-bundle.json").write_text(
        '{\n  "schemaVersion": "emule-harness-seed-bundle/v1",\n  "bundleId": "canonical"\n}\n',
        encoding="utf-8",
        newline="\n",
    )
    paths = WorkspacePaths(
        project_root=tmp_path,
        tooling_root=tooling_root,
        agents_root=tmp_path / "agents",
        be_root=tmp_path / "be",
        tmp_dir=tmp_path / "tmp",
        log_dir=tmp_path / "logs",
        emule_workspace_root=None,
    )

    seed_bundle = resolve_emule_harness_seed_bundle(paths, bundle_id="canonical")
    entries = resolve_live_server_entries(
        seed_bundle,
        {"serverSelection": {"maxCandidates": 1}},
    )

    assert entries == [LiveEd2kServerEntry(host="11.0.0.1", port=4661, name="alpha")]


def test_resolve_live_server_entries_rejects_non_positive_manifest_budget(
    tmp_path: Path,
) -> None:
    tooling_root = tmp_path / "tooling"
    seed_root = tooling_root / ".local" / "emule-harness-seeds" / "canonical"
    seed_root.mkdir(parents=True, exist_ok=True)
    (seed_root / "nodes.dat").write_bytes(b"nodes")
    (seed_root / "server.met").write_bytes(_encode_server_met([LiveEd2kServerEntry(host="11.0.0.1", port=4661)]))
    (seed_root / "seed-bundle.json").write_text(
        '{\n  "schemaVersion": "emule-harness-seed-bundle/v1",\n  "bundleId": "canonical"\n}\n',
        encoding="utf-8",
        newline="\n",
    )
    paths = WorkspacePaths(
        project_root=tmp_path,
        tooling_root=tooling_root,
        agents_root=tmp_path / "agents",
        be_root=tmp_path / "be",
        tmp_dir=tmp_path / "tmp",
        log_dir=tmp_path / "logs",
        emule_workspace_root=None,
    )

    seed_bundle = resolve_emule_harness_seed_bundle(paths, bundle_id="canonical")
    with pytest.raises(ValueError, match="maxCandidates"):
        resolve_live_server_entries(seed_bundle, {"serverSelection": {"maxCandidates": 0}})


def _encode_server_met(entries: list[LiveEd2kServerEntry]) -> bytes:
    payload = bytearray()
    payload.append(0xE0)
    payload.extend(struct.pack("<I", len(entries)))
    for entry in entries:
        payload.extend(ipaddress.IPv4Address(entry.host).packed)
        payload.extend(struct.pack("<H", entry.port))
        tags = _encode_tags(entry)
        payload.extend(struct.pack("<I", len(tags)))
        for tag in tags:
            payload.extend(tag)
    return bytes(payload)


def _encode_tags(entry: LiveEd2kServerEntry) -> list[bytes]:
    tags: list[bytes] = []
    if entry.name is not None:
        tags.append(_short_string_tag(0x01, entry.name))
    if entry.description is not None:
        tags.append(_short_string_tag(0x0B, entry.description))
    if entry.udp_flags:
        tags.append(_short_uint32_tag(0x92, entry.udp_flags))
    if entry.udp_key:
        tags.append(_short_uint32_tag(0x95, entry.udp_key))
    if entry.udp_key_ip:
        tags.append(_short_uint32_tag(0x96, entry.udp_key_ip))
    if entry.obfuscation_port_tcp:
        tags.append(_short_uint16_tag(0x97, entry.obfuscation_port_tcp))
    if entry.obfuscation_port_udp:
        tags.append(_short_uint16_tag(0x98, entry.obfuscation_port_udp))
    return tags


def _short_string_tag(tag_id: int, value: str) -> bytes:
    encoded = value.encode("utf-8")
    return bytes([0x82, tag_id]) + struct.pack("<H", len(encoded)) + encoded


def _short_uint32_tag(tag_id: int, value: int) -> bytes:
    return bytes([0x83, tag_id]) + struct.pack("<I", value)


def _short_uint16_tag(tag_id: int, value: int) -> bytes:
    return bytes([0x88, tag_id]) + struct.pack("<H", value)
