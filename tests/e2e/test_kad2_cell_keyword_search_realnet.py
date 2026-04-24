from __future__ import annotations

import pytest

from tests.e2e.lib.kad_live import run_live_kad_search_download_to_agent_scenario
from tests.e2e.lib.manifests import load_manifest
from tests.e2e.lib.paths import WorkspacePaths


@pytest.mark.e2e
@pytest.mark.live
@pytest.mark.requires_vpn
@pytest.mark.kad
@pytest.mark.cell
@pytest.mark.slow
@pytest.mark.plaintext
def test_live_kad2_cell_keyword_search_plaintext_realnet(
    workspace_paths: WorkspacePaths,
    pytestconfig: pytest.Config,
) -> None:
    scenario_id = "kad2.cell.keyword.search.plaintext.realnet.v1"
    manifest = load_manifest(workspace_paths, scenario_id)

    assert manifest["scenarioKind"] == "cell"
    assert manifest["protocol"] == "kad2"

    source_manifest = load_manifest(
        workspace_paths,
        str(manifest["execution"]["summarySourceScenarioId"]),
    )
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
@pytest.mark.kad
@pytest.mark.cell
@pytest.mark.slow
@pytest.mark.obfuscated
def test_live_kad2_cell_keyword_search_obfuscated_realnet(
    workspace_paths: WorkspacePaths,
    pytestconfig: pytest.Config,
) -> None:
    scenario_id = "kad2.cell.keyword.search.obfuscated.realnet.v1"
    manifest = load_manifest(workspace_paths, scenario_id)

    assert manifest["scenarioKind"] == "cell"
    assert manifest["protocol"] == "kad2"

    source_manifest = load_manifest(
        workspace_paths,
        str(manifest["execution"]["summarySourceScenarioId"]),
    )
    run_live_kad_search_download_to_agent_scenario(
        workspace_paths,
        pytestconfig,
        scenario_id=scenario_id,
        manifest=source_manifest,
        transport_mode="obfuscated",
    )
