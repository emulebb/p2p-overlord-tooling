# Pytest E2E Parity Scenarios

Native pytest scenarios live here. Manifest-backed parity cells and campaigns
are collected through `test_parity_scenarios.py`, which resolves
`scenarios/**/manifest.v1.json` and dispatches to registered native Python
runners.

Legacy scenario runners were removed; pytest tests must stay native Python.
Thin one-file wrappers for individual parity cells are intentionally avoided.
If a new scenario is runnable, add a manifest command and register the real
runner instead.

Common local commands:

```console
python -m pytest tests/e2e --collect-only
python -m pytest tests/e2e -m "local and ed2k" --run-e2e --file-size-bytes 127926272
python -m pytest tests/e2e -m "local and ed2k and plaintext" --run-e2e --file-size-bytes 10485760 --skip-runtime-build
python -m overlord_tooling parity-status --availability available
```

Live scenarios must be explicitly enabled with `--run-live` once implemented,
and should only run with the VPN and UPnP prerequisites from the workspace
policy in place.

Current parity status:

- ED2K private parity covers direct download, callback/source acquisition,
  Kad-assisted source fallback, AICH/hashset, compressed parts, and local
  roundtrip behavior.
- KAD2 live startup/publish plus plaintext and obfuscated keyword
  search/download have passing real-network evidence. The obfuscated transfer
  gate passed on April 26, 2026 with run
  `kad2.cell.keyword.search.obfuscated.realnet.v1.obfuscated-20260426-204828`.
- KAD2 private triplet cells are collected through the native
  `kad2.private.harness-triplet` runner, which uses the v0.72a tracing harness
  triplet for deterministic bootstrap, publish, and search parity evidence.
