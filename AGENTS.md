# Tooling Repo Notes

- This repo contains reusable workspace tooling for the Overlord project.
- Use `docs/README.md` as the canonical tooling docs home.
- Follow the workspace instructions from `../AGENTS.md` in addition to this file.
- Use `../p2p-overlord-be/BACKLOG.md` as the canonical active backlog.
- Keep a stable top-level CLI surface and put reusable logic in structured platform directories.
- Legacy wrapper scripts may keep the `helper-<area>-<action>.ps1` format.
- Add short header comments so purpose and expected inputs are obvious.
- Prefer tooling that orchestrates existing repo commands instead of re-implementing product logic here.
- Use versioned JSON contracts for manifests, summaries, and machine-readable reports.
- Keep subsystem-specific logic isolated under `subsystems/` when adding new platform features.
- Guard tracked files against user-profile paths and personal-name file leaks.
  - Do not commit content containing local Windows or Unix user-home path fragments.
  - Do not commit tracked filenames that embed personal identifiers such as local usernames.
  - Do not hardcode real personal identifiers in tracked policy files; use local untracked policy or environment configuration for repo-specific identifier checks.
  - Keep the tracked-file privacy guard passing locally and in CI.
- Use LF for tracked text files by default. `.ps1`, `.cmd`, and `.bat` may use CRLF.
- Do not store personal information or user-specific filesystem paths in tracked helper content.
- Oracle seed source paths must stay out of tracked files. Import operator-local
  `nodes.dat` and `server.met` through the untracked local seed bundle flow.
- Seeded oracle `preferences.ini` files must contain only the manifest-owned
  minimal settings needed for the active harness scenario.
