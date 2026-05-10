# Tooling Repo Rules

- Follow the shared workspace policy in `docs/WORKSPACE_POLICY.md`.
- Use `docs/README.md` as the canonical tooling docs home.
- Use `../p2p-overlord-be/BACKLOG.md` as the canonical active backlog.
- Implement only latest/current Kad and ED2K protocol behavior by default.
  Do not add legacy variants, obsolete fallbacks, or compatibility branches
  unless explicitly re-scoped by the user.
- Keep a stable top-level CLI surface and put reusable logic in structured
  platform directories.
- Add short header comments so purpose and expected inputs are obvious.
- Prefer tooling that orchestrates existing repo commands instead of
  re-implementing product logic here.
- Use versioned JSON contracts for manifests, summaries, and machine-readable
  reports.
- Keep tracked text files normalized to UTF-8 with LF endings; use
  `python -m overlord_tooling guard-line-endings` to verify and
  `python -m overlord_tooling normalize-source --write` to repair.
- Keep source-size policy ratcheted through
  `python -m overlord_tooling guard-source-size --ratchet`; do not add new
  oversized tracked source files or grow baselined oversized files.
- When touching oversized or locally complex tooling code, opportunistically
  split or simplify the touched area if the change is behavior-preserving,
  scoped, and covered by targeted checks.
- Keep subsystem-specific logic isolated under `subsystems/` when adding new
  platform features.
- Use `python -m overlord_tooling` for the supported tooling CLI.
- Do not add shell wrapper launchers.
