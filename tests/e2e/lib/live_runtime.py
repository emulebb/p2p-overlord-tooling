from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from tests.e2e.lib.live_network import LiveInterfaceBinding, resolve_live_interface_binding
from tests.e2e.lib.live_seeds import EmuleHarnessSeedBundle, resolve_emule_harness_seed_bundle
from tests.e2e.lib.paths import WorkspacePaths


@dataclass(frozen=True)
class LiveScenarioPrerequisites:
    interface_binding: LiveInterfaceBinding
    seed_bundle: EmuleHarnessSeedBundle
    file_size_bytes: int | None


def resolve_live_scenario_prerequisites(
    paths: WorkspacePaths,
    manifest: dict[str, Any],
) -> LiveScenarioPrerequisites:
    interface_alias = str(manifest.get("interfaceAlias") or "hide.me")
    seed_bundle_id = str(manifest.get("seedBundleId") or "canonical")
    interface_binding = resolve_live_interface_binding(paths, interface_alias=interface_alias)
    seed_bundle = resolve_emule_harness_seed_bundle(paths, bundle_id=seed_bundle_id)
    file_block = manifest.get("file")
    file_size_bytes = None
    if isinstance(file_block, dict) and file_block.get("sizeBytes") is not None:
        file_size_bytes = int(file_block["sizeBytes"])
    return LiveScenarioPrerequisites(
        interface_binding=interface_binding,
        seed_bundle=seed_bundle,
        file_size_bytes=file_size_bytes,
    )
