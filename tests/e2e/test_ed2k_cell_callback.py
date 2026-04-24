from __future__ import annotations

import pytest

from tests.e2e.lib.manifests import load_manifest
from tests.e2e.lib.paths import WorkspacePaths
from tests.e2e.test_ed2k_triplet_validation import (
    SCENARIO_ID as TRIPLET_SCENARIO_ID,
    run_private_ed2k_server_triplet_callback_limit_scenario,
)


SCENARIO_ID = "ed2k.cell.downloader.plaintext.callback.callback-issued.fresh.private.v1"


@pytest.mark.e2e
@pytest.mark.local
@pytest.mark.ed2k
@pytest.mark.cell
@pytest.mark.slow
def test_private_ed2k_cell_downloader_plaintext_callback_issued(
    workspace_paths: WorkspacePaths,
    pytestconfig: pytest.Config,
    transport_mode: str,
) -> None:
    if transport_mode != "plaintext":
        pytest.skip("cell manifest is defined only for plaintext transport")

    manifest = load_manifest(workspace_paths, SCENARIO_ID)

    assert manifest["scenarioKind"] == "cell"
    assert manifest["parity"]["availability"] == "available"
    assert manifest["execution"]["command"] == "validate-ed2k-server-triplet"
    assert manifest["execution"]["summarySourceScenarioId"] == TRIPLET_SCENARIO_ID

    run_private_ed2k_server_triplet_callback_limit_scenario(
        workspace_paths,
        pytestconfig,
        scenario_id=SCENARIO_ID,
    )
