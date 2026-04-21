# Scenarios

Versioned scenario contracts live here.

Scenario identifiers should stay stable and semantic, for example
`kad.startup.hello.publish.realnet.v1`.

The parity program uses three manifest kinds:

- `legacy` for obsolete scenario contracts retained as references
- `cell` for one canonical parity matrix cell
- `campaign` for a composed gate over one or more parity cells

Use `python -m overlord_tooling show-parity-matrix` to list the current KAD2 and
ED2K matrix inventory, including planned cells that still need deterministic
harness shaping.

Legacy `execution.command` values in manifests refer to removed runners. Native
parity E2E execution now belongs under `..\tests\e2e\`.

Current live-transfer coverage includes:

- `ed2k.server.emule-harness.agent.roundtrip.realnet.v1` for a real-network
  same-server ED2K roundtrip between the eMule harness and the agent
- `ed2k.server.roundtrip.realnet.large.v1` for the large-file real-network
  ED2K roundtrip gate on the modern `FileIdentifier` path
- `kad.search-download.emule-harness.agent.realnet.v1` for paired live Kad
  search and downstream ED2K download evidence

Current deterministic local transfer coverage includes:

- `ed2k.server.emule-harness.agent.roundtrip.private.large.v1` for same-host
  ED2K roundtrip evidence on the modern `FileIdentifier` /
  `OP_HASHSETREQUEST2` path
- `ed2k.server.agent.emule-harness.private.large.v1` for focused local
  agent->harness ED2K server-download evidence
- `kad.emule-harness.agent.download.private.large.v1` for harness->agent
  Kad-discovered large-file transfer on loopback
- `kad.agent.emule-harness.download.private.large.v1` for agent->harness
  Kad-discovered large-file transfer on loopback
