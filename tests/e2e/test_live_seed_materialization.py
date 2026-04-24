from __future__ import annotations

from pathlib import Path

from tests.e2e.lib.ed2k_live import (
    materialize_live_seed_bundle_to_agent_state,
    materialize_live_seed_bundle_to_harness_profile,
)
from tests.e2e.lib.emule_harness import EmuleProfile
from tests.e2e.lib.live_network import LiveInterfaceBinding
from tests.e2e.lib.live_runtime import LiveScenarioPrerequisites
from tests.e2e.lib.live_seeds import EmuleHarnessSeedBundle
from tests.e2e.lib.live_servers import LiveEd2kServerEntry


def test_materialize_live_seed_bundle_to_harness_profile_copies_nodes_and_servers(
    tmp_path: Path,
) -> None:
    prerequisites = _prerequisites(tmp_path)
    profile = EmuleProfile(
        profile_root=tmp_path / "profile",
        preferences_path=tmp_path / "profile" / "config" / "preferences.ini",
        logs_root=tmp_path / "profile" / "logs",
        incoming_root=tmp_path / "profile" / "Incoming",
        temp_root=tmp_path / "profile" / "Temp",
    )
    (profile.profile_root / "config").mkdir(parents=True, exist_ok=True)

    materialize_live_seed_bundle_to_harness_profile(profile, prerequisites)

    assert (profile.profile_root / "config" / "server.met").read_bytes() == b"server-met"
    assert (profile.profile_root / "config" / "nodes.dat").read_bytes() == b"nodes-dat"


def test_materialize_live_seed_bundle_to_agent_state_copies_nodes_dat(tmp_path: Path) -> None:
    prerequisites = _prerequisites(tmp_path)

    destination = materialize_live_seed_bundle_to_agent_state(tmp_path / "state", prerequisites)

    assert destination.name == "overlord-kad.nodes.dat"
    assert destination.read_bytes() == b"nodes-dat"


def _prerequisites(tmp_path: Path) -> LiveScenarioPrerequisites:
    seed_root = tmp_path / "seed"
    seed_root.mkdir(parents=True, exist_ok=True)
    nodes_dat_path = seed_root / "nodes.dat"
    server_met_path = seed_root / "server.met"
    bundle_manifest_path = seed_root / "seed-bundle.json"
    nodes_dat_path.write_bytes(b"nodes-dat")
    server_met_path.write_bytes(b"server-met")
    bundle_manifest_path.write_text(
        '{\n  "schemaVersion": "emule-harness-seed-bundle/v1",\n  "bundleId": "canonical"\n}\n',
        encoding="utf-8",
        newline="\n",
    )
    manifest = {
        "schemaVersion": "emule-harness-seed-bundle/v1",
        "bundleId": "canonical",
    }
    return LiveScenarioPrerequisites(
        interface_binding=LiveInterfaceBinding(interface_alias="hide.me", bind_ip="10.8.0.4"),
        seed_bundle=EmuleHarnessSeedBundle(
            bundle_id="canonical",
            seed_root=seed_root,
            manifest_path=bundle_manifest_path,
            nodes_dat_path=nodes_dat_path,
            server_met_path=server_met_path,
            manifest=manifest,
        ),
        server_entries=[LiveEd2kServerEntry(host="1.2.3.4", port=4661)],
        file_size_bytes=None,
    )
