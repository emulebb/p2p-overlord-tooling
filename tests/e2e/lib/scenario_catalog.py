from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any

from tests.e2e.lib.manifests import manifest_availability
from tests.e2e.lib.paths import WorkspacePaths


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
        campaign = self.manifest.get("campaign")
        if not isinstance(campaign, dict):
            return []
        members = campaign.get("members")
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
    def load(cls, paths: WorkspacePaths) -> "ScenarioCatalog":
        records: dict[str, ScenarioRecord] = {}
        for scenario_dir in sorted((paths.tooling_root / "scenarios").iterdir()):
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
                parity = record.manifest.get("parity")
                if not isinstance(parity, dict):
                    errors.append(f"{record.scenario_id}: missing parity object")
                elif record.availability not in {"available", "planned"}:
                    errors.append(f"{record.scenario_id}: invalid cell availability")
        return errors

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


def campaign_step_slug(member_id: str) -> str:
    member = member_id.lower()
    if "startup.hello.publish" in member:
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
    import json

    with path.open("r", encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"manifest {path} did not contain a JSON object")
    return value
