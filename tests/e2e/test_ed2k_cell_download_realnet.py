from __future__ import annotations

import pytest

from tests.e2e.lib.kad_live import run_live_kad_search_download_to_agent_scenario
from tests.e2e.lib.manifests import load_manifest
from tests.e2e.lib.paths import WorkspacePaths


@pytest.mark.e2e
@pytest.mark.live
@pytest.mark.requires_vpn
@pytest.mark.ed2k
@pytest.mark.cell
@pytest.mark.slow
def test_live_ed2k_cell_downloader_plaintext_direct_serving_realnet(
    workspace_paths: WorkspacePaths,
    pytestconfig: pytest.Config,
) -> None:
    scenario_id = "ed2k.cell.downloader.plaintext.direct.serving.fresh.realnet.v1"
    manifest = load_manifest(workspace_paths, scenario_id)
    source_manifest = load_manifest(workspace_paths, str(manifest["execution"]["summarySourceScenarioId"]))
    run_live_kad_search_download_to_agent_scenario(
        workspace_paths,
        pytestconfig,
        scenario_id=scenario_id,
        manifest=source_manifest,
        transport_mode="plaintext",
    )


@pytest.mark.e2e
@pytest.mark.live
@pytest.mark.requires_vpn
@pytest.mark.ed2k
@pytest.mark.cell
@pytest.mark.slow
def test_live_ed2k_cell_downloader_obfuscated_direct_serving_realnet(
    workspace_paths: WorkspacePaths,
    pytestconfig: pytest.Config,
) -> None:
    scenario_id = "ed2k.cell.downloader.obfuscated.direct.serving.fresh.realnet.v1"
    manifest = load_manifest(workspace_paths, scenario_id)
    source_manifest = load_manifest(workspace_paths, str(manifest["execution"]["summarySourceScenarioId"]))
    run_live_kad_search_download_to_agent_scenario(
        workspace_paths,
        pytestconfig,
        scenario_id=scenario_id,
        manifest=source_manifest,
        transport_mode="obfuscated",
    )
