# Merge plan: origin/main (v26.11.2 + 2) into steering/upstream-pr — 2026-11-05

Merge-base c86e4b29 (just past v26.11.1, the base of the 10-30 re-port). Theirs: 62 commits, 700 files,
+26k/-3k, tip cb8dafed. Ours since the base: b0389f0e (the steering port) over the 3afda6bd merge.
Dry run: `git merge-tree --write-tree HEAD origin/main` → 4 textual conflicts, everything else auto-merges.

## 1. What upstream brings

- **MLX 0.32.5** (`lib/mlx-src` bump, Metal half ported, M5 proof tapes re-baselined, sdpa_split-off patch dropped).
  Needs `scripts/build-mlx.sh` before any build. Outside-plugin kit/manifest bumped (plugins say "Needs rebuild").
- **Per-request directional ablation** (073e282b, #1045): `Caps.ablation`, `Forward.ablation` (`Ablation{directions,
  strengths, keys}`), `--ablation-profiles` + `--ablation-key-file`, `"ablation"` field on chat/completions with an
  `X-Ablation-Key` header, `slot.cache_variant` → `ModuleBinding.variant` keys the module prefix cache. No in-tree
  plugin declares the cap (tests + the outside DeepSeek-V4.1 plugin only); qwen4_exp does NOT.
- DeepSeek-V4.1: `--dist tensor` across two Macs, GGUF on the MLX path (`--mlx-gguf`), non-NAX kernels, DSpark batched.
- qwen4_exp: batched M-RoPE image slots at the right cache position (`batchedCachePos`), stacked logits freed,
  forward-failure log line, MoE/PLE/linear tweaks, QSA kernels as_type loads, tapes re-baselined. None touch
  `hc.zig`, `hc_fused.zig`, `forward.zig`, `steer.zig`, `sdk/blocks/hc/`, `kernels/hc/` — the steering seams are untouched.
- Prefix cache: a ladder of module checkpoints per conversation; disk-tier heirs inherit SSM checkpoints.
- Host: `HostGpu.alias`, `HostGpu.command_buffer_limits`, `Host.ane`, `MLX_SERVE_KEYED_SAMPLING`, `repetition_penalty`
  alias, GGUF settings found by `.gguf` path (`lookupPack` in model_settings.zig), weights kept wired through idle.
- App: usage strip/dashboard (moved throughput state out of ServerManager), Plugins pane, model browser default, MCP fixes.

## 2. Conflicts and resolutions

| File | Conflict | Resolution |
|---|---|---|
| `src/abi/plugin.zig` | Both took Caps bit 31 (`_: u34 → u33`): theirs `ablation`, ours `dir_steering` | Keep `ablation` at bit 31 (upstream's ABI, which outside plugins are built against), `dir_steering` after it, `_: u32`. Reversing the order would make an upstream-built plugin's `ablation` read as `dir_steering`. |
| `docs/plugin-abi.md` | Same two Caps rows | Both rows, same order, `_` row = `u32`. |
| `src/host/AGENTS.md` | Our steering bullet vs their rewritten Observability bullet | Keep our steering bullet + THEIR Observability line (adds `/metrics.json usage`). |
| `app/.../ServerManager.swift` (reset block ~355) | We added two resets inside a block upstream deleted (`throughput`, `decodeTPSNow`, `prefillTPSNow` moved out by the usage dashboard #1043) | Keep only `directionalSteering = nil` and `rememberedSteering = [:]`; drop the three upstream-removed lines. |

Auto-merged files to eyeball after the merge: `src/kernels/digests.txt` (our `hc_decode2_nd.metal` hash must survive),
`src/plugins/qwen4_exp/plugin.zig` (our `apply_settings` + their `batchedCachePos`), `model_settings.zig` (our
`steering` key + their `lookupPack`), `router.zig`, `props.zig`, `main.zig`, `registry.zig`, `tests.zig`.

`src/html/index.html`: we carry a rebuilt blob, upstream changed `app-web/src/lib/core/console.ts` + zh-hans i18n
without rebuilding. Rebuild the console from `app-web/` after the merge and commit the fresh blob.

## 3. Steps

1. `git merge origin/main` on `steering/upstream-pr`; resolve the 4 conflicts as above.
2. `git submodule update --init lib/mlx-src` → `scripts/build-mlx.sh` (0.32.5, NAX assert).
3. Rebuild `src/html/index.html` from `app-web/`.
4. `zig build check` → `zig build test` (all shards; watch `sdk/blocks/hc` contract + `hc_decode2_test` and the
   qwen4_exp served tests against the re-baselined tapes) → `python3 scripts/lint.py --strict`.
5. `zig build -Doptimize=ReleaseFast`; `bash app/test.sh` / `swift build`.
6. Live: `tests/test_qwen4_steering.sh` — unload the Flash-Next pack from the app's port 11234 first.
7. `bash app/build.sh` only after the above is green (it replaces the app you run).
8. Commit the merge (no Co-Authored-By line); push to `fork` when you say so.

## 4. Follow-ups this merge surfaces (not in the merge commit)

- **Prefix cache vs a live steering change: INTENDED.** Reusing the unsteered prefix lets a mid-session turn run
  steered without re-prefilling the session. Do NOT adopt upstream's bypass: on qwen4_exp (KV prefix cache, not
  module-owned) an ablated request neither reads nor writes the cache (`skip_prefix_cache or cache_variant != 0`).
- **Steering vs ablation.** Upstream now has a sanctioned per-request residual-direction ABI. Ablation projects out
  (`y − s(y·r)r`), our steering adds a scaled direction on the ffn arm, so it is not a replacement, but the
  plumbing (per-slot directions, keys, cache variant, proxy/LAN refusals) is a model for a per-request steering
  field, and a qwen4_exp `Caps.ablation` implementation would land in the same HC fold. This is also the concrete
  case PR #538's closure asked for, if you want to reopen it as "steering beside ablation".
- **`ModelTable.apply_settings` past an older table.** `settle.applySettings` reads `b.table.apply_settings` without a
  `table.size` check; an outside plugin built with upstream's kit has a shorter table. Today it is reached only for
  models with `dir_steering`, so it is latent; add a size gate if the hook ever goes upstream.
