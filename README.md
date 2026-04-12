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

- `overlord-tooling.ps1` stable top-level CLI entrypoint
- `cli/` command dispatch and CLI helpers
- `orchestration/` run/session orchestration
- `scenarios/` versioned scenario contracts
- `profiles/` profile templates and materializers
- `schemas/` versioned manifest and summary schemas
- `normalizers/` trace normalization and post-processing
- `reports/` summary generation
- `subsystems/` subsystem-specific tooling modules and internal scripts

## Supported Surface

Operator-facing entrypoints are:

- `overlord-tooling.ps1`
- `orchestration/` scenario runners
- `scenarios/` manifest contracts

Subsystem-owned scripts under `subsystems/` are internal implementation
details. They can be reorganized as the platform evolves and should not be
treated as stable operator entrypoints.

## Tooling Architecture

- `cli/` exposes the stable workspace command surface
- `orchestration/` composes subsystem behaviors into reproducible runs
- `scenarios/` defines versioned scenario contracts
- `subsystems/` owns runtime-specific logic for agent, eMule harness, goed2k,
  network, pcap, parity, and protocol helpers
- `reports/` and `normalizers/` transform raw run artifacts into consumable
  summaries

## Contributor Note

Do not add new root-level `helper-*` scripts. New reusable logic should live
under the owning subsystem, and orchestration should call subsystem-owned
scripts or functions rather than depending on repo-root helper naming.

## Docs

- [Tooling Docs](docs/README.md)
- [Workspace Policy](docs/WORKSPACE_POLICY.md)
- [PowerShell Mistakes](docs/POWERSHELL_MISTAKES.md)

## Guards

- `.\overlord-tooling.ps1 guard-tracked-files` scans tracked files for user-profile
  path leaks and configured personal-name filename leaks.
- Repo-specific personal identifier checks should come from local untracked
  policy or environment configuration, not from tracked source.
- The same guard is enforced in GitHub Actions for pushes and pull requests.

## Deterministic Harness

- `.\overlord-tooling.ps1 import-emule-harness-seeds -NodesDatPath <path> -ServerMetPath <path>`
  copies the local canonical `nodes.dat` and `server.met` into the untracked
  `.local/emule-harness-seeds/canonical/` bundle without persisting the source paths.
- `.\overlord-tooling.ps1 show-scenario kad.startup.hello.publish.realnet.v1`
  prints the first paired eMule harness and agent scenario contract.
- `.\overlord-tooling.ps1 run-kad-startup-hello-publish` materializes a
  scenario-owned eMule harness profile with a manifest-owned minimal
  `preferences.ini`, launches the eMule harness with an explicit profile-root
  override, launches the agent, triggers a deterministic manual publish,
  resolves the eMule harness runtime from `%EMULE_WORKSPACE_ROOT%`, and writes
  run artifacts under
  `%OVERLORD_TMP_DIR%`.
- `.\overlord-tooling.ps1 run-realnet-emule-harness-ed2k-server-roundtrip`
  pins both runtimes to one reachable live ED2K server, transfers a
  deterministic binary from the eMule harness to the agent, restarts the agent,
  and verifies that a fresh eMule harness profile can download the same file
  back over the live server path.
