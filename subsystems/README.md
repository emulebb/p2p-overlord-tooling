# Subsystems

Subsystems own the internal implementation of the tooling platform.

The intended split is:

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

These scripts are internal implementation detail. Orchestration and the stable
CLI may depend on them, but contributors should not treat their individual file
paths as operator-facing API.

Internal conventions:

- `RuntimeContext.ps1` owns repo-root resolution, shared path assertions, and internal script invocation
- `*Subsystem.ps1` files are the supported internal entry modules for orchestration and CLI code
- `helper-*` scripts under subsystem folders are implementation detail behind those entry modules
