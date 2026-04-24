from __future__ import annotations

import pytest

from tests.e2e.lib.kad_startup_live import run_live_kad_startup_publish_scenario
from tests.e2e.lib.manifests import load_manifest
from tests.e2e.lib.paths import WorkspacePaths


SCENARIO_ID = "kad2.cell.startup.hello.publish.realnet.v1"


@pytest.mark.e2e
@pytest.mark.live
@pytest.mark.requires_vpn
@pytest.mark.kad
@pytest.mark.cell
@pytest.mark.slow
def test_live_kad2_cell_startup_publish_realnet(
    workspace_paths: WorkspacePaths,
    pytestconfig: pytest.Config,
) -> None:
    manifest = load_manifest(workspace_paths, SCENARIO_ID)

    assert manifest["scenarioKind"] == "cell"
    assert manifest["protocol"] == "kad2"

    source_manifest = load_manifest(
        workspace_paths,
        str(manifest["execution"]["summarySourceScenarioId"]),
    )
    run_live_kad_startup_publish_scenario(
        workspace_paths,
        pytestconfig,
        scenario_id=SCENARIO_ID,
        manifest=source_manifest,
    )
