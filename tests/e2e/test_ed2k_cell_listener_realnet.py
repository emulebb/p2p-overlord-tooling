from __future__ import annotations

import pytest

from tests.e2e.lib.ed2k_live import run_live_ed2k_server_roundtrip_scenario
from tests.e2e.lib.manifests import load_manifest
from tests.e2e.lib.paths import WorkspacePaths


SCENARIO_ID = "ed2k.cell.listener.plaintext.inbound.serving.fresh.realnet.v1"


@pytest.mark.e2e
@pytest.mark.live
@pytest.mark.requires_vpn
@pytest.mark.ed2k
@pytest.mark.cell
@pytest.mark.roundtrip
@pytest.mark.agent_to_harness
@pytest.mark.slow
def test_live_ed2k_cell_listener_plaintext_inbound_serving(
    workspace_paths: WorkspacePaths,
    pytestconfig: pytest.Config,
) -> None:
    manifest = load_manifest(workspace_paths, SCENARIO_ID)
    source_scenario_id = str(manifest["execution"]["summarySourceScenarioId"])
    source_manifest = load_manifest(workspace_paths, source_scenario_id)
    run_live_ed2k_server_roundtrip_scenario(
        workspace_paths,
        pytestconfig,
        scenario_id=SCENARIO_ID,
        manifest=source_manifest,
    )
