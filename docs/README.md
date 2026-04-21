# Tooling Docs

Supporting notes for the workspace tooling platform.

## Read First

- [Workspace Policy](./WORKSPACE_POLICY.md)

## Platform Areas

- `../overlord_tooling/` Python command surface
- `../cli/` command-surface notes
- `../orchestration/` scenario orchestration notes
- `../tests/e2e/` native pytest parity scenarios
- `../scenarios/` scenario contracts
- `../profiles/` profile notes
- `../schemas/` versioned JSON contracts
- `../normalizers/` trace normalization
- `../reports/` machine-readable and terminal summaries
- `../subsystems/` retired subsystem notes and remaining Python helpers

## Supported Surface

Treat these as the supported operator-facing surface:

- `python -m overlord_tooling`
- `python -m pytest tests/e2e ...` parity E2E scenarios
- scenario manifests under `../scenarios/`

Legacy wrapper scripts were removed. Do not add compatibility shims for them.

## Architecture

- CLI dispatch stays in `../overlord_tooling/`
- scenario composition moves to native pytest under `../tests/e2e/`
- `../orchestration/` keeps scenario orchestration notes
- runtime-owned parity logic stays in `../tests/e2e/lib/`
- result shaping stays in `../normalizers/` and `../reports/`

Do not add wrapper scripts. New reusable automation should be Python modules
under the owning package or pytest library.

## Repo Guards

- `python -m overlord_tooling guard-tracked-files` validates that tracked files do
  not contain committed local user-profile paths and do not use configured
  personal-name filenames.
- `python -m overlord_tooling guard-workspace-conventions` validates that
  tracked files do not use stale `overlord-*` repo-directory references and
  that canonical repos do not contain forbidden wrapper files.
- Tracked safe exceptions for public references must stay narrow and justified
  in the repo policy; local personal identifiers still belong in untracked
  policy or environment configuration.
- Real personal identifiers must not be stored in tracked policy files; use
  local untracked policy or environment configuration for those checks.

## Harness Commands

- `python -m overlord_tooling import-emule-harness-seeds <nodes.dat> <server.met>`
  imports canonical eMule harness seed files into the untracked local seed
  bundle.
- `python -m overlord_tooling show-scenario kad.startup.hello.publish.realnet.v1`
  prints the first paired eMule harness and agent deterministic scenario
  manifest.
- `python -m overlord_tooling show-parity-matrix`
  prints the KAD2 and ED2K parity matrix inventory across `cell` and
  `campaign` manifests.
- `python -m pytest tests/e2e --collect-only`
  lists native pytest parity scenarios without launching runtimes.
- `python -m pytest tests/e2e -m "local and ed2k" --run-e2e --file-size-bytes 127926272`
  runs the native local ED2K parity matrix with the 122 MiB payload size.
