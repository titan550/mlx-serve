# Plan: `/v1/adapters` — one adapter mechanism, two target types

> **Status 2026-10-31:** written before the v26.11.1 merge. Every anchor in §2 moved, and part of PR 1 is done (the
> attn arm is gone; steering is a model-level setting with live apply). Current state, the bank-building gap and the
> options: `steering-banks-and-adapters-2026-10-31.md` (§7 maps old anchors to new).

Working plan for generalizing the directional-steering fork into a general low-rank
adapter feature. Written against branch `steering/upstream-pr` at `10ade6ef`; line
numbers below were read at that commit and must be re-checked before editing.

**One sentence:** every adapter edit is `out += scale · B·(A·in)`; what differs between
a LoRA and a steering bank is only *where* it attaches, so one format, one registry and
one request field serve both.

---

## 1. Why this shape

The upstream objection to PR #538 was "4000 lines for a niche feature". Most of those
lines are not steering — they are adapter plumbing (registry with pins, per-request
selection with a strength knob, per-model default persisted in settings, HTTP, CLI, app
UI). A LoRA feature needs all of it. Renaming and widening the format turns a niche
feature into the general one the maintainer asked for, without rebuilding the plumbing.

Two target types:

| Target | Attaches to | Cost on qwen4_exp | Supply today |
|---|---|---|---|
| `residual` | the hyper-connection residual stream, after the MLP/MoE write | **zero extra GPU dispatches** (folds into the existing norm launch); measured −2.7% decode | the banks we build |
| weight module | a linear's output, `y = Wx + scale·B(Ax)` | extra op per adapted matrix per token | 2 LoRA adapters on HF for Flash-Next vs 83 full merges |

Residual ships first because it is free and has content. Weight targets land second,
behind the same surface, for downloaded PEFT adapters and anything we train.

---

## 2. Verified current state (anchors)

### Fork-owned modules
- `src/steering.zig` — rules, `Banks` (8 LRU slots, `Reservation` refcount pins, locks
  `mu` / `control_mu` / `model_settings.file_mu`, frees via `free_later` drained by the
  inference thread), `Plan`, projection kernels, capture helpers.
  - `projectRow` :620, `projectFused` :749, `projectChain` :808, `projectStream` :827
  - `Plan` :850, `Plan.pending` :957, `Plan.direction` :967, `Plan.apply` :990
  - `Plan` has three shapes: off, uniform, mixed; mixed does one GPU `mlx_stack` of the
    per-bank `[n_layers, hidden]` matrices
- `src/steering_http.zig` — `GET|POST /v1/steering`, `requestSteering` on every chat
  surface, `captureResponseField`, `steeringPost`, `persistAndSwap`, `errorMessage` table
- `src/steering_cli.zig` — `mlx-serve steer` client (`SteerArgs`, `cmdSteer`)
- `app/Sources/MLXServe/Models/Steering.swift`, `app/Sources/MLXServe/Views/SteeringQuickBox.swift`

### The residual seam (the thing that makes this cheap)
`src/hc_decode2.zig`:
- `Steer` doc :12-13 — `.attn` projects `out` before the write (`ST 1`), `.ffn` projects
  each written stream after it (`ST 2`)
- `Pending` :22 — `{ out, inj, steer: ?Steer }`
- kernel source :95-117 — the `ST` arms; lane split + `simd_sum` + 8-way sum, **rank 1**
- `steered: u64` :469 and `steer_fold_logged` :470 — engagement counters tests assert
- `config` :571 passes `ST` as a template value; `run` :600 binds `v.dir` / `v.scale`
- fold gate: engages only when `hidden % 256 == 0` **and** hc rank `% 64 == 0`.
  Flash Next: hidden 2560 = 10×256 ✓

### Reusable LoRA half (already arch-agnostic)
`src/lora.zig` — imported by `tests.zig`, `krea.zig`, `minimax_h3.zig`, `flux.zig`,
`gen.zig`, `ltx_video.zig`, `qwen_image.zig`. **Not** by `transformer.zig`.
- `Ref` :48, `Role` :54, `KeyInfo` :55, `parseKey` :72
- `Arch` :125 — `{ flux2, krea2, minimax_h3, qwen_image21, generic }` — **`generic` already exists**
- `canonicalize` :369, `delta` :405, `addTo` :432, `deltaSum` :461
- `MAX_LORAS` :482 (8), `Slot` :487, `addSlot` :502, `Entry` :509, `File` :518,
  `Stack` :544, `Stack.findAll` :573
- `validatePath` :708, `loadFile` :719
- Attachment is **per-backend**: each engine's linear holds `lora_refs` and calls
  `deltaSum` in its own forward (pattern: `flux.zig:202` apply, `:216` install,
  `:1093` `stack.findAll`). The LM path has no such hook — that is the new work.

### Model geometry (`ddalcu/Qwen3.8-Flash-Next-MLX-Serve-*`)
hidden 2560 · 48 layers · 24 heads / 2 kv · head_dim 256 · moe_intermediate 640 ·
shared_expert_intermediate 640 · 512 experts top-10 · full_attention_interval 4 ·
linear_attn 48 v-heads × 128 / 16 k-heads × 128 · vocab 248320 · `hc_count`, `hc_lowrank`

### Measured cost (steering-lab `results/REPORT.md` §3, same boot, server timings)
| arm | decode tok/s | vs off |
|---|---|---|
| off | 64.3 | — |
| ffn 1.0 | 62.6 | −2.7% |
| ffn 1.0 + attn 0.5 | 60.5 | −5.9% |

4 concurrent streams, aggregate: 106.5 → 103.4 (−2.9%), so the cost does not compound
under batching.

### Tests and fixtures
- `tests/test_qwen4_steering.sh` — sections [1]–[8], 60 checks, `set -uo pipefail`,
  `boot` takes `--model`, `stop` waits for the port
- `tests/build_steering_bank.py`, `tests/dump_qwen4_exp_fixtures.py` (`--hidden`, `--hc-lowrank`)
- `~/claude-tmp/qwen4-tiny256/pack` — fold-capable fixture (hidden 256, hc_lowrank 128),
  byte-level `tokenizer.json`
- `~/claude-tmp/qwen4-tiny/pack-tok` — 64-wide fixture (fold declines)
- Upstream lines touched: `git diff -U0 origin/main -- src app docs tests AGENTS.md | grep -c '^-[^-]'` → **84** at `10ade6ef`

---

## 3. Format spec

One safetensors file per adapter. `~/.mlx-serve/adapters/<name>.safetensors`.

```
layers.<k>.residual.lora_A              [r, hidden]     residual target
layers.<k>.residual.lora_B              [hidden, r]     omitted in projection mode
layers.<k>.self_attn.q_proj.lora_A      [r, in]         weight target (PR 2)
layers.<k>.self_attn.q_proj.lora_B      [out, r]
__metadata__ = {
  "mlxserve_adapter_version": "1",
  "mode": "projection" | "general",
  "default_scale": "1.0",
  "arch": "qwen4_exp",
  "hidden": "2560", "layers": "48", "rank": "1"
}
```

- **`mode: projection`** means `B = −Aᵀ` is derived and `lora_B` is absent. Rows of `A`
  must be unit-norm (validated at load). This is what keeps a converted bank at 0.49 MB
  and makes steering a *declared* mode rather than an accident of the numbers.
- **`mode: general`** stores both, plus optional `layers.<k>.<target>.lora_bias [r]`.
- Rank is per-file, not per-entry. Keep it that way until something needs otherwise.
- PEFT naming (`lora_down`/`lora_up`, dotted, `.default.` infix, `__metadata__` alpha) is
  already handled by `lora.parseKey` / `lora.fileAlphaScale` — reuse, do not re-implement.

### Sizes (hidden 2560, 48 layers, f32)
| Form | Bytes |
|---|---|
| today's raw bank | 491,520 (0.49 MB) |
| rank 1 projection | 491,520 — **identical** |
| rank 8 projection | 3.9 MB |
| rank 8 general | 7.9 MB |
| rank 16 general | 15.7 MB |
| weight-LoRA equivalent of the ffn edit (all residual writers incl. 512 experts) | ~65 MB |

### Bank → adapter conversion
Script `tests/bank_to_adapter.py`: read raw f32 `[48][2560]`, write
`layers.k.residual.lora_A = d_k`, `mode: projection`, `rank: 1`. No training, seconds.
**Acceptance: the converted adapter is bit-identical in output to the raw bank.**

---

## 4. PR 1 — the surface + residual target

Smaller than the current PR, because the attn arm goes away.

### 4.1 Drop the attn arm
Justified by measurement, not taste: REPORT §1.4 — "attention-arm steering alone barely
moves the three-class result; the ffn arm on the full residual is the operating arm", and
the deployed configuration is `attn 0, ffn 1`.

Removes: one of two hook points in `transformer.zig`, `ST == 1` from the kernel, the
`Steer.Arm` enum and its two-valued vocabulary across settings / HTTP / CLI / UI / Swift,
and roughly half the test matrix. **Fewer seams in upstream files = fewer merge conflicts.**

### 4.2 Rename and widen
| From | To |
|---|---|
| `src/steering.zig` | `src/adapters.zig` |
| `src/steering_http.zig` | `src/adapters_http.zig` |
| `src/steering_cli.zig` | `src/adapters_cli.zig` |
| `GET\|POST /v1/steering` | `GET\|POST /v1/adapters` |
| `mlx-serve steer` | `mlx-serve adapter` |
| request `steering: {name\|file, ffn, attn}` | request `adapters: [{name, scale}]` |
| model-settings `steering` | model-settings `adapters` |
| `~/.mlx-serve/steering/<name>.f32` | `~/.mlx-serve/adapters/<name>.safetensors` |

Request grammar mirrors the media side (`lora_paths` + `lora_scales`, PR #849): a list,
cap 8 (`lora.MAX_LORAS`), summed never merged, negative and large scales legal.

`Banks` → `Registry`: same 8 LRU slots, same `Reservation` pins, same `free_later`
discipline. Entry payload changes from `[n_layers][hidden]` to the parsed adapter table.

### 4.3 Rank r in the residual path
Two call sites, both must take the loop:
1. **Folded** — `hc_decode2.zig` kernel `ST` arm. `sd_in` becomes `[r, hidden]`,
   `sc_in` becomes `[r]`. Start with `r` sequential reductions reusing the existing lane
   split; measure before optimizing. `ST` template value stays, now meaning "residual
   edit present" rather than naming an arm.
2. **Unfolded** — `projectRow` / `projectStream` / `projectFused` / `projectChain` in
   `adapters.zig`, the fallback when the fold gate declines (64-wide fixture, non-decode
   widths). Same rank loop.

`Plan`'s mixed shape becomes `[n_layers, r, hidden]` per bank.

**General mode** adds the `B` multiply: the kernel currently computes
`y -= sc · d · dot(d, y)`; general mode computes `y += Σ_i sc_i · B[:,i] · dot(A[i], y)`.
Same reduction, different writeback vector. Ship projection mode first; general mode is
dead weight until something trains one.

### 4.4 Carry over the open review points from #538
- **Path oracle (#540/#541 class):** the request field accepts **names only**. Absolute
  paths stay on launch flags and `POST`. Use `lora.validatePath` (stat → regular file →
  400) and the loopback gate, so the fix matches the one upstream already took.
- **Prefix cache:** keep the current policy — a steered request reuses the cached prefix
  and only prefills its new tokens; a restored prefix keeps whatever adapter computed it.
  This is what makes "adapt one turn" cheap, and it is the opposite of vLLM's
  re-prefill-on-switch. **Document it explicitly in `docs/reference.md` as a declared
  policy with its rationale**, rather than leaving it implied. Guard stays
  `test_qwen4_steering.sh` [6].

---

## 5. PR 2 — weight targets

### 5.1 Survey first (half a day, do this before estimating the rest)
For each candidate module on qwen4_exp, determine whether decode reaches it through a
generic `qmatmul` call or through a fused kernel that reads the weight buffer directly.
Read `transformer.forwardQwen4With` plus the decode kernel gates in `hc_decode2.zig`,
`moe_affine4.zig`, `qsa_decode.zig`, and the `gatherQmv` paths.

Fill this table in before writing code:

| Module | Decode path | Prefill path | Bucket |
|---|---|---|---|
| `self_attn.{q,k,v,o}_proj` | ? | ? | ? |
| `linear_attn` in/out projections | ? | ? | ? |
| `shared_expert.{gate,up,down}_proj` | ? | ? | ? |
| routed `experts.*.down_proj` | ? | ? | ? |
| router / gate | ? | ? | ? |
| `embed_tokens`, `lm_head` | ? | ? | ? |

Buckets, in order of preference:
1. **Generic path** — add the `lora.deltaSum` call, following the `flux.zig:202` pattern.
2. **Fused, extendable** — the kernel takes `B(Ax)` as an extra input term.
3. **Fused, declines** — the fused path is skipped while an adapter is attached. Correct
   but slow, and must log.

### 5.2 Scope: attention + linear_attn + shared expert. Skip the 512 routed experts.
Rationale: we choose the target set when we train (see `steering-lab/PLAN-LORA.md`), so
pick targets the engine serves cheaply. A weight-LoRA on the routed experts costs ~480
extra small ops per token (10 active experts × 48 layers) through exactly the kernels
upstream keeps re-fusing, which is the invasiveness objection all over again.

A *downloaded* adapter that targets routed experts falls to bucket 3 or refuses by name.

### 5.3 PEFT key mapping
`lora.canonicalize` + an `Arch.qwen4_exp` table mapping HF/PEFT spellings onto our module
keys. `lora.Split` already handles fused-QKV sources splitting into thirds — likely needed
if a pack ships a fused `q_k_v_proj`.

---

## 6. The invariant that must be built in from day one

> **Every declared target either engages or refuses loudly.** No silent no-ops.

A weight adapter attached to a tensor a fused kernel reads directly would be silently
ignored — the output is plausible and wrong. This is the failure class AGENTS.md already
legislates against ("a fast path keyed on one pack's quant layout is SILENT on another's")
and the house rule `10ade6ef` established for malformed settings.

Mechanics:
- Per-target engagement counters, same shape as `hc_decode2.steered` :469, asserted by
  tests, surfaced in `/props`.
- A target the loader cannot bind is `log.err` + a named refusal, never a warning.
- One `[adapters]` log line per load naming rank, mode, target count and bucket per target.

---

## 7. Open decisions

| # | Decision | Recommendation |
|---|---|---|
| D1 | safetensors vs raw f32 | safetensors — `lora.zig` reads it, PEFT compatible, carries metadata |
| D2 | projection mode omits `B` | yes — halves the file and declares intent |
| D3 | drop the attn arm | yes — measured as doing nothing |
| D4 | residual before weight targets | yes — free, and weight adapters have no supply |
| D5 | request field is a list with scales | yes — mirrors #849's grammar |
| D6 | names only on the request field | yes — #540 |
| D7 | cache policy | keep reuse, document it as declared |
| D8 | engage-or-refuse | mandatory |
| D9 | keep the `.f32` bank loader for back-compat? | **decide.** Leaning no: convert and drop, one format |
| D10 | rank per file or per entry | per file until something needs otherwise |

---

## 8. Test plan

Additions to `tests/test_qwen4_steering.sh` (renamed `test_qwen4_adapters.sh`), keeping
all 60 existing checks in renamed form:

- **Conversion equivalence:** a rank-1 projection adapter converted from a bank produces
  byte-identical output to the raw bank on a fixed prompt, greedy. The headline guard.
- **Rank sweep:** r = 1, 2, 8 load, engage (counter > 0) and change output.
- **Fold and fallback agree:** same adapter on `qwen4-tiny256/pack` (fold engages) and
  `qwen4-tiny/pack-tok` (fold declines) produce matching output within tolerance.
- **Stacking:** two adapters with scales sum; order-independent; cap at 8 refuses the 9th.
- **Engage-or-refuse:** an adapter naming an unbindable target refuses by name, exit non-zero.
- **Path oracle:** a request-field path 400s; a non-regular file 400s; a bank name resolves.
- **Headless 503** and the cold-named-model arch report (existing section [8]).
- Hermetic unit tests at the bottom of `adapters.zig` as today (32 currently pass).

Full suite before any PR: `.zig-toolchain/zig build -Doptimize=ReleaseFast`,
`zig build test -Doptimize=ReleaseFast --summary all`, `bash app/test.sh`,
`bash app/build.sh`. Read pass/fail from the exit code and the Build Summary line — the
`failed command:` line in a zig test log is a documented false signal (`src/log.zig`).

---

## 9. Acceptance criteria

**PR 1**
- Converted rank-1 adapter bit-identical to the raw bank
- Decode cost within noise of the measured −2.7%, same-boot medians, nonce per prompt
- Upstream lines touched **≤ 84** and ideally lower (the attn arm removal should reduce it)
- All existing 60 live checks pass renamed; full Zig + Swift suites 0 fail
- `docs/reference.md` carries the cache policy as a declared rule; AGENTS.md rows updated

**PR 2**
- The survey table filled in, with each shipped target's bucket recorded
- Weight-target parity against an fp32 reference per target (cos **and** rms ratio —
  cosine cannot see scale)
- Engagement counters asserted per target
- A real downloaded PEFT adapter loads, or refuses by name with its unsupported targets listed

---

## 10. Risks

| Risk | Mitigation |
|---|---|
| Fused kernels bypass weight adapters silently | the §6 invariant, built first |
| Rank r costs more than rank 1 in the folded kernel | measure at r = 1, 2, 8 before adopting; sequential reductions first |
| General mode never gets a producer | ship projection only; general mode is spec, not code, until PLAN-LORA delivers |
| Rename churn conflicts with upstream | the rename touches fork-owned files; upstream seams shrink because the attn arm goes |
| Upstream declines again | PR 1 is standalone-useful locally; nothing here depends on it being merged |

---

## 11. Rough effort (estimates, not measured)

| Piece | Days |
|---|---|
| Format + loader + registry generalization | 1–2 |
| Residual rank r (both call sites) | 1 |
| Rename: request / settings / CLI / Swift UI / strings | 1–2 |
| Weight-target survey | 0.5 |
| Weight targets (attention + linear_attn + shared expert) | 3–5 |
| PEFT key mapping + `Arch.qwen4_exp` table | 1–2 |
| Tests + docs + AGENTS.md | 2–3 |

~2 focused weeks for both PRs.

---

## 12. First session should do

1. `tests/bank_to_adapter.py` + the equivalence test. Proves the format with no engine change.
2. Layer-cosine check on the existing bank (`cos(d_k, d_j)` across 48 layers) — CPU only,
   tells us whether rank > 1 is likely to be coherent and whether a per-writer weight
   formulation could ever match the per-layer residual one.
3. The §5.1 survey table.

None of the three needs a GPU or a loaded model.
