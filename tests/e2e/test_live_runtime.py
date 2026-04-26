from __future__ import annotations

from pathlib import Path

from tests.e2e.lib.ed2k import write_server_met
from tests.e2e.lib.live_runtime import resolve_live_scenario_prerequisites
from tests.e2e.lib.live_servers import LiveEd2kServerEntry
from tests.e2e.lib.paths import WorkspacePaths


def test_resolve_live_scenario_prerequisites_reads_manifest_defaults(
    tmp_path: Path,
) -> None:
    tooling_root = tmp_path / "tooling"
    seed_root = tooling_root / ".local" / "emule-harness-seeds" / "canonical"
    seed_root.mkdir(parents=True, exist_ok=True)
    (seed_root / "nodes.dat").write_bytes(b"nodes")
    write_server_met(
        seed_root / "server.met",
        server_ip="10.20.0.30",
        server_port=4661,
        udp_flags=0x51,
    )
    (seed_root / "seed-bundle.json").write_text(
        '{\n  "schemaVersion": "emule-harness-seed-bundle/v1",\n  "bundleId": "canonical"\n}\n',
        encoding="utf-8",
        newline="\n",
    )

    prerequisites = resolve_live_scenario_prerequisites(
        WorkspacePaths(
            project_root=tmp_path,
            tooling_root=tooling_root,
            agents_root=tmp_path / "agents",
            be_root=tmp_path / "be",
            tmp_dir=tmp_path / "tmp",
            log_dir=tmp_path / "logs",
            emule_workspace_root=None,
        ),
        {
            "interfaceAlias": "hide.me",
            "seedBundleId": "canonical",
            "file": {"sizeBytes": 10_485_760},
        },
        command_runner=_interface_query_runner(
            '[{"InterfaceAlias":"hide.me","IPAddress":"10.9.0.5","SkipAsSource":false,"AddressState":"Preferred"}]'
        ),
    )

    assert prerequisites.interface_binding.interface_alias == "hide.me"
    assert prerequisites.interface_binding.bind_ip == "10.9.0.5"
    assert prerequisites.seed_bundle.bundle_id == "canonical"
    assert prerequisites.server_entries == [
        LiveEd2kServerEntry(host="10.20.0.30", port=4661, udp_flags=0x51)
    ]
    assert prerequisites.file_size_bytes == 10_485_760


def test_resolve_live_scenario_prerequisites_uses_fallback_defaults(
    tmp_path: Path,
) -> None:
    tooling_root = tmp_path / "tooling"
    seed_root = tooling_root / ".local" / "emule-harness-seeds" / "canonical"
    seed_root.mkdir(parents=True, exist_ok=True)
    (seed_root / "nodes.dat").write_bytes(b"nodes")
    write_server_met(
        seed_root / "server.met",
        server_ip="10.20.0.30",
        server_port=4661,
        udp_flags=0x51,
    )
    (seed_root / "seed-bundle.json").write_text(
        '{\n  "schemaVersion": "emule-harness-seed-bundle/v1",\n  "bundleId": "canonical"\n}\n',
        encoding="utf-8",
        newline="\n",
    )

    prerequisites = resolve_live_scenario_prerequisites(
        WorkspacePaths(
            project_root=tmp_path,
            tooling_root=tooling_root,
            agents_root=tmp_path / "agents",
            be_root=tmp_path / "be",
            tmp_dir=tmp_path / "tmp",
            log_dir=tmp_path / "logs",
            emule_workspace_root=None,
        ),
        {},
        command_runner=_interface_query_runner(
            '[{"InterfaceAlias":"hide.me","IPAddress":"10.8.0.4","SkipAsSource":false,"AddressState":"Preferred"}]'
        ),
    )

    assert prerequisites.interface_binding.interface_alias == "hide.me"
    assert prerequisites.interface_binding.bind_ip == "10.8.0.4"
    assert prerequisites.seed_bundle.bundle_id == "canonical"
    assert prerequisites.server_entries == [
        LiveEd2kServerEntry(host="10.20.0.30", port=4661, udp_flags=0x51)
    ]
    assert prerequisites.file_size_bytes is None


def _interface_query_runner(stdout: str):
    class _Completed:
        def __init__(self, stdout: str) -> None:
            self.stdout = stdout

    return lambda *args, **kwargs: _Completed(stdout)
