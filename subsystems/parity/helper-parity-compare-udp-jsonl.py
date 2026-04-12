#!/usr/bin/env python3
"""
Compare eMule harness and agent UDP JSONL dumps by actual wire mode and opcode.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path


SUMMARY_RE = re.compile(r"(?P<key>[A-Za-z0-9_]+)=(?P<value>\S+)")

OPCODE_NAME_BY_HEX = {
    "0x01": "KADEMLIA2_BOOTSTRAP_REQ",
    "0x09": "KADEMLIA2_BOOTSTRAP_RES",
    "0x11": "KADEMLIA2_HELLO_REQ",
    "0x19": "KADEMLIA2_HELLO_RES",
    "0x20": "KADEMLIA2_HELLO_RES_ACK",
    "0x21": "KADEMLIA2_REQ",
    "0x29": "KADEMLIA2_RES",
    "0x33": "KADEMLIA2_SEARCH_KEY_REQ",
    "0x34": "KADEMLIA2_SEARCH_SOURCE_REQ",
    "0x35": "KADEMLIA2_SEARCH_NOTES_REQ",
    "0x3B": "KADEMLIA2_SEARCH_RES",
    "0x43": "KADEMLIA2_PUBLISH_KEY_REQ",
    "0x44": "KADEMLIA2_PUBLISH_SOURCE_REQ",
    "0x45": "KADEMLIA2_PUBLISH_NOTES_REQ",
    "0x4B": "KADEMLIA2_PUBLISH_RES",
    "0x4C": "KADEMLIA2_PUBLISH_RES_ACK",
    "0x50": "KADEMLIA_FIREWALLED_REQ",
    "0x53": "KADEMLIA2_FIREWALLED2_REQ",
    "0x58": "KADEMLIA2_FIREWALLED_RES",
    "0x59": "KADEMLIA2_FIREWALLED_ACK_RES",
    "0x60": "KADEMLIA2_FIREWALLUDP",
    "0x61": "KADEMLIA2_FIREWALLUDP",
    "0x62": "KADEMLIA_FINDBUDDY_REQ",
    "0x63": "KADEMLIA_FINDBUDDY_RES",
    "0x64": "KADEMLIA_CALLBACK_REQ",
    "0x65": "KADEMLIA2_PING",
    "0x66": "KADEMLIA2_PONG",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Compare eMule harness and agent UDP JSONL packet dumps."
    )
    parser.add_argument("--emule-harness", required=True, help="Path to the eMule harness JSONL dump")
    parser.add_argument("--agent", required=True, help="Path to the agent JSONL dump")
    parser.add_argument(
        "--opcodes",
        nargs="*",
        default=[],
        help="Optional opcode names to keep, for example KADEMLIA2_HELLO_REQ",
    )
    return parser.parse_args()


def parse_summary(summary: str) -> dict[str, str]:
    return {match.group("key"): match.group("value") for match in SUMMARY_RE.finditer(summary)}


def normalize_record(source: str, record: dict) -> dict:
    summary = parse_summary(record.get("summary", ""))
    opcode_name = record.get("opcode_name") or summary.get("opcode_name")
    opcode = record.get("opcode") or summary.get("opcode")
    if opcode_name is None and opcode:
        opcode_name = OPCODE_NAME_BY_HEX.get(normalize_hex_key(opcode), "UNKNOWN")
    transport_mode = record.get("transport_mode") or summary.get("transport_mode")
    if not transport_mode:
        raw_obfuscated = record.get("raw_obfuscated")
        if raw_obfuscated is None:
            raw_obfuscated = summary.get("raw_obfuscated")
        receiver_valid = record.get("receiver_verify_key_valid")
        if receiver_valid is None:
            receiver_valid = summary.get("receiver_verify_key_valid")
        receiver_verify_key = record.get("receiver_verify_key")
        if receiver_verify_key is None:
            receiver_verify_key = summary.get("receiver_verify_key")
        raw_obfuscated = as_bool(raw_obfuscated)
        receiver_valid = as_bool(receiver_valid)
        receiver_verify_key = as_int(receiver_verify_key)
        if not raw_obfuscated:
            transport_mode = "plaintext"
        elif source == "emuleHarness":
            transport_mode = infer_emule_harness_transport_mode(record.get("wire_hex", ""))
        elif receiver_valid or (receiver_verify_key is not None and receiver_verify_key > 0):
            transport_mode = "receiver_verify_key"
        else:
            transport_mode = "node_id"
    return {
        "source": source,
        "direction": record.get("direction"),
        "family": record.get("family"),
        "opcode_name": opcode_name or "UNKNOWN",
        "opcode": opcode or "UNKNOWN",
        "transport_mode": transport_mode,
        "wire_len": record.get("wire_len", 0),
        "peer": record.get("peer", "-"),
    }


def as_bool(value) -> bool | None:
    if value is None:
        return None
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        lowered = value.lower()
        if lowered in {"yes", "true", "1"}:
            return True
        if lowered in {"no", "false", "0"}:
            return False
    return None


def as_int(value) -> int | None:
    if value is None:
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        try:
            return int(value, 0)
        except ValueError:
            return None
    return None


def normalize_hex_key(value: str) -> str:
    value = value.strip()
    if value.lower().startswith("0x"):
        return "0x" + value[2:].upper()
    return value.upper()


def infer_emule_harness_transport_mode(wire_hex: str) -> str:
    if len(wire_hex) < 2:
        return "node_id"
    first_byte = int(wire_hex[:2], 16)
    if first_byte in {0xE3, 0xE4, 0xE5, 0xA3, 0xC5, 0xD4}:
        return "plaintext"
    if (first_byte & 0x03) == 0x02:
        return "receiver_verify_key"
    return "node_id"


def load_records(path: Path, source: str) -> list[dict]:
    records: list[dict] = []
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            records.append(normalize_record(source, json.loads(line)))
    return records


def bucket_records(records: list[dict], keep_opcodes: set[str]) -> dict[tuple[str, str, str], Counter]:
    buckets: dict[tuple[str, str, str], Counter] = defaultdict(Counter)
    for record in records:
        if keep_opcodes and record["opcode_name"] not in keep_opcodes:
            continue
        key = (
            record["direction"] or "-",
            record["transport_mode"] or "-",
            record["opcode_name"] or "UNKNOWN",
        )
        buckets[key]["count"] += 1
        buckets[key]["wire_len_sum"] += int(record["wire_len"] or 0)
    return buckets


def render_side(name: str, buckets: dict[tuple[str, str, str], Counter]) -> list[str]:
    lines = [f"{name} buckets:"]
    if not buckets:
        lines.append("  <none>")
        return lines
    for key in sorted(buckets):
        counter = buckets[key]
        avg_len = counter["wire_len_sum"] / max(counter["count"], 1)
        lines.append(
            f"  direction={key[0]} mode={key[1]} opcode={key[2]} count={counter['count']} avg_wire_len={avg_len:.1f}"
        )
    return lines


def render_parity(emule_harness_buckets: dict, agent_buckets: dict) -> list[str]:
    lines = ["parity matrix:"]
    all_keys = sorted(set(emule_harness_buckets) | set(agent_buckets))
    if not all_keys:
        lines.append("  <none>")
        return lines
    for key in all_keys:
        emule_harness_count = emule_harness_buckets.get(key, Counter()).get("count", 0)
        agent_count = agent_buckets.get(key, Counter()).get("count", 0)
        lines.append(
            f"  direction={key[0]} mode={key[1]} opcode={key[2]} emule_harness={emule_harness_count} agent={agent_count}"
        )
    return lines


def main() -> int:
    args = parse_args()
    keep_opcodes = set(args.opcodes)
    emule_harness_records = load_records(Path(args.emule_harness), "emuleHarness")
    agent_records = load_records(Path(args.agent), "agent")

    emule_harness_buckets = bucket_records(emule_harness_records, keep_opcodes)
    agent_buckets = bucket_records(agent_records, keep_opcodes)

    for line in render_side("emuleHarness", emule_harness_buckets):
        print(line)
    for line in render_side("agent", agent_buckets):
        print(line)
    for line in render_parity(emule_harness_buckets, agent_buckets):
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
