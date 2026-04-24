from __future__ import annotations

import pytest

from tests.e2e.lib.manifests import load_manifest
from tests.e2e.lib.paths import WorkspacePaths
from tests.e2e.test_ed2k_cell_callback import SCENARIO_ID as CALLBACK_CELL_SCENARIO_ID
from tests.e2e.test_ed2k_triplet_validation import (
    run_private_ed2k_server_triplet_callback_limit_scenario,
)


SCENARIO_ID = "ed2k.campaign.callback.v1"


@pytest.mark.e2e
@pytest.mark.local
@pytest.mark.ed2k
@pytest.mark.campaign
@pytest.mark.slow
def test_private_ed2k_callback_campaign(
    workspace_paths: WorkspacePaths,
    pytestconfig: pytest.Config,
) -> None:
    manifest = load_manifest(workspace_paths, SCENARIO_ID)

    assert manifest["scenarioKind"] == "campaign"
    assert manifest["campaign"]["availability"] == "available"
    assert manifest["campaign"]["members"] == [
        {
            "scenarioId": CALLBACK_CELL_SCENARIO_ID,
            "required": True,
        }
    ]

    run_private_ed2k_server_triplet_callback_limit_scenario(
        workspace_paths,
        pytestconfig,
        scenario_id=SCENARIO_ID,
    )
