# Helper Repo Notes

- This repo contains reusable workspace helper scripts for the Overlord project.
- Use `docs/README.md` as the canonical helper docs home.
- Follow the workspace instructions from `../AGENTS.md` in addition to this file.
- Use `../overlord-be/BACKLOG.md` as the canonical active backlog.
- Keep helper names in the `helper-<area>-<action>.ps1` format.
- Add short header comments so purpose and expected inputs are obvious.
- Prefer helpers that orchestrate existing repo commands instead of re-implementing product logic here.
- Use LF for tracked text files by default. `.ps1`, `.cmd`, and `.bat` may use CRLF.
- Do not store personal information or user-specific filesystem paths in tracked helper content.
