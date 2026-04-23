from __future__ import annotations

import pytest

from tests.e2e.lib.paths import WorkspacePaths


def pytest_addoption(parser: pytest.Parser) -> None:
    group = parser.getgroup("p2p-overlord parity")
    group.addoption(
        "--run-e2e",
        action="store_true",
        default=False,
        help="run tests that launch parity runtimes",
    )
    group.addoption(
        "--run-live",
        action="store_true",
        default=False,
        help="run real-network tests that require VPN/UPnP prerequisites",
    )
    group.addoption(
        "--file-size-bytes",
        type=int,
        default=127_926_272,
        help="payload size override for generated parity files",
    )
    group.addoption(
        "--transport",
        choices=("both", "plaintext", "obfuscated"),
        default="both",
        help="transport variant selector for parametrized scenarios",
    )
    group.addoption(
        "--skip-runtime-build",
        action="store_true",
        default=False,
        help="reuse existing debug runtimes instead of building agent/harness/server",
    )
    group.addoption(
        "--keep-sessions-running",
        action="store_true",
        default=False,
        help="leave launched runtimes alive for manual debugging",
    )


def pytest_collection_modifyitems(config: pytest.Config, items: list[pytest.Item]) -> None:
    skip_e2e = pytest.mark.skip(reason="requires --run-e2e")
    skip_live = pytest.mark.skip(reason="requires --run-live")

    for item in items:
        if item.get_closest_marker("e2e") is not None and not config.getoption("--run-e2e"):
            item.add_marker(skip_e2e)
        if item.get_closest_marker("live") is not None and not config.getoption("--run-live"):
            item.add_marker(skip_live)


def pytest_generate_tests(metafunc: pytest.Metafunc) -> None:
    if "transport_mode" not in metafunc.fixturenames:
        return

    selected = metafunc.config.getoption("--transport")
    modes = ["plaintext", "obfuscated"] if selected == "both" else [selected]
    params = []
    for mode in modes:
        marks = [getattr(pytest.mark, mode)]
        params.append(pytest.param(mode, marks=marks, id=mode))
    metafunc.parametrize("transport_mode", params)


@pytest.fixture(scope="session")
def workspace_paths() -> WorkspacePaths:
    return WorkspacePaths.discover()
