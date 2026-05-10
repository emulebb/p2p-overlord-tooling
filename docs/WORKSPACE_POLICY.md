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
- Current Kad and ED2K work targets full stock eMule `v0.72a` parity,
  including deprecated legacy compatibility behavior when stock eMule still
  implements or advertises it. The only standing ED2K protocol exception is
  defunct PeerCache support: do not advertise or implement `OP_PEERCACHE_*`
  behavior unless the user explicitly re-scopes it. Use the parity target to
  keep capability adverts truthful and peer behavior acceptable, while still
  prioritizing live acceptance and harvest evidence over cosmetic behavior
  matching.

## Canonical Locations

- `%OVERLORD_PROJECT_DIR%\p2p-overlord-agents` is the Rust agents repo.
- `%OVERLORD_PROJECT_DIR%\p2p-overlord-be` is the backend repo.
- `%OVERLORD_PROJECT_DIR%\p2p-overlord-ed2k-server` is the active local ED2K
  server repo.
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
- Do not add a separate ED2K server path environment variable; derive the
  active server checkout from `%OVERLORD_PROJECT_DIR%`.

## Code And Repo Hygiene

- Add clear comments and doc comments where they materially explain protocol,
  state, or non-obvious behavior.
- Do not reinvent the wheel when an existing crate, package, or library fits.
- Prefer granular commits and small coherent changes.
- Persist reusable automation, scenarios, profiles, schemas, and helper logic
  under `%OVERLORD_PROJECT_DIR%\p2p-overlord-tooling`.
- Do not add shell wrapper launchers to the canonical repos.
- Tracked text files use LF by default.
- Do not store personal information, user-specific filesystem paths, or
  user-identifying data results in tracked source or markdown files.

## Quality And Refactoring Policy

- Treat repo-local `AGENTS.md` files as the enforceable mirror for commands and
  gates that differ by repo. Shared workspace policy belongs here.
- Run narrow checks for the area changed first, then run the required
  repo-local gate before finishing. Use
  `python -m overlord_tooling quality-baseline` from the tooling repo for the
  non-live workspace baseline.
- Keep source-size policy ratcheted while existing oversized files are being
  split. Do not add new oversized tracked source files or grow baselined
  oversized files. Shrink or remove baseline entries as files are reduced.
- When touching source that is already oversized, near a source-size threshold,
  or locally complex, opportunistically split or simplify only the touched area
  when the cleanup is behavior-preserving, scoped, and covered by targeted
  checks. Do not mix broad style churn with feature or bug-fix work.
- For Rust, treat `rustfmt` output as canonical and keep public-facing items
  documented with `///` or `//!`. The agents repo promotes
  `clippy::too_many_arguments`, `clippy::type_complexity`, and
  `clippy::cognitive_complexity`; keep `clippy::too_many_lines` advisory until
  the oversized-file inventory is cleared.
- Keep `#[allow(...)]` attributes narrow and local to the behavior that needs
  them. Prefer removing stale allowances during nearby refactors.
- Keep line-ending, tracked-file privacy, and workspace-convention guards clean:
  UTF-8 text, LF endings, final newline, no local path leaks, and no repo-local
  shell wrapper launchers.

## Testing And Runtime Operations

- When testing, refactoring, or investigating issues, attach a debugger when
  practical.
- When testing agents on the real network, bind P2P traffic to the VPN
  interface and enable UPnP.
- Verify UPnP mappings with `C:\bin\overrides\miniupnpc.exe -l`.
- Use the following canonical live-wire stress search terms for download and
  network-behavior validation unless a scenario requires another value:
  `linux`, `ubuntu`, `fedora`, `freebsd`, `debian`, `emule`.

## eMule Harness Policy

- The runnable eMule reference build is called `emule-harness` in shared docs,
  tooling, scenarios, and artifacts.
- The only mutable app variant for parity work is the tracing harness at
  `%EMULE_WORKSPACE_ROOT%\workspaces\v0.72a\app\eMule-v0.72a-tracing-harness`.
  Do not patch other app variants for this workspace program.
- p2p-overlord tooling consumes the existing `tracing-harness` debug output
  from the canonical workspace path. Build orchestration for the external
  eMule workspace is not invoked from this repo.
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

- The system is Windows-first today, but keep Windows-specific logic isolated
  so future multi-platform support stays viable.
- Avoid Windows command-length failures by breaking work into file-sized
  patches or direct package commands when needed.
