from __future__ import annotations

from tests.e2e.lib.manifests import load_manifest
from tests.e2e.lib.paths import WorkspacePaths


def test_ed2k_callback_campaign_members_match_available_private_cell(
    workspace_paths: WorkspacePaths,
) -> None:
    manifest = load_manifest(workspace_paths, "ed2k.campaign.callback.v1")

    assert manifest["scenarioKind"] == "campaign"
    assert manifest["campaign"]["availability"] == "available"
    assert manifest["campaign"]["members"] == [
        {
            "scenarioId": "ed2k.cell.downloader.plaintext.callback.callback-issued.fresh.private.v1",
            "required": True,
        }
    ]


def test_ed2k_downloader_startup_campaign_members_pin_private_and_realnet_cells(
    workspace_paths: WorkspacePaths,
) -> None:
    manifest = load_manifest(workspace_paths, "ed2k.campaign.downloader-startup.v1")

    assert manifest["scenarioKind"] == "campaign"
    assert manifest["campaign"]["availability"] == "available"
    assert manifest["campaign"]["members"] == [
        {
            "scenarioId": "ed2k.cell.downloader.plaintext.direct.serving.fresh.private.v1",
            "required": True,
        },
        {
            "scenarioId": "ed2k.cell.downloader.plaintext.direct.serving.fresh.kad-private.v1",
            "required": True,
        },
        {
            "scenarioId": "ed2k.cell.downloader.plaintext.direct.serving.fresh.realnet.v1",
            "required": True,
        },
        {
            "scenarioId": "ed2k.cell.downloader.obfuscated.direct.serving.fresh.realnet.v1",
            "required": True,
        },
    ]


def test_ed2k_source_acquisition_campaign_members_pin_callback_and_realnet_cells(
    workspace_paths: WorkspacePaths,
) -> None:
    manifest = load_manifest(workspace_paths, "ed2k.campaign.source-acquisition.v1")

    assert manifest["scenarioKind"] == "campaign"
    assert manifest["campaign"]["availability"] == "available"
    assert manifest["campaign"]["members"] == [
        {
            "scenarioId": "ed2k.cell.downloader.plaintext.callback.callback-issued.fresh.private.v1",
            "required": True,
        },
        {
            "scenarioId": "ed2k.cell.downloader.plaintext.direct.serving.fresh.realnet.v1",
            "required": True,
        },
        {
            "scenarioId": "ed2k.cell.downloader.obfuscated.direct.serving.fresh.realnet.v1",
            "required": True,
        },
    ]


def test_ed2k_listener_serving_campaign_members_pin_realnet_listener_cell(
    workspace_paths: WorkspacePaths,
) -> None:
    manifest = load_manifest(workspace_paths, "ed2k.campaign.listener-serving.v1")

    assert manifest["scenarioKind"] == "campaign"
    assert manifest["campaign"]["availability"] == "available"
    assert manifest["campaign"]["members"] == [
        {
            "scenarioId": "ed2k.cell.listener.plaintext.inbound.serving.fresh.realnet.v1",
            "required": True,
        }
    ]


def test_ed2k_realnet_confidence_campaign_members_pin_live_cells(
    workspace_paths: WorkspacePaths,
) -> None:
    manifest = load_manifest(workspace_paths, "ed2k.campaign.realnet-confidence.v1")

    assert manifest["scenarioKind"] == "campaign"
    assert manifest["campaign"]["availability"] == "available"
    assert manifest["campaign"]["members"] == [
        {
            "scenarioId": "ed2k.cell.downloader.plaintext.direct.serving.fresh.realnet.v1",
            "required": True,
        },
        {
            "scenarioId": "ed2k.cell.downloader.obfuscated.direct.serving.fresh.realnet.v1",
            "required": True,
        },
        {
            "scenarioId": "ed2k.cell.listener.plaintext.inbound.serving.fresh.realnet.v1",
            "required": True,
        },
    ]
