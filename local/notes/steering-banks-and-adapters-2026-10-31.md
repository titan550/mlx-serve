# Steering after the v26.11.1 port: building banks, and what comes next

Status 2026-10-31, branch `steering/upstream-pr`. Companions: `adapters-plan.md` (the general adapter engine plan,
written before the merge), `steering-port-adr-2026-10-30.md` (this port's decisions), and the lab's
`~/workplace/local-ai/steering-lab/{BACKLOG,PLAN-LORA,METHOD}.md`.

Nothing here is decided. It records what the port removed, what still works, and the options, so the choice
between rebuilding bank-making in mlx-serve and moving it to a general LoRA trainer/builder can be made later.

---

## 1. Where things stand

The merged server: upstream v26.11.1 (merge 3afda6bd) plus the port as ONE squashed commit, which carries the fold,
the app, the server feature and the review fixes. `tests/test_qwen4_steering.sh` passes 53/53 live. The repo's `app/MLX-Serve.app`, the app in daily use, is rebuilt from this tree, and its server
arms the saved `refusal_qwen3.8-flash-next-iq-4.7bpw` entry at load. It no longer captures: the preserved bundle
below is the only capture-capable build on disk.

| Serves | Does not serve |
|---|---|
| a model-level `steering` Model Setting: `model-settings.json`, `--dir-steering-file` / `--dir-steering-ffn`, `GET`/`POST /v1/steering`, `mlx-serve steer`, the app's tray box and Model Settings row | the per-request `steering` field |
| the ffn arm, folded into the two-launch hyper-connection read up to 16 rows (decode, verify, batched slots); the f32 chain elsewhere | `steering_capture` and `MLX_SERVE_STEERING_DUMP_DIR`: no bank building |
| every bank in the existing format (raw f32 `[48][2560]`) | the attn arm; the lab levers `mode: add`, `layers`, `threshold` (never on the PR line) |

Plugin seams: `ModelTable.apply_settings` (live changes, generic JSON keys), `Caps.dir_steering` (which models take
it), `hc_decode2.Pending.steer` (the fold). The host never sees the math.

### Builds that still capture

| Build | Capture | Per-request `steering` | Lab levers | Where |
|---|---|---|---|---|
| v26.10.3 PR-line app bundle (built Oct 23) | yes | yes (ffn, attn) | no | `~/claude-tmp/steering-capture/MLX-Serve-26.10.3.app`; its server runs from there |
| its source | yes | yes | no | `8bbfca70` (first parent of the merge) |
| `lab/steering-full` | yes | yes | yes | branch at `2f5a1502` |

Rebuilding either source needs the three submodules upstream has since absorbed (`lib/sushi`, `lib/mlx-serve-gguf`,
`lib/mlx-stream`): a worktree at the commit plus `git submodule update --init`. The preserved bundle avoids that,
but serves no lab levers: the band, threshold and additive tools need a `lab/steering-full` build.

Using the bundle with the old builder (quit the app first; the pack does not fit twice):

```sh
MLX_SERVE_STEERING_DUMP_DIR=~/claude-tmp/caps \
  ~/claude-tmp/steering-capture/MLX-Serve-26.10.3.app/Contents/MacOS/mlx-serve \
  --model ~/.mlx-serve/models/ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit \
  --serve --host 127.0.0.1 --port 11420 --max-concurrent 8
```

The merged server loads the resulting `.f32` unchanged.

---

## 2. What breaks against the merged server

| Lab tools | Need | Against the merged server |
|---|---|---|
| `build_direction`, `build_onpolicy`, `capture_set`, `direction_probe`, `steered_separation`, `capture_all_rollouts`; mlx-serve's `tests/build_steering_bank.py` | `steering_capture`, the dump dir, `GET /v1/steering` reporting `capture: true` | refused at the capture check, loudly |
| `refusal_bench`, `verbosity_bench`, `perf_bench`, `release_bench`, `rollouts`, `build_boundary`, `thought_vs_answer`, `toolcall_gate_probe`, `toolcall_integrity` | per-request `steering` arms within one boot | **silently wrong**: no handler reads the field, so every arm gets a 200 and runs the model's own setting |
| `refusal_bench` band arms, `jacobian_probe`, `threshold_probe` | `layers`, `mode: add`, `threshold` | only `lab/steering-full` ever served these |

The second row is the hazard: plausible numbers for arms that never ran. Until a direction is chosen, point the lab
only at a capture-capable build.

**A guard worth adding whatever is chosen:** the merged server refuses a request that carries `steering` or
`steering_capture`, by name (400: per-request steering is not served by this build; set the model's steering with
`POST /v1/steering`). That is `adapters-plan.md` §6's engage-or-refuse rule applied to the fields the port removed.

---

## 3. Constraints already on record

- **Lab `BACKLOG.md`, "Engine surface audit":** the engine LOADS a bank and does not build one. The capture path
  lives on a bank-making branch, not on the serving line.
- **`adapters-plan.md`:** one adapter mechanism, `out += scale · B(A·in)`; a residual target (banks) and weight
  targets (LoRA); a per-request list grammar; every declared target engages or refuses.
- **`PLAN-LORA.md`:** adapters are trained outside the engine (mlx-lm with PR #1788, or rented H100s with transformers
  + PEFT), behind Gate 1 (prompt + steering may already suffice) and Gate 2 (can this architecture be trained here at
  all). A trained adapter is never published (§8).
- **The port's ADR:** model-level only, ffn only, no capture, the fold kept.

---

## 4. Options for building banks

Every option must produce the same rows the old capture wrote: per layer, the residual after the layer's MLP write,
averaged over the 4 hyper-connection streams, at the last token of a rendered sequence. On-policy capture takes
that token inside a rollout (the lab settled on 32 generated words), so the sequence is arbitrary text, not only a
user prompt. The bank math (mean difference, orthogonalized against the control mean, normalized) is the lab's and
does not change.

### A. Keep a frozen bank-making build (status quo)

The preserved v26.10.3 bundle, or a `lab/steering-full` build, does every capture and every per-request A/B; the
merged branch only serves the resulting banks.

- Cost: none.
- Every lab tool keeps working unchanged.
- Respects "the engine loads, does not build".
- Limits: frozen to the old engine. It works only on packs it can load (a new pack layout or model ends it), cannot
  measure the merged engine's own steering path, and leaves two binaries to keep apart.

### B. Build banks in the external training stack

Capture with a forward hook in the Python stack that will train LoRAs, and keep the lab's math. mlx-serve stays
load-only.

- Fits the LoRA direction: one toolchain builds banks and adapters; mlx-serve serves both.
- Respects the constraint.
- Needs a hook at exactly the capture point above, and a parity gate before trusting it: per-layer cosine between a
  bank built this way and one built with A on the same prompts.
- Limits: mlx-lm has no `qwen4_exp` (PR #1788: open, inference-only, last updated 2026-10-04). A transformers bf16
  load does not fit this Mac (PLAN-LORA's rented route). Whether a bank captured on bf16 activations steers the
  served 4-bit pack the same is for the parity gate to answer.

### C. Re-port capture onto a bank-making branch of the merged tree

The backlog's three-line split, on the plugin layout: a branch off `steering/upstream-pr` that adds capture back
without touching the serving line.

- The engine half is small. The plugin already publishes the stream after each layer's MLP write through
  `abi.Forward.capture_layers` / `ForwardOut.captured` (DFlash uses it), so a capture forward needs no new plugin
  hook; the engine averages the streams at the last token and writes the rows.
- The host half can keep the old request shape (`steering_capture` + the dump dir), so the lab's capture tools run
  unchanged; it needs to accept and ignore the `steering: {ffn: 0, attn: 0}` those requests send.
- Cost: a few hundred lines with tests, and one more branch to rebase at every upstream merge.
- Respects the constraint and keeps the lab on the current engine.

### D. Native `mlx-serve steer build`

The server builds banks itself (`POST /v1/steering/build`, host-side math, no Python).

- Cost: about C's plus the math.
- Contradicts the constraint. Worth it only if bank-making becomes a product feature, such as an app button.

### The per-request axis: the lab's same-boot A/B

Independent of how banks are built, the lab's harness runs several arms against one boot.

- **E1.** Measure on the frozen build (with A). No work.
- **E2.** Run arms one at a time, `POST /v1/steering` between them. A harness change; concurrent mixed arms are lost.
- **E3.** Per-request steering through the plugin ABI: a per-slot setting on `abi.Forward` (an ABI change; the plugin
  kit's header regenerates) and per-row steers in the fold (the old fork's mixed-batch path). Medium cost; the only
  way the merged engine serves the harness as it is.

---

## 5. Where a general LoRA trainer fits

- **Different edits.** A bank is a rank-1 edit of the residual; a LoRA edits weights, `y = Wx + s · B(Ax)`. The
  residual target has no weight equivalent at equal cost: emulating the ffn edit on every writer, routed experts
  included, is about 65 MB of weight adapter against the bank's 0.49 MB (`adapters-plan.md` §3 sizes).
- **A trainer does not replace capture.** Banks, and analytic rank-1 adapters, still come from captured activations;
  only trained adapters need gradients. So a general LoRA builder pairs naturally with B: the same Python stack
  captures for banks and trains adapters, and the engine stays load-only.
- **Serving trained adapters is new engine work.** `sdk/weights/lora.zig` (runtime stacked LoRA) attaches only to the
  media backends today. The qwen4 plugin owns its projections, so weight targets mean hooks in
  `src/plugins/qwen4_exp/` (attention, `linear_attn`, the shared expert, per `PLAN-LORA.md` §3.5). Model-level
  selection can ride `apply_settings` now; per-request selection needs E3's ABI change.
- **Runtime cost.** The fold makes steering nearly free: before the merge, both arms on, M5 Max, mixed-4-8bit, decode
  measured −0.8% folded against −3.3% unfolded (commit 349b39d3; ffn-only should cost less, not re-measured on the
  merged tree). A runtime LoRA adds two small matmuls per adapted linear per token on a decode that is dispatch
  bound. Measure before adopting.
- **Portability.** A trained adapter reproduces the behaviour with no server support, which makes it easier to leak
  than a bank (`PLAN-LORA.md` §8).

---

## 6. By goal

| If the goal is | Do | Skip |
|---|---|---|
| keep the lab running now | A + E1, plus the §2 guard | the rest, until Gate 1 and Gate 2 answer |
| go the LoRA way | B (behind the parity gate), then LoRA serving in the plugin; A bridges until then | C, D |
| bank-making on the current engine without a Python trainer | C, with E2 or E3 for measurement | D |
| bank-making as an app feature | D | |

Read: A and the guard now, and let PLAN-LORA's two gates choose between B and C. D only if bank-making should become a
product feature, which the backlog has ruled out so far.

---

## 7. `adapters-plan.md` after the merge

Every anchor in its §2 moved:

| Was | Now |
|---|---|
| `src/hc_decode2.zig` (`Steer`, `Pending`, the ND source) | `src/sdk/blocks/hc/hc_decode2.zig` (`Pending.steer`), `src/kernels/hc/hc_decode2_nd.metal` (the `ST` block, ffn only, rank 1), its line in `src/kernels/digests.txt`, the contract in `src/sdk/blocks/hc/contract.zig` |
| `transformer.forwardQwen4With` seams | `src/plugins/qwen4_exp/forward.zig` (the MLP-write seams), `hc.zig` (`hcWriteOrDefer(.., steer)`, `steerStream`) |
| `src/steering.zig` | `src/sdk/config/steering.zig` (setting, registry, `served`) and `src/plugins/qwen4_exp/steer.zig` (bank rows, chain) |
| `src/steering_http.zig`, `src/steering_cli.zig` | `src/host/api/steering.zig`, `src/host/cli/steer.zig` |
| `src/lora.zig` | `src/sdk/weights/lora.zig`, still media-only |
| per-request `requestSteering`, `Banks` pins | gone; `ModelTable.apply_settings` carries live changes |

Done from the plan: the attn arm is gone (§4.1), the fold is kept, steering is a model-level setting with live apply.
Not done: the safetensors format, the rename to adapters, a registry with pins, the per-request list, rank r, weight
targets.

What the plugin layout changes for the rest:

- Weight-target hooks live in each plugin's own projections; a plugin may import `sdk/`, so `lora.zig` is reachable.
- Per-request selection is an ABI question: `abi.Forward` has no per-slot adapter field, so the plan's request grammar
  costs an ABI change that the model-level route does not.
- Engage-or-refuse maps onto `apply_settings` verdicts: `unsupported` is a named refusal.

---

## 8. Open questions

1. Does the lab need the merged engine (speed, upstream fixes), or is the frozen build acceptable as its measurement
   platform for now?
2. Gate 1 and Gate 2 outcomes decide between B and C.
3. Should `tests/build_steering_bank.py` and `tests/fixtures/steering/` stay in mlx-serve, or move into the lab beside
   `build_direction.py`? The backlog's constraint argues for the lab.
4. Is per-request steering needed beyond the lab? That is what E3 costs.
