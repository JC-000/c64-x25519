# Issue #72 — `X25519_ONCHIP_MUL` build profile (design)

Status: DRAFT — implementation in progress on `issue-72-onchip-mul`.
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
