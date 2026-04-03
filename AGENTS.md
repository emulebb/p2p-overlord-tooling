# Tooling Repo Notes

- This repo contains reusable workspace tooling for the Overlord project.
- Use `docs/README.md` as the canonical tooling docs home.
- Follow the workspace instructions from `../AGENTS.md` in addition to this file.
- Use `../overlord-be/BACKLOG.md` as the canonical active backlog.
- Keep a stable top-level CLI surface and put reusable logic in structured platform directories.
- Legacy wrapper scripts may keep the `helper-<area>-<action>.ps1` format.
- Add short header comments so purpose and expected inputs are obvious.
- Prefer tooling that orchestrates existing repo commands instead of re-implementing product logic here.
- Use versioned JSON contracts for manifests, summaries, and machine-readable reports.
- Keep subsystem-specific logic isolated under `subsystems/` when adding new platform features.
- Use LF for tracked text files by default. `.ps1`, `.cmd`, and `.bat` may use CRLF.
- Do not store personal information or user-specific filesystem paths in tracked helper content.
