# Feature request: compress SSM disk-tier checkpoints at rest (and a long-context bf16 overflow we found while measuring it)

## The ask

Store the hybrid SSM/conv checkpoints that the disk prefix-cache tier writes
(`{root}/e{id}/s{pos}.safetensors`, one per rewind position) **compressed**, and
decompress on the restore path. Measured on real checkpoints this cuts the
per-checkpoint footprint from **59 MB to 48 MB (~81%)** with a standard codec
(zstd or gzip). That is the only compression lever that survives measurement —
the two "clever" ones (delta-encoding, low-rank factorization) are both dead,
and the measurement that killed them also turned up a bf16 overflow in the
long-context state that I think is a real bug worth filing alongside this.

## Why compression, and why it pays

The disk tier caps each cache entry at `SSM_DISK_MAX_PER_ENTRY` (16)
checkpoints, each a fixed-size recurrent state of 36 layers ×
`[1,48,128,128]` bf16 ≈ **59 MB raw** (see `ssmCheckpointBytes()`, which the
tests pin to 58.83 MB). The tier writes these **raw** — `loadSsmFile`
(`src/kv_disk_cache.zig:941`) reads the file verbatim through
`mlx_load_safetensors` and there is no codec on the write path.

A 64 GB disk budget holds ~1085 raw checkpoints. At an 81% ratio it holds
~1334 — **~23% more** — which is exactly the headroom that lets the tier keep
more cache entries (each still capped at 16 checkpoints) within the same
budget: more distinct prefixes/sessions coexist on disk.
The win is per-checkpoint and compounds across the whole tier; it is not a one-off.

The two obvious "smarter" encodings do **not** work. I measured both on the
actual checkpoint files (scripts in `.ssm-exp/`):

| encoding | idea | measured result | verdict |
|---|---|---|---|
| delta | consecutive states are "effectively the same"; store `cp[0]` full, then only `cp[i]−cp[i−1]` | **Byte-level overlap test:** compress `A‖B` in one pass vs `A` and `B` separately — saves only **~0.7%** (93.3 MB vs 94.0 MB), and the saving is *flat* across gaps (tightest gap 382 → 0.79%, widest 4502 → 0.66%), nowhere near the 50% ceiling that two *identical* copies hit. Confirmed by the numerical test: `rel = ‖B−A‖/‖A‖ ≈ 1.4` (≈√2, the signature of two *independent* vectors) at every gap. | **dead** — the state is not incremental at checkpoint granularity |
| low-rank | the `[128,128]` head-matrices are low-rank; store `U@V` (`128×r + r×128`) | exact cyclic-Jacobi SVD (outlier-robust): top-16 captures only **~50%** of the energy, top-8 ~30%, top-64 ~97%. The spectrum is flat. | **dead** — the matrices are high-rank |
| byte-level | gzip / zstd the raw file | **81.1–81.7%** (59.0 → 47.9 MB), identical across all checkpoints and both datasets | **viable** — this is the feature |

The delta row deserves the most scrutiny, so here is the overlap test in full.
For each consecutive pair I compressed the concatenation `A‖B` in a single zstd
pass (1 GiB window so back-references can cross the boundary) and compared it to
compressing `A` and `B` separately; `zstd(A‖A)` is the ceiling — the maximum a
compressor could save if `B` were a byte-identical copy of `A`.

| pair | gap | zstd(A) | zstd(B) | zstd(A‖B) | save | save% | ceiling |
|---|---|---|---|---|---|---|---|
| e32 8192→12694 | 4502 | 46.95 | 47.00 | 93.33 | 0.62 MB | 0.66% | 50% |
| e32 12694→16384 | 3690 | 47.00 | 46.96 | 93.21 | 0.75 MB | 0.79% | 50% |
| e32 16384→19420 | 3036 | 46.96 | 47.08 | 93.36 | 0.67 MB | 0.72% | 50% |
| e32 19420→20866 | 1446 | 47.08 | 46.90 | 93.30 | 0.68 MB | 0.72% | 50% |
| e32 20866→24194 | 3328 | 46.90 | 47.07 | 93.29 | 0.68 MB | 0.72% | 50% |
| e32 24194→24576 | **382** | 47.07 | 46.93 | 93.26 | 0.74 MB | 0.79% | 50% |
| e32 24576→25837 | 1261 | 46.93 | 46.96 | 93.14 | 0.75 MB | 0.80% | 50% |

The saving is ~0.7% — 1.3% of the 50% ceiling — and it does **not** grow as the
gap shrinks (the tightest gap is not the biggest saver). A gzip cross-check on
the tightest pair gives `save = 0.00 MB`. The ~0.7% residual is shared
*file-format* bytes (the safetensors JSON header — tensor names, offsets,
metadata — that is identical in both files and which zstd back-references across
the boundary), not shared *state*. Real state overlap would push the saving
toward the 50% ceiling; it sits at 0.7%. So there is no overlapping information
to delta-encode.

So the proposal is deliberately narrow: wrap the existing safetensors blob in a
reversible codec on write, unwrap it on read. No change to the on-disk tensor
layout, the `l{i}.ssm` / `l{i}.conv` keying, or the `SSMCheckpoint` shape.

## The overflow we found while measuring (please file separately)

The delta test had to compare states across checkpoints, and the long-context
dataset (`e20`, checkpoints at positions 144k–156k) came back with `rel = nan`
on every pair. Tracing that to the source, the long-context SSM state is
**saturated at the bf16 ceiling**:

| dataset | context | max finite entry | entries > 1e30 | entries > 1e37 (≈ bf16 max) | bf16 NaN per layer |
|---|---|---|---|---|---|
| e32 (short) | ≤ 25k | **27.5** | 0 | 0 | **0** |
| e20 (long) | ≤ 156k | **2.55e38** | 64,421 (8.2%) | 11,196 (1.4%) | **~2,200** |

Three facts make this a bug and not "the state is just big":

- The overflow is **present from the first long-context checkpoint** and stays
  pinned at the same ceiling (2.565e38) across all 12 — it is saturated, not
  still growing.
- It is **all 48 heads** in a layer, not a few stray entries — the whole state
  is at the dtype limit.
- The short-context state of the same model is clean (max 27, zero NaNs).

The `rel = nan` is the direct symptom: `‖A‖` overflows to inf and the ratio
becomes inf/inf. Whatever consumes these checkpoints downstream is reading
saturated/NaN bf16. I have not root-caused the recurrence (the GDN kernel in
`src/transformer.zig`), so I'm flagging it as a separate investigation rather
than bundling a fix into the compression feature. A cheap guard that belongs in
this work regardless: **detect** a checkpoint whose state is saturated or
NaN-bearing and log it, so a future overflow is visible instead of silently
corrupting restores.

## Implementation sketch

1. **Write path** — in the SSM checkpoint flush (`appendCommitWithSpec*` → the
   safetensors writer), compress the serialized blob before it hits disk. Keep
   the safetensors byte layout; wrap the whole file in the codec.
2. **Read path** — `loadSsmFile` (`kv_disk_cache.zig:941`): detect the wrapper
   (a 4-byte magic / a `codec` key in the safetensors metadata map) and
   decompress into a buffer before `mlx_load_safetensors`. Files without the
   marker are read raw, so existing on-disk checkpoints keep loading.
3. **Codec** — zstd if a dependency is acceptable (better ratio + speed than
   gzip at these sizes); gzip is the zero-dependency fallback. Record the choice
   in metadata so the reader is self-describing.
4. **Back-compat** — the marker makes old and new files coexist; no migration.

Acceptance: a checkpoint written and then restored is byte-identical to the
uncompressed original (the existing `restoreInto` round-trip tests cover this);
`fileSize` on a persisted checkpoint reports the compressed size; and the
byte-budget accounting (`ssm_bytes` / `retainedSsmCheckpointBytes`) uses the
**compressed** size so the budget math reflects real disk usage.

## Measurement notes (so this is reproducible, not asserted)

- Scripts: `.ssm-exp/overlap.py` (byte-level cross-checkpoint overlap — the
  primary delta evidence), `.ssm-exp/measure.py` (numerical delta),
  `.ssm-exp/rank2.py` (low-rank, exact cyclic-Jacobi SVD after median-
  normalization + zeroing the top 0.1% of magnitudes), `.ssm-exp/bulk.py`
  (outlier-masked delta).
- The overlap test uses `zstd -19 --long=30` (1 GiB window) so back-references
  can span the full `A‖B`; `zstd(A‖A)` is the ceiling and `zstd(A)+zstd(B)−
  zstd(A‖B)` is the saving. A gzip cross-check confirms the result is
  codec-independent.
- The bf16→f32 decode is exact (bf16 is the top 16 bits of f32), so f32 NaN
  counts equal real bf16 NaN counts. An earlier byte-level NaN detector was
  itself buggy (it tested the mantissa byte for the exponent field); the
  f32-conversion count is the correct one.
- The low-rank test had to be outlier-robust: a naive SVD lets the ~1e38
  entries own the top singular values and report a false rank-1. Median-
  normalizing and zeroing the top 0.1% before the SVD measures the bulk's true
  spectrum, which is what the table above reports.
