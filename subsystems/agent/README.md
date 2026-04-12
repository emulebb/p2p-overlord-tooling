# Agent Subsystem

Owns local agent runtime control and agent-owned scenario helpers.

Primary responsibilities:

- start and stop agent sessions for parity, private ED2K, and soak workflows
- materialize local agent config and networking state
- expose session metadata used by orchestration
- run agent-side search, download enrichment, and transfer collection helpers

Main orchestration consumers:

- Kad startup/publish scenarios
- private ED2K download scenarios
- local triplet validation
- real-network ED2K roundtrip and parity scenarios
