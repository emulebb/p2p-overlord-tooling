# p2p-overlord-tooling

Workspace tooling platform for the `p2p-overlord` workspace.

This repo is the canonical home for reusable automation across parity, reproducibility,
scenario orchestration, trace/report normalization, and workspace operations.
Product runtime logic remains in:

- `../p2p-overlord-agents`
- `../p2p-overlord-be`

Use the shared workspace policy from `docs/WORKSPACE_POLICY.md` and the
tooling-repo notes in `./AGENTS.md`.

## Layout

- `overlord_tooling/` Python command surface
- `cli/` command-surface notes
- `orchestration/` scenario orchestration notes
- `scenarios/` versioned scenario contracts
- `tests/e2e/` native pytest parity scenarios
- `profiles/` profile notes
- `schemas/` versioned manifest and summary schemas
- `normalizers/` trace normalization and post-processing
- `reports/` summary generation
- `subsystems/` retired subsystem notes and remaining Python helpers

## Supported Surface

Operator-facing entrypoints are:

- `python -m overlord_tooling`
- `python -m pytest tests/e2e ...` for parity E2E scenarios
- `scenarios/` manifest contracts

Legacy wrapper scripts were removed. Do not add compatibility shims for them.

## Tooling Architecture

- `overlord_tooling/` exposes the stable workspace command surface
- `tests/e2e/` composes runtimes into reproducible pytest parity runs
- `orchestration/` keeps scenario orchestration notes
- `scenarios/` defines versioned scenario contracts
- runtime-specific parity logic lives in `tests/e2e/lib/`
- `reports/` and `normalizers/` transform raw run artifacts into consumable
  summaries

## Contributor Note

Do not add wrapper scripts. New reusable automation should be Python modules
under the owning package or pytest library.

## Docs

- [Tooling Docs](docs/README.md)
- [Workspace Policy](docs/WORKSPACE_POLICY.md)

## Guards

- `python -m overlord_tooling quality-baseline` runs the non-live workspace
  quality baseline across agents, backend, tooling, and guards.
- `python -m overlord_tooling hygiene-report` prints JSON hygiene metadata for
  repo status, source hotspots, Rust allows, parity status, environment
  readiness, and advisory internal API drift.
- `python -m overlord_tooling guard-tracked-files` scans tracked files for user-profile
  path leaks and configured personal-name filename leaks.
- `python -m overlord_tooling guard-workspace-conventions` scans the canonical
  repos for stale `overlord-*` repo-directory references and forbidden wrapper
  files.
- Repo-specific personal identifier checks should come from local untracked
  policy or environment configuration, not from tracked source.
- The same guard is enforced in GitHub Actions for pushes and pull requests.

## Deterministic Harness

- `python -m overlord_tooling import-emule-harness-seeds <nodes.dat> <server.met>`
  copies the local canonical `nodes.dat` and `server.met` into the untracked
  `.local/emule-harness-seeds/canonical/` bundle without persisting the source paths.
- `python -m overlord_tooling show-scenario kad.startup.hello.publish.realnet.v1`
  prints the first paired eMule harness and agent scenario contract.
- `python -m overlord_tooling show-parity-matrix`
  prints the KAD2 and ED2K parity inventory, including runnable cells,
  campaigns, and planned harness-hook gaps.
- `python -m pytest tests/e2e --collect-only`
  lists native pytest parity scenarios without launching runtimes.
- `python -m pytest tests/e2e -m "local and ed2k" --run-e2e --file-size-bytes 127926272`
  runs the native local ED2K parity matrix with the 122 MiB payload size.
