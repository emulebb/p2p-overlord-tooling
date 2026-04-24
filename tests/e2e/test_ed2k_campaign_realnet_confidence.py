from __future__ import annotations

import pytest

from tests.e2e.lib.ed2k_live import run_live_ed2k_server_roundtrip_scenario
from tests.e2e.lib.kad_live import run_live_kad_search_download_to_agent_scenario
from tests.e2e.lib.manifests import load_manifest
from tests.e2e.lib.paths import WorkspacePaths


SCENARIO_ID = "ed2k.campaign.realnet-confidence.v1"


@pytest.mark.e2e
@pytest.mark.live
@pytest.mark.requires_vpn
@pytest.mark.ed2k
@pytest.mark.campaign
@pytest.mark.slow
def test_live_ed2k_realnet_confidence_campaign(
    workspace_paths: WorkspacePaths,
    pytestconfig: pytest.Config,
) -> None:
    manifest = load_manifest(workspace_paths, SCENARIO_ID)

    assert manifest["scenarioKind"] == "campaign"
    assert manifest["campaign"]["availability"] == "available"
    assert manifest["campaign"]["members"] == [
        {
            "scenarioId": "ed2k.cell.downloader.plaintext.direct.serving.fresh.realnet.v1",
            "required": True,
        },
        {
            "scenarioId": "ed2k.cell.downloader.obfuscated.direct.serving.fresh.realnet.v1",
            "required": True,
        },
        {
            "scenarioId": "ed2k.cell.listener.plaintext.inbound.serving.fresh.realnet.v1",
            "required": True,
        },
    ]

    plaintext_cell = load_manifest(
        workspace_paths,
        "ed2k.cell.downloader.plaintext.direct.serving.fresh.realnet.v1",
    )
    run_live_kad_search_download_to_agent_scenario(
        workspace_paths,
        pytestconfig,
        scenario_id=f"{SCENARIO_ID}.downloader-plaintext",
        manifest=load_manifest(
            workspace_paths,
            str(plaintext_cell["execution"]["summarySourceScenarioId"]),
        ),
        transport_mode="plaintext",
    )

    obfuscated_cell = load_manifest(
        workspace_paths,
        "ed2k.cell.downloader.obfuscated.direct.serving.fresh.realnet.v1",
    )
    run_live_kad_search_download_to_agent_scenario(
        workspace_paths,
        pytestconfig,
        scenario_id=f"{SCENARIO_ID}.downloader-obfuscated",
        manifest=load_manifest(
            workspace_paths,
            str(obfuscated_cell["execution"]["summarySourceScenarioId"]),
        ),
        transport_mode="obfuscated",
    )

    listener_cell = load_manifest(
        workspace_paths,
        "ed2k.cell.listener.plaintext.inbound.serving.fresh.realnet.v1",
    )
    run_live_ed2k_server_roundtrip_scenario(
        workspace_paths,
        pytestconfig,
        scenario_id=f"{SCENARIO_ID}.listener",
        manifest=load_manifest(
            workspace_paths,
            str(listener_cell["execution"]["summarySourceScenarioId"]),
        ),
    )
