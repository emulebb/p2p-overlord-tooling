from __future__ import annotations

import pytest

from tests.e2e.lib.manifests import load_manifest
from tests.e2e.lib.paths import WorkspacePaths
from tests.e2e.test_ed2k_kad_download import (
    SCENARIO_ID as LEGACY_SCENARIO_ID,
    run_private_kad_ed2k_download_to_agent_scenario,
)


SCENARIO_ID = "ed2k.cell.downloader.plaintext.direct.serving.fresh.kad-private.v1"


@pytest.mark.e2e
@pytest.mark.local
@pytest.mark.ed2k
@pytest.mark.cell
@pytest.mark.slow
@pytest.mark.harness_to_agent
def test_private_ed2k_cell_downloader_plaintext_direct_serving_kad_private(
    workspace_paths: WorkspacePaths,
    pytestconfig: pytest.Config,
    transport_mode: str,
) -> None:
    if transport_mode != "plaintext":
        pytest.skip("cell manifest is defined only for plaintext transport")

    manifest = load_manifest(workspace_paths, SCENARIO_ID)

    assert manifest["scenarioKind"] == "cell"
    assert manifest["parity"]["availability"] == "available"
    assert manifest["execution"]["command"] == "run-private-emule-harness-ed2k-download"
    assert manifest["execution"]["summarySourceScenarioId"] == LEGACY_SCENARIO_ID

    run_private_kad_ed2k_download_to_agent_scenario(
        workspace_paths,
        pytestconfig,
        scenario_id=SCENARIO_ID,
        config_scenario_id=LEGACY_SCENARIO_ID,
    )
