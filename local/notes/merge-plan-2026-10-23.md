# Merge plan: origin/main (v26.10.3) into steering/upstream-pr — 2026-10-23

Merge-base ba0088f7 (#884). Ours: 17 commits (steering). Theirs: 30 commits, 291 files, +39k/-3k.
Dry run (`git merge-tree --write-tree HEAD origin/main`): 9 conflicting files, 13 hunks, all small.

## Step 0 — before merging
- `git submodule update --init lib/mlx-stream` after the merge (pin moves 7d29eaa → fcb4011; DSV4.1 K=2 EXL3 layers).
- lib/mlxc-src working tree carries the build script's gather_qmm patch (ops.cpp +2). Expected; do not commit.
- Branch is pushed to `fork/steering/upstream-pr`; no open PR on ddalcu/mlx-serve yet.

## Step 1 — `git merge origin/main` and resolve

| File | Hunks | Resolution |
|---|---|---|
| src/transformer.zig:8 | import | keep BOTH: `const steering = …;` and `const distributed_mod = …;` |
| src/transformer.zig:42484 (hcFusedRead) | HC read dispatch | take upstream's shape (CUDA arm + `pending` const); build `pending` WITH `.steer = pd.steer`; CUDA arm only when `pending.?.steer == null` (hc_cuda.read ignores steer → would drop it silently); Metal arm as upstream |
| src/hc_decode2.zig:616 | ND launch bind list | ours + theirs: keep our 11-input bind (`sd_in`, `ssc_in` after `wi`) AND upstream's `dsb` dense indirection: `&.{ x, nw, iw-or-nw, eps, wo, wi, steer.dir-or-nw, steer.scale-or-eps, dw, dsb[0], dsb[1] }`; keep our steered-engagement log block; upstream's up/upv `dsb[2], dsb[3]` lines auto-merged already |
| src/main.zig:274 | --help text | keep our three `--dir-steering-*` entries, take upstream's new `--mtp` wording |
| src/main.zig:638 | subcommands | keep `steer` AND add upstream's `worker` / `dist-probe` branches |
| src/model_settings.zig:37 | isEmpty | union: add `o.lm_head_mxfp8 == null and` to ours, keep `o.steering.state == .inherit` |
| src/model_settings.zig:384 | log line | union: `… int8={s} lm_head_mxfp8={s} ane={s} drafter={s} kwargs={s} steering={s}` + matching args |
| APIClient.swift:428 | PropsSnapshot fields | keep both `directionalSteering: SteeringInfo?` and `cluster: ClusterInfo?` |
| APIClient.swift:437 | fetchProps | ours (uses `fetchPropsRaw(port, model)`, which upstream now also has) + add `cluster: ClusterInfo.parse(json)` |
| ServerManager.swift:75 | properties | keep both the steering block and `@Published var cluster` |
| ServerManager.swift:665 | props tick | keep our two steering lines, then upstream's `cluster = props.cluster` and `await noteRegistryGeneration(props.registryGeneration)`; drop our inlined 3 `modelListMoved` lines (upstream's `noteRegistryGeneration` wraps the same static helper, which stays) |
| ko/zh-Hans Localizable.strings | tail append | keep both blocks (ours 10 keys, theirs ~100) |
| src/html/index.html | binary | take THEIRS (`git checkout --theirs`). See finding below. |

## Step 2 — follow-up edits the merge needs (same merge commit or one fix commit)
1. **Steering never folds on CUDA**: `steer_fold = steer.canFold() and rows <= HC_FUSED_MAX_ROWS and !qwen4Standin().hc and !mlx.cudaAvailable()` (transformer.zig ~26047). The standalone projection still applies there.
2. **Steering declines on a cluster rank**: `steeringSupported()` returns false when `config.dist_span != null or config.dist_shard != null`. A pipeline rank renumbers layers to its span (`applySpan`: `num_hidden_layers = span.len()`), so bank rows by local index would be wrong, and the bank's row count would not match. Document as "not served across a Thunderbolt cluster" in docs/reference.md steering section.
3. **Console source vs artifact**: our committed index.html contains a `GET /v1/steering` route entry that `app-web/src/lib/core/console.ts` does NOT have (built from an uncommitted edit). Either add the GET/POST `/v1/steering` rows to console.ts (+ zh-hans i18n), `npm run build`, commit both; or drop the console change entirely. Pick one; current state violates the "built, never hand-edited" rule.
4. AGENTS.md: our `steering_cli.zig` row auto-merges; re-check the layout table still reads cleanly next to upstream's new rows (distributed, moss_image, trellis2, pixal3d, modelopt_pack).

## Step 3 — verify
- `zig build check` (new upstream edit-loop target, ~35 s) → `zig build test -Dtest-filter="steering"` → `zig build test` full → `zig build -Doptimize=ReleaseFast`.
- `bash app/test.sh` (Swift), esp. SteeringQuickSetTests, ModelSettings*Tests, ServerEnsureChatModelTests (upstream new).
- `tests/test_qwen4_steering.sh` live on Flash Next (fold engagement line `[steering] folded into the hyper-connection read`).
- `tests/test_model_settings.sh`, `tests/test_models_capabilities.sh`.
- Sanity: `/props?model=` still carries both `steering` and `cluster` keys; tray shows steering row and cluster row.

## What changed upstream (v26.10.3)
See the reply / CHANGELOG. Flash Next on Metal: no measured speedup in this delta (details in reply).

## Outcome (2026-10-23)
Merged as 8bbfca70 on steering/upstream-pr (not pushed). Resolutions as planned, plus:
- `return;` after `steering_cli.cmdSteer` restored (it sat in shared context between the two hunks; the live test
  printed "unrecognized argument 'steer'" while its `CLI off` check still passed on stdout).
- Console: GET/POST /v1/steering rows added to console.ts + zh-hans, index.html rebuilt, size ratchet 592 → 593 KiB.
Verified: zig build check; zig build test 4846 pass / 0 fail / 585 skipped; app/test.sh 4201 pass; app-web 474 pass;
ReleaseFast build; tests/test_qwen4_steering.sh sections 1-3 pass (fold, POST, CLI, MTP invariance), section 4+
blocked by memory: the app's server holds the 4.7bpw pack (70 GiB). Rerun with it unloaded:
  ./tests/test_qwen4_steering.sh
