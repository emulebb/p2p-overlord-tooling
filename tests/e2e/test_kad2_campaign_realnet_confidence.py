from __future__ import annotations

import pytest

from tests.e2e.lib.kad_live import run_live_kad_search_download_to_agent_scenario
from tests.e2e.lib.kad_startup_live import run_live_kad_startup_publish_scenario
from tests.e2e.lib.manifests import load_manifest
from tests.e2e.lib.paths import WorkspacePaths


SCENARIO_ID = "kad2.campaign.realnet-confidence.v1"


@pytest.mark.e2e
@pytest.mark.live
@pytest.mark.requires_vpn
@pytest.mark.kad
@pytest.mark.campaign
@pytest.mark.slow
def test_live_kad2_realnet_confidence_campaign(
    workspace_paths: WorkspacePaths,
    pytestconfig: pytest.Config,
) -> None:
    manifest = load_manifest(workspace_paths, SCENARIO_ID)

    assert manifest["scenarioKind"] == "campaign"
    assert manifest["campaign"]["availability"] == "available"
    assert manifest["campaign"]["members"] == [
        {
            "scenarioId": "kad2.cell.startup.hello.publish.realnet.v1",
            "required": True,
        },
        {
            "scenarioId": "kad2.cell.keyword.search.plaintext.realnet.v1",
            "required": True,
        },
        {
            "scenarioId": "kad2.cell.keyword.search.obfuscated.realnet.v1",
            "required": True,
        },
    ]

    startup_cell = load_manifest(
        workspace_paths,
        "kad2.cell.startup.hello.publish.realnet.v1",
    )
    run_live_kad_startup_publish_scenario(
        workspace_paths,
        pytestconfig,
        scenario_id=f"{SCENARIO_ID}.startup-publish",
        manifest=load_manifest(
            workspace_paths,
            str(startup_cell["execution"]["summarySourceScenarioId"]),
        ),
    )

    plaintext_cell = load_manifest(
        workspace_paths,
        "kad2.cell.keyword.search.plaintext.realnet.v1",
    )
    run_live_kad_search_download_to_agent_scenario(
        workspace_paths,
        pytestconfig,
        scenario_id=f"{SCENARIO_ID}.keyword-search-plaintext",
        manifest=load_manifest(
            workspace_paths,
            str(plaintext_cell["execution"]["summarySourceScenarioId"]),
        ),
        transport_mode="plaintext",
    )

    obfuscated_cell = load_manifest(
        workspace_paths,
        "kad2.cell.keyword.search.obfuscated.realnet.v1",
    )
    run_live_kad_search_download_to_agent_scenario(
        workspace_paths,
        pytestconfig,
        scenario_id=f"{SCENARIO_ID}.keyword-search-obfuscated",
        manifest=load_manifest(
            workspace_paths,
            str(obfuscated_cell["execution"]["summarySourceScenarioId"]),
        ),
        transport_mode="obfuscated",
    )
