from __future__ import annotations

from overlord_tooling.scenarios import iter_manifests, load_manifest, load_manifest_ids, manifest_availability
from tests.e2e.lib.paths import WorkspacePaths


def test_iter_manifests_returns_sorted_inventory(workspace_paths: WorkspacePaths) -> None:
    manifests = iter_manifests(workspace_paths.tooling_root)

    assert len(manifests) >= 50
    assert [manifest["scenarioId"] for manifest in manifests] == sorted(
        manifest["scenarioId"] for manifest in manifests
    )


def test_iter_manifests_filters_ed2k_deterministic_private_available(workspace_paths: WorkspacePaths) -> None:
    scenario_ids = load_manifest_ids(
        workspace_paths.tooling_root,
        protocol="ed2k",
        tier="deterministic-private",
        availability="available",
    )

    assert "ed2k.server.emule-harness.agent.roundtrip.private.large.v1" in scenario_ids
    assert "ed2k.cell.listener.plaintext.inbound.queue-only.fresh.private.v1" in scenario_ids


def test_manifest_availability_reads_campaign_and_cell_shapes(workspace_paths: WorkspacePaths) -> None:
    campaign = load_manifest(workspace_paths.tooling_root, "kad2.campaign.startup-and-bootstrap.v1")
    available_cell = load_manifest(
        workspace_paths.tooling_root,
        "ed2k.cell.listener.obfuscated.inbound.queue-only.fresh.private.v1",
    )

    assert manifest_availability(campaign) == "available"
    assert manifest_availability(available_cell) == "available"
