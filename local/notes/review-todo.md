# Steering PR: style review todo

Excluded (kept by decision): the `hcReadJoined` steer guard; the `steering_flags` needle in
the cold-load scan test.

## Safety
- [x] Swift tests: rename bank `"refusal"` -> `terse` / `verbosity` (14x)
- [x] reference.md: delete "nothing to do with safety" sentence
- [x] test script + steering.zig comment: drop "lab" wording on steering_capture_steered
- [x] CHANGELOG: drop "studying the steered stream" (one-sentence rewrite)
- [x] test script: rename "refusal names SteeringFileSize" label

## Experimental code
- [x] remove `fwdUbenchSteerLadder` (also reverted tests/fwd_ubench.sh to main) (scheduler) + `Transformer.steer_diag_flush_only` + `MLX_SERVE_DECODE_FWD_UBENCH_STEER` doc refs

## steering.zig
- [x] history comments: reserve doc, foldEnabled doc, ProjectCfgKey doc, cfg-cache comment, projectStream assert comment, swapDefault parenthetical
- [x] wrong/restating comments: defaultPathInto "returns slice", "input is untouched" x2, scalarAs duplicate rationale, settingFromFlags doc, two test comments
- [x] dead: `Banks.count` (fix test loop), `refsOf` non-pub, `error.BadSteeringScale`, `HostBank`
- [x] drop `pub` on file-local decls
- [x] validateFile: drop `path.len == 0`; take `io`
- [x] projectStream shape guard: delete
- [x] readBank catch-all: let OOM through
- [x] defaultPathInto: no silent truncation
- [x] inline: drainFreeLater `pending`, hammer `rr`, `key`
- [x] DRY: rowsFor -> freeRows; fold/fused env helper; `hostAs` helper; name+scale validation into one place
- [x] `var b` -> `const b`; `Reservation.none(null)` in test
- [ ] SKIPPED `MAX_BANKS` type: it is both an array length and the u8 bank-index bound, so u8 is right
- [x] hammer: fixed seeds
- [x] unit-direction test helper shared

## transformer.zig
- [x] comments: cfg build-then-evict, `steering_engaged_logged` doc, f32-mean, fold conjunct restatement, SteerPlan doc, HcPending.deinit vs HcSteer duplicate, `Transformer.steering` ownership, `steering_dump` length
- [x] test comments to one line (3 sites) + delete restating one
- [x] delete `fold_override=false` block, `isOff` assert, debug print in qwen4 steering test
- [x] prefill conjunct `pend.?.steer == null`: delete
- [x] steerPending: inline uniform lookup, drop assert
- [x] hcCfgStored + 3 errdefers -> store into slot immediately
- [ ] SKIPPED dropping the `hc_fused_cfgs` alias: pre-existing global read by the apply path; out of scope
- [x] steerPlan: fold second loop into first
- [x] `steeringMaxAbsDiff` -> `maxAbsDiff`; fold test `bytesEqual` -> `expectRowsByteEqual`
- [x] move `*_logged` globals beside users; `steer_arm == 1` magic number; blank line before qsa test

## server.zig
- [x] comments: arch_pending "waits" wrong; capture-dir env doc; history (no seams, createDir, plain return); capture chat-only; persist comment; CLAUDE.md ref; 4-line comment; symlink comment
- [x] optional `root` params -> non-optional
- [x] `supported` local; double kind filter
- [x] Configured before reserve; one `defer res.release()`
- [x] inline single-use locals (props builder, active.req/path, registry_dir, banks)
- [x] DRY: per-surface steering block helper; completions resolves once in handler; persist/reset bool helper; absolute-HOME guard into registryDir; parseSteeringCapture sets capture_dir
- [x] POST body parse in the file's style; model id read with one switch (not the raw-byte `parseModelFromBody`: the body is already parsed)
- [x] `steeringCaptureDir` drop pub
- [x] sendSteeringError else -> 500
- [x] sort registry listing

## cli.zig
- [x] port comments (history) + test comment
- [x] tests to bottom; delete duplicate default-port test
- [x] `SteerArgs`: parse once, build url + body (removes steerPort/steerFlag/steerTarget walk, ffn/attn duplicate, is_named)
- [x] drop `pub` on file-local decls

## generate.zig
- [x] capture tail comment to 2 lines
- [x] promptSha256Hex -> bytesToHex; manifest body via one writer
- [x] CaptureSteering defaults; drop `pub`
- [x] test comment one line

## model_settings.zig
- [x] createDirPath `catch {}` -> try
- [x] entry lookup without `entry.?` unwraps

## scheduler.zig
- [x] armSteering doc wrong; inner comment duplicate; arch-miss comment trim
- [x] inline steeringErrorsAreFatal + delete its test
- [x] armSteering: banks from xfm.steering.?; take io
- [x] releaseSteeringPin: no re-derive
- [x] io_util re-import
- [x] LoadRequest doc one-liner

## main.zig
- [x] steering flag globals -> locals
- [x] error text duplicating name rules

## index.html
- [x] /v1/steering row: GET + POST

## Swift
- [x] SteeringQuickSet: delete isAvailable (+test); history comments (arch gate, configuredBank, visibleBank); header "ffn box" + duplicate rationale; stepped uses clamped; `step` private; redundant empty checks
- [x] APIClient: steeringBody doc; SteeringInfo.file doc single home
- [x] ServerManager: steering doc (resident chat model); history comments
- [x] ModelSettingsSheet: history comments x3; inline steeringScales
- [x] StatusMenuView: @State placement + blank lines; duplicate cache comment; history comments; slot-row comment; box doc duplicate; Arm doc; memory comment; failure comment; step() DRY; remember() helper; `if let failure`
- [x] Swift test comments to one-line bars (7); fold redundant body tests; ModelSettingsApplyTests class comment

## Tests / tools
- [x] test_qwen4_steering.sh: history comments (errored request, 0.25, engagement NOTE); status() doc; misplaced cold comment; MTP_AFTER `|| true`; SteeringFileSize check simpler
- [x] build_steering_bank.py: `with open`; `pairs` -> show/control counts

## Docs
- [x] CHANGELOG one sentence
- [x] engine-mlx.md: split piggy-back stories, trim to <20 lines, rewrap, trailing blank
- [x] reference.md: rewraps, three-states paragraph, review-reply sentence
- [x] tests/CLAUDE.md [6b] trim
