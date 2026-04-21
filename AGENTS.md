# Tooling Repo Rules

- Follow the shared workspace policy in `docs/WORKSPACE_POLICY.md`.
- Use `docs/README.md` as the canonical tooling docs home.
- Use `../p2p-overlord-be/BACKLOG.md` as the canonical active backlog.
- Keep a stable top-level CLI surface and put reusable logic in structured
  platform directories.
- Add short header comments so purpose and expected inputs are obvious.
- Prefer tooling that orchestrates existing repo commands instead of
  re-implementing product logic here.
- Use versioned JSON contracts for manifests, summaries, and machine-readable
  reports.
- Keep subsystem-specific logic isolated under `subsystems/` when adding new
  platform features.
- Use `python -m overlord_tooling` for the supported tooling CLI.
- Do not add shell wrapper launchers.
