# Pytest E2E Parity Scenarios

Native pytest scenarios live here. They orchestrate the agent, eMule tracing
harness, goed2k-server, payloads, and evidence checks directly from Python.

Legacy scenario runners were removed; pytest tests must stay native Python.

Common local commands:

```console
python -m pytest tests/e2e --collect-only
python -m pytest tests/e2e -m "local and ed2k" --run-e2e --file-size-bytes 127926272
python -m pytest tests/e2e -m "local and ed2k and plaintext" --run-e2e --file-size-bytes 10485760 --skip-runtime-build
```

Live scenarios must be explicitly enabled with `--run-live` once implemented,
and should only run with the VPN and UPnP prerequisites from the workspace
policy in place.
