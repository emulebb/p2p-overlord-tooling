# Workspace Policy

Canonical shared policy for the `%OVERLORD_PROJECT_DIR%` workspace.

Repo-local `AGENTS.md` files should point here and keep only repo-specific
rules, quality gates, or deltas that are not shared across the workspace.

## Workspace Goals

- Primary objective for Kad and eD2k work: maximize harvest yield on the real
  network.
- Treat wire parity as a hard requirement whenever it affects
  interoperability, acceptance, or how suspicious traffic looks on the wire.
- Do not treat full behavior parity with the eMule harness as a goal by
  itself.
- Keep eMule harness behavior only when it materially improves acceptance,
  reachability, or harvest yield.
- Prefer Overlord-specific behavior when it increases harvest throughput or
  stability without breaking wire compatibility.

## Canonical Locations

- `%OVERLORD_PROJECT_DIR%\p2p-overlord-agents` is the Rust agents repo.
- `%OVERLORD_PROJECT_DIR%\p2p-overlord-be` is the backend repo.
- `%OVERLORD_PROJECT_DIR%\p2p-overlord-tooling` is the shared tooling repo.
- `%OVERLORD_PROJECT_DIR%\p2p-overlord-be\docs\README.md` is the canonical
  workspace/spec docs home.
- `%OVERLORD_PROJECT_DIR%\p2p-overlord-be\BACKLOG.md` is the canonical active
  backlog.
- `%OVERLORD_PROJECT_DIR%\p2p-overlord-agents\docs\README.md` is the canonical
  agents/protocol docs home.
- Service and package names remain on the stable `overlord-*` prefixes even
  though repo directories use `p2p-overlord-*`.

## Path And Environment Rules

- Do not hardcode local absolute workspace paths in shared docs, scripts, or
  tracked config.
- Use `%OVERLORD_PROJECT_DIR%` for workspace repo paths.
- Use `%EMULE_WORKSPACE_ROOT%` for eMule workspace, build, and runtime paths.
- Use `%OVERLORD_TMP_DIR%` for temporary run roots and sample simulations.
- Use `%OVERLORD_LOG_DIR%` for coordinator and agent log discovery.

## Code And Repo Hygiene

- Add clear comments and doc comments where they materially explain protocol,
  state, or non-obvious behavior.
- Do not reinvent the wheel when an existing crate, package, or library fits.
- Prefer granular commits and small coherent changes.
- Persist reusable automation, scenarios, profiles, schemas, and helper logic
  under `%OVERLORD_PROJECT_DIR%\p2p-overlord-tooling`.
- Thin PowerShell wrappers may use `helper-<area>-<action>.ps1`, but reusable
  logic belongs in the structured tooling layout.
- Tracked text files use LF by default. `.ps1`, `.cmd`, and `.bat` may use
  CRLF.
- Do not store personal information, user-specific filesystem paths, or
  user-identifying data results in tracked source or markdown files.

## Testing And Runtime Operations

- When testing, refactoring, or investigating issues, attach a debugger when
  practical.
- When testing agents on the real network, bind P2P traffic to the VPN
  interface and enable UPnP.
- Verify UPnP mappings with `C:\bin\overrides\miniupnpc.exe -l`.
- Use `ubuntu linux` as the canonical search term for live validation unless a
  scenario requires another value.

## eMule Harness Policy

- The runnable eMule reference build is called `emule-harness` in shared docs,
  tooling, scenarios, and artifacts.
- The only mutable app variant for parity work is the tracing harness at
  `%EMULE_WORKSPACE_ROOT%\workspaces\v0.72a\app\eMule-v0.72a-tracing-harness`.
  Do not patch other app variants for this workspace program.
- All eMule harness builds must go through the canonical eMule-build entrypoint
  from `%EMULE_WORKSPACE_ROOT%`:
  - `%EMULE_WORKSPACE_ROOT%\repos\eMule-build\workspace.ps1 build-app`
  - `-EmuleWorkspaceRoot %EMULE_WORKSPACE_ROOT%`
  - `-Config Debug`
  - `-Platform x64`
- `build-app` builds the workspace app set; harness tooling then consumes the
  `tracing-harness` output from the canonical workspace path.
- Do not present direct raw output directories as the supported primary build
  flow.
- Before launching the harness on the real network, ensure the active profile
  binds to the current `hide.me` VPN IPv4 address.
- Seeded harness `preferences.ini` files must contain only the minimal
  scenario-owned settings needed for the active run.
- Canonical `nodes.dat` and `server.met` inputs belong to the untracked local
  emule-harness seed bundle flow and must not persist operator-local source
  paths.

## Coordinator Database Policy

- Keep naming consistent across SQL, Prisma, TypeScript, routes, and UI DTOs.
- Persisted SQL objects use `snake_case`.
- Prisma is the translation layer and the only coordinator schema source in
  this phase.
- Prisma model names may be `PascalCase`; Prisma field names must be
  `camelCase`.
- Every mapped SQL table must use `@@map`; every mapped SQL column must use
  `@map`.
- Reset and rebuild the local DB from the current Prisma schema instead of
  preserving migration history in this phase.
- After coordinator schema changes, validate Prisma, rebuild the DB, confirm
  `snake_case` persisted names, and run coordinator type checks.

## Current-Phase Rules

- Database compatibility is not a goal.
- API compatibility is not a goal.
- Configuration compatibility is not a goal.
- Resetting and recreating local state is preferred over preserving historical
  compatibility.

## Operational Constraints

- Treat the direct coordinator and agent `.cmd` launcher scripts as stable
  operator entrypoints. Change them only when required to preserve canonical
  repo layout or operator runtime correctness.
- The system is Windows-first today, but keep Windows-specific logic isolated
  so future multi-platform support stays viable.
- Avoid Windows command-length failures by breaking work into file-sized
  patches or helper scripts when needed.
