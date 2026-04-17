# Tooling Docs

Supporting notes for the workspace tooling platform.

## Read First

- [Workspace Policy](./WORKSPACE_POLICY.md)
- [PowerShell Mistakes](./POWERSHELL_MISTAKES.md)

## Platform Areas

- `../overlord-tooling.ps1` stable top-level CLI entrypoint
- `../cli/` command dispatch
- `../orchestration/` reproducible session control
- `../scenarios/` scenario contracts
- `../profiles/` generated runtime profiles
- `../schemas/` versioned JSON contracts
- `../normalizers/` trace normalization
- `../reports/` machine-readable and terminal summaries
- `../subsystems/` subsystem modules and internal implementation scripts

## Supported Surface

Treat these as the supported operator-facing surface:

- `../overlord-tooling.ps1`
- documented orchestration scripts under `../orchestration/`
- scenario manifests under `../scenarios/`

Scripts under `../subsystems/` are internal implementation details that back
the platform surface above. Contributors may refactor them freely as long as
the supported surface and scenario behavior remain coherent.

## Architecture

- CLI dispatch stays in `../cli/` and should come from the command registry
- scenario composition stays in `../orchestration/`
- shared root/path resolution stays in `../subsystems/RuntimeContext.ps1`
- subsystem entry modules stay in `../subsystems/*/*Subsystem.ps1`
- subsystem-owned runtime logic stays behind those subsystem entry modules
- result shaping stays in `../normalizers/` and `../reports/`

Do not add new repo-root `helper-*` scripts. New reusable logic belongs under
the owning subsystem, and orchestration should not depend on helper file names.

## Repo Guards

- `../overlord-tooling.ps1 guard-tracked-files` validates that tracked files do
  not contain committed local user-profile paths and do not use configured
  personal-name filenames.
- `../overlord-tooling.ps1 guard-workspace-conventions` validates that tracked
  files do not use stale `overlord-*` repo-directory references and that every
  tracked `.ps1` starts with `#Requires -Version 7.6`.
- Tracked safe exceptions for public references must stay narrow and justified
  in the repo policy; local personal identifiers still belong in untracked
  policy or environment configuration.
- Real personal identifiers must not be stored in tracked policy files; use
  local untracked policy or environment configuration for those checks.

## Harness Commands

- `../overlord-tooling.ps1 import-emule-harness-seeds -NodesDatPath <path> -ServerMetPath <path>`
  imports canonical eMule harness seed files into the untracked local seed
  bundle.
- `../overlord-tooling.ps1 show-scenario kad.startup.hello.publish.realnet.v1`
  prints the first paired eMule harness and agent deterministic scenario
  manifest.
- `../overlord-tooling.ps1 show-parity-matrix`
  prints the KAD2 and ED2K parity matrix inventory across `cell` and
  `campaign` manifests.
- `../overlord-tooling.ps1 run-parity-cell -ScenarioId <id>`
  executes one parity cell wrapper and writes a wrapper `run-manifest.json`
  plus `run-summary.json`.
- `../overlord-tooling.ps1 run-parity-campaign -ScenarioId <id>`
  executes one parity campaign by running its member cells and aggregating
  their wrapper summaries.
- `../overlord-tooling.ps1 run-kad-startup-hello-publish`
  runs the paired eMule harness and agent Kad startup, HELLO, and publish
  harness, resolves the eMule harness runtime from `%EMULE_WORKSPACE_ROOT%`,
  and writes JSON manifests, summaries, and raw artifacts under
  `%OVERLORD_TMP_DIR%`.
