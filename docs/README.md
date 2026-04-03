# Tooling Docs

Supporting notes for the workspace tooling platform.

## Read First

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
- `../subsystems/` subsystem modules

## Repo Guards

- `../overlord-tooling.ps1 guard-tracked-files` validates that tracked files do
  not contain committed local user-profile paths and do not use configured
  personal-name filenames.
- Real personal identifiers must not be stored in tracked policy files; use
  local untracked policy or environment configuration for those checks.

## Harness Commands

- `../overlord-tooling.ps1 import-oracle-seeds -NodesDatPath <path> -ServerMetPath <path>`
  imports canonical oracle seed files into the untracked local seed bundle.
- `../overlord-tooling.ps1 show-scenario kad.startup.hello.publish.realnet.v1`
  prints the first paired oracle+agent deterministic scenario manifest.
- `../overlord-tooling.ps1 run-kad-startup-hello-publish`
  runs the paired oracle+agent Kad startup, HELLO, and publish harness and
  writes JSON manifests, summaries, and raw artifacts under `%OVERLORD_TMP_DIR%`.
