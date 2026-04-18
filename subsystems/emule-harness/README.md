# eMule Harness Subsystem

Owns the eMule harness runtime lifecycle and local harness-specific mutation.

Primary responsibilities:

- build and locate the tracing-harness runtime
- start and stop harness sessions for parity and private scenarios
- mutate harness runtime configuration such as bind address, obfuscation, and
  server-met materialization
- extract harness trace evidence for scenario reports

Current contract:

- only the canonical `Debug` x64 tracing-harness build is supported in this
  workspace
- both parity and private scenario launchers use the canonical
  `eMule_v072a_parity.exe` runtime from the tracing-harness debug directory
- private startup validates the same ready-state contract as parity startup

Main orchestration consumers:

- Kad startup/publish scenarios
- private ED2K download scenarios
- local harness triplet validation
- real-network ED2K roundtrip and parity scenarios
