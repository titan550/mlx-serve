# Steering port onto v26.11.1 — decisions (2026-10-30)

Reviewed from four seats: plugin architecture, kernel/SDK, host API + app, test/verification. Each decision names the
seam it respects; "feasible" means no steering-specific knowledge leaks into the host or the ABI.

D1  Steering is a MODEL SETTING, applied per model, never per request. The request-level `steering` and
    `steering_capture` fields are gone; prefix-cache keying, bank pins and per-row plans go with them.
    Seam: the host knows only Model Settings JSON; the plugin decides what a setting means.
D2  Live changes cross the plugin ABI through ONE generic hook, `ModelTable.apply_settings(m, settings_json)`,
    optional, at the end of the extern table (size-versioned). It carries whatever keys the host lets a user change
    on a loaded model (today: `steering`); the plugin applies what it serves and refuses the rest by verdict.
    The host reaches it through the engine API (`host/engines/mlx.zig` table) and the GPU thread's side queue,
    like embeddings: no intree.zig, no engine knowledge of steering.
D3  `Caps.dir_steering` declares the fact; the host uses it to list support and to refuse by name before touching
    the GPU thread. Load-time steering rides `LoadCtx.settings_json` (`ModelConfig.steering_override` stamped by
    `applyModelSettings`, serialized by the driver's `loadSettings`, parsed by the plugin like `lm_head_mxfp8`).
D4  The fold lives in the SDK block (`sdk/blocks/hc/hc_decode2.zig` `Pending.steer`, `kernels/hc/hc_decode2_nd.metal`
    ST block, contract updated), ffn arm only (the stream after the MLP write). The plugin passes the steer at its
    two MLP-write seams; the chain (`projectStream`) serves prefill, CUDA and shapes the two-launch read declines.
    The MTP head's reads never receive a steer.
D5  The bank is the plugin's (`plugins/qwen4_exp/steer.zig`): parse, read, size check, bf16 rows per layer. The
    host validates the name/path and the file size against the model's shell (named 400) first.
D6  The active setting per loaded model is HOST state (`LoadedModel`), set at load and after a confirmed apply;
    `GET /v1/steering` and `/props` never query the engine. `persist:true` writes model-settings.json.
D7  No env variables, no kill switches: OFF is bit-identical by construction (the plugin's frozen proof tapes are the
    guard); fold vs chain is a tolerance bar against float64 truth, the same class as upstream's prefill-vs-decode
    HC launches.
D8  Capture (bank building) is deferred: `tests/build_steering_bank.py` and the fixtures stay in the tree with a note;
    phase 2 rides `abi.Forward.capture_layers` engine-side.
D9  `mlx-serve steer` stays (host/cli/steer.zig), ffn-only; the app keeps both surfaces (tray box, Model Settings
    row) with one scale field; `ffn == 0` is off.

Order: merge (upstream side on every Zig conflict, steering files deleted) -> SDK fold + test -> plugin -> ABI hook +
engine path -> host (settings, flags, API, props, CLI) -> app -> docs -> builds.
