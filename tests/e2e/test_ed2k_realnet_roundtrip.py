from __future__ import annotations

import pytest

from tests.e2e.lib.ed2k_live import run_live_ed2k_server_roundtrip_scenario
from overlord_tooling.scenarios import load_manifest
from tests.e2e.lib.paths import WorkspacePaths


SCENARIO_ID = "ed2k.server.emule-harness.agent.roundtrip.realnet.v1"


@pytest.mark.e2e
@pytest.mark.live
@pytest.mark.requires_vpn
@pytest.mark.ed2k
@pytest.mark.roundtrip
@pytest.mark.harness_to_agent
@pytest.mark.agent_to_harness
@pytest.mark.slow
def test_live_ed2k_server_roundtrip(
    workspace_paths: WorkspacePaths,
    pytestconfig: pytest.Config,
) -> None:
    manifest = load_manifest(workspace_paths.tooling_root, SCENARIO_ID)
    run_live_ed2k_server_roundtrip_scenario(
        workspace_paths,
        pytestconfig,
        scenario_id=SCENARIO_ID,
        manifest=manifest,
    )
