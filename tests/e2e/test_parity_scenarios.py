from __future__ import annotations

import pytest

from tests.e2e.lib.paths import WorkspacePaths
from tests.e2e.lib.scenario_execution import collect_scenario_cases, execute_scenario_case


def _params():
    cases = collect_scenario_cases(WorkspacePaths.discover())
    params = []
    for case in cases:
        marks = [getattr(pytest.mark, name) for name in case.marker_names]
        params.append(pytest.param(case, id=case.pytest_id, marks=marks))
    return params


@pytest.mark.parametrize("scenario_case", _params())
def test_manifest_parity_scenario(
    scenario_case,
    workspace_paths: WorkspacePaths,
    pytestconfig: pytest.Config,
) -> None:
    execute_scenario_case(
        scenario_case,
        workspace_paths=workspace_paths,
        pytestconfig=pytestconfig,
    )
