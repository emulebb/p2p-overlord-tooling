# overlord-tooling

Workspace tooling platform for the `p2p-overlord` workspace.

This repo is the canonical home for reusable automation across parity, reproducibility,
scenario orchestration, trace/report normalization, and workspace operations.
Product runtime logic remains in:

- `../overlord-agents`
- `../overlord-be`

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
- The same guard is enforced in GitHub Actions for pushes and pull requests.
