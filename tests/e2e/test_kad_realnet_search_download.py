from __future__ import annotations

import pytest

from tests.e2e.lib.kad_live import run_live_kad_search_download_to_agent_scenario
from overlord_tooling.scenarios import load_manifest, write_json
from tests.e2e.lib.paths import WorkspacePaths


SCENARIO_ID = "kad.search-download.emule-harness.agent.realnet.v1"


@pytest.mark.e2e
@pytest.mark.live
@pytest.mark.requires_vpn
@pytest.mark.kad
@pytest.mark.ed2k
@pytest.mark.slow
def test_live_kad_search_download_to_agent(
    workspace_paths: WorkspacePaths,
    pytestconfig: pytest.Config,
    transport_mode: str,
) -> None:
    manifest = load_manifest(workspace_paths.tooling_root, SCENARIO_ID)
    run_live_kad_search_download_to_agent_scenario(
        workspace_paths,
        pytestconfig,
        scenario_id=SCENARIO_ID,
        manifest=manifest,
        transport_mode=transport_mode,
    )
