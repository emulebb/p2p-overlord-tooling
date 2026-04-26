from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Callable

from tests.e2e.lib.live_network import LiveInterfaceBinding, resolve_live_interface_binding
from tests.e2e.lib.live_seeds import EmuleHarnessSeedBundle, resolve_emule_harness_seed_bundle
from tests.e2e.lib.live_servers import LiveEd2kServerEntry, resolve_live_server_entries
from tests.e2e.lib.paths import WorkspacePaths


@dataclass(frozen=True)
class LiveScenarioPrerequisites:
    interface_binding: LiveInterfaceBinding
    seed_bundle: EmuleHarnessSeedBundle
    server_entries: list[LiveEd2kServerEntry]
    file_size_bytes: int | None


def resolve_live_scenario_prerequisites(
    paths: WorkspacePaths,
    manifest: dict[str, Any],
    *,
    command_runner: Callable[..., Any] | None = None,
) -> LiveScenarioPrerequisites:
    interface_alias = str(manifest.get("interfaceAlias") or "hide.me")
    seed_bundle_id = str(manifest.get("seedBundleId") or "canonical")
    interface_binding = resolve_live_interface_binding(
        paths,
        interface_alias=interface_alias,
        command_runner=command_runner,
    )
    seed_bundle = resolve_emule_harness_seed_bundle(paths, bundle_id=seed_bundle_id)
    server_entries = resolve_live_server_entries(seed_bundle, manifest)
    file_block = manifest.get("file")
    file_size_bytes = None
    if isinstance(file_block, dict) and file_block.get("sizeBytes") is not None:
        file_size_bytes = int(file_block["sizeBytes"])
    return LiveScenarioPrerequisites(
        interface_binding=interface_binding,
        seed_bundle=seed_bundle,
        server_entries=server_entries,
        file_size_bytes=file_size_bytes,
    )
