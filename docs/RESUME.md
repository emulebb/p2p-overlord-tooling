# Session Resume

This file is written only when terminating a working session. Treat it as the
handoff for the next session, not as a continuously maintained status page.

## Timestamp

- Written: 2026-04-26
- Workspace: `C:\prj\p2p\p2p-overlord`
- eMule tracing harness: `C:\prj\p2p\eMule-workspace\workspaces\v0.72a\app\eMule-v0.72a-tracing-harness`

## Current Git State

Agents `develop` is clean and pushed to origin through:

- `59e19a7 Skip source refresh for exhausted ED2K endpoints`
- `bc955d3 Suppress exhausted ED2K direct endpoints`

Tooling `develop` is pushed to origin through:

- `40d9bc2 Accept uncompressed ED2K payload evidence`
- `bfa4c63 Bound live Kad search download cells`

Tooling has uncommitted documentation edits:

- `docs/RESUME.md`
- `scenarios/README.md`
- `tests/e2e/README.md`

Backend has one uncommitted backlog edit:

- `BACKLOG.md`

These doc/backlog edits record that the obfuscated KAD2 live cell passed and
should be reviewed/committed next.

## Process State At Handoff

The interrupted `kad2.campaign.realnet-confidence.v1` run left these processes,
and they were stopped before handoff:

- pytest process `5968`
- `overlord-agent-emule.exe` process `18780`

Unrelated Python processes were left alone:

- `python c:\prj\p2p\yscripts\Plex-Auto-Languages\main.py`
- `python c:\prj\p2p\yscripts\qbautom\qb_scheduler_main.py`

## What Improved

- Live bind IP resolution now derives from the `hide.me` interface alias rather
  than stale hard-coded values.
- Live Kad search/download cells now have a bounded 40-minute budget and
  bounded per-candidate transfer timeout.
- Direct ED2K downloads suppress exhausted endpoints by `ip:port` so repeated
  user-hash/obfuscation variants do not burn the cell budget.
- The agent now skips a source refresh when all known direct endpoints are
  exhausted and the manifest has no transfer progress.
- Live tooling now records candidate terminal reasons such as
  `completed`, `source_search_timeout`, and `no_progress_repeated_endpoints`.
- ED2K payload evidence now accepts valid uncompressed part opcodes
  `OP_SENDINGPART` / `OP_SENDINGPART_I64`, not only compressed part opcodes.

## Validated

Tooling:

- `python -m pytest tests\e2e\test_kad_live.py tests\e2e\test_kad_live_evidence.py -q`
- `python -m pytest tests -q` passed with `51 passed, 41 skipped`
- `python -m overlord_tooling guard-tracked-files`
- `python -m overlord_tooling guard-workspace-conventions`

Agents:

- `cargo test -p overlord-agent-emule no_progress_source_requery -- --nocapture`
- `cargo test -p overlord-agent-emule direct_download_candidates -- --nocapture`
- `cargo test -p overlord-agent-emule native_direct_download -- --nocapture`
- `cargo test -p overlord-agent-emule source -- --nocapture`
- `cargo fmt --all --check`
- `cargo build -p overlord-agent-emule --bin overlord-agent-emule`

Live:

- Focused obfuscated live cell passed:
  `kad2.cell.keyword.search.obfuscated.realnet.v1.obfuscated-20260426-204828`
- Command used:

  ```powershell
  $env:OVERLORD_LIVE_INTERFACE_ALIAS='hide.me'
  python -m pytest tests\e2e\test_parity_scenarios.py --run-e2e --run-live --skip-runtime-build -k "kad2.cell.keyword.search.obfuscated.realnet.v1" -q
  ```

- Result: `1 passed, 28 deselected in 565.92s (0:09:25)`
- Summary path:
  `C:\tmp\p2p-overlord\overlord-tooling\runs\kad2.cell.keyword.search.obfuscated.realnet.v1\kad2.cell.keyword.search.obfuscated.realnet.v1.obfuscated-20260426-204828\run-summary.json`

## Current Interrupted Run

After pushing the code commits and editing docs/backlog, the broader live
confidence campaign was started and then intentionally interrupted by the user:

```powershell
$env:OVERLORD_LIVE_INTERFACE_ALIAS='hide.me'
python -m pytest tests\e2e\test_parity_scenarios.py --run-e2e --run-live --skip-runtime-build -k "kad2.campaign.realnet-confidence.v1" -q
```

Artifacts from that interrupted campaign:

- Startup cell completed and wrote:
  `C:\tmp\p2p-overlord\overlord-tooling\runs\kad2.campaign.realnet-confidence.v1\startup-publish.plaintext-20260426-210203\run-summary.json`
- Plaintext keyword-search cell started at:
  `C:\tmp\p2p-overlord\overlord-tooling\runs\kad2.campaign.realnet-confidence.v1\keyword-search-plaintext.plaintext-20260426-210652`
- No `run-summary.json` existed for the interrupted plaintext cell at handoff.

## Known Caveat

The repo-required clippy command is currently blocked by an unrelated existing
lint:

```text
cargo clippy --workspace --all-targets --all-features -- -D warnings -W clippy::all
crates\overlord-agent-emule\src\ed2k_server.rs:1912
clippy::too_many_arguments on search_source_udp_servers
```

That API shape was not changed in this session.

## Next Steps

1. Review and commit the uncommitted documentation/backlog edits:

   - `p2p-overlord-tooling/docs/RESUME.md`
   - `p2p-overlord-tooling/scenarios/README.md`
   - `p2p-overlord-tooling/tests/e2e/README.md`
   - `p2p-overlord-be/BACKLOG.md`

2. Rerun the full realnet confidence campaign from a clean process state:

   ```powershell
   $env:OVERLORD_LIVE_INTERFACE_ALIAS='hide.me'
   python -m pytest tests\e2e\test_parity_scenarios.py --run-e2e --run-live --skip-runtime-build -k "kad2.campaign.realnet-confidence.v1" -q
   ```

3. If the campaign flakes, preserve each `run-summary.json` and rerun only the
   failed cell once before changing code.

4. Treat the clippy `too_many_arguments` failure as a separate cleanup slice if
   the next session needs a fully green repo-required clippy gate.
