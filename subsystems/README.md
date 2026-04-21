# Subsystems

Subsystems used to own internal runtime wrappers. The wrapper files were
removed; native pytest libraries now own active runtime orchestration.

Historical ownership areas were:

- `agent/` agent runtime control, local config materialization, session
  metadata, and post-download helpers
- `emule-harness/` harness build, runtime control, profile mutation, and trace
  extraction
- `goed2k/` local goed2k-server runtime and config helpers
- `network/` shared adapter and bind-address resolution
- `ed2k/` shared ED2K server selection and rotation helpers
- `pcap/` passive capture and offline packet analysis helpers
- `parity/` parity comparison utilities
- `kad/` Kad-specific normalization and future protocol tooling

Do not add wrapper scripts here. Active parity orchestration belongs under
`../tests/e2e/lib/` or a Python package with direct tests.
