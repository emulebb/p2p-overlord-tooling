#!/usr/bin/env python3
"""
Compare oracle and agent UDP JSONL dumps by actual wire mode and opcode.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path


SUMMARY_RE = re.compile(r"(?P<key>[A-Za-z0-9_]+)=(?P<value>\S+)")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Compare oracle and agent UDP JSONL packet dumps."
    )
    parser.add_argument("--oracle", required=True, help="Path to the oracle JSONL dump")
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
    transport_mode = record.get("transport_mode") or summary.get("transport_mode")
    if not transport_mode:
        raw_obfuscated = record.get("raw_obfuscated")
        if raw_obfuscated is None:
            raw_obfuscated = summary.get("raw_obfuscated")
        receiver_valid = record.get("receiver_verify_key_valid")
        if receiver_valid is None:
            receiver_valid = summary.get("receiver_verify_key_valid")
        raw_obfuscated = as_bool(raw_obfuscated)
        receiver_valid = as_bool(receiver_valid)
        if not raw_obfuscated:
            transport_mode = "plaintext"
        elif receiver_valid:
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


def render_parity(oracle_buckets: dict, agent_buckets: dict) -> list[str]:
    lines = ["parity matrix:"]
    all_keys = sorted(set(oracle_buckets) | set(agent_buckets))
    if not all_keys:
        lines.append("  <none>")
        return lines
    for key in all_keys:
        oracle_count = oracle_buckets.get(key, Counter()).get("count", 0)
        agent_count = agent_buckets.get(key, Counter()).get("count", 0)
        lines.append(
            f"  direction={key[0]} mode={key[1]} opcode={key[2]} oracle={oracle_count} agent={agent_count}"
        )
    return lines


def main() -> int:
    args = parse_args()
    keep_opcodes = set(args.opcodes)
    oracle_records = load_records(Path(args.oracle), "oracle")
    agent_records = load_records(Path(args.agent), "agent")

    oracle_buckets = bucket_records(oracle_records, keep_opcodes)
    agent_buckets = bucket_records(agent_records, keep_opcodes)

    for line in render_side("oracle", oracle_buckets):
        print(line)
    for line in render_side("agent", agent_buckets):
        print(line)
    for line in render_parity(oracle_buckets, agent_buckets):
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
