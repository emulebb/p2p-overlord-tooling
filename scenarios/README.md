# Scenarios

Versioned scenario contracts live here.

Scenario identifiers should stay stable and semantic, for example
`kad.startup.hello.publish.realnet.v1`.

The parity program uses three manifest kinds:

- `legacy` for the existing runnable scenario contracts
- `cell` for one canonical parity matrix cell
- `campaign` for a composed gate over one or more parity cells

Use `..\overlord-tooling.ps1 show-parity-matrix` to list the current KAD2 and
ED2K matrix inventory, including planned cells that still need deterministic
harness shaping.

Current live-transfer coverage includes:

- `ed2k.server.emule-harness.agent.roundtrip.realnet.v1` for a real-network
  same-server ED2K roundtrip between the eMule harness and the agent
- `kad.search-download.emule-harness.agent.realnet.v1` for paired live Kad
  search and downstream ED2K download evidence
