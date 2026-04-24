from __future__ import annotations

from tests.e2e.lib.manifests import load_manifest
from tests.e2e.lib.paths import WorkspacePaths


def test_kad2_realnet_confidence_campaign_members_pin_live_cells(
    workspace_paths: WorkspacePaths,
) -> None:
    manifest = load_manifest(workspace_paths, "kad2.campaign.realnet-confidence.v1")

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
