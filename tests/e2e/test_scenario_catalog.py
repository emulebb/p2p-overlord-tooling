from __future__ import annotations

from overlord_tooling.scenarios import ScenarioCatalog, campaign_step_slug
from tests.e2e.lib.scenario_execution import collect_scenario_cases
from tests.e2e.lib.scenario_registry import registered_command_names
from tests.e2e.lib.paths import WorkspacePaths


def test_scenario_catalog_validates_manifest_relationships(
    workspace_paths: WorkspacePaths,
) -> None:
    catalog = ScenarioCatalog.load(workspace_paths.tooling_root)

    assert catalog.validate() == []


def test_manifest_driven_cases_include_native_runner_backed_cells_and_campaigns(
    workspace_paths: WorkspacePaths,
) -> None:
    case_ids = {case.scenario_id for case in collect_scenario_cases(workspace_paths)}

    assert "ed2k.cell.downloader.plaintext.direct.serving.fresh.private.v1" in case_ids
    assert "ed2k.campaign.realnet-confidence.v1" in case_ids
    assert "kad2.cell.keyword.search.obfuscated.realnet.v1" in case_ids
    assert "kad2.campaign.realnet-confidence.v1" in case_ids
    assert "kad2.cell.keyword.search.triplet.private.v1" not in case_ids


def test_native_command_gaps_are_explicit_legacy_kad2_triplet_cells(
    workspace_paths: WorkspacePaths,
) -> None:
    catalog = ScenarioCatalog.load(workspace_paths.tooling_root)

    assert catalog.native_command_gaps(registered_command_names()) == [
        "kad2.cell.bootstrap.lookup.triplet.private.v1",
        "kad2.cell.hello.senderkey.ack.triplet.private.v1",
        "kad2.cell.keyword.publish.triplet.private.v1",
        "kad2.cell.keyword.search.triplet.private.v1",
        "kad2.cell.notes.search.private.v1",
        "kad2.cell.source.publish.triplet.private.v1",
        "kad2.cell.source.search.private.v1",
    ]


def test_campaign_step_slug_is_stable_and_readable() -> None:
    assert campaign_step_slug(
        "kad2.cell.keyword.search.obfuscated.realnet.v1",
    ) == "keyword-search-obfuscated"
