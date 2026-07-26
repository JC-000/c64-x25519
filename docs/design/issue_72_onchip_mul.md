# Issue #72 — `X25519_ONCHIP_MUL` build profile (design)

Status: IMPLEMENTED on `issue-72-onchip-mul`, VICE-validated (see
"Measured" section). Hardware A/B pending — the merge gate below.
Ported concept from c64-nist-curves #69/#71 (`FP_ONCHIP_MUL`), redesigned
for x25519's constant-time contract. VICE-validated only for now;
hardware A/B at 16/48/64 MHz is a **deferred merge gate** for all
wall-clock claims (U64E/C64U remote access pending).

## 1. Problem

REU DMA runs at the ~1 MHz bus rate regardless of CPU turbo. Every
`fe25519_mul` outer iteration FETCHes a 512-byte product row
(`src/fe25519.s:632-640`, 32 rows/call); the default `fe25519_sqr`
FETCHes up to `SQR_DMA_K = 22` pre-doubled rows (`src/fe25519.s:1148`).
On accelerated hosts those stalls are a speed-invariant wall-clock
floor. nist-curves measured 87% of `ecdsa_verify_256` wall at 64 MHz;
x25519's share is comparable or worse (estimate pending the Q1
measurement below).

A second deliverable falls out: the profile issues **no REU traffic at
all** — x25519's first configuration that runs on a stock, expansion-
less C64.

## 2. Why the nist-curves generator cannot port mechanically

Their `og_common` (nist-curves `src/mul_8x8.s:306-376`) is non-CT by
design — acceptable for ECDSA verify (public inputs only). x25519 has
no public-input operation: the row value `a = src1[i]` and every
generated index `b = src2[j]` are secret ladder state. Every non-CT
trick must be replaced:

| og_common trick | disposition here |
|---|---|
| `beq` zero-byte skip (worst: row time counts secret nonzero bytes) | deleted — generate all 32 unconditionally |
| `bcs` diff-sign branch | canonical body's branchless flip (`src/mul_8x8.s:226-234`) |
| `bcs` sum-page branch | canonical body's SMC'd hi-byte fold (L2 closure, `src/mul_8x8.s:240-244`) |
| unaligned SMC'd staged-buffer load | SMC-patched **aligned** src2 load (caller-buffer 32-byte alignment contract, `docs/LIBRARY.md` §"buffer alignment") |
| consumer-side zero-skip guards | already removed here (L12-L15/L25) — no sparse set exists, always 32 values |

Consequence: the "sparse set" degenerates to *"the 32 values of src2,
always, in public loop order"* — simpler than nist-curves, and the two
stale-data invariants their design carries (index 0 never read, stale
entries load-bearing by omission) dissolve entirely.

## 3. Generator design (the only new CT surface)

One swap point exists (confirmed: `reu_fetch_mul_row`'s sole caller is
the gated-out `reu_fetch_doubled_row`; `fe25519_mul_a24` and
`mul_by_38` use RAM tables). The stub replaces `src/fe25519.s:632-640`
under `.if ::X25519_ONCHIP_MUL`.

Shape (per outer-i row; A = src1[i] on entry, X/Y/C dead, may clobber
all registers/flags — verified against the fall-through at
`src/fe25519.s:645-679`):

```
sta smc_sum_a_imm+1       ; bake a once per row (exported SMC sites)
sta smc_diff_a_imm+1
ldx #31
@gen_row:
        stx fe_mul_j      ; park j (public) across ct_mul_8x8 — fe_mul_j
                          ; is free in fe25519_mul (only sqr uses it,
                          ; and mul/sqr never nest)
@gen_src2_a:
        ldy mul_src2_buf,x ; SMC-patched abs,x — NEW site, patched at
                          ; proc entry alongside @ldy_src2_a..d (src2 is
                          ; secret: no (zp),y — CLAUDE.md CT rule)
        jsr ct_mul_8x8    ; canonical §8.3 body, UNTOUCHED — fixed-cycle;
                          ; clobbers A/X/Y
        ldx fe_mul_j
@gen_src2_b:
        ldy mul_src2_buf,x ; second SMC site: reload b as store index
        lda poly_prod_lo
        sta mul_dma_lo,y  ; page-aligned abs,y — CT
        lda poly_prod_hi
        sta mul_dma_hi,y
        dex
        bpl @gen_row      ; public index countdown, fixed 32 iterations
```

As implemented: ~127 cy/product (ldy 4 + stx 3 + jsr/body/rts 90 +
ldx 3 + ldy 4 + 2×(lda abs + sta abs,y) 18 + dex/bpl 5), ~4.1K cy/row,
~130K cy added per fe25519_mul before the DMA saving. Two SMC src2
sites (not one + scratch byte) — zero new ZP/data allocation.

CT argument sketch:
- Loop count fixed (32), branch depends only on public X.
- `ct_mul_8x8` is 84 cy data-independent (L1/L2 closures; measured, to
  be gated — see §7).
- All secret-indexed loads/stores hit page-aligned bases
  (`mul_dma_lo/hi` at `src/data.s:135-141`; src2 via the 32-byte-aligned
  caller-buffer contract). **Add the missing `.assert` on `mul_dma_*`
  page alignment** — today it is only indirectly asserted via
  `src/reu_config.s:172-174`.
- `a == 0` is NOT short-circuited: row 0 generates 32 zero entries,
  which is exactly the reinterpreted L25 invariant — "every generated
  entry of the a==0 row is zero" replaces "DMA row 0 is all-zero".
  L12-L15 (`y == 0` reads) need no new obligation: index 0 is in the
  generated set iff src2 contains a zero byte, and only generated
  indices are read (the 8 `adc mul_dma_*` sites × 4 bodies are the
  complete consumer set; `mul_dma_carry` is sqr-DMA-only, never
  generated or read under this profile).
- Duplicate src2 values are recomputed and rewritten — count stays 32.
- SMC residue: a secret byte lives in the two baked immediates between
  calls. Not a timing leak (imm operands, fixed cycles); outside the
  network-timing threat model but recorded in CT_ANALYSIS.

New CT_ANALYSIS entries: the generator loop (Lnn), the new SMC src2
load site (Lnn+1), and a REWRITE of the `mul_8x8` threat-model
paragraph — `ct_mul_8x8` stops being boot-only and becomes hot-path
with secret operands under this profile. L1/L2 go from "retained
canonical shape" to load-bearing.

`jsr` vs inlined clone: the call costs ~12 cy/product ≈ 12.3K cy/mul
(~3% of scalarmult). Start with `jsr` (zero new multiply audit surface,
body already brute-checked + contract-pinned); an inlined documented
clone is a recorded follow-up optimization, NOT part of this arc.
Rationale: nist-curves' shape-1→2 win came mostly from call-overhead
elimination (transfers to the clone) and branch tricks (cannot
transfer); do it right once, measure, then decide.

## 4. Everything else the profile touches

- `src/constants.s`: numeric-default guard next to `SQR_DMA_K`
  (`.ifndef X25519_ONCHIP_MUL / = 0`); the profile **forces
  `SQR_DMA_K = 0`** in constants.s (sqr runs the existing, measured
  mult66 path — Group B, +2,489 jif; no doubled-row generator, per the
  #72 comment: staging a doubled row is the same product count as
  computing directly).
- Gated OUT under the profile (`.if ::X25519_ONCHIP_MUL` wrappers on
  exports too, per the `src/x25519_init.s:10-18` idiom):
  `reu_mul_init`/`reu_mul_tables_init`, `reu_fetch_mul_row` (+
  `_bank_patch` export), `reu_probe`, `reu_clear_wide`'s
  autoload-restore tail (`src/x25519_init.s:545-552`; the CPU clear
  stays), H2/S2 defensive $DFxx writes (`src/fe25519.s:579-581`,
  `1098-1100`, `1802-1804`, `src/x25519.s:105-107` — I/O2 is not
  unconditionally free: GeoRAM/ethernet decode $DFxx), the §8.2 export
  block (`src/reu_config.s:182-201`).
- Manifest (`src/lib_version.s`): `LIB_X25519_REU_BANKS_USED = 0`
  (SPEC §5 — the zero IS the no-REU declaration);
  `LIB_X25519_SHARED_PRIMITIVES` drops the §8.2 `$0002` term by
  omission → `$0005` (do NOT define `SHARED_REU_MUL_INIT`, which means
  "defers to a provider"); drop `LIB_PRECALC_TABLE "reu_mul"` +
  `"reu_mul_doubled"` claims (keep `sqtab` — the generator reads it on
  every product, sqtab moves firmly resident); refresh
  RESIDENT/COLD/ZP equates. nist-curves' onchip manifest still claims
  §8.2 — a known inconsistency, deliberately not replicated.
- Init contract: `sqtab_init` only. No REU probe, no bank claims.
- Header: `.if`-gated section in `src/x25519.inc` (additive; default
  build surface unchanged → MINOR bump, lands in v0.8.0).
- `Makefile`: `lib-x25519-onchip` target on the 1764-variant template
  (build-onchip/, `CA65FLAGS="-D X25519_ONCHIP_MUL=1"`), manifest grep,
  od65 segsize dump; plus an onchip test-harness PRG for VICE. The
  `lib-verify` symbol list goes profile-conditional (supersedes-R6
  adjacent — the stub must not import gated-out symbols).
- Contract paperwork: adopters.md §6 cell flips to shipped (enumerate
  targets); §8/§8.0 cells gain per-profile annotations (chacha
  "Profile A/B" precedent); `docs/precalc-tables.md` rows annotated
  per-profile (SPEC §8.0 symmetry rule, SPEC.md:252). No §4 segment
  split: the profile is a pure `.ifdef` swap inside existing segments.

## 5. Predicted cost (VICE-checkable, hardware-pending)

Baseline measured (docs/REU_USAGE_ANALYSIS.md): scalarmult 261,640,265
cy; `fe25519_mul` 94,733 cy; 1,031 muls + 1,274 sqrs.

Per mul: +32×32 products × ~102 cy ≈ +105K cy, −DMA saved; per
scalarmult ≈ +108M (mul) +42.4M (K=0, measured) → **~412M cy ≈ 1.6×
stock (~6.9 min NTSC)**. The same analytic method under-predicted
Group B by 74%, so treat 1.6× as a floor; measure.

Turbo: crossover = gen-cycles-per-row / DMA-row-wall. **Q1 (open):**
the true DMA stall per row — `docs/REU_USAGE_ANALYSIS.md` says ~180 cy,
physics of a 512-byte cycle-steal transfer says ~540. Settle in VICE
(CIA-timed single fetch) before quoting any crossover figure. At ~540
the crossover is ~6-7 MHz; at ~180, ~19 MHz. Either way well below 48
and 64 MHz targets.

## 6. Validation plan (VICE-only for this arc)

1. `ct_mul_brute_check.py` shim audit FIRST — nist-curves' same-named
   tool was silently broken since the §8.3 adoption ($C000 shim used
   the pre-§8.3 A=a/X=b convention; failure-shaped garbage). Verify
   ours bakes the SMC immediates + Y=b before trusting it as a gate.
2. Default build byte-identical: worktree baseline PRG SHA vs branch
   with profile undefined (#70/#71 standard). Obviates VICE reruns for
   the default profile.
3. Onchip PRG: full differential suite (pyca oracle) in REU'd VICE
   AND in no-REU VICE (`extra_args=["+reu"]`, nist-curves
   `C64_NO_REU=1` pattern). Runtime proof, not link-level — a single
   REU status poll would hang a stock machine.
4. New CT cycle gate for the onchip `fe25519_mul` (test_ct_square_cycles
   pattern): ≤1 jif spread across structurally distinct secret inputs
   (all-zeros, all-$FF, sparse, dense, duplicate-heavy src2).
5. Bench: `fe25519_mul` per-call + full scalarmult on onchip build;
   Q1 single-fetch measurement; analytic crossover table in the docs.
6. `make lib-x25519-onchip` + profile-aware lib-verify.

Deferred (merge gate for wall-clock claims): hardware A/B 16/48/64 MHz
same-run on U64E/C64U.

## 7. Follow-ups recorded, not in scope

- Inlined generator clone (−12 cy/product) if measurement justifies.
- Direct-inline-at-body variant (skip staging entirely, ~−10 cy/product
  more): strictly cheaper but discards the byte-identical inner loop +
  L12-L26 chain proof reuse; staging buys proof stability, not cycles.
  Revisit only with hardware numbers in hand.
- `tools/test_ct_mul_cycles.py`-style per-proc guard for `ct_mul_8x8`
  itself (84 cy fixed) once it is hot-path.

## Measured (VICE, 2026-07-26)

All numbers below are from the `X25519_ONCHIP_MUL` build at branch HEAD
`035c73e` (amend of `9d10f50`, identical source tree — build artifacts
under `build-onchip/` were dropped from the commit and gitignored),
PRG SHA256 `22a45668b5ff7826750f01227400ee75682f4eeb41cd534531bbfd32ba3b4ffc`
(7,585 bytes), built with:

```
rm -rf build-onchip && make BUILD_DIR=build-onchip CA65FLAGS="-D X25519_ONCHIP_MUL=1"
```

**Hardware A/B at 16/48/64 MHz remains a deferred merge gate — every
wall-clock and crossover figure here is VICE-derived and must not be
quoted as a hardware result.**

### Test-harness caveat (affects how these runs must be reproduced)

Ten `tools/*.py` run `make clean && make` internally (e.g.
`tools/bench_x25519.py:125-126`, `tools/test_fe25519.py:601-602`). With
`CA65FLAGS` unset that rebuild silently replaces the onchip PRG with the
**default** build, and the tool then measures the wrong profile without
any warning. Every run below was therefore made with

```
export PYTHONPATH=/Users/someone/Documents/c64-test-harness/src
export CA65FLAGS="-D X25519_ONCHIP_MUL=1"
```

so each internal rebuild regenerates the onchip profile, and the PRG
SHA256 was asserted equal to `22a45668…` after every single tool. Copying
`build-onchip/x25519.prg` over `build/x25519.prg` is **not** sufficient on
its own. (`CA65FLAGS ?=` in the Makefile means an exported value wins,
verified by SHA.)

`tools/*.py` also gained the nist-curves `C64_NO_REU` pattern (29 files):
`if os.environ.get("C64_NO_REU"): reu_args = ["+reu"] else: reu_args =
["-reu", "-reusize", "512"]`. Default behaviour is unchanged.

### Differential + CT suite (onchip, REU attached)

| Tool | Result | Count |
|---|---|---|
| `test_fe25519.py` | PASS | 64/64 |
| `test_fe_sqr_stress.py` | PASS | 49/49 |
| `test_fe_mul_stress.py` | PASS | 128/128 |
| `test_mul38_tables.py` | PASS | 256/256 |
| `test_fe_reduce_wide_carry.py` | PASS | 3/3 |
| `test_ct_square_cycles.py` | PASS | spread 0.005 jif (threshold 1.0) |
| `test_ct_mul_cycles.py` | PASS | spread 0.005 jif (threshold 1.0) |
| `test_ct_mul_a24_cycles.py` | PASS | spread 0.005 jif (threshold 1.0) |
| `test_ladder_checkpoint.py` | PASS | 10/10 steps |
| `ct_mul_brute_check.py` | PASS | 0 mismatches / 65,536 |
| `bench_x25519.py` (RFC 7748) | PASS | 449,589,657 cy |

CT per-call jiffies, onchip vs default (batch-200 CIA1 thunk):

| Op | Onchip | Default | Spread (onchip) |
|---|---|---|---|
| `fe25519_mul` | 13.200–13.205 jif | 6.010–6.015 | 0.005 |
| `fe25519_sqr` | 8.570–8.575 jif | 6.505–6.510 | 0.005 |
| `fe25519_mul_a24` | 0.475–0.480 jif | 0.480 | 0.005 |

`fe25519_mul`'s CT gate covers the cases §6.4 asked for: `mul_zeros` and
`mul_ff` are the maximal duplicate-heavy src2 inputs (all 32 bytes
identical), `sparse_09` the sparse case, `dense_55`/`mixed_*` the dense
ones. The generator holds 0.005 jif across all six — no measurable
dependence on src2 content, duplicate count, or zero count.

### No-REU runtime proof (`C64_NO_REU=1`, VICE launched with `+reu`)

| Tool | Result | Count |
|---|---|---|
| `test_fe25519.py` | PASS | 64/64 |
| `test_fe_mul_stress.py` | PASS | 128/128 |
| `test_fe_sqr_stress.py` | PASS | 49/49 |
| `test_ladder_checkpoint.py` | PASS | 10/10 steps |
| `bench_x25519.py` | PASS | 449,589,657 cy — **identical to the REU'd run** |

No hang at any point: no REU status poll survived the gating. The
scalarmult cycle count is *bit-identical* with and without the REU
attached, which is a stronger statement than "it completes" — any
surviving `$DFxx` access would have perturbed the count.

Negative control: the **default** build under `C64_NO_REU=1` fails
immediately and loudly (`test_fe25519.py`: `mul 0*1: expected=0 got=74`),
confirming the no-REU VICE really has no REU and that the onchip passes
above are meaningful rather than a misconfigured flag silently attaching
one.

### Q1 — RESOLVED: REU DMA stall ≈ **537 cy per 512-byte row**

Static generator cost, counted exactly from `src/fe25519.s:686-702` and
`src/mul_8x8.s:232-270` (`ct_mul_8x8` = 84 cy including `rts`; all
indexed loads are page-cross-free by the sqtab alignment + SMC hi-byte
patch, so the body is genuinely fixed-cycle):

| Quantity | Cycles |
|---|---|
| `ct_mul_8x8` incl. `rts` | 84 |
| per product (`stx`+`ldy`+`jsr`+body+`ldx`+`ldy`+2×(`lda`+`sta`)+`dex`+`bpl`) | 127 |
| per row (32 products, last `bpl` falls through, +10 row setup) | 4,073 |
| per `fe25519_mul` (32 rows) | 130,336 |

Measured mul-side cost, isolated at the scalarmult level. The onchip
build and the documented `SQR_DMA_K=0` variant share identical `sqr` and
`mul_a24` paths, so their difference is purely generator-minus-DMA:

```
onchip - K0 = 449,589,657 - 304,060,643 = 145,529,014 cy
            / 1,286 muls                = 113,164 cy per fe25519_mul
dma_per_row = (130,336 - 113,164) / 32  = 536.6 cy/row
```

Independent cross-check from the batch-200 CT thunk: default 6.010 jif =
94,733 cy ⇒ 15,763 cy/jif; onchip−default = 7.195 jif = 113,412 cy —
**100.2 % agreement** with the scalarmult-derived 113,164.

So Q1 settles on the **physics figure (~540), not the ~180 cy quoted in
`docs/REU_USAGE_ANALYSIS.md`**. 536.6 cy for 512 bytes is 1.05 cy/byte,
exactly the shape expected of a cycle-steal transfer that halts the CPU
for one bus cycle per byte plus a little setup. The ~180 figure should be
treated as superseded.

> Note: this derivation uses **1,286** muls/scalarmult
> (`tools/bench_fe_mul.py:156-162`), not the `~1,031` at
> `docs/REU_USAGE_ANALYSIS.md:35`. That 1,031 is stale — it shares the
> lineage of the debunked "763 sqrs" comment corrected in that same doc
> (§"Root cause of the prediction error"). Line 35 should be fixed.

### Crossover clock

DMA wall time is fixed at the ~1 MHz bus rate regardless of CPU turbo,
while the generator's wall time scales with the clock, so
`crossover_MHz = gen_cycles_per_row / dma_stall_per_row`:

| Stall assumption | cy/row | Crossover |
|---|---|---|
| **derived (this work)** | **536.6** | **7.59 MHz** |
| physics estimate (§5) | 540 | 7.54 MHz |
| `REU_USAGE_ANALYSIS` ~180 | 180 | 22.63 MHz |

At the derived value the profile overtakes the REU build at **~7.6 MHz** —
comfortably below the 16, 48 and 64 MHz targets, so on any accelerated
host the on-chip generator is expected to win outright. Hardware A/B
still required before this is quoted as fact.

### Scalarmult totals

| Build | Cycles | NTSC | vs default |
|---|---|---|---|
| default (`SQR_DMA_K=22`) | 261,640,265 | 255.8 s (4.26 min) | 1.000× |
| `SQR_DMA_K=0` only | 304,060,643 | 297.3 s (4.96 min) | 1.162× |
| **onchip (K=0 + generator)** | **449,589,657** | **439.6 s (7.33 min)** | **1.718×** |

Splitting the two contributions: the sqr-side `K=0` fallback costs
+42,420,378 cy (already documented), and the mul-side generator costs
+145,529,014 cy — the generator is ~3.4× the more expensive half.

§5 predicted ~412M cy (1.6×); measured 449.6M (1.72×), i.e. the analytic
method under-predicted by 8.4 %. Much better than the 74 % miss it had on
Group B, but still an under-prediction — consistent with the §5 warning
to treat 1.6× as a floor.

### Exact invocations

```
export PYTHONPATH=/Users/someone/Documents/c64-test-harness/src
export CA65FLAGS="-D X25519_ONCHIP_MUL=1"        # keeps internal rebuilds onchip
make clean && make                                # -> 22a45668...
python3 tools/test_fe25519.py                     # and each tool below
python3 tools/test_fe_sqr_stress.py
python3 tools/test_fe_mul_stress.py
python3 tools/test_mul38_tables.py
python3 tools/test_fe_reduce_wide_carry.py
python3 tools/test_ct_square_cycles.py
python3 tools/test_ct_mul_cycles.py
python3 tools/test_ct_mul_a24_cycles.py
python3 tools/test_ladder_checkpoint.py
python3 tools/ct_mul_brute_check.py
python3 tools/bench_x25519.py
# no-REU proof: prefix any of the above with
C64_NO_REU=1 python3 tools/<tool>.py
```

`tools/bench_fe_mul.py` was run but reports whole jiffies only (13–14 jif
per call) — too coarse for the Q1 derivation, which is why the
scalarmult-level isolation and the batch-200 thunk were used instead.

### Not yet done

- `ct_mul_8x8`'s own fixed-cycle property is argued statically here (84 cy)
  but still has no per-proc runtime guard — the §7 follow-up. It is now
  hot-path with secret operands, so this matters more than it did.
- Hardware A/B at 16/48/64 MHz (deferred merge gate).
