from __future__ import annotations

import pytest

from tests.e2e.lib.ed2k_live import run_live_ed2k_server_roundtrip_scenario
from tests.e2e.lib.manifests import load_manifest
from tests.e2e.lib.paths import WorkspacePaths


SCENARIO_ID = "ed2k.campaign.listener-serving.v1"


@pytest.mark.e2e
@pytest.mark.live
@pytest.mark.requires_vpn
@pytest.mark.ed2k
@pytest.mark.campaign
@pytest.mark.roundtrip
@pytest.mark.agent_to_harness
@pytest.mark.slow
def test_live_ed2k_listener_serving_campaign(
    workspace_paths: WorkspacePaths,
    pytestconfig: pytest.Config,
) -> None:
    manifest = load_manifest(workspace_paths, SCENARIO_ID)

    assert manifest["scenarioKind"] == "campaign"
    assert manifest["campaign"]["availability"] == "available"
    assert manifest["campaign"]["members"] == [
        {
            "scenarioId": "ed2k.cell.listener.plaintext.inbound.serving.fresh.realnet.v1",
            "required": True,
        }
    ]

    cell_manifest = load_manifest(
        workspace_paths,
        str(manifest["campaign"]["members"][0]["scenarioId"]),
    )
    source_manifest = load_manifest(
        workspace_paths,
        str(cell_manifest["execution"]["summarySourceScenarioId"]),
    )
    run_live_ed2k_server_roundtrip_scenario(
        workspace_paths,
        pytestconfig,
        scenario_id=SCENARIO_ID,
        manifest=source_manifest,
    )
