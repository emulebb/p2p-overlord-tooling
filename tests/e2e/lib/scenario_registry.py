from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

import pytest

from tests.e2e.lib.paths import WorkspacePaths


@dataclass(frozen=True)
class ScenarioContext:
    workspace_paths: WorkspacePaths
    pytestconfig: pytest.Config
    scenario_id: str
    run_scenario_id: str
    manifest: dict[str, Any]
    source_manifest: dict[str, Any] | None
    source_scenario_id: str | None
    transport_mode: str | None
    artifact_scenario_id: str | None = None
    run_slug: str | None = None
    metadata: dict[str, Any] | None = None


Runner = Callable[[ScenarioContext], None]


def registered_command_names() -> set[str]:
    return set(_REGISTRY)


def execute_registered_command(command: str, context: ScenarioContext) -> None:
    try:
        runner = _REGISTRY[command]
    except KeyError as exc:
        raise KeyError(f"no runner registered for scenario command {command!r}") from exc
    runner(context)


def _run_ed2k_private_server_download(context: ScenarioContext) -> None:
    from tests.e2e.test_ed2k_server_download import (
        run_private_ed2k_server_download_to_agent_scenario,
    )

    transport_mode = context.transport_mode or "plaintext"
    run_private_ed2k_server_download_to_agent_scenario(
        context.workspace_paths,
        context.pytestconfig,
        scenario_id=context.run_scenario_id,
        config_scenario_id=context.source_scenario_id,
        transport_mode=transport_mode,
        use_plaintext_loopback_source_hint=transport_mode == "plaintext",
        artifact_scenario_id=context.artifact_scenario_id,
        run_slug=context.run_slug,
        metadata=context.metadata,
    )


def _run_ed2k_private_kad_assisted_download(context: ScenarioContext) -> None:
    from tests.e2e.test_ed2k_kad_download import (
        run_private_kad_ed2k_download_to_agent_scenario,
    )

    run_private_kad_ed2k_download_to_agent_scenario(
        context.workspace_paths,
        context.pytestconfig,
        scenario_id=context.run_scenario_id,
        config_scenario_id=context.source_scenario_id,
        artifact_scenario_id=context.artifact_scenario_id,
        run_slug=context.run_slug,
        metadata=context.metadata,
        transport_mode=context.transport_mode,
    )


def _run_ed2k_private_callback_source_acquisition(context: ScenarioContext) -> None:
    from tests.e2e.test_ed2k_triplet_validation import (
        run_private_ed2k_server_triplet_callback_limit_scenario,
    )

    run_private_ed2k_server_triplet_callback_limit_scenario(
        context.workspace_paths,
        context.pytestconfig,
        scenario_id=context.run_scenario_id,
        artifact_scenario_id=context.artifact_scenario_id,
        run_slug=context.run_slug,
        metadata=context.metadata,
        transport_mode=context.transport_mode or "plaintext",
    )


def _run_ed2k_private_listener_queue(context: ScenarioContext) -> None:
    from tests.e2e.lib.ed2k_rust_scenarios import run_private_ed2k_listener_queue_scenario

    run_private_ed2k_listener_queue_scenario(
        context.workspace_paths,
        context.pytestconfig,
        scenario_id=context.run_scenario_id,
        artifact_scenario_id=context.artifact_scenario_id,
        run_slug=context.run_slug,
        metadata=context.metadata,
    )


def _run_ed2k_private_downloader_queue(context: ScenarioContext) -> None:
    from tests.e2e.lib.ed2k_rust_scenarios import run_private_ed2k_downloader_queue_scenario

    run_private_ed2k_downloader_queue_scenario(
        context.workspace_paths,
        context.pytestconfig,
        scenario_id=context.run_scenario_id,
        artifact_scenario_id=context.artifact_scenario_id,
        run_slug=context.run_slug,
        metadata=context.metadata,
        transport_mode=context.transport_mode,
    )


def _run_ed2k_private_downloader_resume(context: ScenarioContext) -> None:
    from tests.e2e.lib.ed2k_rust_scenarios import (
        run_private_ed2k_downloader_resume_scenario,
    )

    run_private_ed2k_downloader_resume_scenario(
        context.workspace_paths,
        context.pytestconfig,
        scenario_id=context.run_scenario_id,
        artifact_scenario_id=context.artifact_scenario_id,
        run_slug=context.run_slug,
        metadata=context.metadata,
        transport_mode=context.transport_mode,
    )


def _run_ed2k_private_listener_serving(context: ScenarioContext) -> None:
    from tests.e2e.lib.ed2k_rust_scenarios import run_private_ed2k_listener_serving_scenario

    run_private_ed2k_listener_serving_scenario(
        context.workspace_paths,
        context.pytestconfig,
        scenario_id=context.run_scenario_id,
        artifact_scenario_id=context.artifact_scenario_id,
        run_slug=context.run_slug,
        metadata=context.metadata,
        transport_mode=context.transport_mode,
    )


def _run_ed2k_private_listener_resume(context: ScenarioContext) -> None:
    from tests.e2e.lib.ed2k_rust_scenarios import run_private_ed2k_listener_resume_scenario

    run_private_ed2k_listener_resume_scenario(
        context.workspace_paths,
        context.pytestconfig,
        scenario_id=context.run_scenario_id,
        artifact_scenario_id=context.artifact_scenario_id,
        run_slug=context.run_slug,
        metadata=context.metadata,
        transport_mode=context.transport_mode,
    )


def _run_live_kad_search_download(context: ScenarioContext) -> None:
    from tests.e2e.lib.kad_live import run_live_kad_search_download_to_agent_scenario

    if context.source_manifest is None:
        raise ValueError(f"{context.scenario_id} requires a summarySourceScenarioId manifest")
    if context.transport_mode is None:
        raise ValueError(f"{context.scenario_id} requires a concrete transport mode")
    run_live_kad_search_download_to_agent_scenario(
        context.workspace_paths,
        context.pytestconfig,
        scenario_id=context.run_scenario_id,
        manifest=context.source_manifest,
        transport_mode=context.transport_mode,
        artifact_scenario_id=context.artifact_scenario_id,
        run_slug=context.run_slug,
        metadata=context.metadata,
    )


def _run_live_wire_stress_search_download(context: ScenarioContext) -> None:
    from tests.e2e.lib.live_wire_stress import run_live_wire_stress_search_download_scenario

    run_live_wire_stress_search_download_scenario(
        context.workspace_paths,
        context.pytestconfig,
        scenario_id=context.run_scenario_id,
        manifest=context.manifest,
        source_manifest=context.source_manifest,
        artifact_scenario_id=context.artifact_scenario_id,
        run_slug=context.run_slug,
        metadata=context.metadata,
    )


def _run_live_ed2k_server_roundtrip(context: ScenarioContext) -> None:
    from tests.e2e.lib.ed2k_live import run_live_ed2k_server_roundtrip_scenario

    if context.source_manifest is None:
        raise ValueError(f"{context.scenario_id} requires a summarySourceScenarioId manifest")
    run_live_ed2k_server_roundtrip_scenario(
        context.workspace_paths,
        context.pytestconfig,
        scenario_id=context.run_scenario_id,
        manifest=context.source_manifest,
        artifact_scenario_id=context.artifact_scenario_id,
        run_slug=context.run_slug,
        metadata=context.metadata,
    )


def _run_live_kad_startup_publish(context: ScenarioContext) -> None:
    from tests.e2e.lib.kad_startup_live import run_live_kad_startup_publish_scenario

    if context.source_manifest is None:
        raise ValueError(f"{context.scenario_id} requires a summarySourceScenarioId manifest")
    run_live_kad_startup_publish_scenario(
        context.workspace_paths,
        context.pytestconfig,
        scenario_id=context.run_scenario_id,
        manifest=context.source_manifest,
        artifact_scenario_id=context.artifact_scenario_id,
        run_slug=context.run_slug,
        metadata=context.metadata,
    )


def _run_kad2_private_harness_triplet(context: ScenarioContext) -> None:
    from tests.e2e.lib.kad_private import run_private_kad_harness_triplet_scenario

    if context.source_manifest is None:
        raise ValueError(f"{context.scenario_id} requires a summarySourceScenarioId manifest")
    run_private_kad_harness_triplet_scenario(
        context.workspace_paths,
        context.pytestconfig,
        scenario_id=context.run_scenario_id,
        manifest=context.manifest,
        source_manifest=context.source_manifest,
        artifact_scenario_id=context.artifact_scenario_id,
        run_slug=context.run_slug,
        metadata=context.metadata,
    )


_REGISTRY: dict[str, Runner] = {
    "ed2k.private.callback-source-acquisition": _run_ed2k_private_callback_source_acquisition,
    "ed2k.private.downloader-queue": _run_ed2k_private_downloader_queue,
    "ed2k.private.downloader-resume": _run_ed2k_private_downloader_resume,
    "ed2k.private.listener-resume": _run_ed2k_private_listener_resume,
    "ed2k.private.listener-queue": _run_ed2k_private_listener_queue,
    "ed2k.private.listener-serving": _run_ed2k_private_listener_serving,
    "ed2k.private.kad-assisted-download": _run_ed2k_private_kad_assisted_download,
    "ed2k.private.server-download": _run_ed2k_private_server_download,
    "ed2k.live.kad-search-download": _run_live_kad_search_download,
    "ed2k.live.search-download-stress": _run_live_wire_stress_search_download,
    "ed2k.live.server-roundtrip": _run_live_ed2k_server_roundtrip,
    "kad2.private.harness-triplet": _run_kad2_private_harness_triplet,
    "kad2.live.keyword-search-download": _run_live_kad_search_download,
    "kad2.live.startup-publish": _run_live_kad_startup_publish,
}
