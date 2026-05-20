# REU Usage Re-examination (post-v0.5.0)

The library currently claims 6 REU banks (384 KB) for precomputed
multiplication tables. This document asks whether each bank earns its
keep.

**Status:** The cluster-B experiment (`SQR_DMA_K=0`, see
[Measured A/B results](#measured-ab-results) below) has been **run on
VICE warp + Ultimate-64 / NTSC** at commit `ebd388a` against the RFC 7748
basepoint-9 vector. RFC vector passed in both configurations.

The pre-experiment cycle-count predictions in this document were
**off by ~3×** vs the measured numbers. See the §"Predicted vs measured"
section for root cause.

## Current REU layout

Built once at startup by `reu_mul_init` (`src/x25519_init.s`). At the
default `X25519_REU_BANK = 0`:

| Bank | Content                                | Size  | Consumer                          |
|------|----------------------------------------|-------|-----------------------------------|
|  0–1 | `a*b` lo+hi (256 rows × 512 B)         | 128 KB | `fe25519_mul` inline DMA           |
|  2   | 64 zero bytes at offset 0; rest unused | 64 KB | `reu_clear_wide` *legacy* path     |
|  3   | 17th-bit carry of `2*a*b`              | 64 KB | `fe25519_sqr` DMA path             |
|  4–5 | Pre-doubled `2*a*b` lo+hi              | 128 KB | `fe25519_sqr` DMA path (i < `SQR_DMA_K`) |

Three logical groups: **regular mul** (banks 0–1), **doubled mul + carry**
(banks 3–5), and **legacy zero stash** (bank 2). The cost/benefit
differs sharply between groups.

## Per-bank cost-benefit

For each group, this section estimates the cycle delta on a full
`x25519_scalarmult` (`~1,031 fe25519_mul + ~763 fe25519_sqr + ~256 fe25519_mul_a24` per RFC 7748 ladder + inverse).

### Group A: regular mul tables (banks 0–1, 128 KB)

**What it replaces.** Without these tables, each inner body of
`fe25519_mul` must compute `a[i] * src2[j]` inline — either by
`jsr mul_8x8` (quarter-square: ~90 cy body + ~12 cy call overhead +
~7 cy arg setup ≈ **~109 cy/body**) or inlined mult66 (~91 cy/body).
With DMA tables the body collapses to `adc mul_dma_lo,y` +
`adc mul_dma_hi,y` (**~8 cy** to consume the precomputed product).

**Per-mul delta if removed.**
- 1024 inner-body executions per mul × ~100 cy slower = +102,400 cy
- Save 32 REU fetches × ~180 cy = −5,760 cy
- **Net per `fe25519_mul`: ~+96,600 cy**

**Per-scalarmult delta.** `1,031 × 96,600 ≈ 99.6M cy ≈ ~5,840 jif`.

**Trade.** 128 KB REU reclaims **~5,840 jif (+38% on a 15,350-jif
baseline)**. Net cost per KB: **~46 jif / KB** — high value. Keep.

### Group B: doubled mul tables + carry (banks 3–5, 192 KB)

**What it replaces.** `fe25519_sqr` has *two* cross-term paths,
selected by `SQR_DMA_K` (default 22):
- DMA path (`i < 22`): consumes pre-doubled tables in banks 4–5 + 17th-bit
  carry in bank 3. Per body ~41 cy.
- mult66 path (`i ≥ 22`): branchless quarter-square inline. Per body
  ~91 cy.

If the doubled tables were dropped, `SQR_DMA_K = 0` would force the
mult66 path for every `i`. The mult66 path is already CT-closed
(`L19–L24` argument in `docs/CT_ANALYSIS.md`) and is the v0.3.0
fallback — battle-tested.

**Per-sqr delta if doubled tables are removed.**
- Body executions in the (former) DMA range (i = 0..21): 462. Each
  becomes ~50 cy slower under mult66: +23,100 cy.
- Save 22 REU fetches × ~180 cy = −4,000 cy.
- **Net per `fe25519_sqr`: ~+19,100 cy** (≈ +1.1 jif/call → 7.55 vs
  6.44 jif/call).

**Per-scalarmult delta.** `763 × 19,100 ≈ 14.6M cy ≈ ~860 jif (+5.6%)`.

**Trade.** 192 KB REU reclaims **~860 jif (+5.6%) on a 15,350-jif
baseline**. Net cost per KB: **~4.5 jif / KB** — **10× less efficient
than Group A**. This is the cluster the maintainer's instinct flagged
correctly: large footprint for a modest perf return.

### Group C: bank 2 zero stash (64 KB reserved, 64 B in use)

**Current state.** `reu_clear_wide` was rewritten in v0.4.0 prep (W2)
to do a 64-byte CPU clear (`sta fe_wide,x` with `x` from 63 down). It
no longer fetches from REU bank 2. The 64 bytes of zeros are still
stashed at init time but are *never read*.

The bank reservation is documented in `src/reu_config.s:20` itself as
the "*legacy stash*".

**Trade.** 64 KB REU reclaimable for **0 jif perf cost**. Free.

## Summary table

| Group | Banks | Size | jif saved on scalarmult | jif/KB | Verdict |
|-------|-------|------|-------------------------|--------|---------|
| A     | 0–1   | 128 KB | 5,840 (+38%)        | 46     | **Keep** |
| B     | 3–5   | 192 KB | 860 (+5.6%)         | 4.5    | **Candidate for drop** |
| C     | 2     | 64 KB  | 0                   | 0      | **Drop unconditionally** |

If A + C are kept and B dropped, the library runs in **128 KB of REU**
instead of 384 KB. **That changes the minimum-REU spec from 1750 (512 KB)
to a stock 1764 (256 KB)**, which is a material widening of the
hardware compatibility envelope — 1764s are much more common in the
wild than 512 KB-class REUs.

The cost is ~5.6% of one ECDH operation, on an op already taking
~4 minutes wall-clock at NTSC. Marginal.

## Build variants for the A/B test

These are tweaks to `constants.s` / `reu_config.s` that can be exercised
without modifying the hot path. The `SQR_DMA_K` constant is already
host-overridable:

```ca65
; src/constants.s
.ifndef SQR_DMA_K
  SQR_DMA_K        = 22          ; outer i < K uses pre-doubled DMA tables
.endif
```

### Variant 1: `SQR_DMA_K = 0`

```
ca65 -D SQR_DMA_K=0 -o build/fe25519.o src/fe25519.s
# (rebuild rest of library normally)
```

This forces the mult66 path for every `i` in `fe25519_sqr`. The doubled
tables are still *built* in `reu_mul_init` (so init time is unchanged)
but the runtime never reads them.

**Predicted delta:** `+860 jif (+5.6%)` on scalarmult,
`+1.1 jif/call` on `fe25519_sqr`.

This is the minimum experiment. If the measured delta lines up with
the prediction (within ±20%), Group B's contribution is confirmed.

### Variant 2: `SQR_DMA_K = 0` + skip doubled-table init

If the measurement confirms Variant 1, the follow-up is to also remove
the `@dbl_gen` / "stash doubled lo/hi/carry" sections of
`reu_mul_init` (about 80 lines in `x25519_init.s:108-188`). This
recovers:
- ~600 ms of init wall-clock (one-time, but visible on cold boot)
- The 192 KB of REU truly stops being touched (banks 3–5 free for the
  consumer to use for other tables)

LIBRARY.md §REU + `LIB_X25519_REU_BANKS_USED` mask must update to
reflect the new claim ($3 instead of $3F).

### Variant 3: also drop bank 2

Pair with variants 1+2. Remove the bank-2 zero stash in
`reu_mul_init` (lines 194–218) — `reu_clear_wide` already doesn't read
it. Bank 2 free.

Combined with variants 1+2, the library uses **banks 0–1 only** = 128 KB,
fits a stock 1764, ~5.6% perf cost.

## Measurement plan

Sequence to confirm the predictions before committing:

```bash
# Baseline (current default).
make clean && make
python3 tools/bench_x25519.py --json /tmp/bench_default.json
python3 tools/bench_fe_ops.py  --json /tmp/fe_default.json

# Variant 1: SQR_DMA_K=0.
make clean
CA65FLAGS="-D SQR_DMA_K=0" make            # or rebuild fe25519.o manually
python3 tools/bench_x25519.py --json /tmp/bench_K0.json
python3 tools/bench_fe_ops.py  --json /tmp/fe_K0.json

# Compare.
python3 -c '
import json
a = json.load(open("/tmp/bench_default.json"))
b = json.load(open("/tmp/bench_K0.json"))
print(f"scalarmult delta: {b[\"scalarmult_cycles\"]-a[\"scalarmult_cycles\"]:+,} cy")
print(f"  in jif: {b[\"scalarmult_jif\"]-a[\"scalarmult_jif\"]:+.0f} ({(b[\"scalarmult_jif\"]-a[\"scalarmult_jif\"])/a[\"scalarmult_jif\"]*100:+.1f}%)")
print(f"sqr/call delta: {json.load(open(\"/tmp/fe_K0.json\"))[\"fe25519_sqr_jif\"] - json.load(open(\"/tmp/fe_default.json\"))[\"fe25519_sqr_jif\"]:+.3f} jif")
'
```

The Makefile doesn't currently honor a `CA65FLAGS` variable, so
Variant 1 may need either (a) a small Makefile change to pass `$(CA65FLAGS)`
to `ca65`, or (b) one-shot manual `ca65 -D SQR_DMA_K=0 ...` invocations
for each `.s` file. The bench scripts run `make` internally before the
test, which means we have to be careful that Variant 1's CA65 flag
actually takes effect (the bench's internal `make` will override a
manual rebuild). For a clean experiment, either:
- Patch the Makefile to thread `CA65FLAGS` through to the `ca65` rule.
- Or temporarily edit `SQR_DMA_K = 22` to `SQR_DMA_K = 0` in
  `src/constants.s` for the variant run (revert after).

## Measured A/B results

Baseline build: `make clean && make` (default `SQR_DMA_K = 22`).
Variant build: `CA65FLAGS="-D SQR_DMA_K=0" make clean && make` —
forces every `fe25519_sqr` iteration through the mult66 inline path,
leaving banks 3–5 built-but-unread at runtime.

Both runs against the RFC 7748 basepoint-9 vector. VICE NTSC warp.
Cycle counts via CIA1 (sei-safe, cycle-exact). Per-op numbers via the
batch-200 thunk, also CIA1.

| Metric                | Baseline (K=22)    | Variant (K=0)      | Δ                  |
|-----------------------|--------------------|--------------------|--------------------|
| `x25519_scalarmult`   | 261,640,265 cy     | 304,060,643 cy     | **+42,420,378 cy** |
| `x25519_scalarmult`   | 15,349.6 jif       | 17,838.2 jif       | **+2,488.6 jif (+16.2 %)** |
| `x25519_scalarmult`   | 256 s NTSC         | 297 s NTSC         | +41 s NTSC          |
| `fe25519_mul`         |  94,733.1 cy/call  |  94,734.4 cy/call  | +1.3 cy (noise; K does not affect mul) |
| `fe25519_sqr`         | 102,022.1 cy/call  | 135,319.1 cy/call  | **+33,297 cy (+32.6 %)** |
| `fe25519_mul_a24`     |   7,538.1 cy/call  |   7,538.1 cy/call  | 0 cy                |
| `fe25519_inv`         | 28,765,951.4 cy    | 37,793,912.6 cy    | +9,027,961 cy (+31.4 %; downstream of sqr) |
| `fe25519_add` / `_sub` / `_reduce_final` / `_cswap` | (all unchanged) | (all unchanged) | 0 cy |
| RFC 7748 vec-0        | PASS               | PASS               | —                  |

Both rows live in [`docs/perf_history.csv`](perf_history.csv) for
direct `tools/perf_diff.py` reproduction.

## Predicted vs measured

| Quantity                   | Predicted | Measured   | Error  |
|----------------------------|-----------|------------|--------|
| Δ cy per `fe25519_sqr`     | +19,100   | +33,297    | **+74 %** |
| sqr count per scalarmult   | 763       | 1,274      | **+67 %** |
| Δ jif per scalarmult       | +860      | +2,489     | **+189 %** |
| Δ % on scalarmult          | +5.6 %    | +16.2 %    | **+10.6 pp** |
| jif saved per KB reclaimed | 4.5       | 13.0       | +189 % |

**Root cause of the prediction error:** I cited "763 sqrs / scalarmult"
from a stale doc comment in `tools/bench_fe_mul.py:148`:

> 255 ladder steps × (4 mul + 1 mul_a24 + **2 sqr** + 4 add/sub)

The current ladder in `src/x25519.s:x25519_ladder_step` actually does
**4 sqr per step** (AA, BB, `(DA+CB)^2`, `(DA-CB)^2`), giving
`255 × 4 + 254 (inv) = 1,274`. The measurement-derived count
(`scalarmult_Δcy / sqr_Δcy = 42,420,378 / 33,297 = 1,274.00`) matches
to the cycle. The mult66-vs-DMA per-body delta was also low by ~50 %
(predicted ~50 cy, measured ~72 cy on average across the i=0..21
range), partially because mult66's chain step costs more than I
allowed for.

Net: the doubled-table cluster (banks 3–5) is **substantially more
load-bearing** than the analytic prediction suggested. It is still less
efficient per-KB than the regular-mul cluster (banks 0–1), but by 3.5×,
not 10×.

**Action item from this experiment:** correct the stale comment in
`bench_fe_mul.py:146-148` (and any matching language in `CT_ANALYSIS.md`)
to use the actual 1,274 sqr / scalarmult figure.

## Updated cost-benefit (measured)

| Group | Banks | Size  | jif on scalarmult if removed | jif/KB | Verdict |
|-------|-------|-------|------------------------------|--------|---------|
| A     | 0–1   | 128 KB | ~5,840 (analytic only)*     | 46     | **Keep** |
| B     | 3–5   | 192 KB | **2,489 (measured)**         | **13** | **Less attractive than predicted; user decision** |
| C     | 2     | 64 KB  | 0                            | 0      | **Drop unconditionally** |

\* Group A wasn't experimentally measured (would require gutting
`fe25519_mul`'s DMA inner loop, which is a larger rewrite than the
`SQR_DMA_K` knob allows). The analytic estimate uses the same
methodology that under-estimated Group B by ~3×, so the real Group A
contribution is likely **15,000+ jif** if it scales the same way —
making Group A even more clearly the keep.

## Recommendation

1. **Group C: SHIPPED.** Bank-2 stash + zeroing loop removed from
   `src/x25519_init.s:@init_done`. `LIB_X25519_REU_BANKS_USED` flipped
   from `$3F` to `$3B` (banks 0, 1, 3, 4, 5). `LIB_X25519_RESIDENT_BYTES`
   flipped from `9275` to `9224` (−51 B in `x25519_init.o`'s CODE).
   Verified against `make lib-verify` + full `make test-vice` +
   `bench_x25519` (RFC 7748 basepoint-9 PASS at 261,681,380 cy — within
   layout-noise of the 261,640,265 baseline; +0.016 %, attributable to
   code-address shift inside the CODE segment after the removed bytes).
   Row in `docs/perf_history.csv` tagged `v0.6-prep+groupC`.

2. **Group B decision is a judgment call, not a slam-dunk.** The
   measured trade is **+16.2 % scalarmult slowdown in exchange for
   192 KB REU and lowered hardware floor (1750 → 1764)**. The
   pre-measurement analysis predicted +5.6 %, which would have made
   this a comfortable yes; +16 % is borderline.

   Arguments for shipping `SQR_DMA_K = 0` as the new default:
   - C64 1764 owners outnumber 1750/512KB-mod owners by a large margin.
   - +41 s NTSC on a 4-min ECDH op is in the "annoying but not
     prohibitive" range.
   - Banks 3–5 are otherwise unrecoverable for sibling crypto libs.

   Arguments against:
   - The library is already at +27.2 % vs v0.3.0 because of CT
     closure; another +16 % stacks ugly in the release-notes table
     (cumulative +47 % vs v0.3.0 baseline).
   - The K knob is *already* host-overridable via `-D SQR_DMA_K=0`.
     A 1764 owner can compile the smaller variant themselves; the
     library doesn't need to default to it.

   **Possible compromise:** keep `SQR_DMA_K = 22` as default but
   ship a `make lib-x25519-1764` build target that flips the knob,
   skips the doubled-table init, and exports
   `LIB_X25519_REU_BANKS_USED = $03`. Lowers the hardware floor for
   downstream consumers without penalizing the 1750/maxed-REU
   path. Aligns with c64-lib-contract §6 build-variant pattern that
   was already deferred in `follow_ups`.

3. **Either way, fix the stale 763 sqr/scalarmult comment in
   `bench_fe_mul.py:148` and any matching language elsewhere.** The
   measurement establishes 1,274 as the correct figure.

The `make bench-record` infrastructure makes future A/B experiments
trivial to capture — each variant becomes one row in
`docs/perf_history.csv`, with `tools/perf_diff.py` printing the
markdown diff for the release-notes table.
