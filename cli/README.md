# CLI

Stable top-level command surface for the workspace tooling platform.

The root `../overlord-tooling.ps1` entrypoint delegates here so callers do not
depend on internal file layout.

`CommandRegistry.ps1` is the single source of truth for script-backed commands,
their descriptions, and dispatch targets. Keep help text and routing derived
from the registry instead of duplicating command metadata in the entry script.

Current built-in commands include:

- `help`
- `layout`
- `paths`
- `guard-tracked-files`
