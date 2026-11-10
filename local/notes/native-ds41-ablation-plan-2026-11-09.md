# Native ablation for the in-tree `deepseek_v41` plugin — plan for review

Goal: the built-in `deepseek_v41` plugin declares `Caps.ablation` and applies one direction per slot at every
residual write, the same contract `qwen4_exp` serves (CR-A) and the Sushi outside plugin serves. Needed for
Pruned192 (runs on this 128 GB Mac) and for the non-pruned pack (does not run here), so the groundwork must be
verifiable without the full model.

## What already exists (evidence, not assumption)

- Upstream ships the seam and the host side: `abi.Ablation` (directions `[slots, hidden]`, strengths, keys),
  `Forward.ablation`, `Caps.ablation`, profile loading, per-slot marshalling in `plugin/driver.zig`. No in-tree
  model declares the cap except `qwen4_exp` (CR-A).
- `deepseek_v41` caps: `slot_state`, `batches_decode`, `owns_decode_state`, `prefix_cache`, `spec.native_stages = 3`
  (DSpark). A streamed pack (`experts.bin`) loses `slot_state` and `batches_decode` (`config.zig` tests).
- The trunk is plugin-local: `hcExpand`/`hcExpandPreNorm` live in `src/plugins/deepseek_v41/deepseek_v41.zig`, not
  in `sdk/blocks/hc/hc_decode2.zig`. So ablation is a plain op chain on each sublayer output before the expand —
  **no kernel work**, unlike CR-A which folded it into the shared fused kernel.
- Write sites, by line:
  - embedding: `m.embed.rows(...)` at 3970 (decode), 5308 (verify), 5531 (prefill) → site 0
  - attention output: `ao[0]`/`wo_a`/`wo_b` result, before the layer's `hcExpand` → site `li + 1`
  - FFN output: `y` from `moe(...)` before `hcExpand` (3682) → site `li + 1`
  - engram value: `engramApply`'s `wkv` output (3577, called at 4541) → site `e.layer + 1`
- Fused decode: `ffnDecode` (2952) returns the stream the `moe_down` kernel already expanded (`x1`, `sp`), so an
  ablated FFN output cannot be projected after the fact without the expanded formula. The surgical answer is the
  repo's own precedent (`qwen4_exp.foldsExpand`): decline fusion while an ablation is armed.
- Batched decode: `forwardBatched` → `dsv41.extendBatched`, also called by the engine
  (`src/engines/mlx/spec/dspark_group.zig:226`) and by `deepseek_v4/served_test.zig`. Directions are per slot, so
  that call needs the per-slot requests.
- Tests without the full pack exist: `fixture.v41Files(alloc, seed)` builds a tiny random pack, tapes live in
  `src/plugins/deepseek_v41/fixtures/`, and `DSV41_TINY` drives tiny-checkpoint tests.

## Part 1 — the engine seam (~350 lines, one plugin folder + 2 call sites)

1. `config.zig`: `.ablation = true` in the caps the parse returns, plus a caps test (~4 lines).
2. New `src/plugins/deepseek_v41/ablate.zig` (~110 lines), modelled on `qwen4_exp/ablate.zig`:
   - `Ablation { dirs [slots, hidden], strengths [slots], owns_dirs }`
   - `fromForward(f)` (borrows the host's table), `fromRequests(reqs, hidden)` (builds rows for module calls),
     `slot(i)`, `apply(s, y, site)` = `y - s·(y·r)·r` in f32, `deinit`
   - site bound: a site past `layers + 1` (the DSpark/MTP stages) passes through untouched — the defect the Sushi
     bank had, guarded here from the start
   - `servesAcross(pipeline, tensor)` = false for a Thunderbolt pair (same refusal as CR-A)
3. `deepseek_v41.zig` (~45 lines): `ablation: ?Ablation` on `Dsv41Model`; the four site projections; the fusion
   guard (`fusedOn`/`ffnDecode` decline when `ablation != null`, so the generic path projects `y` before
   `hcExpand`); `extendBatched` gains `reqs: []const ?Request` (~15 lines).
4. `plugin.zig` (~25 lines): arm/disarm around `forward`, `forwardBatched` (per-slot rows from `f.slots`), and the
   native drafter round paths; refuse a cluster pair.
5. Engine call site: `spec/dspark_group.zig` passes each slot's request from `gens[k].ctx.ablation` (~10 lines).
   `deepseek_v4/served_test.zig` passes `&.{}`.

No ABI, SDK, kernel, host-API or manifest changes. The only host-side edit is the `extendBatched` call in
`dspark_group.zig`.

## Part 2 — capture tap (~120 lines) — do this FIRST

The tap does not need ablation: it records the stream the model already produces, so capture can run before
Part 1 lands and the direction can be built offline.

- `DEEPSEEK41_TAP_DIR` (registered in `src/env.zig`, kind `diag`, owner `plugins/deepseek_v41`): for a prompt pass,
  write the mean of the hyper-connection copies entering every layer and leaving the last, for the last 4 rows and
  the last token, as `tap-<seq>.npy` (`[layers + 1, rows, dim]`, f32) plus a line in `index.jsonl` — the same
  format as `sushi_ds41`'s tap, so `build_dirs.py` / `make_profile.py` work unchanged.
- Test: tiny pack, one prompt, assert the shape, the index line and that a decode step records nothing.

## Part 3 — profile and evaluation (scripts only, no repo code)

1. Capture harmful/good build sets (steering-lab `harmful_build.txt` / `good_build.txt`), thinking off.
2. Difference of means per site/row; sweep sites 30–40 and rows 2–4; pick by held-out refusal rate.
3. Write the profile with **Pruned192's** `config.json` sha (`00a4ccc2…`), declaring `strength` and
   `max_strength` (CR-G), so the app seeds the field.
4. Held-set refusal + benign drift; adopt as the model setting.
5. The non-pruned pack is a *separate profile* (its own config sha) built from its own capture on a machine that
   can hold it — the code is the same.

## Validation

| level | check |
|---|---|
| tiny pack | strength 0 bit-identical to the recorded tape; strength > 0 changes logits; each site's projection equals a float64 reference; per-slot rows; fusion declined while armed; a site past the bank passes through |
| Pruned192 live | small hard set: refusal rate with and without the profile, benign drift |
| full pack | same code path, validated by the tiny pack; no live run on this machine (stated in the ledger) |

## Cost and risk

- ~470 lines total, all inside `src/plugins/deepseek_v41/` plus one engine call site — the surgical shape the
  policy asks for. Nothing upstream would have to accept beyond "a model declares `Caps.ablation`".
- Fusion off while steering: decode is slower on an ablated request (opt-in path only).
- A streamed pack has no batched decode, so it takes the single-slot path — one slot's rows at a time, which the
  per-slot rows already cover.
- The full pack cannot be run here; that limit is recorded, not worked around.

## Order

1. Part 2 (tap) → capture Pruned192 now.
2. Part 1 (ablation) → tiny-pack tests green.
3. Part 3 (profile + held-set eval) → adopt the model setting.
