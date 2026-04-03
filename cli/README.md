# CLI

Stable top-level command surface for the workspace tooling platform.

The root `../overlord-tooling.ps1` entrypoint delegates here so callers do not
depend on internal file layout.

Current built-in commands include:

- `help`
- `layout`
- `paths`
- `guard-tracked-files`
