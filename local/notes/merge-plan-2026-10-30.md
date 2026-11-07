# Merge analysis: origin/main (v26.11.1) into steering/upstream-pr — 2026-10-30

Merge-base 191da71d (v26.10.3). Ours: 18 commits (steering, all of it). Theirs: 346 commits, 2826 files,
+489k/-221k. This is NOT a conflict-resolution merge like 2026-10-23: upstream rewrote the source tree and the
five files that hold the fork's engine seams were deleted and split into ~2,300 files under
`src/{host,engines,sdk,plugins,abi,kernels,mlx}/`. Resolving the merge means re-porting the steering engine
code onto the new layout.

## 0. Status of the fork's upstream PR

- PR #538 (this branch) was converted to draft on 2026-10-04 and CLOSED 2026-10-07 by the owner: "we'd rather
  handle steering through the code launchers than in the server … If the launcher route turns out not to cover
  your use case, reopen it with that case." Upstream has no directional steering (its `SteeringNotes.swift` is
  the chat steering-note feature of #497, unrelated).
- So the fork stays a fork. Decide the strategy BEFORE spending the re-port effort (section 6).

## 1. Dry-run result (`git merge origin/main` in a scratch worktree, then discarded)

14 conflicting paths:

| Kind | Paths | Fork lines there |
|---|---|---|
| modify/delete (upstream deleted, fork edited) | `src/transformer.zig` | +807 (411 prod, ~397 tests) |
| | `src/hc_decode2.zig` | +94 (steer arms in the ND kernel + bind list + config cache) |
| | `src/scheduler.zig` | +67 (Slot pin, SubmitParams, LoadRequest flags, cold load) |
| | `src/server.zig` | +66 (route, `/props`, per-surface `requestSteering`) |
| | `src/generate.zig` | +7 (`steering_capture_dir` → ctx) |
| content, small | `src/main.zig` (3 blocks: imports, `steer` subcommand help, `--dir-steering-*` help) | |
| | `src/host/registry/model_settings.zig` (3 blocks: imports, `isEmpty`, log line) | |
| | `src/sdk/config/model.zig` (1: imports) | |
| | `src/tests.zig` (1: test-root imports) | |
| | `AGENTS.md` (2: whole layout table rewritten), `tests/CLAUDE.md` (1: our test row) | |
| | `app/…/ModelSettingsFile.swift` (1: `isEmpty` + `steering`), `app/…/ModelSettingsSheet.swift` (1: `ModelSettingsApply.row`) | |
| binary | `src/html/index.html` (take theirs, rebuild from `app-web/`) | |

Auto-merged cleanly (verified present in the scratch tree): `host/lan/lan.zig` (routeClass rows),
`host/registry/registry.zig` (`holdIfReady` + its test), `tests/dump_qwen4_exp_fixtures.py`, the Swift
`APIClient`/`ServerManager`/`StatusMenuView`/localizations, `docs/reference.md` (steering section),
`skills/mlx-serve/chat.md`, `app-web/src/lib/core/console.ts`. Fork-only files untouched: `src/steering.zig`,
`src/steering_http.zig`, `src/steering_cli.zig`, `tests/test_qwen4_steering.sh`, `tests/build_steering_bank.py`,
`app/…/Steering.swift`, `app/…/SteeringQuickBox.swift`, `tests/fixtures/steering/`.

The scratch tree would NOT compile: every fork import path (`"steering.zig"`, `"transformer.zig"`, …) is gone,
and `src/steering.zig` imports `mlx.zig`/`model.zig`/`log.zig` at the old paths.

## 2. Where each fork seam lives now

| Fork seam (old file) | Upstream home |
|---|---|
| `forwardQwen4With` attn/ffn steer seams, `steerPlan`, `hcWriteOrDefer(.steer)` | `src/plugins/qwen4_exp/forward.zig` (lines ~426-459: `hcReadPending` → `attn_out` → `hcWriteOrDefer` → `hcReadPending` → `mlp_out` → `hcWriteOrDefer`), `plugins/qwen4_exp/hc.zig` |
| grouped verify rows (`forwardQwen4VerifyRows`, joined read declines on differing steers) | `plugins/qwen4_exp/forward.zig:91-290`, `hc.zig:hcReadVerifyRows` |
| `HcPending{out,inj,steer}` | `plugins/qwen4_exp/hc_fused.zig:36` (`HcPending{out,inj}` today) |
| `hcReadFused` steer fold dispatch | `plugins/qwen4_exp/hc_fused.zig:138` (`hcReadFused`), `hc.zig:154` (`hcReadFusedFor`) |
| `hc_decode2.read(... pend)` + `Pending.steer` + ND bind list + config cache | `src/sdk/blocks/hc/hc_decode2.zig` (`Pending{out,inj}` at line 14, `read` at 140) |
| ND kernel source (`ST == 1/2` arms, `sd_in`/`ssc_in` inputs) | `src/kernels/hc/hc_decode2_nd.metal` (136 lines) + its sha256 line in `src/kernels/digests.txt` (the loader embeds by digest list) |
| CUDA arm (never folds) | `src/sdk/blocks/hc/hc_cuda.zig` — leave; standalone projection applies |
| `Transformer.steering`, `steeringSupported`, `ensureSteeringBanks` | the plugin's `Trunk` (`plugins/qwen4_exp/trunk.zig`); the legacy `engines/mlx/transformer.zig` no longer runs qwen4 (`served.legacy_removed`) |
| `ForwardCtx.steering` / `steering_dump` | `src/engines/mlx/forward_ctx.zig` — the plugin reads the engine ctx through `intree.enter` / `plugin.engineCtx` (a `SharedThreadLocal`), the same P8-debt path the MTP head uses |
| `Slot.steering_pinned`, pin release, `SubmitParams.steering` | `engines/mlx/slot.zig`, `engines/mlx/scheduler.zig`, `engines/mlx/scheduler/params.zig` AND `host/gpu_thread/params.zig` (host-side twin) |
| `LoadParams.steering_flags`, cold load re-apply, `armSteering` | `engines/mlx/load.zig` (`doLoadOnInferenceThread`), `engines/mlx/runtime/cold_load.zig`, `host/gpu_thread/requests.zig` |
| `generate.zig` capture dir → ctx | `engines/mlx/generate/generator.zig` |
| `ROUTE_PATHS` + `GET/POST /v1/steering` dispatch | `host/http/router.zig` (`isRoute` refuses a path missing from `ROUTE_PATHS` at compile time) |
| per-surface `requestSteering` (chat, completions, messages, stream/non-stream) | `host/api/chat_completions.zig`, `chat_stream.zig`, `completions.zig`, `anthropic.zig`, `submit.zig` |
| `/props` steering block | `host/api/props.zig` (`propsSettingsFor`, `settingsPropsJson`) |
| `steering_http.zig` | new `host/api/steering.zig` |
| `steering_cli.zig` | `host/cli/` |
| `model_settings.steering` (Setting, isEmpty, log) | `host/registry/model_settings.zig` + `model_settings_apply.zig` (`applyModelSettings` moved there) |
| `model.zig` `ModelConfig` steering override | `sdk/config/model.zig` (and/or `plugins/qwen4_exp/config.zig`: plugin parse now reads `settings_json`) |
| `main.zig` flags + `steer` subcommand | `src/main.zig` (same file; 3 conflict blocks) |
| `tests.zig` imports | `src/tests.zig` is now a flat list of ~340 paths; plus `-Dunits` roots (`host_unit.zig`, `engine_unit.zig`, generated `unit_<plugin>.zig`) |
| AGENTS.md rows | root layout table is now per-AREA; per-model rules live in `src/plugins/qwen4_exp/AGENTS.md` |

## 3. New upstream constraints the port must meet

House lint (`zig build lint`, `scripts/lint.py`; strict-failing rules today: `pin-unmatched`,
`source-scan-test`, `history-comment`; the rest report-only but are the direction of travel):

- **Layering**: `host/` may not import `engines/` or `plugins/`; `engines/mlx/` may not import `plugins/`
  (except via `plugin/intree.zig`, the declared debt file); a plugin imports only `sdk/ mlx/ abi/ plugins/`.
  → `steering.zig` must split: bank file registry + Setting parsing + HTTP (host); projection math, fold plan,
  Reservation pins (engine/plugin, under `sdk/` or `plugins/qwen4_exp/`).
- **`env-read`**: every env var registered in `src/env.zig` (`vars`, kind/owner/since/doc) and read through its
  accessors; `std.c.getenv` is forbidden. Fork reads `HOME` (registered), `MLX_SERVE_STEERING_DUMP_DIR`,
  `MLX_SERVE_STEER_FOLD`, `MLX_SERVE_STEER_FUSED` (three to register; the two kill switches as `.kill`, the dump
  dir as `.diag` → becomes a `MLX_SERVE_DIAG` token, which changes `tests/test_qwen4_steering.sh` and the doc).
- **`inline-kernel`**: no Metal source in Zig strings → the ST arms go into `kernels/hc/hc_decode2_nd.metal`
  (or a sibling file) and `kernels/digests.txt` gets the new sha256 (the loader's comptime list reads it).
- **`-Dunits`**: a global the host sets and a plugin unit reads must be a `Shared(T, name, init)` from
  `sdk/util/shared.zig` and listed in `shared_all.zig`; `scripts/unit_globals.py` fails on a duplicated plain
  global. Fork globals: the bank registry (8-LRU), `hc_decode2.config_builds`, `steered`, `steer_fold_logged`,
  the `*_logged` flags in transformer.zig.
- **`file-header`**: each `.zig` opens with `//!`. **`history-comment`** (ENFORCED): no "PR #", ISO dates, "used
  to" in comments — re-read every ported comment.
- **Kernel contract**: `plugins/qwen4_exp/contract*.zig` registers every Metal kernel the plugin launches; a changed
  ND kernel is re-registered there.
- **Proof tapes**: `plugins/qwen4_exp/fixtures/*.tape` are FROZEN replays of the legacy forward
  (`proof_test.zig`, `served_test.zig`). Steering OFF must stay bit-identical, which is the fork's own
  invariant ("off is bit-identical") — these tapes become the guard for it for free.
- **Per-request state across the plugin ABI**: `abi.Forward` (extern, `size`-versioned) has NO field for a
  request's steering. Options: (a) keep it on the engine `ForwardCtx` and read it in the plugin through
  `plugin.engineCtx` (how the MTP head and M-RoPE table already cross; in-tree only, matches the P8 debt
  list); (b) extend `abi.Forward` with a trailing field (ABI change, the plugin kit's header regenerates);
  (c) drop per-request steering and keep only the model's active default on the Trunk, set at load and by
  `POST /v1/steering`. Recommend (a) now, note it in the qwen4_exp AGENTS.md debt list.

## 4. Other things the merge drags in

- Three submodules were ABSORBED into the tree: `lib/sushi` (→ `sdk/quant/exl3/sushi`), `lib/mlx-serve-gguf`
  (→ `sdk/quant/gguf/`), `lib/mlx-stream` (→ `src/mlx_stream.zig` + `sdk/weights/streamed/`). After the merge:
  `git rm --cached` is done by the merge; delete the three working dirs and run `git submodule sync`. Remaining
  submodules: `lib/ds4`, `lib/mlx-src`, `lib/mlxc-src`, `lib/opencode2-mlx-serve`.
- `lib/mlxc-src` still carries the build script's gather_qmm patch in its working tree (expected, do not commit).
- Build: `build.zig` now delegates to `build/{macos,linux,ios,standalone,lint,plugins,test_runner}.zig`; new
  steps `zig build lint`, `-Dunits`; `scripts/unit_memory.py`. Re-read `## Building` after the merge.
- DiffusionGemma support was removed upstream (irrelevant to the fork, noted for the model list).
- Swift: our nested `enum Scale` in `Steering.swift` does not collide (upstream has none at file scope).
  `ModelSettingsSheet.swift` conflict: take upstream's `ModelSettingsApply.row(for:in:)`.
- `src/html/index.html`: take theirs, re-add the GET/POST `/v1/steering` rows in `console.ts` (already merged),
  `npm run build`, commit both; size ratchet in `app-web/test/size.test.ts` will move again.
- `notes/` is untracked; `stash@{0}` holds only a 7-line `tests/fwd_ubench.sh` tweak (drop or apply, unrelated).

## 5. Sizing

Fork production Zig to re-home: steering.zig ~1,110 prod lines (+726 tests), transformer.zig 411 prod (+397
tests), hc_decode2 94, scheduler 67, server 66, main 41, model_settings ~130, steering_http 312,
steering_cli 135 (+27 tests). Roughly 2,400 production lines, 1,150 test lines. The HTTP/CLI/registry/Swift
half moves with path edits; the engine half (~700 lines: forward seams, fold plan, HcPending, kernel ND arms,
grouped-verify decline, pins, cold-load flags) is a real port into an unfamiliar plugin layout plus the
`-Dunits`/env/kernel-file rules. Expect the port to be a multi-day job, not an afternoon.

## 6. Options for review

1. **Full re-port** (keeps every shipped behaviour incl. per-request steering, fold, capture). Steps:
   A. `git merge origin/main`; for the 5 modify/delete files `git rm` ours; resolve the 9 small content
      conflicts taking upstream's shape and keeping our rows; take theirs on `index.html`; temporarily drop
      `steering*.zig` from `tests.zig`/`main.zig` so the tree compiles (`zig build check`). Commit as the merge.
   B. Host half: `host/api/steering.zig` (from steering_http), router rows, per-surface `requestSteering`,
      `/props`, `host/cli/steer.zig`, `model_settings` + `model_settings_apply`, `main.zig` flags, `env.zig`
      registration, `Shared` for the bank registry.
   C. Engine/plugin half: `sdk/blocks/hc/hc_decode2.zig` `Pending.steer` + bind list + config cache;
      `kernels/hc/hc_decode2_nd.metal` ST arms + digest; `plugins/qwen4_exp/{hc_fused,hc,forward,trunk}.zig`
      seams + plan + fold + verify decline; `engines/mlx/{forward_ctx,slot,scheduler,load,runtime/cold_load,
      generate/generator}.zig` pins and flags; contract registration.
   D. Tests: unit tests follow their code; `proof_test` tapes pin steering-off; `tests/test_qwen4_steering.sh`
      re-run live (needs the 70 GiB pack unloaded from the app's server — see memory note); `zig build lint`
      clean on our files; `bash app/test.sh`; `zig build test`; ReleaseFast build.
2. **Reduced re-port**: drop the kernel fold (standalone projection only, ~2 extra dispatches per layer at
   decode — measure), drop capture/dump, keep per-model active default + `POST /v1/steering` + flags + app UI.
   Removes hc_decode2/kernel/digest/contract work and most of the transformer.zig prod lines; keeps the user-
   visible feature minus per-request `steering` if (c) in section 3 is chosen.
3. **Stay on v26.10.3** for the steering branch and treat upstream as a separate install; cheapest, forgoes
   v26.11.1 (Idol, Nemotron Transcribe, plugin kit, DSV4.1 speedups, hardening) until a later, larger jump.

Recommendation: 1 if steering is a long-lived fork feature (the plugin layout is the shape upstream will keep,
so the port is paid once; later merges should be small again), 2 if the fold and capture were PR polish rather
than needs. Not 3: the gap only grows, and upstream now moves qwen4_exp code inside its plugin dir where our
seams will keep landing.

## 7. Revised option 2 (2026-10-30, after review): ffn-only, model-level, fold kept

Inputs: the app only ever sets `ffn` (1); the perf commit 349b39d3 measured on M5 Max, mixed-4-8bit, both arms:
unsteered 65.08 tok/s, steered folded 64.57 (-0.8%), steered one-kernel-per-seam 62.92 (-3.3%); the op chain
(5 dependent dispatches per seam) sits below that. ffn-only halves the seams (48 layers, hc 4 x 2560, R 320).

Keep: banks (`~/.mlx-serve/steering/<name>.f32`), `steering` in model-settings.json, `--dir-steering-file/-ffn`,
`GET|POST /v1/steering`, `mlx-serve steer`, `/props` block, tray box + Model Settings row (both model-level, both
survive unchanged in kind), LAN deny, the fold at decode/verify/batched (<= 16 rows).
Drop: attn arm (ST 1, `projectRow`, every `attn` field incl. Swift), per-request `steering` body field (and with it
Reservation pins, 8-LRU, per-row plans, joined-read decline, the prefix-cache question), the private projection
kernel (`projectFused`, `MLX_SERVE_STEER_FUSED`), `MLX_SERVE_STEER_FOLD`, capture/dump (phase 2 if wanted: rides
`abi.Forward.capture_layers` + `ForwardOut.captured`, engine-side; the plugin already publishes the flushed stream).

Engine/plugin footprint (~150 prod lines over files with 1-2 upstream commits since the base):
- `sdk/blocks/hc/hc_decode2.zig`: `Pending.steer: ?Steer{dir [hidden], scale [1]}`, `Key.st`, dtype/size checks,
  bind list 9 -> 11 (`sd_in`, `ssc_in`), template `ST`. ~20 lines.
- `kernels/hc/hc_decode2_nd.metal`: after `written[i]` under `if (WR)`, the ST block: dot(d, v) by simd_sum + the
  8-way `npart` sum (barrier before reuse), `v -= cs*d`, store to `written`/`xv`. ~14 lines; new sha256 in
  `kernels/digests.txt`; `sdk/blocks/hc/contract.zig` nd inputs + one steered spec (~15 lines).
- `plugins/qwen4_exp/hc_fused.zig`: `HcPending.steer` pass-through (~6). `hc.zig`: `hcWriteOrDefer(.., steer)`:
  defer with the steer only when the two-launch read will take it (rows <= 16, fused on, Metal), else
  `hcWrite` + `projectStream` chain now (prefill, CUDA, declines); `hcFlush` same; `hcReadVerifyRows` passes the
  one shared steer (~20). `forward.zig`: the MLP-write seams pass `trunk.steerFor(layer)` (serial 459, verify 248;
  batched rides hcReadPending) (~6). The MTP head's own reads never receive a steer: unsteered by construction.
- `plugins/qwen4_exp/trunk.zig` + `sdk/.../steer_bank.zig`: `steer: ?Bank{dirs: [48]array bf16, scale}`, file read
  + size check (n_layers*hidden*4), `setSteering`, deinit (~90). Load-time: plugin `load` reads `steering` from
  `LoadCtx.settings_json` (verify the host serializes the key; `headMxfp8Setting` is the pattern).
- Live swap: a side-queue request (host `gpu_thread/requests.zig` kind + `runtime/loop.zig` drain, conn thread
  waits like unload) -> `intree` -> `trunk.setSteering` (~80). Leaner alternative: a `Shared` desired-state table
  keyed by model_dir the plugin re-reads at forward entry (~40) — less conventional.
Host (~600): `host/api/steering.zig`, router rows, props, `host/cli/steer.zig`, model_settings key, main flags;
the active setting per model is host state (set at load, updated after a confirmed POST), so GET/props never
query the engine. No env.zig entries (no kill switches, no dump dir). Swift: `SteeringOverride.configured(name,
ffn)`, one scale field; `ffn == 0` = off.

Parity bar: OFF stays bit-identical (the plugin's frozen proof tapes guard it for free). Fold vs chain is a
tolerance bar against fp32 truth (the fold reproduces the deleted private kernel's order, not mlx_sum's tree);
the same class of f32-order difference upstream accepts between its prefill norm and decode ND launches.

Cost: steered decode ~ -0.4% (half the fold's measured -0.8%), unsteered 0; steered prefill +~7 small dispatches
per layer per chunk, noise. Lost: per-request steering for API clients, the attn arm, capture until phase 2.

## Outcome (2026-10-30, same day)

Merged as 3afda6bd (upstream's side on every Zig conflict, steering files deleted; `zig build check` green before any
port). Then the port per `steering-port-adr-2026-10-30.md`:
- the fold in the SDK HC block (`Pending.steer`, the ND kernel's ST arm + digest, contract registration,
  tests: fold vs float64, multi-row steer parity, declines).
- (next commit) the plugin bank + hook (`plugins/qwen4_exp/steer.zig`, `Caps.dir_steering`,
  `ModelTable.apply_settings`), the engine's settings request (`SettingsRequest`, `settings_queue`, `applySettings`
  through `host/engines/mlx.zig`), the host's setting (`sdk/config/steering.zig`, `model_settings.steering`,
  `steering_override`, the driver's load JSON, `/props` `settings.steering`, `GET|POST /v1/steering`, `mlx-serve steer`,
  `--dir-steering-file/-ffn`), the app (one scale, picker + live apply restored on upstream's sheet), the console rows,
  docs, `tests/test_qwen4_steering.sh` rewritten for the new surface.

Verification on this box (the app's server holds the 70 GiB iQ pack throughout, so GPU memory is tight):
- `zig build check` green; `hc decode2` (64 tests), the contract drift guard, steering/steer/model_settings units green.
- Full `zig build test`: 5248 pass, 455 skip, 3 fail, 1 crash under memory pressure; re-run one at a time
  (`/tmp/msv_rerun.log`): see the final report.
- Swift: every steering test passes; `SystemMetricsTests.testAvailableBytesMatchesVmStat` (upstream, live memory
  counters) failed while the Zig shards ran.
- Console: build + size ratchet + vitest green.
- Live `tests/test_qwen4_steering.sh`: NOT run (needs the pack unloaded from the app's server, port 11234).

Re-runs one at a time (`/tmp/msv_rerun.log`), after the fixes they prompted:
- The index-page drift guard failed only against the console page compiled before the rebuild: green on the rebuilt page.
- `busy disk retry` and the `deepseek_v41 served: cancel ...` crash were MINE: both build a `Scheduler` by hand and now
  read the new `settings_queue` uninitialized (0xaa in Debug). Both tests set it; a rule line in
  `src/engines/mlx/AGENTS.md`. Green alone afterwards.
- The steered ND registration missed gate 3 by 2x: the reference multiplied by 0.7 where the device holds bf16(0.7).
  Fixed (`Cfg`'s `sc` is the bf16 value); the gates re-run is the check.
- Every other kernel-contract FAIL in the full run was a `nonfinite` class check or a Metal "Insufficient Memory"
  cascade with the app's 70 GiB pack resident and 8 shards running: not reproduced alone.

Commits: 3afda6bd merge, then ONE squashed feature commit (b0389f0e at the squash; the eight fold/app/feature/fix
commits it replaced are gone from history). Not pushed.
- Kernel contract gates alone on the final tree (`/tmp/kcg_current.log`): SUMMARY 515/515 kernels pass gates 1-4, 53
  known findings (the `FAIL nonfinite` lines are those, each followed by KNOWN), 8/8 controls red, all 62 tests pass.
  The steered ND registration passes every gate (shapes worst 0.988 of its bound: the allowance is right-sized, not
  loose). mlx-stream-test alone: green. A baseline run at the merge commit was no longer needed and was dropped.
- Full `zig build test` on the final tree: every shard green, exit 0 (`/tmp/test_full2.log`).

## Bank building after the port (2026-10-31)
- The new server has no capture; `tests/build_steering_bank.py` needs the old `steering_capture`. Existing banks load.
- The last capture-capable server (the Oct 23 app bundle, 26.10.3 fork) is preserved at
  `~/claude-tmp/steering-capture/MLX-Serve-26.10.3.app` (runs from there; `--help` shows `--dir-steering-attn`).
- Recommended port: `POST /v1/steering/build` + `mlx-serve steer build <name> --show --control`; the engine runs a cold
  prefill per prompt with `ForwardCtx.capture_layers` = every layer (the driver already forwards it to the plugin and
  reads `ForwardOut.captured`); the plugin publishes the stream after each layer's MLP write, the same row the old
  `dumpRow("ffn_out", h)` wrote (hc-mean, last token); host-side f64 math; refuse while steered. Not built yet.
- App bundle not rebuilt: the running app is the Oct 23 build. Release Swift compile checked green (2026-10-31).

## Live run and the load-time fix (2026-10-31, app quit)
- First live run of `tests/test_qwen4_steering.sh`: 46/51 (`~/claude-tmp/steering-live/live-run1.log`). All five
  failures were one bug: a bank set BEFORE load (Model Settings or `--dir-steering-file`) never armed. The load logged
  `[steering] setting skipped (BadSteeringPath)` while `GET /v1/steering` named the bank and POST to the loaded model
  worked.
- Cause: `std.json.Value` copies every string into the parse's arena (even from a slice). The plugin's `steerSpec`
  returned the bank path borrowed from a parse it freed on return; the ReleaseFast allocator reused the bytes before
  the stat. The live apply kept its parse alive across the bank load, which is why POST worked.
- Fix: `steer.Spec.on` is `steering.Configured` (path inline). Regression test red (reads 0xAA) then green;
  rule line in `src/plugins/AGENTS.md`, story in `docs/gotchas/models-media.md`. Audit: no other steering-port value
  outlives its parse (the HTTP handler holds its parse for the request; saved settings copy into `Configured`).
- Full `zig build test -Dslow-tests`: 34/34 steps, 4837/5222 passed, 385 skipped, 0 failed.
- Second live run: 51/51 (`~/claude-tmp/steering-live/live.log`, 9 min).
- App rebuilt (ad-hoc, `SKIP_NOTARIZE=1`): `app/MLX-Serve.app` + `app/MLX-Serve.dmg`, v26.11.1, codesign verify ok.
  The Oct 23 bundle it replaced is byte-identical to `~/claude-tmp/steering-capture/MLX-Serve-26.10.3.app`. The new
  bundle's server, booted on a scratch HOME holding copies of the real `model-settings.json` and the iQ bank, logged
  `[steering] armed: ... ffn=1 (48 layers x 2560)` at load (the old `{name, ffn, attn}` entry parses, and a test pins it).
