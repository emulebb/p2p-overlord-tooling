# eMule Harness Subsystem

Owns the eMule harness runtime lifecycle and local harness-specific mutation.

Primary responsibilities:

- build and locate the tracing-harness runtime
- start and stop harness sessions for parity and private scenarios
- mutate harness runtime configuration such as bind address, obfuscation, and
  server-met materialization
- extract harness trace evidence for scenario reports

Main orchestration consumers:

- Kad startup/publish scenarios
- private ED2K download scenarios
- local harness triplet validation
- real-network ED2K roundtrip and parity scenarios
