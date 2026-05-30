# Tooling Repo Rules

- Follow the eMuleBB workspace policy in
  `../emulebb-tooling/docs/WORKSPACE-POLICY.md` when this repo is checked out
  under `EMULEBB_WORKSPACE_ROOT\repos`.
- If the standalone p2p-overlord workspace is in use, also follow
  `docs/WORKSPACE_POLICY.md`.
- Use `docs/README.md` as the canonical tooling docs home.
- Use `../p2p-overlord-be/BACKLOG.md` as the canonical active backlog.
- Target full stock eMule `v0.72a` Kad and ED2K parity, including deprecated
  legacy compatibility behavior. The only standing protocol exception is
  defunct ED2K PeerCache support.
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
