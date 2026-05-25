# Tooling Docs

Supporting notes for the workspace tooling platform.

## Read First

- [Workspace Policy](./WORKSPACE_POLICY.md), including the shared quality and
  opportunistic-refactoring policy.

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
- `python -m overlord_tooling materialize`
- `python -m overlord_tooling validate`
- `python -m pytest tests/e2e ...` parity E2E scenarios
- scenario manifests under `../scenarios/`

Legacy wrapper scripts were removed. Do not add compatibility shims for them.

## Architecture

- CLI dispatch stays in `../overlord_tooling/`
- scenario composition moves to native pytest under `../tests/e2e/`
- `../orchestration/` keeps scenario orchestration notes
- runtime-owned parity logic stays in `../tests/e2e/lib/`
- result shaping stays in `../normalizers/` and `../reports/`
- eMule profile and preference materialization is shared from
  `emulebb-build-tests` via the workspace `deps.json`; p2p-overlord owns only
  scenario manifests, launch orchestration, and parity evidence shaping.
- p2p-overlord test code should not hand-write eMule `preferences.ini` files.
  Use the shared profile builder through `tests/e2e/lib/emulebb_shared.py`,
  then keep p2p-specific server, agent, and campaign setup in this repo.
- Generated eMule harness profiles are disposable run state. Retain full
  profiles only through explicit debug flags such as `--keep-sessions-running`;
  summaries and copied evidence stay as the normal diagnostic surface.

Do not add wrapper scripts. New reusable automation should be Python modules
under the owning package or pytest library.

## Repo Guards

- Shared quality expectations live in [Workspace Policy](./WORKSPACE_POLICY.md).
  Keep repo-specific enforceable gates mirrored in each repo's `AGENTS.md`.
- `python -m overlord_tooling quality-baseline` runs the non-live workspace
  quality baseline by orchestrating the canonical `cargo`, `npm`, `pytest`, and
  guard commands directly. It may write normal build, package, and test caches,
  but it must not edit tracked source.
- `python -m overlord_tooling hygiene-report` prints a JSON report covering repo
  cleanliness, largest tracked source files, Rust `allow` inventory, parity
  status, required environment variables, advisory source-size findings, and
  advisory internal API drift.
- `python -m overlord_tooling guard-source-size` reports tracked source files
  above the workspace source-size thresholds. It is advisory by default.
  `quality-baseline` runs ratchet mode against
  `docs/source-size-baseline.json`, which fails only when oversized files are
  new or have grown beyond their baseline. Use `--enforce` only when
  deliberately moving to a hard no-findings gate.
- `python -m overlord_tooling guard-line-endings` checks that tracked text files
  in canonical repos are normalized to UTF-8, LF line endings, final newline,
  and editorconfig trailing-whitespace policy.
- `python -m overlord_tooling normalize-source --write` applies that
  normalization policy. Without `--write`, it reports what would change.
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
- Source-size enforcement moves in stages: ratchet the current baseline while
  existing hotspots are being split, shrink or delete baseline entries as files
  are refactored, then hard-enforce only after current oversized files are
  reduced or explicitly accepted.
- LF is canonical for all tracked text files, including PowerShell, CMD, and
  batch files; `ext-deps` remains out of scope because those are upstream repos.
  The active ED2K server is no longer under `ext-deps`.

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
