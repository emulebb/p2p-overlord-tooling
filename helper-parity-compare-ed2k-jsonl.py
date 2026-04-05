#!/usr/bin/env python3
"""
Compare oracle and agent ED2K JSONL dumps by flow, transport mode, state IDs,
and per-trace state-machine sequences.
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter, defaultdict
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Compare oracle and agent ED2K JSONL packet dumps."
    )
    parser.add_argument("--oracle", required=True, help="Path to the oracle JSONL dump")
    parser.add_argument("--agent", required=True, help="Path to the agent JSONL dump")
    parser.add_argument(
        "--flow",
        action="append",
        default=[],
        help="Optional flow filter, for example listener or native_download",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=8,
        help="Maximum number of unique trace sequences to print per side",
    )
    return parser.parse_args()


def load_records(path: Path, source: str, keep_flows: set[str]) -> list[dict]:
    records: list[dict] = []
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            record = json.loads(line)
            flow = record.get("flow") or "unknown"
            if keep_flows and flow not in keep_flows:
                continue
            record["source"] = record.get("source") or source
            record["flow"] = flow
            record["transport_mode"] = record.get("transport_mode") or "unknown"
            record["trace_key"] = record.get("trace_key") or f"{flow}:{record.get('remote_addr', '-')}"
            record["state_id"] = record.get("state_id") or f"{flow}.{record.get('phase', 'session')}"
            record["state_label"] = record.get("state_label") or record.get("phase") or "session"
            record["event_seq"] = int(record.get("event_seq") or 0)
            records.append(record)
    records.sort(key=lambda item: (item["trace_key"], item["event_seq"]))
    return records


def bucket_states(records: list[dict]) -> dict[tuple[str, str, str], Counter]:
    buckets: dict[tuple[str, str, str], Counter] = defaultdict(Counter)
    for record in records:
        key = (
            record.get("flow", "unknown"),
            record.get("transport_mode", "unknown"),
            record.get("state_id", "unknown"),
        )
        buckets[key]["count"] += 1
    return buckets


def build_trace_sequences(records: list[dict]) -> Counter:
    traces: dict[str, list[str]] = defaultdict(list)
    for record in records:
        traces[record["trace_key"]].append(record["state_id"])
    sequence_counter: Counter = Counter()
    for states in traces.values():
        sequence_counter[" -> ".join(states)] += 1
    return sequence_counter


def render_state_buckets(name: str, buckets: dict[tuple[str, str, str], Counter]) -> list[str]:
    lines = [f"{name} state buckets:"]
    if not buckets:
        lines.append("  <none>")
        return lines
    for key in sorted(buckets):
        lines.append(
            f"  flow={key[0]} mode={key[1]} state={key[2]} count={buckets[key]['count']}"
        )
    return lines


def render_sequence_summary(name: str, sequences: Counter, limit: int) -> list[str]:
    lines = [f"{name} trace sequences:"]
    if not sequences:
        lines.append("  <none>")
        return lines
    for sequence, count in sequences.most_common(limit):
        lines.append(f"  count={count} sequence={sequence}")
    return lines


def render_parity(oracle_buckets: dict, agent_buckets: dict) -> list[str]:
    lines = ["state parity matrix:"]
    all_keys = sorted(set(oracle_buckets) | set(agent_buckets))
    if not all_keys:
        lines.append("  <none>")
        return lines
    for key in all_keys:
        oracle_count = oracle_buckets.get(key, Counter()).get("count", 0)
        agent_count = agent_buckets.get(key, Counter()).get("count", 0)
        lines.append(
            f"  flow={key[0]} mode={key[1]} state={key[2]} oracle={oracle_count} agent={agent_count}"
        )
    return lines


def main() -> int:
    args = parse_args()
    keep_flows = set(args.flow)
    oracle_records = load_records(Path(args.oracle), "oracle", keep_flows)
    agent_records = load_records(Path(args.agent), "agent", keep_flows)

    oracle_buckets = bucket_states(oracle_records)
    agent_buckets = bucket_states(agent_records)
    oracle_sequences = build_trace_sequences(oracle_records)
    agent_sequences = build_trace_sequences(agent_records)

    for line in render_state_buckets("oracle", oracle_buckets):
        print(line)
    for line in render_state_buckets("agent", agent_buckets):
        print(line)
    for line in render_parity(oracle_buckets, agent_buckets):
        print(line)
    for line in render_sequence_summary("oracle", oracle_sequences, args.limit):
        print(line)
    for line in render_sequence_summary("agent", agent_sequences, args.limit):
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
