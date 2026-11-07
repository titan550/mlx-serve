# CR-D: building ablation profiles — plan (2026-11-06)

Goal: make new directions for Flash-Next (and any model that serves layer capture) with the smallest, most mergeable
change to mlx-serve. Input: the steering-lab review (`~/workplace/local-ai/steering-lab`) and the shipped CRs.

## Split the work where it belongs

| Piece | Lives in | Why |
|---|---|---|
| Capture: per-layer residual at chosen prompt positions | **mlx-serve, CR-D** (~250 lines) | needs the forward; nothing outside can run the iQ pack |
| Math: difference of means, PCA/pc1, whitening, layer screens, profile writer | **steering-lab (Python)** | already written (`build_direction`, `build_onpolicy`, `study_data`, `bank_to_profiles.py`); upstream never has to own it |
| Evaluation: refusal bench, judge, drift | **steering-lab** | already written; needs an `ablation` arm |

Not a plugin: outside plugins are model tables; they cannot add a request option or route. But the engine half
already IS the plugin ABI: `abi.Forward.capture_layers` / `ForwardOut.captured`, served by qwen4_exp, glm5_next,
deepseek_v4/v41 (refuses today) and the template, and driven by DFlash. CR-D adds no ABI and no kernel; it is host
plumbing to an existing seam, so it is model-agnostic and cheap to carry across upstream merges.

## CR-D: a `capture` request option (upstream-shaped)

- **Surface:** `"capture": {"layers": "all" | [int], "positions": [-1]}` on `/v1/completions` and
  `/v1/chat/completions`, modelled on `prompt_logprobs` (same cold-prefill path: `skip_prefix_cache`, serial prefill).
  The response carries `"capture": {"prompt_tokens", "prompt_sha256", "layers": {"<l>": [[f32 base64 per position]]}}`.
  Rows are the plugin's raw captured hidden (Flash-Next: `[hc*hidden]`, the 4 streams); the client averages streams
  (the lab knows `hc` from config). No host knowledge of hc.
- **Gates (named 400s):** a plugin that does not serve capture; a request that also names `ablation` unless
  `"capture": {"ablated": true}` (the lab's steered-capture opt-in, recorded in the response); `n > 1`; more than the
  plugin's 64-capture cap. Loopback-only or behind `--api-key` like other introspection; never forwarded to LAN or
  providers (the ablation proxy-refusal rule).
- **Engine:** the slot sets `ctx.capture_layers` on the prefill chunk that holds the requested positions (the last
  chunk for `-1`); the driver already copies `captured` out. `max_tokens` 0 means prefill only.
- **Tests:** a served test on qwen4's fixture (capture equals the stream the class-guard test reads; cold prefill
  enforced; `ablated` gate), a refusal matrix for the parser, `tests/test_capture.sh` live.
- **Size:** host parse + response (~120), SubmitParams/slot/prefill wiring (~60), tests (~120). No ABI, kernel or
  app change.

## steering-lab changes (no mlx-serve code)

1. Capture tools (`capture_set`, `build_direction`, `build_onpolicy`, `direction_probe`, `steered_separation`,
   `capture_all_rollouts`): swap the `/v1/steering` probe + dump dir for the `capture` field; average the 4 streams.
2. A `build_profile.py`: captures -> per-layer candidates + pc1/mean -> `manifest.json` + `direction.safetensors`
   stamped with the pack's `config.json` sha (fold in `bank_to_profiles.py`).
3. Eval arms: add `{"ablation": {"profile", "strength"}}` + `X-Ablation-Key`; remove the dead `steering` arm.
4. **Fix now, even without CR-D:** the eval tools currently run against `fork-main` and silently ignore `steering`;
   and the model setting (`refusal-l24`, strength 1) makes every "off" arm ablated. An off arm must send
   `ablation.strength: 0` with the key, or the setting must be removed for the run.
5. Thinking-on directions: STRML's #1045 found a thinking-off direction did nothing with thinking on (layer 17,
   position -2, captured with thinking on, worked). `positions` and `enable_thinking` in the capture request cover it.

## Separate, optional: strength above 1 (CR-E)

The lab's best arm was ffn 2 (reflection: the component flipped, not removed). Ablation caps strength at [0, 1]
(`sdk/request/ablation.zig`). Allowing (0, 2] is a two-line parse change plus a test, but it changes the meaning
("ablation" becomes "reflection" past 1) and REPORT shows collapse from 2.25. Propose upstream only with numbers.

## Until CR-D exists

`~/claude-tmp/steering-capture/MLX-Serve-26.10.3.app` still captures on the iQ pack (old fields, thinking off);
`bank_to_profiles.py` converts. Existing lab captures are on mixed-4-8bit (pack not on disk), so they can only make
profiles for that pack.

## Order

1. Lab fixes 3-4 (an evening, no server change).
2. CR-D on its own branch off main; lab capture tools switched to it.
3. Rebuild refusal with thinking on; then new directions as needed.
4. CR-E only if a sweep shows strength > 1 is worth it.
