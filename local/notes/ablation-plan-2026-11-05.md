# Directional ablation on qwen4_exp: the council plan — 2026-11-05

Replaces the fork's per-layer steering with upstream's per-request ablation (#1045, `Caps.ablation`), single direction
first. Supersedes `merge-plan-2026-11-05.md` sections 2-3 (no 4-conflict merge: the fork restarts from origin/main).
File refs are upstream main (`~/claude-tmp/mlx-serve-main`, cb8dafed) unless marked (fork).

## 0. Brief

1. One direction per profile (upstream's format). Test it; build multi-layer only if it loses.
2. A server-side default per model: no request needs a field or a key. The app keeps its UI for it.
   The setting and its app editors = ONE CR (AGENTS.md: one feature, one PR).
3. Prefix reuse is built, ON by default in the fork. The upstream PR ships it OFF, with an opt-in.
4. Break nothing that already serves ablation (sushi_ds41), and shrink what each upstream merge has to re-port.

## Words

- **Menu bar, never "tray".** macOS says menu bar (tray is the Windows word), the app's user-facing text says menu
  bar, and `app/CLAUDE.md` already uses "tray" for two different things: the menu-bar popover and the media
  generator windows.
- **The Ablation setting** is the model's `ablation` key in `model-settings.json`. It is a Model Setting, not app
  state: the server reads it on every request, so it applies to every client of that model (the app's chat, Claude
  Code on `/v1/messages`, curl, LAN peers). The app's two editors (D11) write the same key.
- **UI labels:**
  - "Ablation": upstream's word; "steering" already names the chat composer's steering notes.
  - "Reuse prefix cache": the app's Settings already say "Prefix cache".

## 1. The council

| Seat | Ruling in one line |
|---|---|
| Architect (ABI, seams) | Adopt upstream's contract verbatim: the fork adds no ABI, no route, no CLI. |
| qwen4 plugin/kernel engineer | Project the WRITE, not the stream. Plain MLX ops cover every path; the decode fold lands in phase 1 for speed parity. |
| Cache engineer | One switch: a `shared` request keeps cache variant 0, and every cache rule follows from that. |
| Host/API engineer | The default is a model setting read per request (like `generation_defaults`), applied on every text surface. |
| App engineer | Model Settings and a menu bar control edit the Ablation setting; the server picks it up on the next request: no POST. The app creates the key file. |
| Security reviewer | The key guards the REQUEST field. The owner's settings file needs none, and nothing ablated is ever forwarded. |
| QA lead | Red-first per AGENTS.md. The class guard is "orthogonal to r after every write, on every path". Snapshot the old app before replacing it. |
| Perf engineer | Unablated stays byte-identical and the same speed. Ablated decode stays within about 1% of today's fork, measured. |
| Upstream steward | Three small PRs, ordered by how easily upstream will accept them. The fork carries one default flip. |

## 2. Decisions

**D1 Build on upstream's ablation; retire the fork's steering.** qwen4_exp declares `Caps.ablation`. Gone: the
`dir_steering` bit, `ModelTable.apply_settings`, `/v1/steering`, `mlx-serve steer`, `sdk/config/steering.zig`,
`plugins/qwen4_exp/steer.zig` and the fork's `hc_decode2` steer arms. Tag `steering-bank-v1` at b0389f0e so the bank
path stays reachable. The cost: after this, the fork owns no ABI field and no route.

**D2 One direction, two candidates.** Built from the iq-4.7bpw bank (`~/.mlx-serve/steering/refusal_qwen3.8-flash-next-iq-4.7bpw.f32`, 48x2560):
- `refusal-pc1`: the bank's first principal component.
- `refusal-l24`: the layer-24 row (Arditi-style: one layer's direction used at every layer).

The bank does NOT collapse to one direction. pc1 keeps a mean cos² of 0.40 over the 48 rows, L24 0.27, and L0
is orthogonal to both. So the test is real, not a formality.

If both lose, use D2'. It is additive and not built now:
- `Ablation.layer_directions` `[slots, layers, hidden]` appended (the struct has a `size`);
- a new `Caps.ablation_layers` bit;
- a `[layers, hidden]` profile shape;
- the host refuses such a profile on a plugin without the bit.

Single-direction profiles and sushi_ds41 are untouched either way.

**D3 What qwen4_exp projects, per upstream's contract.** Every write to the residual, `w' = w − s(w·r)r`, in f32,
cast back to the activation dtype. Keeping the dtype keeps `hcWriteOrDefer`'s same-dtype deferral (`hc.zig:241`) and
never promotes the bf16 residual. Sites:
- the embedding, after the vision splice and before the tile (`forward.zig:373`; verify rows `:127`);
- the PLE `add`, one dot per stream (`forward.zig:416`, `addVerifyPle`);
- attention, GDN and QSA out (`:429`→`:441`; verify rows `:195`, `:214`);
- MoE or MLP out (`:448`→`:459`, also feeding `ladderStepMulti` at `:471`; verify rows `:248`).

That is 98 writes per forward. Each sublayer output is its own `[B,S,H]` tensor before it is written, so no kernel
changes for correctness: Metal decode2, CUDA, the prefill kernel and the joined verify reads all receive `w'`.

Directions come per row: `[B,1,H]` with strengths `[B,1,1]`, built once per forward from `Forward.ablation`
(batched: row b = slot b; verify: S rows broadcast). A strength-0 row is exact: x − 0 = x, and bf16→f32→bf16 round-trips.

This differs from the fork: projecting writes vs each stream after the MLP, and attention writes now included. That
difference is part of what the test measures.

**D4 MTP.** Every VERIFY is ablated:
- solo verify, through `driver.forward`;
- grouped MTP verify, which bypasses the ABI through `modules.call("qwen4_row_axis_verify")`
  (`engines/mlx/batched/row_axis_verify.zig:134`). The trunk reads each engine ctx's `ForwardCtx.ablation` there.

The MTP head's drafts run unablated in v1. The output stays exact for the ablated model, because the target verifies
every token. The cap's "native drafter's rounds" clause names `SpecHooks.native_drafter`, which qwen4 doesn't have.
Measure acceptance in `[spec-stats]`; plumb a direction into the head (`mtp.zig` op-chain writes) only if acceptance drops.

**D5 Clusters.** An ablated forward on a pipeline pair (`dist_peer`, `forward.zig:493`) is a named refusal: the
worker's layers are out of reach. Tensor parallel: verify that both ranks project the summed MoE output, else refuse
the same way.

**D6 Speed.** Baseline, from the fork's 349b39d3 (M5 Max, Flash Next mixed-4-8bit, interleaved boots, medians):
unsteered 65.08 tok/s, op-chain steering 62.92 (−3.3%), folded 64.57 (−0.8%), MTP depth 3 within noise.

- With no ablation the forward adds no op; the frozen tapes prove it.
- The op chain alone (98 sites, one dot per row each) is estimated at 3-7% below unablated.
- The fold projects the pending `out` inside `hc_decode2`'s write branch: per-row `[rows,H]` directions and `[rows]`
  strengths, one dot per row, and a decline falls back to projecting `pd.out`. It is the fork's old ST1 arm
  ("project `out` before the write", 349b39d3, dropped by the 10-30 port) with per-row inputs. It removes 96 of the
  98 op-chain sites, is expected at about −1%, and gets a kernel-contract registration with planted controls.
- The fold does NOT depend on D2: per-layer would only bind a different `[rows,H]` per layer. It lands in phase 1
  (decided), so the build you test is the build you keep.

**D7 Prefix cache: `"prefix_cache"`, set by whoever owns the model's cache.**
- `shared`: the request keeps `cache_variant = 0` (`slot.zig:379`), so it reads AND writes the model's one prefix
  cache, RAM and SSD, as if unablated. Every gate already keys on that variant (`prefill.zig:333`, `commit.zig:101`,
  `prefill_interleave.zig:327,430`, `ModuleBinding.forVariant`).
- `read`: the request may restore unablated entries but commits nothing (a slot flag beside the variant gates).
- `isolated`: upstream's behaviour today. On qwen4 an ablated request neither reads nor writes the KV prefix cache.

Who may set what:
- The model setting (the operator; the app's editors write it) may set all three.
- A request field may set only `read | isolated`. `shared` writes change what every later request on the model
  restores; a client with a shared system prompt would leak its ablation into another client's turns.
- The server default is `isolated` upstream and `shared` in the fork (one constant).
- The profile manifest sets nothing: the cache is the model's, profiles are shared artifacts, and manifests need a
  restart while the model setting applies on the next request.

Precedence: request field > model setting > server default.

Rejected: variant-keyed KV with a fallback to the base entries (upstream's module-cache design, ported to the token
cache). It gives full reuse with no leakage, but it is the bigger change; a later upstream PR.

Accepted cost, documented on `shared`: a later request may restore KV computed under another ablation (or none).
That is the mid-session behaviour wanted on a single-user server.

**D8 Server-side default.**
- **Where it lives:** `model-settings.json` → `"<pack>": {"ablation": {"profile", "strength", "prefix_cache"}}`, read
  per request through `model_settings.Cache` (`model_settings.zig:263`, re-parses on a new inode, at most every 1 s),
  next to `generationDefaults`. An edit applies to the next request.
- **Who wins:** a body field still goes through upstream's path and needs the key; it wins over the default. The
  default applies only when the body names none, and needs no key. Its `prefix_cache` may be `shared` (D7).
- **Surfaces:** chat and completions (`forRequest`); `/v1/messages`, `/v1/responses` and the Responses WS (beside
  `refuseOnSurface`, plus `.ablation = stream.ablation` on their submits, `anthropic_stream.zig:109`,
  `responses/handler.zig:919`); Ollama inherits it through chat.
- **Response:** `X-Ablation` is set, and the log line ends `(model setting)`.
- **A default the server cannot honour** (profile missing, refused, for another pack, or a model without the cap):
  every request on that model fails with a named error, the fork's own rule (10ade6ef, "loud, not a warning"), and
  `/props` reports it so the app shows it before a request fails.
- **Off:** `strength: 0` keeps the profile name. It is upstream's "standard run, header still names the profile", and
  it is what lets the app forget its remembered-bank map.

**D9 What the app reads. The rule is: a model shows the Ablation control iff a profile exists for it.**
- `/v1/models` rows gain `"ablation_profiles": [names]`, loaded or not. A name is listed when the profile loaded
  unrefused, its `base_config_sha256` matches the pack's `config.json` and its hidden size fits. The field appears
  only when the plugin declares `Caps.ablation` (check that cold, stub rows carry the same caps as loaded ones).
- The list is the server's, not the folder's: profiles load at server start, so the app never offers one the running
  server can't use. A profile dropped in later shows up after a restart.
- `/props?model=<loaded>` (the router already resolves `model=`, `router.zig:537`) adds the live `"ablation":
  {"setting", "error"}`. The menu bar polls `/props` already.

**D10 The app owns its key and profiles dir.**
- `toCLIArgs` (`ServerOptions.swift:663`) always emits `--ablation-profiles ~/.mlx-serve/ablation --ablation-key-file
  ~/.mlx-serve/ablation.key`.
- `launch()` (`ServerManager.swift:228`) first creates the dir (0700) and a 0600 key (32 random bytes, hex), and
  leaves an existing key alone (mirror `SandboxSSH.swift:151-187`). Upstream exits at start if the dir can't be opened
  or the key isn't a 0600 regular file owned by the user, and a plain atomic write leaves 0644.
- The key never reaches argv or the log.

**D11 Two editors of one setting.**
Both show only when the model's `/v1/models` row lists a profile (D9), and nowhere else.

- **Model Settings sheet**, the home of every per-model setting. It covers any model, loaded or not, and replaces
  the fork's steering section there. Its "Ablation" section has:
  - a profile picker;
  - a strength field 0-1;
  - "Reuse prefix cache", default on.

  It is save-only: `ablation` leaves `changesLoad` (`ModelSettingsFile.swift:164`) the way `alias` and
  `generation_defaults` do. It re-reads the key at save, so it never reverts a menu bar edit.
- **Menu bar control**, quick access on the chat model's row, where today's steering box is:
  - on/off (strength 1 / 0, the profile name kept);
  - the profile;
  - strength;
  - "Reuse prefix cache".

  Status comes from `/props`, with an error in orange.
- **Both:**
  - an atomic save of the one `ablation` key, applied on the next request;
  - the help text says it applies to every request to this model, from any app;
  - the old `steering` key is dropped on the first write.
- **Dropped from the fork:** `rememberedSteering`, `steeringBank(for:)`, `setSteering`, `SteeringInfo`, the sheet's
  `.live` plan, the 409 handling, the "steer on load" line, the `~/.mlx-serve/steering` bank picker, and the
  console's `/v1/steering` rows.

**D12 Converting the bank is a one-time local step, not repo code.** Upstream has no bank format and no use for a
converter, and the fork doesn't need one checked in either. A throwaway script in `~/claude-tmp/ablation-scratch/`
writes `refusal-pc1` and `refusal-l24` into `~/.mlx-serve/ablation/<name>/{manifest.json, direction.safetensors}`,
with `base_config_sha256` from the pack's `config.json`. The server's own load log is the check:
`[ablation] enabled: 2 profile(s)`, nothing refused. Tests that need a direction make a synthetic one.

## 3. Change requests

All three branch from origin/main.

### CR-A `ablation/qwen4-exp`: qwen4_exp serves `Caps.ablation` (upstream PR 1)
- **Code:**
  - `plugins/qwen4_exp/ablate.zig` (new): builds per-row `[B,1,H]` / `[B,1,1]` from `abi.Ablation` or from engine
    ctxs, `project(w)` and `projectStreams(add)`; null → returns `w`, no ops.
  - `forward.zig`: the six sites in D3.
  - `plugin.zig`: caps, `runOne` / `runBatched` / `runBatchedVerify` set the trunk's per-forward ablation, deferred clear.
  - `trunk/verify.zig`: grouped rows read `ctx.ablation`.
  - The `dist_peer` refusal.
  - `config.zig`: `.ablation = true`.
  - The fold (D6): an ablation arm in `sdk/blocks/hc/hc_decode2.zig` and `kernels/hc/hc_decode2_nd.metal` (per-row
    direction and strength, decline → project `pd.out`), its `kernels/digests.txt` line, and a kernel-contract
    registration in `sdk/blocks/hc/contract.zig` against a float64 reference with planted controls.
- Plus `tests/test_qwen4_ablation.sh`, written fresh. It makes a random-direction profile and checks that `X-Ablation`
  is set, that strength 0 gives stock bytes at temp 0, and that strength 1 differs. Nothing from your bank.
- **Tests, red first:**
  - `config.zig:824` asserts the cap;
  - **the class guard**: at strength 1 every stream is orthogonal to r after every write, on serial prefill, decode,
    batched decode (N=2,3), batched verify, grouped verify rows and an image slot (capture via `capture_layers` /
    `want_hidden`);
  - null or strength 0 reproduces the frozen tapes;
  - a mixed batch: the unablated slot is byte-identical to its solo run, the ablated slot equals its solo ablated run;
  - the dtype stays bf16 and the fused read still engages;
  - the pipeline refusal is named;
  - the real-plugin twin of the driver proof (`plugin/proof.zig:494-559`);
  - the fold matches the op chain on every row and slot mix: byte-identical where the reduction order can match
    (the fork's fold met that bar), else within the contract's bar (`hc_decode2_test.zig`).
- **Gates:** `zig build test` + lint; ReleaseFast bench: unablated decode unchanged, ablated decode within about 1%
  of unablated, MTP solo and grouped (same session, /bench rules).
- **Pitch:** the first in-tree model for their feature.

### CR-B `ablation/prefix-cache`: the three policies, per-request `read` (upstream PR 2, default `isolated`)
- **Code:**
  - `resolve` accepts the field (today it 400s any key but `profile`/`strength`, `ablation.zig:311`); a request may
    name `read` or `isolated`, and `shared` from a request is a named 400;
  - `sdk/request/ablation.zig` `Request.prefix` carries the policy;
  - `slot.zig:379`: `shared` → variant 0;
  - `read`: the lookup gates (`prefill.zig:333`, `prefill_interleave.zig:327`) open while commits stay skipped.
  - About 60 lines. `shared` is reachable only from the operator side (CR-C, the server default).
- **Tests:**
  - the field's parse and refusals;
  - the variant and gates per policy;
  - a served test with the cap forced on (as `deepseek_v4/served_test.zig:232` does for module caches):
    - `read` restores what a plain request committed and leaves nothing behind;
    - `shared` also commits what the next plain request restores;
    - `isolated` still bypasses.
- **Pitch:** "a mid-session ablated turn reuses its conversation instead of re-prefilling it", per-request opt-in
  that can't touch other clients' cache.

### CR-C `ablation/model-default`: the Ablation setting, server side and app editors (fork-first; upstream maybe, issue first)
- **Zig:**
  - `model_settings.Cache.ablationSetting(io, path, buf)`;
  - `resolve` split into the key check + `select(set, value, served)`, shared by body and setting;
  - the surfaces in D8;
  - `/props` `ablation` (D9).
- **Swift:** D10 + D11.
- **Tests:**
  - setting parse and per-request refresh (the `Cache` test pattern with `recheck_ms = 0`);
  - body beats setting;
  - setting needs no key;
  - unhonourable setting → named refusal;
  - strength 0 → standard run + header;
  - `/props` JSON;
  - `/v1/models` lists a profile only for a model with the cap, a matching digest and an unrefused load (a
    mismatched digest, a refused profile and an uncapped model each list nothing);
  - `tests/test_ablation_default.sh`: chat, completions, messages, responses and ollama each answer with `X-Ablation`.
  - Swift: `ModelSettingsFile` round-trip and `changesLoad`, a pure helper for the menu bar control's state, `ServerOptionsTests` (both
    flags), the key helper (0600, ≥32 bytes, existing key kept), strength parse 0-1.
- **Size:** net negative against the fork's current steering UI and host code.

### Fork-only: `fork/defaults`, one commit
The `prefix_cache` default is `shared` (the constant from CR-B). Nothing else.

## 4. Branches and merges

```
origin/main ─┬─ ablation/qwen4-exp     (CR-A) ──► upstream PR 1
             ├─ ablation/prefix-cache  (CR-B) ──► upstream PR 2
             └─ ablation/model-default (CR-C, on CR-B's select())  ──► fork; upstream issue
fork/main = origin/main + A + B + C + fork/defaults      ← the app you run is built from here
```

- Each upstream merge is `git merge origin/main` into each CR branch and into `fork/main`.
- The fork's footprint drops from 65 files / ~3k lines that own ABI, route and CLI to the plugin sites in A, about
  40 lines in B, and C's host and app code.
- A merged upstream CR drops out of the fork for good.
- Before upstream takes A, a qwen4 change on `forward.zig` lines near a site is the only likely conflict.

## 5. Rollout on this Mac (phase 1)

1. **Preserve the old arm first:** `cp -R app/MLX-Serve.app ~/claude-tmp/steering-fork-26.11.1.app`. It is the only
   build that runs the per-layer bank at ffn 1 under 26.11.1.
2. Run the one-time script (D12) to write `refusal-pc1` and `refusal-l24` into `~/.mlx-serve/ablation/` for
   `ddalcu/Qwen3.8-Flash-Next-MLX-Serve-iQ-MLX-4.7bpw` (config sha256 a3929902…). Only this pack is on disk;
   mixed-4-8bit needs its pack before its profile.
3. Build fork/main: `scripts/build-mlx.sh` (MLX 0.32.5), `zig build -Doptimize=ReleaseFast`, `bash app/build.sh`.
4. In the menu bar (or Model Settings): pick a profile, turn it on, keep "Reuse prefix cache" on.
5. **Evaluate the arms** stock, bank@ffn1 (old app), pc1@1 and l24@1 on held-out prompts (NOT the 400 build pairs):
   - refusal rate;
   - benign quality;
   - thinking on and off;
   - temp 0;
   - decode tok/s;
   - MTP acceptance (`[spec-stats]`).

   Mid-session check: the log shows a hot-cache restore (no full re-prefill) on the ablated turn, and `X-Ablation` is set.
6. **The verdict picks phase 2:**
   - pc1 or l24 holds → bench, open PR 1 then PR 2, file the C issue;
   - both lose → D2' and its own CR; the fold binds a per-layer `[rows,H]`.

## 6. Risks

| Risk | Handling |
|---|---|
| One direction is weaker than the bank (coverage 0.40) | Two candidates; D2' is designed and additive |
| Op-chain overhead on decode (est. 3-7%) | D6 fold in phase 1 (the fork's fold measured −0.8%) |
| `shared` serves KV computed under another ablation | Wanted; documented on the field; upstream default stays `isolated` |
| MTP acceptance drops (drafts unablated) | `[spec-stats]`; project in the head if needed |
| A bad default fails every request on the model | The error shows in the menu bar and Model Settings before a request fails |
| Model Settings and the menu bar both write the key | Each re-reads the file and saves only the `ablation` key |
| Upstream reshapes ablation (e.g. adds per-layer itself) | Nothing fork-owned in the ABI to conflict with; follow theirs |

## 7. Decided (2026-11-05)

1. The fold lands in phase 1 (D6).
2. A default the server can't honour fails the request loudly, by name (D8).
3. The Ablation control shows for a model iff a profile exists for it (D9), in Model Settings and on its menu bar row (D11).
4. `steering/upstream-pr` is tagged `steering-bank-v1` and retired once fork/main runs; `notes/` stays as is.
