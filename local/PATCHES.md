# Ledger of the fork's changes (see CHANGE-POLICY.md §5)

Entry names are the feature they carry (the old two-letter ids are in the table below, so an older note or commit
message still finds its entry).

| old id | entry |
|---|---|
| F1 | `dev-build-version` |
| CR-A | `qwen4-exp-ablation` |
| CR-B | `ablation-prefix-cache` |
| CR-C | `ablation-model-setting` |
| CR-E | `ablation-strength-range` |
| CR-G | `ablation-profile-strength` |
| CR-F | `ablation-profile-name` (dropped) |
| D1 | `per-layer-steering` (dropped) |

Base: `v26.11.2`. `fork-main` = base + merges of the active entries. Budget check (fork-only entries, upstream
files): run `git diff --numstat origin/main fork-main` filtered to files on `origin/main`; as of 2026-11-06 the
whole delta is +1671/−359 over 52 upstream files, all of it in entries with PRs intended, so the fork-only
count is `dev-build-version`'s 2 lines.

### dev-build-version — SUPERSEDED upstream, our patch dropped
- Level: L3          Status: **dropped 2026-11-10** (upstream `scripts/dev-version.sh`)
- Why it existed: `app/build.sh`'s no-`gh` arm read the tracked plist (26.11.1 even on the v26.11.2 tag), and the app
  matches a plugin kit by that string, so a fork build installed plugins against the wrong release's kit.
- Superseded by: upstream's `scripts/dev-version.sh` (with `tests/test_dev_version.sh`), "the newest release tag
  behind HEAD, so the engine and the plugin kit the app fetches for it match the source". The merge into
  `origin/main` took upstream's block and dropped our two lines.
- What stays ours: `local/build.sh` stages the kit under the same version (`scripts/dev-version.sh`), installs the
  plugins `local/plugins.conf` pins, and relaunches last — fork-only, no upstream file.
- Upstream-file lines: 0.

### qwen4-exp-ablation — qwen4_exp serves directional ablation (`Caps.ablation`)
- Level: L5          Status: active, PR pending the owner's review
- Why: upstream's #1045 gave the server per-request ablation but no in-tree model declares the cap; the
  fork's steering (PR #538, closed) needed a sanctioned seam.
- Branch: `ablation/qwen4-exp`       Files touched: `src/plugins/qwen4_exp/{ablate.zig (new), forward,
  hc, hc_fused, plugin, trunk, config}.zig`, `src/sdk/blocks/hc/{hc_decode2.zig, contract.zig,
  hc_decode2_test.zig}`, `src/kernels/hc/hc_decode2_nd.metal` (+ `kernels/digests.txt`), `served_test.zig`,
  `tests/test_qwen4_ablation.sh`, `tests/CLAUDE.md`, the plugin's `AGENTS.md`       Upstream-file lines:
  +1116/−315
- Conflict points: `hc_decode2.zig` and its Metal kernel (upstream tunes them), `forward.zig` write sites.
- Off switch: no profile selected → the forward is byte-identical (strength-0 companion test).
- Tests: the class guard across every path (worst cos 0.00195 vs bar 0.02), mixed-batch bit-exact, kernel
  contract AB arm, `tests/test_qwen4_ablation.sh` live.
- Upstream: yes (PR A, after review).       If declined: carry; it is one plugin folder plus one kernel arm.
- Drop when: upstream ships ablation for qwen4_exp itself.
- Notes: a direction built with thinking off does nothing with thinking on (STRML, #1045); rebuild with
  thinking on (roadmap).

### ablation-prefix-cache — `prefix_cache`: isolated | shared for ablated requests (two modes)
- Level: L5          Status: active (revised 2026-11-09), PR pending the owner's review
- Revision: `read` dropped (merged `0846990c`) — it had no consumer beyond a request naming it. With it gone a
  request has nothing left to choose (`isolated` is what it gets; `shared` is the operator's call because it
  lets one request's KV serve another), so the request-level `prefix_cache` field is a named 400 and the mode
  lives only in the model setting. That removes `reads_base_prefix` and its four engine branches.
- Why: an ablated mid-session turn must reuse the unsteered prefix (a feature: no re-prefill for a long
  session); upstream isolates by default.
- Branch: `ablation/prefix-cache`       Files touched: `src/sdk/request/ablation.zig`, engine `slot.zig`,
  `prefill.zig`, `prefill_interleave.zig`, `host/api/ablation.zig`, `docs/api.md`, deepseek_v4
  `served_test.zig`       Upstream-file lines: +248/−269
- Conflict points: `prefill.zig` checkout/restore path; `slot.cache_variant`.
- Off switch: default `isolated` upstream; the fork's model setting picks `shared`.
- Tests: served test on llama's conformance fixture; prefix cache suites.
- Upstream: yes (PR B).       If declined: carry; or reshape so the model setting alone selects it.
- Drop when: upstream adopts a cache-reuse mode for ablation.

### ablation-model-setting — per-model `ablation` setting (`model-settings.json`), `/props` + `/v1/models` rows, app UI
- Level: L1 + L5          Status: active; upstream as an issue first (UI is a harder sell)
- Why: every client of the server should be steered without sending a field; the owner wants the menu-bar
  control and Model Settings section the old fork had.
- Branch: `ablation/model-setting`       Files touched: `sdk/request/ablation.zig`, `model_settings.zig`,
  `host/api/ablation.zig`, anthropic/responses/props/models surfaces, `tests/test_ablation_model_setting.sh`;
  app `Models/Ablation.swift` (new), `Views/AblationControls.swift` (new), `ServerOptions`, `ServerManager`,
  `APIClient`, `ChatModels`, `ModelSettingsFile`, `ModelSettingsSheet`, `StatusMenuView`, localizations,
  `app/CLAUDE.md`       Upstream-file lines: +1538/−301 (cumulative with `ablation-prefix-cache`'s base)
- Conflict points: the four API surfaces' request parsing; `ModelSettingsSheet`; `StatusMenuView`.
- Off switch: no `ablation` entry in the model's settings.
- Tests: model_settings, props, anthropic, responses suites; app tests (4308, 0 failures).
- Upstream: issue for C; PR only if they want it.       If declined: carry the server half (small, settings
  file read); the app half is the biggest fork-only surface and the first candidate for §7.
- Drop when: upstream has a server-side default for ablation.
- Notes: steering-lab's "off" arms are ablated by this setting until the lab sends strength 0.

### ablation-strength-range — ablation strength above 1 (one constant, `max_strength = 30`)
- Level: L4          Status: active, merged to `fork-main` 2026-11-08 (`e5b705ba`)
- Why: upstream documents a strength in (0, 1]. Measured on Sushi-STQ-1.75bpw, one direction, thinking off:
  s=1 leaves 11/15 refusing, s=2 5/15, s=3 1/15, s=4 0/15, with 0/10 benign over-refusals at every step.
  With the upstream cap the feature cannot clear a refusal this model holds strongly, which is the whole
  point of using it.
- Files touched: `src/sdk/request/ablation.zig` (`max_strength`, the parse and its tests),
  `src/host/api/ablation.zig` (the refusal matrix's sentence), `app/Sources/MLXServe/Models/Ablation.swift`
  (the same bound, so a stored 4 is neither refused nor dropped on save), `app/Tests/…/AblationTests.swift`.
  Upstream-file lines: ~40.
- Off switch: none needed — a strength in [0, 1] behaves exactly as before; the cap only widens what is
  accepted. A server without it refuses the value with its old sentence.
- Conflict points: the strength parse in `sdk/request/ablation.zig`; the app's `AblationSetting` bounds.
- Tests: `zig build test -Dtest-filter="ablation"` 77/77; `AblationControlTests` 11/11 including a new case
  that a stored strength above 1 survives a read.
- Measured on the FULL held sets (99 harmful / 100 benign, sequential, thinking off, Sushi-STQ-1.75bpw,
  single direction captured thinking off): no ablation 97/99 (0.98) and 8/100 (0.08); strength 3 at layer 37
  6/99 (0.061) and 4/100 (0.04); **strength 4 at layer 37 4/99 (0.04) and 2/100 (0.02)** — adopted as the
  model's setting. A "never refuse" system prompt stacked on strength 3 was 9/99 (0.091) against strength 3's
  6/99: no help, within noise. A per-layer bank at strength 4 was 7/15 and 2/10 on the screening set (`ablation-profile-name`).
- Upstream: yes, and it is the best single candidate (2 lines of behaviour, with numbers).
- Drop when: upstream's `Ablation` range changes on its own.

### ablation-profile-strength — a profile declares its strength and its measured ceiling
- Level: L4/L5          Status: active, merged 2026-11-09
- Why: the safe strength is a property of the PROFILE, not of the caller. Measured on Qwen3.8-Flash-Next
  (qwen4_exp, hyper-connections): strength 1 is byte-identical to no ablation on 6/8 benign prompts; strength 3
  emits `'ioioioio…'` and empty answers, strength 4 one-word garbage — the projection reflects components in all
  four hc streams and compounds over 48 layers. On Sushi (single-direction, 5120-wide) strength 4 clears 96% of
  refusals with no benign damage. One global cap cannot serve both, and a caller cannot know which is which.
- Shape: `manifest.json` gains optional `strength` (the strength the profile was measured at: what a request or
  setting that names none runs) and optional `max_strength` (the strongest measured safe; default = the global
  30). Resolution: request > model setting > profile default. Above the profile's ceiling is a named 400.
- Surfaces: `/v1/models` `ablation_profiles` becomes objects `{name, strength, max_strength}` so the app seeds
  its strength field from the profile and bounds it; `/props` reports the setting's strength as written (null =
  the profile's default).
- Files touched: `src/host/api/ablation.zig` (Profile, parseProfile, select, rowJson, propsFragment),
  `src/sdk/request/ablation.zig` (optional `Field.strength`), `src/host/registry/model_settings.zig` (optional
  setting strength), app `Models/Ablation.swift` + `Views/AblationControls.swift` + `APIClient` + `ChatModels`,
  `tests/test_ablation_model_setting.sh`, `docs/api.md`. Upstream-file lines: ~90.
- Off switch: a manifest without `strength`/`max_strength` behaves exactly as before (default 1, ceiling 30).
- Tests: ablation 76/76, model_settings 80/80, `test_ablation_model_setting.sh` 11/11, app
  `AblationControlTests` 11/11 + `AblationServerReportTests` 3/3.
- Upstream: plausible as "a profile carries the strength it was measured at"; it also makes `ablation-strength-range` safer.
- Drop when: upstream's manifest gains a strength field of its own.

### Thinking on vs off (measurement, not a code change)
- 2026-11-09, Sushi-STQ-1.75bpw, harmful_held 99: **refusals with thinking on are 3/99 (0.030) unablated**,
  against 97/99 with thinking off. The model argues the refusal out of itself when it thinks, so there is almost
  nothing left for an ablation to remove, and the thinking-off direction does not transfer: at strength 4 it
  scored 5/99 (3 of them the same prompts), i.e. noise, with two prompts newly refused.
- Consequence: a thinking-ON profile is NOT needed. It would have to be fitted against a 3-prompt residual,
  which cannot beat not steering at all. One profile (thinking off, layer 37, strength 4) is what the model
  setting names; a thinking request runs the same profile and the ablation is inert over an already-low rate.
- If steering a thinking request ever matters, fit it on the residual (3 prompts here), never reuse a
  thinking-off direction — the earlier 14/15 reading was the same non-transfer, not a mode artifact.

### ablation-profile-name — `abi.Ablation.name` (the profile's directory name, so a plugin can load a per-layer bank)
- Level: L5          Status: **DROPPED, not built** (2026-11-08)
- Why it was proposed: an outside plugin (`sushi_ds41`) wanted to load a per-layer `bank.f32` by profile name;
  upstream's `Ablation` carries only `directions`/`strengths`/`keys`.
- Why dropped: the per-layer bank measured WORSE than the single direction upstream already ships. Same 25
  prompts, sequential, Sushi-STQ-1.75bpw thinking off: bank (31 of 41 sites) at strength 4 leaves 7/15
  refusals and 2/10 benign over-refusals; one direction at layer 30/37/38 at strength 3-4 leaves 0/15 and
  0/10. A DM profile is broadcast to every site by the plugin, so "single direction everywhere" and "bank"
  edit the same sites; the only difference is per-site directions, and per-site unit normalization lifts
  early-layer noise (norm ~30-42 below site 20, ~68-97 in the signal band) to full strength.
- Consequence: no ABI change, and the plugin's bank path (`bankFor`/`loadBank`/`bankArray`, the site-indexed
  `siteDir`/`siteCol`) is dead weight that also caused the only two plugin defects found (the exact-size
  limited read and the past-the-bank site).
- Drop when: n/a — dropped. Reopen only for a per-site concept (a different direction per layer on purpose,
  not one concept sharpened), which needs no ABI field: the manifest's `pick` can carry a site map.

### per-layer-steering — per-layer steering bank for qwen4_exp (PR #538)
- Level: L5          Status: dropped (2026-11-05) → tag `steering-bank-v1`, branches on `private`
- Why dropped: owned an ABI bit, a route (`/v1/steering`) and a CLI; conflicted on every merge; upstream's
  #1045 is the sanctioned seam and single-direction ablation proved sufficient (user test 2026-11-06).
- Notes: the only runnable per-layer arm is `~/claude-tmp/steering-fork-26.11.1.app`; capture-capable old
  build `~/claude-tmp/steering-capture/MLX-Serve-26.10.3.app`; converter
  `~/claude-tmp/ablation-scratch/bank_to_profiles.py`.

### Stale — `fix/qsa-select-tiny-array`, `fix/tiny-qwen4-fixture-guards`
- Status: **deleted 2026-11-09**. Pre-rewrite (#978) fixes; the rewritten tree already declines the defect
  (`contract_qsa_attn.zig`: `shape.rows * shape.k < 8` returns null, and the block lists bind as one array under
  8 elements), so the patches are obsolete and their branches were based on an ancient tree.

## Planned (not implemented; call out before starting, §4)
- **`qwen4-exp-capture-tap`** — env-gated capture tap in qwen4_exp (`QWEN4_TAP_DIR`, <100 lines, one plugin
  folder), sushi's shape. L5, upstream-worthy.
- **`deepseek-v41-ablation`** — `Caps.ablation` on the in-tree plugin. Plan: `local/notes/native-ds41-ablation-plan-2026-11-09.md`
  (tap first, fusion declined). L5.
- **Plugin side (CommunityServe/plugins, not this repo):** `expert_pick_tolerance` as a sushi_ds41 model
  setting; the `PREFILL_TOP_K` lines folded into a patch file. L2.
- **Dev-build kit in the app** — Install uses the build's own kit for a non-release version. Supersedes `dev-build-version`'s
  env var. L4, upstream-worthy.

## Outside plugins reviewed (CHANGE-POLICY §4 L2)
- `sushi_ds41` @ CommunityServe/plugins `59473a90` (plugin last touched `203ed90`, 2026-11-05): PASS
  2026-11-06. Details in `local/notes/roadmap-2026-11-06.md` step 1. Pinned in `local/plugins.conf` at
  `00f9bec` (2026-11-07; the delta from `59473a90` is `plugin.json` title/homepage/icon metadata and an
  `icon.png`, no code). Installed by `local/build.sh plugins` 2026-11-07, sha256 `4804d9cd…`.
- `sushi_ds41` @ `titan550/mlx-serve-plugins` `50a3482` (2026-11-10), a fork of CommunityServe/plugins: one
  commit, "ablation strength above 1, up to mlx-serve's cap" (accept 0..30; test at 4 and 31). Upstream `main`
  moved to `cfc3704` since the review and its `KIT_VERSION` is 26.11.3 while mlx-serve's newest tag is
  v26.11.2, so it was built here against our 26.11.2 kit. The dropped per-layer bank (measured worse, see
  `ablation-profile-name`) is preserved on the same fork as `feature/per-layer-bank`.
  Local layout: bare `~/workplace/local-ai/mlx-serve-plugins.git` (origin = the fork, upstream =
  CommunityServe/plugins), main worktree `~/workplace/local-ai/mlx-serve-plugins`, and `~/.mlx-serve/plugin-src`
  is a symlink to that worktree. Installed sha256 `b73e2cd6…`.
