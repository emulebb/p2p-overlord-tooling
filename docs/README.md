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
