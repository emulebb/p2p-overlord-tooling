from __future__ import annotations

import pytest

from tests.e2e.lib.manifests import load_manifest
from tests.e2e.lib.paths import WorkspacePaths
from tests.e2e.test_ed2k_server_download import (
    run_private_ed2k_server_download_to_agent_scenario,
)


SCENARIO_ID = "ed2k.cell.downloader.plaintext.direct.serving.fresh.private.v1"
SUMMARY_SOURCE_SCENARIO_ID = "ed2k.server.emule-harness.agent.private.v1"


@pytest.mark.e2e
@pytest.mark.local
@pytest.mark.ed2k
@pytest.mark.cell
@pytest.mark.harness_to_agent
def test_private_ed2k_cell_downloader_plaintext_direct_serving(
    workspace_paths: WorkspacePaths,
    pytestconfig: pytest.Config,
    transport_mode: str,
) -> None:
    if transport_mode != "plaintext":
        pytest.skip("cell manifest is defined only for plaintext transport")

    manifest = load_manifest(workspace_paths, SCENARIO_ID)

    assert manifest["scenarioKind"] == "cell"
    assert manifest["parity"]["availability"] == "available"
    assert manifest["execution"]["command"] == "run-private-emule-harness-ed2k-server-download"
    assert manifest["execution"]["summarySourceScenarioId"] == SUMMARY_SOURCE_SCENARIO_ID

    run_private_ed2k_server_download_to_agent_scenario(
        workspace_paths,
        pytestconfig,
        scenario_id=SCENARIO_ID,
        config_scenario_id=SUMMARY_SOURCE_SCENARIO_ID,
        transport_mode=transport_mode,
        use_plaintext_loopback_source_hint=True,
    )
