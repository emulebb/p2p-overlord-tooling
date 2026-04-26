# Session Resume

This file is written only when terminating a working session. Treat it as the
handoff for the next session, not as a continuously maintained status page.

## Timestamp

- Written: 2026-04-26
- Workspace: `C:\prj\p2p\p2p-overlord`
- eMule tracing harness: `C:\prj\p2p\eMule-workspace\workspaces\v0.72a\app\eMule-v0.72a-tracing-harness`

## Current Git State

Tooling `develop` is pushed through:

- `43658d2 Bind startup live agent by interface alias`
- `5610697 Stop eMule harness profile descendants`
- `5fa9dc1 Bind live agents by interface alias`

Agents `develop` is pushed through:

- `a465070 Try plaintext after optional obfuscated peer failure`
- `04d9027 Keep ED2K enrich control path responsive`
- `b4e4a6e Reconcile P2P runtime on interface IP changes`
- `24a0027 Retry ED2K downloads after source refresh`
- `a02713a Broaden Kad source fallback window`
- `576892f Align ED2K UDP source search with eMule`

## Process State At Handoff

The interrupted p2p-overlord focused obfuscated live run was terminated:

- stopped pytest process for `kad2.cell.keyword.search.obfuscated.realnet.v1`
- stopped `overlord-agent-emule.exe` using `C:\tmp\overlord-tmp\agent-real-miniupnpc.toml`

Do not kill unrelated `eMule-build-tests` processes unless explicitly working on
that suite. They use paths like `C:\tmp\emule-live-e2e-suite-*`.

## What Improved

- Live agent configs now bind P2P by `bind_iface = "hide.me"` and leave `bind_ip = ""`, so long realnet runs are not pinned to stale VPN IPv4 addresses.
- The agent reconciles P2P runtime when the selected interface resolves to a new IPv4 address.
- Active agent config snapshots are copied into artifacts as `agent-real-miniupnpc.active.toml`.
- Harness stop now performs profile-scoped descendant cleanup.
- ED2K enrich no longer blocks the control API on manifest inspection before spawning background download work.
- Direct ED2K download now tries a plaintext peer session after an optional obfuscated peer attempt fails, while preserving crypt-required sources.

## Validated

Tooling:

- `python -m pytest tests\e2e\test_agent_runtime.py tests\e2e\test_scenario_catalog.py tests\e2e\test_processes.py -q`
- `python -m py_compile tests\e2e\lib\kad_startup_live.py`

Agents:

- `cargo fmt -p overlord-agent-emule`
- `cargo test -p overlord-agent-emule p2p_interface_reconcile_target -- --nocapture`
- `cargo test -p overlord-agent-emule native_direct_download -- --nocapture`
- `cargo test -p overlord-agent-emule plaintext_fallback -- --nocapture`
- `cargo build -p overlord-agent-emule --bin overlord-agent-emule`

Live:

- Full realnet campaign passed once after interface binding and cleanup work:
  `kad2.campaign.realnet-confidence.v1`, run members from `20260426-040238`,
  `20260426-040757`, and `20260426-041125`.
- Startup live cell passed after startup was switched to interface binding:
  `kad2.cell.startup.hello.publish.realnet.v1.plaintext-20260426-042925`.
- Later full campaign progressed past startup and plaintext:
  - startup: `startup-publish.plaintext-20260426-063619`, completed
  - plaintext: `keyword-search-plaintext.plaintext-20260426-064057`, completed after 4 attempts
  - obfuscated: `keyword-search-obfuscated.obfuscated-20260426-070727`, failed after 20 candidates

## Current Parity Gap

The remaining active failure is obfuscated realnet download completion, not bind
selection and not control API responsiveness.

Latest useful failure:

`C:\tmp\overlord-tmp\overlord-tooling\runs\kad2.campaign.realnet-confidence.v1\keyword-search-obfuscated.obfuscated-20260426-070727\run-summary.json`

Observed:

- 20 candidates attempted.
- Candidate source acquisition usually found one direct source.
- No candidate obtained AICH or payload bytes.
- Repeated direct Kad source was `195.154.51.215:14662`.
- Obfuscated direct sessions were closed/reset by the peer.
- ED2K server source searches often timed out or refused connections.
- No stale `bind_ip` failure appeared in this run.

The latest focused obfuscated run was interrupted before a `run-summary.json` was written:

`C:\tmp\overlord-tmp\overlord-tooling\runs\kad2.cell.keyword.search.obfuscated.realnet.v1\kad2.cell.keyword.search.obfuscated.realnet.v1.obfuscated-20260426-092029`

## Next Steps

1. Rerun the focused obfuscated live cell first:

   ```powershell
   $env:OVERLORD_LIVE_INTERFACE_ALIAS='hide.me'
   Remove-Item Env:OVERLORD_LIVE_BIND_IP -ErrorAction SilentlyContinue
   python -m pytest tests\e2e\test_parity_scenarios.py --run-e2e --run-live --skip-runtime-build -k "kad2.cell.keyword.search.obfuscated.realnet.v1" -q
   ```

2. Inspect whether commit `a465070` produces plaintext fallback attempts in the ED2K TCP dump and agent log:

   - look for `native ED2K download scheduling plaintext fallback`
   - compare `agent-ed2k-tcp-dump-*.jsonl` transport modes for the same peer
   - verify whether `OP_HELLO`, `OP_HELLOANSWER`, and `OP_STARTUPLOADREQ` appear after fallback

3. If obfuscated still fails with the same one-source pattern, extend source acquisition rather than increasing candidate count blindly:

   - keep failed direct peers suppressed across requery rounds
   - allow more Kad source lookup attempts for obfuscated runs when the same direct source repeats
   - consider server source search endpoint rotation away from repeatedly refusing endpoints

4. After focused obfuscated passes, rerun full campaign:

   ```powershell
   $env:OVERLORD_LIVE_INTERFACE_ALIAS='hide.me'
   Remove-Item Env:OVERLORD_LIVE_BIND_IP -ErrorAction SilentlyContinue
   python -m pytest tests\e2e\test_parity_scenarios.py --run-e2e --run-live --skip-runtime-build -k "kad2.campaign.realnet-confidence.v1" -q
   ```

5. Keep granular commits and pushes after each confirmed improvement.

## Notes

- Disk was previously at 0 bytes free due to generated artifacts. Old
  p2p-overlord run artifacts under `C:\tmp\overlord-tmp\overlord-tooling\runs`
  were cleaned, freeing substantial space. Recheck `Get-PSDrive C` before long
  live runs.
- The live environment is noisy. A campaign pass can still be followed by a
  later live failure due to peer/server availability. Preserve run summaries and
  make code changes only when the artifact points to a deterministic agent or
  harness gap.
