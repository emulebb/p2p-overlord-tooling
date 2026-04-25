from __future__ import annotations

import pytest

from tests.e2e.lib.paths import WorkspacePaths
from overlord_tooling.scenarios import (
    ScenarioCase,
    ScenarioCatalog,
    ScenarioRecord,
    campaign_step_slug,
)
from tests.e2e.lib.scenario_registry import (
    ScenarioContext,
    execute_registered_command,
    registered_command_names,
)


def execute_scenario_case(
    case: ScenarioCase,
    *,
    workspace_paths: WorkspacePaths,
    pytestconfig: pytest.Config,
) -> None:
    catalog = ScenarioCatalog.load(workspace_paths.tooling_root)
    selected_transport = str(pytestconfig.getoption("--transport"))
    if (
        case.transport_mode is not None
        and selected_transport != "both"
        and selected_transport != case.transport_mode
    ):
        pytest.skip(f"scenario transport is {case.transport_mode}, selected --transport={selected_transport}")

    record = catalog.get(case.scenario_id)
    if record.scenario_kind == "cell":
        _execute_cell(
            catalog,
            record,
            workspace_paths=workspace_paths,
            pytestconfig=pytestconfig,
        )
        return

    if record.scenario_kind == "campaign":
        for member in record.members:
            if not member.required:
                continue
            member_record = catalog.get(member.scenario_id)
            _execute_cell(
                catalog,
                member_record,
                workspace_paths=workspace_paths,
                pytestconfig=pytestconfig,
                artifact_scenario_id=record.scenario_id,
                run_slug=campaign_step_slug(member_record.scenario_id),
                metadata={
                    "campaignId": record.scenario_id,
                    "campaignStepId": campaign_step_slug(member_record.scenario_id),
                    "memberScenarioId": member_record.scenario_id,
                },
            )
        return

    raise ValueError(f"{record.scenario_id}: unsupported scenarioKind {record.scenario_kind!r}")


def collect_scenario_cases(paths: WorkspacePaths) -> list[ScenarioCase]:
    catalog = ScenarioCatalog.load(paths.tooling_root)
    return catalog.runnable_cases(registered_command_names())


def _execute_cell(
    catalog: ScenarioCatalog,
    record: ScenarioRecord,
    *,
    workspace_paths: WorkspacePaths,
    pytestconfig: pytest.Config,
    artifact_scenario_id: str | None = None,
    run_slug: str | None = None,
    metadata: dict[str, object] | None = None,
) -> None:
    if not catalog.is_runnable_cell(record, registered_command_names()):
        raise ValueError(f"{record.scenario_id}: cell is not runnable")
    source_scenario_id = record.summary_source_scenario_id
    source_manifest = catalog.get(source_scenario_id).manifest if source_scenario_id else None
    command = record.command
    if command is None:
        raise ValueError(f"{record.scenario_id}: missing execution command")
    execute_registered_command(
        command,
        ScenarioContext(
            workspace_paths=workspace_paths,
            pytestconfig=pytestconfig,
            scenario_id=record.scenario_id,
            run_scenario_id=record.scenario_id,
            manifest=record.manifest,
            source_manifest=source_manifest,
            source_scenario_id=source_scenario_id,
            transport_mode=record.transport_mode,
            artifact_scenario_id=artifact_scenario_id,
            run_slug=run_slug,
            metadata=metadata,
        ),
    )
