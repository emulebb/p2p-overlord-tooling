# p2p-overlord-tooling

Workspace tooling platform for the `p2p-overlord` workspace.

This repo is the canonical home for reusable automation across parity, reproducibility,
scenario orchestration, trace/report normalization, and workspace operations.
Product runtime logic remains in:

- `../p2p-overlord-agents`
- `../p2p-overlord-be`

Use the shared workspace rules from `../AGENTS.md` and the tooling-repo notes in `./AGENTS.md`.

## Layout

- `overlord-tooling.ps1` stable top-level CLI entrypoint
- `cli/` command dispatch and CLI helpers
- `orchestration/` run/session orchestration
- `scenarios/` versioned scenario contracts
- `profiles/` profile templates and materializers
- `schemas/` versioned manifest and summary schemas
- `normalizers/` trace normalization and post-processing
- `reports/` summary generation
- `subsystems/` subsystem-specific tooling modules
- legacy `helper-*.ps1` scripts remain as compatibility wrappers while the platform surface grows

## Docs

- [Tooling Docs](docs/README.md)
- [PowerShell Mistakes](docs/POWERSHELL_MISTAKES.md)

## Guards

- `.\overlord-tooling.ps1 guard-tracked-files` scans tracked files for user-profile
  path leaks and configured personal-name filename leaks.
- Repo-specific personal identifier checks should come from local untracked
  policy or environment configuration, not from tracked source.
- The same guard is enforced in GitHub Actions for pushes and pull requests.

## Deterministic Harness

- `.\overlord-tooling.ps1 import-oracle-seeds -NodesDatPath <path> -ServerMetPath <path>`
  copies the local canonical `nodes.dat` and `server.met` into the untracked
  `.local/oracle-seeds/canonical/` bundle without persisting the source paths.
- `.\overlord-tooling.ps1 show-scenario kad.startup.hello.publish.realnet.v1`
  prints the first paired oracle+agent scenario contract.
- `.\overlord-tooling.ps1 run-kad-startup-hello-publish` materializes a
  scenario-owned oracle profile with a manifest-owned minimal `preferences.ini`,
  launches the oracle with an explicit profile-root override, launches the
  agent, triggers a deterministic manual publish, resolves the oracle runtime
  from `%EMULE_WORKSPACE_ROOT%`, and writes run artifacts under
  `%OVERLORD_TMP_DIR%`.
