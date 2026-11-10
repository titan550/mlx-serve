# Native ablation for the in-tree `deepseek_v41` plugin — handoff plan

Status: approved shape, not started. Decisions below are locked; do not relitigate without new measurement.

## Goal

`deepseek_v41` declares `Caps.ablation` and applies one direction per slot at every residual write — the contract
`qwen4_exp` serves (CR-A) and the Sushi outside plugin serves. Needed for Pruned192 (runs on this 128 GB Mac) and
for the non-pruned pack (does not run here, so it must be verifiable without it).

## Locked decisions

1. **Tap first.** The capture tap needs no ablation — it records the stream the model already produces. Capture
   Pruned192, build the direction offline, then land the seam.
2. **Decline fusion while armed.** `ffnDecode` returns null when `m.ablation != null`, so the caller falls back to
   the generic `hcExpand(x1, withShared(...))` path where the FFN output is a plain array to project. No kernel
   work, no expanded-formula projection. Cost: slower decode on ablated requests only.

## Non-goals (keep the diff surgical)

- No ABI change (`abi.Ablation` already carries directions/strengths/keys).
- No SDK block change: `hcExpand` is plugin-local; the shared `hc_decode2` kernel is untouched.
- No kernel change, no manifest change, no host-API change.
- No profile format change: CR-G's `strength`/`max_strength` already exist.
- The only host-side edit is the `extendBatched` call in `src/engines/mlx/spec/dspark_group.zig`.

## Facts the plan rests on (verified)

| Fact | Where |
|---|---|
| Upstream seam + host side exist; no in-tree model declares the cap except `qwen4_exp` | `abi/plugin.zig` `Ablation`, `Caps.ablation`; `plugin/driver.zig` marshals per-slot rows |
| Caps today: `slot_state`, `batches_decode`, `owns_decode_state`, `prefix_cache`, `spec.native_stages = 3` | `plugins/deepseek_v41/config.zig` parse + caps tests |
| A streamed pack (`experts.bin`) loses `slot_state` and `batches_decode` | same caps tests |
| Trunk is plugin-local: `hcExpand` / `hcExpandPreNorm` / `split` | `deepseek_v41.zig` ~2191–2240 |
| Batched decode: `forwardBatched` → `extendBatched(m, gpa, states, gens, chunks, verify)` | `plugin.zig:371`, `deepseek_v41.zig:5231` |
| `extendBatched` is also called by the engine and a test | `engines/mlx/spec/dspark_group.zig:226`, `deepseek_v4/served_test.zig` (2 calls) |
| `ffnDecode` returns the stream the `moe_down` kernel already expanded | `deepseek_v41.zig:2952`, callers 3715 and 4654 fall back via `orelse hcExpand(...)` |
| Tests without the full pack exist | `fixture.v41Files(alloc, seed)` tiny random pack, tapes in `plugins/deepseek_v41/fixtures/`, `DSV41_TINY` |

## Step 1 — capture tap (`DEEPSEEK41_TAP_DIR`), ~120 lines

Purpose: record per-layer stream activations for a prompt pass, so a refusal direction can be built for a pack
whose config sha is Pruned192's (`00a4ccc2…`).

- Register `DEEPSEEK41_TAP_DIR` in `src/env.zig` (kind `diag`, owner `plugins/deepseek_v41`, since the release it
  lands in).
- Arm only for prompt passes (a decode step records nothing), and only while the env var names a directory.
- Record, per layer: the mean over the hyper-connection copies of the stream **entering** that layer, and (last
  site) the stream **leaving** the final layer, for the prompt pass's last 4 rows plus the last token.
- Write `tap-<seq>.npy` (`[layers + 1, rows, dim]`, f32) plus one `index.jsonl` line
  `{"seq","file","ablated","prompt_tokens","rows","tail_ids"}` — **the same format as `sushi_ds41`'s tap**, so
  `~/claude-tmp/sushi-prof/build_dirs.py` and `make_profile.py` work unchanged.
- Directory made 0700, files 0600 (owner-only), as the Sushi tap does.
- Acceptance: tiny-pack test asserts the file shape, the index line, and that a decode step writes nothing;
  `zig build test -Dtest-filter="deepseek_v41"` green; lint 0.

## Step 2 — the seam, ~350 lines

### 2a. `config.zig`
`.ablation = true` in the caps the parse returns, plus a caps test asserting it (and that a streamed pack keeps
it — ablation is orthogonal to streaming).

### 2b. New `src/plugins/deepseek_v41/ablate.zig` (~110 lines, modelled on `qwen4_exp/ablate.zig`)
- `Ablation { dirs [slots, hidden], strengths [slots], owns_dirs }`.
- `fromForward(f)` — borrow the host's table; null when no slot has a nonzero strength.
- `fromRequests(reqs, hidden)` — build rows for module calls (one slot per batch row; a slot without a request is a
  zero row at strength 0).
- `slot(i)` — one slot's rows, for a forward that runs one slot alone.
- `apply(s, y, site)` — `y - s·(y·r)·r` in f32, back in `y`'s dtype.
- **Site bound**: a site past `layers + 1` (the DSpark/MTP stages above the backbone) passes through untouched.
  This is the defect the Sushi bank hit; guard it from the start and test it.
- `servesAcross(pipeline, tensor)` = false for a Thunderbolt pair (CR-A's refusal).
- `deinit`.

### 2c. `deepseek_v41.zig` write sites (~45 lines)

| Site | Call | Index |
|---|---|---|
| embedding | `m.embed.rows(...)` (decode ~3970, verify ~5308, prefill ~5531) | 0 |
| attention output | the `wo_a`/`wo_b`/`ao[0]` result before the layer's `hcExpand` | `li + 1` |
| FFN output | `y` from `moe(...)` before `hcExpand` (~3682) | `li + 1` |
| Engram value | `engramApply`'s `wkv` output (~3577, called ~4541) | `e.layer + 1` |

- `ablation: ?Ablation` on `Dsv41Model`.
- Fusion guard: first line of `ffnDecode` — `if (m.ablation != null) return null;` (covers the GGUF branch too).
  Callers already `orelse hcExpand(...)`, so the generic path projects `y`.
- `extendBatched` gains `reqs: []const ?Request` (per slot); `m.ablation` is built from it for the graph's
  lifetime.

### 2d. `plugin.zig` (~25 lines)
- Arm/disarm around `forward`, `forwardBatched` (rows from `f.slots` / the per-slot requests) and the native
  drafter round paths.
- Refuse an ablated request on a cluster pair, naming it.

### 2e. Call sites
- `engines/mlx/spec/dspark_group.zig`: pass `gens[k].ctx.ablation` per slot (~10 lines).
- `deepseek_v4/served_test.zig`: pass `&.{}`.

### Acceptance (tiny pack)
1. Strength 0 is **bit-identical** to the recorded tape (the existing proof tapes).
2. Strength > 0 changes logits.
3. Each site's projection equals a float64 reference (`y - s(y·r)r`), per site, including the Engram value and the
   expanded-free FFN path.
4. Per-slot rows: two slots with different directions/strengths each get their own projection; a slot with no
   request is untouched.
5. Fusion declined while armed: `ffnDecode` returns null, and the generic path is what ran.
6. A site past `layers + 1` passes through (DSpark stage rows unchanged).
7. Cluster pair refuses by name.
8. `zig build test -Dtest-filter="deepseek_v41"` + `-Dtest-filter="ablation"` green; lint 0.

## Step 3 — profile and evaluation (scripts only, no repo code)

1. Capture Pruned192 over steering-lab `harmful_build.txt` / `good_build.txt`, thinking off (thinking-on refuses
   3/99 on Sushi — measured; expect the same shape here, and check before assuming).
2. Difference of means per site/row; sweep sites 30–40 and rows 2–4; pick by held-out refusal rate.
3. Write the profile with **Pruned192's** config sha, declaring `strength` and `max_strength` (CR-G). A profile is
   pack-bound; the non-pruned pack needs its own capture on a machine that can hold it.
4. Held-set refusal + benign drift; adopt as the model setting.
5. Acceptance: harmful refusal drops materially with benign drift at or below baseline (Sushi's bar: 0.98 → 0.04,
   0.08 → 0.02 at layer 37 strength 4).

## Validation limits

- The full non-pruned pack cannot run on this machine. Its correctness rests on the tiny-pack tests (same code
  path) and on Pruned192's live run. Record that limit in the ledger; do not claim a full-pack measurement.
- A streamed pack has no batched decode, so it takes the single-slot path — already covered by per-slot rows.

## Risks

- `extendBatched` signature change touches two call sites; keep `reqs` last and allow `&.{}`.
- Fusion off while armed slows decode; acceptable because steering is opt-in.
- Batched decode with mixed slots (some ablated, some not) must not leak a direction across slots — test 4 above.
- The DSpark stage rows sit past the bank; without the site bound they raise an MLX error (the Sushi defect).

## Ledger entry stub (`local/PATCHES.md`)

```
### CR-H — deepseek_v41 serves directional ablation (`Caps.ablation`)
- Level: L5   Status: planned
- Why: upstream's seam has no in-tree DeepSeek model behind it; Pruned192 (and the full pack elsewhere) needs it.
- Files: plugins/deepseek_v41/{config,ablate(new),deepseek_v41,plugin}.zig, engines/mlx/spec/dspark_group.zig
- Off switch: no profile selected → forward byte-identical (strength-0 test).
- Tests: tiny-pack bit-exactness at strength 0, float64 reference per site, per-slot rows, fusion declined,
  out-of-range site pass-through, cluster refusal.
- Drop when: upstream serves ablation for deepseek_v41 itself.
```

## Order and handoff

1. Step 1 (tap) → capture Pruned192 now; build the direction offline.
2. Step 2 (seam) → tiny-pack tests green.
3. Step 3 (profile + held-set eval) → adopt the model setting.
4. Update `local/PATCHES.md` (CR-H) and the plugin's `AGENTS.md` with the site map and the fusion rule.
