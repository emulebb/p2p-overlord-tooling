from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any


@dataclass(frozen=True)
class CampaignMember:
    scenario_id: str
    required: bool


@dataclass(frozen=True)
class ScenarioRecord:
    scenario_id: str
    manifest: dict[str, Any]
    manifest_path: Path

    @property
    def scenario_kind(self) -> str:
        return str(self.manifest.get("scenarioKind") or "")

    @property
    def protocol(self) -> str:
        return str(self.manifest.get("protocol") or "")

    @property
    def tier(self) -> str:
        return str(self.manifest.get("tier") or "")

    @property
    def availability(self) -> str | None:
        return manifest_availability(self.manifest)

    @property
    def parity(self) -> dict[str, Any]:
        value = self.manifest.get("parity")
        return value if isinstance(value, dict) else {}

    @property
    def campaign(self) -> dict[str, Any]:
        value = self.manifest.get("campaign")
        return value if isinstance(value, dict) else {}

    @property
    def execution(self) -> dict[str, Any]:
        value = self.manifest.get("execution")
        return value if isinstance(value, dict) else {}

    @property
    def command(self) -> str | None:
        value = self.execution.get("command")
        return str(value) if value else None

    @property
    def summary_source_scenario_id(self) -> str | None:
        value = self.execution.get("summarySourceScenarioId")
        return str(value) if value else None

    @property
    def members(self) -> list[CampaignMember]:
        members = self.campaign.get("members")
        if not isinstance(members, list):
            return []
        result: list[CampaignMember] = []
        for member in members:
            if not isinstance(member, dict):
                continue
            result.append(
                CampaignMember(
                    scenario_id=str(member["scenarioId"]),
                    required=bool(member.get("required", False)),
                )
            )
        return result

    @property
    def transport_mode(self) -> str | None:
        scenario_id = self.scenario_id.lower()
        if ".obfuscated." in scenario_id:
            return "obfuscated"
        if ".plaintext." in scenario_id:
            return "plaintext"
        return None


@dataclass(frozen=True)
class ScenarioCase:
    scenario_id: str
    scenario_kind: str
    protocol: str
    tier: str
    transport_mode: str | None
    marker_names: tuple[str, ...]

    @property
    def pytest_id(self) -> str:
        return self.scenario_id


class ScenarioCatalog:
    def __init__(self, records: dict[str, ScenarioRecord]) -> None:
        self._records = records

    @classmethod
    def load(cls, tooling_root: Path) -> "ScenarioCatalog":
        records: dict[str, ScenarioRecord] = {}
        for scenario_dir in sorted((tooling_root / "scenarios").iterdir()):
            manifest_path = scenario_dir / "manifest.v1.json"
            if not manifest_path.is_file():
                continue
            manifest = _read_json(manifest_path)
            scenario_id = str(manifest.get("scenarioId") or "")
            if scenario_id != scenario_dir.name:
                raise ValueError(
                    f"manifest {manifest_path} has scenarioId={scenario_id!r}, "
                    f"expected {scenario_dir.name!r}"
                )
            if scenario_id in records:
                raise ValueError(f"duplicate scenarioId {scenario_id}")
            records[scenario_id] = ScenarioRecord(
                scenario_id=scenario_id,
                manifest=manifest,
                manifest_path=manifest_path,
            )
        return cls(records)

    @property
    def records(self) -> list[ScenarioRecord]:
        return [self._records[key] for key in sorted(self._records)]

    def get(self, scenario_id: str) -> ScenarioRecord:
        try:
            return self._records[scenario_id]
        except KeyError as exc:
            raise KeyError(f"unknown scenarioId {scenario_id}") from exc

    def validate(self) -> list[str]:
        errors: list[str] = []
        for record in self.records:
            if record.scenario_kind not in {"legacy", "cell", "campaign"}:
                errors.append(f"{record.scenario_id}: invalid scenarioKind {record.scenario_kind!r}")
            if not record.protocol:
                errors.append(f"{record.scenario_id}: missing protocol")
            if not record.tier:
                errors.append(f"{record.scenario_id}: missing tier")
            if record.scenario_kind == "campaign":
                if record.availability not in {"available", "planned"}:
                    errors.append(f"{record.scenario_id}: invalid campaign availability")
                for member in record.members:
                    if member.scenario_id not in self._records:
                        errors.append(f"{record.scenario_id}: unknown member {member.scenario_id}")
            if record.scenario_kind == "cell":
                if not record.parity:
                    errors.append(f"{record.scenario_id}: missing parity object")
                elif record.availability not in {"available", "planned"}:
                    errors.append(f"{record.scenario_id}: invalid cell availability")
        return errors

    def filtered_records(
        self,
        *,
        scenario_kind: str | None = None,
        protocol: str | None = None,
        availability: str | None = None,
        tier: str | None = None,
    ) -> list[ScenarioRecord]:
        records: list[ScenarioRecord] = []
        for record in self.records:
            if scenario_kind is not None and record.scenario_kind != scenario_kind:
                continue
            if protocol is not None and record.protocol != protocol:
                continue
            if tier is not None and record.tier != tier:
                continue
            if availability is not None and record.availability != availability:
                continue
            records.append(record)
        return records

    def parity_matrix_rows(
        self,
        *,
        scenario_kind: str | None = None,
        protocol: str | None = None,
        availability: str | None = None,
        tier: str | None = None,
    ) -> list[dict[str, Any]]:
        rows: list[dict[str, Any]] = []
        for record in self.filtered_records(
            scenario_kind=scenario_kind,
            protocol=protocol,
            availability=availability,
            tier=tier,
        ):
            if record.scenario_kind not in {"cell", "campaign"}:
                continue
            rows.append(parity_matrix_row(record))
        return rows

    def runnable_cases(self, registered_commands: set[str]) -> list[ScenarioCase]:
        cases: list[ScenarioCase] = []
        for record in self.records:
            if record.scenario_kind == "cell" and self.is_runnable_cell(record, registered_commands):
                cases.append(self._case_for_record(record))
            elif record.scenario_kind == "campaign" and self.is_runnable_campaign(record, registered_commands):
                cases.append(self._case_for_record(record))
        return cases

    def is_runnable_cell(self, record: ScenarioRecord, registered_commands: set[str]) -> bool:
        return (
            record.scenario_kind == "cell"
            and record.availability == "available"
            and record.command in registered_commands
        )

    def is_runnable_campaign(self, record: ScenarioRecord, registered_commands: set[str]) -> bool:
        if record.scenario_kind != "campaign" or record.availability != "available":
            return False
        required_members = [member for member in record.members if member.required]
        if not required_members:
            return False
        return all(
            self.is_runnable_cell(self.get(member.scenario_id), registered_commands)
            for member in required_members
        )

    def native_command_gaps(self, registered_commands: set[str]) -> list[str]:
        gaps: list[str] = []
        for record in self.records:
            if record.scenario_kind != "cell" or record.availability != "available":
                continue
            if record.command and record.command not in registered_commands:
                gaps.append(record.scenario_id)
        return gaps

    def _case_for_record(self, record: ScenarioRecord) -> ScenarioCase:
        return ScenarioCase(
            scenario_id=record.scenario_id,
            scenario_kind=record.scenario_kind,
            protocol=record.protocol,
            tier=record.tier,
            transport_mode=record.transport_mode,
            marker_names=tuple(_marker_names(record, self)),
        )


def manifest_path(tooling_root: Path, scenario_id: str) -> Path:
    return tooling_root / "scenarios" / scenario_id / "manifest.v1.json"


def load_manifest(tooling_root: Path, scenario_id: str) -> dict[str, Any]:
    path = manifest_path(tooling_root, scenario_id)
    if not path.is_file():
        raise SystemExit(f"Scenario manifest not found at {path}")
    manifest = _read_json(path)
    if manifest.get("scenarioId") != scenario_id:
        raise ValueError(f"manifest {path} has scenarioId={manifest.get('scenarioId')!r}")
    return manifest


def iter_manifests(
    tooling_root: Path,
    *,
    protocol: str | None = None,
    tier: str | None = None,
    scenario_kind: str | None = None,
    availability: str | None = None,
) -> list[dict[str, Any]]:
    return [
        record.manifest
        for record in ScenarioCatalog.load(tooling_root).filtered_records(
            protocol=protocol,
            tier=tier,
            scenario_kind=scenario_kind,
            availability=availability,
        )
    ]


def load_manifest_inventory(
    tooling_root: Path,
    *,
    protocol: str | None = None,
    tier: str | None = None,
    scenario_kind: str | None = None,
    availability: str | None = None,
) -> list[dict[str, Any]]:
    return iter_manifests(
        tooling_root,
        protocol=protocol,
        tier=tier,
        scenario_kind=scenario_kind,
        availability=availability,
    )


def load_manifest_ids(
    tooling_root: Path,
    *,
    protocol: str | None = None,
    tier: str | None = None,
    scenario_kind: str | None = None,
    availability: str | None = None,
) -> list[str]:
    return [
        str(manifest["scenarioId"])
        for manifest in iter_manifests(
            tooling_root,
            protocol=protocol,
            tier=tier,
            scenario_kind=scenario_kind,
            availability=availability,
        )
    ]


def manifest_availability(manifest: dict[str, Any]) -> str | None:
    scenario_kind = manifest.get("scenarioKind")
    if scenario_kind == "campaign":
        campaign = manifest.get("campaign")
        if isinstance(campaign, dict):
            value = campaign.get("availability")
            return str(value) if value is not None else None

    parity = manifest.get("parity")
    if isinstance(parity, dict):
        value = parity.get("availability")
        return str(value) if value is not None else None

    return None


def parity_matrix_row(record: ScenarioRecord) -> dict[str, Any]:
    return {
        "scenarioId": record.scenario_id,
        "scenarioKind": record.scenario_kind,
        "protocol": record.protocol,
        "tier": record.tier,
        "matrixId": record.parity.get("matrixId"),
        "cellId": record.parity.get("cellId"),
        "availability": record.availability,
        "command": record.command,
        "summarySourceScenarioId": record.summary_source_scenario_id,
        "memberCount": len(record.members),
        "expectedBranch": record.parity.get("expectedBranch"),
        "comparisonMode": record.parity.get("comparisonMode"),
        "description": record.manifest.get("description"),
    }


def latest_run_summary(run_root: Path, scenario_id: str) -> Path | None:
    scenario_root = run_root / scenario_id
    if not scenario_root.is_dir():
        return None
    candidates = [path for path in scenario_root.rglob("run-summary.json") if path.is_file()]
    if not candidates:
        return None
    return max(candidates, key=lambda path: path.stat().st_mtime)


def latest_run_status(run_root: Path, scenario_id: str) -> dict[str, Any]:
    latest = latest_run_summary(run_root, scenario_id)
    status = {
        "latestRunId": None,
        "latestCompleted": None,
        "latestFailedReason": None,
        "latestRunSummaryPath": None,
    }
    if latest is None:
        return status
    summary = json.loads(latest.read_text(encoding="utf-8"))
    return {
        "latestRunId": summary.get("runId"),
        "latestCompleted": summary.get("completed"),
        "latestFailedReason": summary.get("failedReason"),
        "latestRunSummaryPath": str(latest),
    }


def parity_status_rows(rows: list[dict[str, Any]], run_root: Path) -> list[dict[str, Any]]:
    return [
        {
            **row,
            **latest_run_status(run_root, str(row["scenarioId"])),
        }
        for row in rows
    ]


def default_run_root() -> Path:
    tmp_dir = Path(os.environ.get("OVERLORD_TMP_DIR", Path(os.environ.get("TEMP", "/tmp")) / "p2p-overlord"))
    return tmp_dir / "overlord-tooling" / "runs"


def campaign_step_slug(member_id: str) -> str:
    member = member_id.lower()
    if "hello.senderkey.ack" in member:
        suffix = "hello-senderkey-ack"
    elif "bootstrap.lookup" in member:
        suffix = "bootstrap-lookup"
    elif "keyword.publish" in member:
        suffix = "keyword-publish"
    elif "source.publish" in member:
        suffix = "source-publish"
    elif "notes.publish" in member:
        suffix = "notes-publish"
    elif "keyword.search.triplet" in member:
        suffix = "keyword-search-private"
    elif "source.search" in member:
        suffix = "source-search"
    elif "notes.search" in member:
        suffix = "notes-search"
    elif "startup.hello.publish" in member:
        suffix = "startup-publish"
    elif "keyword.search.obfuscated" in member:
        suffix = "keyword-search-obfuscated"
    elif "keyword.search.plaintext" in member:
        suffix = "keyword-search-plaintext"
    elif "kad-private" in member:
        suffix = "kad-private"
    elif "listener" in member:
        suffix = "listener"
    elif "obfuscated" in member:
        suffix = "obfuscated"
    elif "callback" in member:
        suffix = "callback"
    elif "private" in member:
        suffix = "private-direct"
    elif "plaintext" in member:
        suffix = "plaintext"
    else:
        suffix = member_id.replace(".", "-")[:32]
    return suffix


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        json.dump(payload, handle, indent=2)
        handle.write("\n")


def _marker_names(record: ScenarioRecord, catalog: ScenarioCatalog) -> list[str]:
    markers = ["e2e", record.scenario_kind, "slow"]
    protocols = _protocol_markers(record, catalog)
    markers.extend(protocols)
    if record.tier == "realnet-confidence":
        markers.extend(["live", "requires_vpn"])
    else:
        markers.append("local")
    if record.transport_mode is not None:
        markers.append(record.transport_mode)
    if "listener" in record.scenario_id:
        markers.append("agent_to_harness")
    if "downloader" in record.scenario_id:
        markers.append("harness_to_agent")
    if "roundtrip" in record.scenario_id or "listener" in record.scenario_id:
        markers.append("roundtrip")
    return list(dict.fromkeys(markers))


def _protocol_markers(record: ScenarioRecord, catalog: ScenarioCatalog) -> list[str]:
    if record.protocol == "ed2k":
        return ["ed2k"]
    if record.protocol == "kad2":
        return ["kad"]
    if record.protocol == "mixed":
        return ["ed2k", "kad"]
    if record.scenario_kind == "campaign":
        protocols: list[str] = []
        for member in record.members:
            member_record = catalog.get(member.scenario_id)
            for marker in _protocol_markers(member_record, catalog):
                if marker not in protocols:
                    protocols.append(marker)
        return protocols
    return []


def _read_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"manifest {path} did not contain a JSON object")
    return value
