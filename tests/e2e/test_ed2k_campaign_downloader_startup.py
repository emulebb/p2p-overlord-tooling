from __future__ import annotations

from dataclasses import dataclass

import pytest

from tests.e2e.lib.manifests import load_manifest
from tests.e2e.lib.paths import WorkspacePaths
from tests.e2e.test_ed2k_cell_download import SCENARIO_ID as PRIVATE_DIRECT_CELL_SCENARIO_ID
from tests.e2e.test_ed2k_kad_download import (
    SCENARIO_ID as KAD_PRIVATE_SCENARIO_ID,
    run_private_kad_ed2k_download_to_agent_scenario,
)
from tests.e2e.test_ed2k_server_download import (
    SCENARIO_ID as PRIVATE_DIRECT_RUNTIME_SCENARIO_ID,
    run_private_ed2k_server_download_to_agent_scenario,
)


SCENARIO_ID = "ed2k.campaign.downloader-startup.v1"
CAMPAIGN_MIN_FILE_SIZE_BYTES = 10_485_760


@pytest.mark.e2e
@pytest.mark.local
@pytest.mark.ed2k
@pytest.mark.campaign
@pytest.mark.slow
def test_private_members_of_ed2k_downloader_startup_campaign(
    workspace_paths: WorkspacePaths,
    pytestconfig: pytest.Config,
) -> None:
    runtime_pytestconfig = _CampaignConfigProxy(
        pytestconfig,
        file_size_bytes=max(int(pytestconfig.getoption("--file-size-bytes")), CAMPAIGN_MIN_FILE_SIZE_BYTES),
    )
    manifest = load_manifest(workspace_paths, SCENARIO_ID)

    assert manifest["scenarioKind"] == "campaign"
    assert manifest["campaign"]["availability"] == "available"
    assert manifest["campaign"]["members"] == [
        {
            "scenarioId": PRIVATE_DIRECT_CELL_SCENARIO_ID,
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

    run_private_ed2k_server_download_to_agent_scenario(
        workspace_paths,
        runtime_pytestconfig,
        scenario_id=f"{SCENARIO_ID}.private-direct",
        config_scenario_id=PRIVATE_DIRECT_RUNTIME_SCENARIO_ID,
        transport_mode="plaintext",
        use_plaintext_loopback_source_hint=True,
    )
    run_private_kad_ed2k_download_to_agent_scenario(
        workspace_paths,
        runtime_pytestconfig,
        scenario_id=f"{SCENARIO_ID}.kad-private",
        config_scenario_id=KAD_PRIVATE_SCENARIO_ID,
    )


@dataclass(frozen=True)
class _CampaignConfigProxy:
    base: pytest.Config
    file_size_bytes: int

    def getoption(self, name: str, default: object | None = None) -> object:
        if name == "--file-size-bytes":
            return self.file_size_bytes
        return self.base.getoption(name, default=default)
