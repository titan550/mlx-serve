# Ledger of the fork's changes (see CHANGE-POLICY.md §5)

Base: `v26.11.2`. `fork-main` = base + merges of the active entries. Budget check (fork-only entries, upstream
files): run `git diff --numstat origin/main fork-main` filtered to files on `origin/main`; as of 2026-11-06 the
whole delta is +1671/−359 over 52 upstream files, all of it in entries with PRs intended, so the fork-only
count is F1's 2 lines.

### F1 — a dev build names itself (`MLX_SERVE_DEV_VERSION`) and stages its own plugin kit
- Level: L3 + L4          Status: active (2026-11-06)
- Why: `app/build.sh`'s no-`gh` arm reads the tracked plist, which says the last release upstream stamped
  there (26.11.1 even on the v26.11.2 tag). The app matches a plugin kit by that string, so a fork build
  installs plugins against the 26.11.1 release kit (another MLX pin): refused as stale, Rebuild all fetches
  the same kit again.
- Branch: `fork/dev-version` (the 2 lines), `fork/local` (`local/build.sh`)       Files touched:
  `app/build.sh`       Upstream-file lines: +2/−0
- Conflict points: the CalVer block of `app/build.sh`; `tests/test_release_workflow_gates.sh` pins that
  block's shape (window of 14 lines before `gh release list`; the PlistBuddy read line verbatim).
- Off switch: unset `MLX_SERVE_DEV_VERSION` (the arm is byte-identical then).
- Tests: `tests/test_release_workflow_gates.sh` (passes unchanged).
- Upstream: yes, later ("a dev build may name its version"); the better upstream shape is the app offering
  a dev build's own kit, which needs no env var.       If declined: carry (2 lines).
- Drop when: upstream's Install flow uses `zig-out/kit` or `~/.mlx-serve/kit` for a non-release version.
- Notes: version is `<tag>.<commits since tag>` so UpdateChecker (numeric compare) stays quiet about this
  build and still offers the next release.

### CR-A — qwen4_exp serves directional ablation (`Caps.ablation`)
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

### CR-B — `prefix_cache`: isolated | read | shared for ablated requests
- Level: L5          Status: active, PR pending the owner's review
- Why: an ablated mid-session turn must reuse the unsteered prefix (a feature: no re-prefill for a long
  session); upstream isolates by default.
- Branch: `ablation/prefix-cache`       Files touched: `src/sdk/request/ablation.zig`, engine `slot.zig`,
  `prefill.zig`, `prefill_interleave.zig`, `host/api/ablation.zig`, `docs/api.md`, deepseek_v4
  `served_test.zig`       Upstream-file lines: +248/−269
- Conflict points: `prefill.zig` checkout/restore path; `slot.cache_variant`.
- Off switch: default `isolated` upstream; the fork's model setting picks `read`/`shared`.
- Tests: served test on llama's conformance fixture; prefix cache suites.
- Upstream: yes (PR B).       If declined: carry; or reshape so the model setting alone selects it.
- Drop when: upstream adopts a cache-reuse mode for ablation.

### CR-C — per-model `ablation` setting (`model-settings.json`), `/props` + `/v1/models` rows, app UI
- Level: L1 + L5          Status: active; upstream as an issue first (UI is a harder sell)
- Why: every client of the server should be steered without sending a field; the owner wants the menu-bar
  control and Model Settings section the old fork had.
- Branch: `ablation/model-default`       Files touched: `sdk/request/ablation.zig`, `model_settings.zig`,
  `host/api/ablation.zig`, anthropic/responses/props/models surfaces, `tests/test_ablation_model_setting.sh`;
  app `Models/Ablation.swift` (new), `Views/AblationControls.swift` (new), `ServerOptions`, `ServerManager`,
  `APIClient`, `ChatModels`, `ModelSettingsFile`, `ModelSettingsSheet`, `StatusMenuView`, localizations,
  `app/CLAUDE.md`       Upstream-file lines: +1538/−301 (cumulative with CR-B's base)
- Conflict points: the four API surfaces' request parsing; `ModelSettingsSheet`; `StatusMenuView`.
- Off switch: no `ablation` entry in the model's settings.
- Tests: model_settings, props, anthropic, responses suites; app tests (4308, 0 failures).
- Upstream: issue for C; PR only if they want it.       If declined: carry the server half (small, settings
  file read); the app half is the biggest fork-only surface and the first candidate for §7.
- Drop when: upstream has a server-side default for ablation.
- Notes: steering-lab's "off" arms are ablated by this setting until the lab sends strength 0.

### D1 — per-layer steering bank for qwen4_exp (PR #538)
- Level: L5          Status: dropped (2026-11-05) → tag `steering-bank-v1`, branches on `private`
- Why dropped: owned an ABI bit, a route (`/v1/steering`) and a CLI; conflicted on every merge; upstream's
  #1045 is the sanctioned seam and single-direction ablation proved sufficient (user test 2026-11-06).
- Notes: the only runnable per-layer arm is `~/claude-tmp/steering-fork-26.11.1.app`; capture-capable old
  build `~/claude-tmp/steering-capture/MLX-Serve-26.10.3.app`; converter
  `~/claude-tmp/ablation-scratch/bank_to_profiles.py`.

### Stale — `fix/qsa-select-tiny-array`, `fix/tiny-qwen4-fixture-guards`
- Status: parked. Pre-rewrite (#978) fixes; the QSA block select change is not on `origin/main` in any form.
  Re-check whether the defect exists on the current tree before the next release adoption; delete if not.

## Planned (not implemented; call out before starting, §4)
- **CR-D** — env-gated capture tap in qwen4_exp (`QWEN4_TAP_DIR`, <100 lines, one plugin folder), sushi's
  shape. L5, upstream-worthy.
- **CR-E** — ablation strength above 1 (reflection). Two-line parse change; only with numbers. L4.
- **Native DeepSeek ablation** in `deepseek_v41` — only if Pruned192 beats Sushi on quality (roadmap step 4).
  L5, CR-A-sized.
- **Plugin side (CommunityServe/plugins, not this repo):** `expert_pick_tolerance` as a sushi_ds41 model
  setting; the `PREFILL_TOP_K` lines folded into a patch file. L2.
- **Dev-build kit in the app** — Install uses the build's own kit for a non-release version. Supersedes F1's
  env var. L4, upstream-worthy.

## Outside plugins reviewed (CHANGE-POLICY §4 L2)
- `sushi_ds41` @ CommunityServe/plugins `59473a90` (plugin last touched `203ed90`, 2026-11-05): PASS
  2026-11-06. Details in `local/notes/roadmap-2026-11-06.md` step 1.
