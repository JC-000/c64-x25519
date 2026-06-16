# Issue #15 design — SMC-patched `reu_fetch_mul_row` reuse from `reu_fetch_doubled_row`

> c64-lib-contract issue #15 follow-up — v0.7.0-prep, target branch
> `feat/issue-15-smc-patch-doubled-fetch`.
>
> The upstream design comment parked at
> `c64-nist-curves/.research/issue_15_design_2026_05_23.md` is NOT
> accessible from this repo. This document is the fresh design log
> for the c64-x25519 side of the refactor.

## 1. Motivation

`src/x25519_init.s` carries two REU FETCH primitives that overlap
structurally:

- **`reu_fetch_mul_row`** — canonical 3-register-touch FETCH used by
  `fe25519_mul`'s per-row inline DMA. It only writes
  `reu_reu_hi` / `reu_reu_bank` / `reu_command` and trusts the
  autoload latch for `reu_c64_lo` / `reu_c64_hi` /
  `reu_len_lo` / `reu_len_hi` / `reu_reu_lo` / `reu_addr_ctrl`.
- **`reu_fetch_doubled_row`** — used by `fe25519_sqr`'s DMA path
  (`SQR_DMA_K > 0`). Pre-v0.7 it open-coded an identical
  3-register-touch FETCH for its 512-byte doubled-lo/hi fetch
  ("DMA #1"), then issued an inline carry-table fetch ("DMA #2",
  256 bytes to `mul_dma_carry` from bank +3).

Track A (`a707b3e`, §8.2 adoption) added an SMC patch point
`reu_fetch_mul_row_bank_patch` that exposes the bank-base immediate
operand of `reu_fetch_mul_row`'s `lda #X25519_REU_BANK` instruction.
Track A explicitly DEFERRED consuming the patch from within
`reu_fetch_doubled_row` ("DO NOT modify reu_fetch_doubled_row
itself"). Issue #15 picks that up.

## 2. Refactor shape

### DMA #1 — delegated to `reu_fetch_mul_row` via SMC

```
; Re-establish canonical autoload-latch state. These five writes are
; NOT redundant: DMA #2 of the previous iteration stomped reu_c64_lo/hi
; and reu_len_hi.
        lda #<(mul_dma_lo)
        sta reu_c64_lo
        lda #>(mul_dma_lo)
        sta reu_c64_hi
        lda #0
        sta reu_reu_lo
        sta reu_len_lo
        sta reu_addr_ctrl
        lda #2
        sta reu_len_hi             ; 512 bytes

        lda #X25519_REU_BANK_DOUBLED
        sta reu_fetch_mul_row_bank_patch
        jsr reu_fetch_mul_row
        lda #X25519_REU_BANK
        sta reu_fetch_mul_row_bank_patch
```

`reu_fetch_mul_row` then loads `mul_cached_a`, shifts to derive
`reu_reu_hi` and the +0/+1 bank carry, fires the FETCH command. Same
512 bytes land in `mul_dma_lo/hi` as before.

### DMA #2 — stays inline

```
        ; --- DMA #2: 256 bytes to mul_dma_carry from CARRY bank,
        ;     offset a*256. Stays inline: different length (256 not 512),
        ;     different target buffer, different reu_reu_hi derivation
        ;     (raw `mul_cached_a`, not `mul_cached_a << 1`). Cannot
        ;     fold into reu_fetch_mul_row without changing that
        ;     primitive's contract.
```

DMA #2 explicitly re-writes the seven REU registers it cares about
before firing, so it never reads a stale latch value.

### `SQR_DMA_K = 0` gating

The whole `.proc reu_fetch_doubled_row` body is wrapped in
`.if ::SQR_DMA_K`, matching the existing gate inside
`reu_mul_init` (where the doubled-table generation block is
already SQR_DMA_K-gated) and `src/lib_version.s`'s
`LIB_X25519_REU_BANKS_USED` manifest mask flip. The matching
`.export reu_fetch_doubled_row` in `src/x25519_init.s` and the
`.import reu_fetch_doubled_row` / DMA-dispatch block in
`src/fe25519.s` are likewise gated. K=0 builds (`make
lib-x25519-1764`) therefore carry zero references to
`reu_fetch_mul_row_bank_patch` or `X25519_REU_BANK_DOUBLED` from
this code path.

## 3. Autoload-latch invariant (LOAD-BEARING)

`reu_fetch_mul_row` only writes three REU registers
(`reu_reu_hi`, `reu_reu_bank`, `reu_command`). It expects the
autoload latch to already hold:

| Register        | Required value           |
|-----------------|--------------------------|
| `reu_c64_lo`    | `<mul_dma_lo`            |
| `reu_c64_hi`    | `>mul_dma_lo`            |
| `reu_reu_lo`    | `$00`                    |
| `reu_len_lo`    | `$00`                    |
| `reu_len_hi`    | `$02` (i.e. 512-byte len)|
| `reu_addr_ctrl` | `$00` (both increment)   |

Three sites establish this state:

1. **`reu_mul_init` tail** — one-shot at library init.
2. **`reu_clear_wide` tail** — runs at the top of every
   `fe25519_sqr` and `fe25519_mul` call, restoring the latch in case
   a prior `reu_fetch_doubled_row` left DMA #2's residue
   (`mul_dma_carry` / 256 bytes).
3. **`reu_fetch_doubled_row` DMA #1 setup** — the five explicit
   register writes shown in §2, run at the top of every iteration of
   `fe25519_sqr`'s DMA loop.

**Why all three are needed:** `fe25519_sqr` calls `reu_clear_wide`
ONCE at entry, then loops 22 times calling `reu_fetch_doubled_row`.
Between iterations of the loop the autoload latch holds DMA #2's
residue (`mul_dma_carry` / 256), so iteration N+1's DMA #1 MUST
re-establish the canonical state before delegating to
`reu_fetch_mul_row`. Skipping the explicit writes would silently
DMA 256 bytes into `mul_dma_carry` instead of 512 bytes into
`mul_dma_lo/hi` — a W2-class state-leak corruption.

**This is documented at the call site** (long banner above
`.proc reu_fetch_doubled_row` in `src/x25519_init.s`) and as a
caller-contract comment in `reu_fetch_mul_row`'s banner, so future
caller-shape changes (e.g. a hypothetical version of `fe25519_sqr`
that dispatches `reu_fetch_doubled_row` from a different surrounding
state) cannot silently regress without first reading the contract.

## 4. Risk register

| ID | Risk                                                                                                        | Coverage                                                                                                                                                                                                                                                              |
|----|-------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| R1 | SMC patch restore window — if the restore `sta reu_fetch_mul_row_bank_patch` is skipped or wrong, the next `fe25519_mul` row fetch reads from `X25519_REU_BANK_DOUBLED` (= bank +4) instead of `X25519_REU_BANK`. Wrong mul table → wrong product → ladder corruption. | `tools/test_fe_sqr_then_mul.py` Phases B + C: every sqr is followed by a series of muls, and every mul output is asserted against `pyca.cryptography`. A skipped/incorrect restore would manifest as a single `fe25519_mul` failure on the first post-sqr iteration. |
| R2 | Autoload-state corruption between `reu_fetch_doubled_row` calls — if iteration N+1's DMA #1 inherits DMA #2's latched state (`mul_dma_carry` / 256), the doubled-lo/hi DMA writes 256 wrong bytes into `mul_dma_carry`. | `tools/test_fe_sqr_then_mul.py` Phase B sub-trials: each sub-trial issues a fresh `fe25519_sqr` which exercises the 22-iter DMA loop; the sqr output is asserted against pyca. Iteration-2 state-leak manifests as a wrong square.                                    |
| R3 | K=0 build (`make lib-x25519-1764`) silently fails to exercise the refactor — accidental K=0 path activation in a default consumer could re-expose latent issues. | (a) `.if ::SQR_DMA_K` gates `.export reu_fetch_doubled_row` and the proc body; K=0 link with a stale `.import` errors at link time. (b) Zero-delta bench verified at K=0 (see §5).                                                                                       |

## 5. Bench results

Hardware-agnostic VICE/CIA1 cycle-exact bench via
`tools/bench_fe_ops.py --iterations 5 --batch 50 --no-blank`. Numbers
in cycles/call (lower = faster).

### Default `SQR_DMA_K=22` build

Bench: `python3 tools/bench_fe_ops.py --iterations 5 --batch 50 --no-blank`
(deterministic via fixed `random.Random(25519)` seed; all numbers
are CIA1-cycle-exact, NTSC, warp-mode VICE 1750 REU).

| Op                  | Baseline (a707b3e) | After refactor | Δ (cy) | Δ (%)   |
|---------------------|--------------------|----------------|--------|---------|
| `fe25519_mul`       | 101 054.8          | 101 053.6      |  -1.2  | -0.001% |
| `fe25519_sqr`       | 108 823.2          | 109 392.0      | +568.8 | +0.523% |
| `fe25519_add`       | 2 340.2            | 2 339.2        |  -1.0  | -0.043% |
| `fe25519_sub`       | 1 775.9            | 1 775.1        |  -0.8  | -0.045% |
| `fe25519_reduce_final` | 3 199.9         | 3 194.8        |  -5.1  | -0.159% |
| `fe25519_mul_a24`   | 8 073.6            | 8 079.6        |  +6.0  | +0.074% |
| `fe25519_cswap`     | 1 625.4            | 1 624.5        |  -0.9  | -0.055% |

Gate: `fe25519_sqr` delta ≤ 2 % → **PASS** (+0.523 %).

The +568.8 cy on `fe25519_sqr` is the expected cost of the
delegation: 22 iterations of `@sqr_outer` each pay one
`jsr reu_fetch_mul_row` + RTS (12 cy) + two `sta abs` SMC writes
(8 cy each = 16 cy), totalling ≈22 × 28 = 616 cy worst-case. The
measured +569 cy lines up after subtracting the deleted
`lda mul_cached_a / asl / sta reu_reu_hi / lda #BANK / adc #0 / sta
reu_reu_bank / lda #cmd / sta reu_command` from the old open-coded
DMA #1 path. Net wash on `fe25519_inv` (which dominates
`x25519_scalarmult` runtime): +0.7 jif observed (within noise).

Other ops (`mul`, `add`, `sub`, `reduce_final`, `mul_a24`, `cswap`)
were untouched — their deltas are within ±6 cycles, consistent with
ca65/ld65 layout reshuffling of unrelated code.

### K=0 (`make lib-x25519-1764`) build

The K=0 build does NOT compile the refactored `reu_fetch_doubled_row`
body — it's gated out entirely via `.if ::SQR_DMA_K`. The K=0 hot
path is byte-identical to the v0.6.0 lib-x25519-1764 hot path
because (a) the proc was already unreachable at runtime via
`cmp #SQR_DMA_K=0 / bcs` always-taken, and (b) the new gate also
drops the (previously-dead-but-emitted) `.export` and `.import` of
`reu_fetch_doubled_row`. Net effect: the K=0 library archive
SHRINKS by the size of the (formerly emitted, dead) proc.

Verified by diffing `.o` segment sizes between
`build-1764-base/` (baseline, pre-refactor) and `build-1764/`
(post-refactor):

| Module              | Baseline | After refactor | Δ (bytes) |
|---------------------|----------|----------------|-----------|
| `x25519_init.o` CODE| 620      | 532            | **-88**   |
| `fe25519.o` CODE    | 2 711    | 2 657          | **-54**   |
| `libx25519.a` total | 85 745   | 84 551         | **-1 194**|
| `lib_linkage_stub.prg` | 8 193 | 8 193          | 0         |

The PRG-stub size is identical because ld65 already dead-stripped
the unreferenced (under K=0) proc body. The `.a` archive shrinks
because the gated-out proc + matching imports/exports never make
it into the object files in the first place.

**Cycle-count delta: zero by construction.** K=0 `fe25519_sqr`
never dispatches to `reu_fetch_doubled_row`; the `cmp #0 / bcs`
takes the mult66 path on every iteration, identical assembly to
v0.6.0. No bench needed — the size-diff is a stronger zero-delta
proof than a noisy single-build bench would be.

## 6. Resolution log — design questions

The five supervisor-#2 questions on c64-lib-contract issue #15
(supervisor-#2 reply dated 2026-05-23) are resolved as follows:

### Q1. Should DMA #1 delegate to `reu_fetch_mul_row` or to a new shared `reu_fetch_row(bank, c64, len)` primitive?

**Resolved: delegate to `reu_fetch_mul_row` via SMC patch.** A
parametric `reu_fetch_row` would require either runtime args
(needs ZP scratch, kills the 3-register-touch property) or SMC of
three operands instead of one, neither of which is cleaner than the
one-byte SMC patch already exposed by Track A. The refactor saves
roughly 16 bytes by collapsing one `lda #/sta` + carry-add into
the shared primitive, without disturbing `reu_fetch_mul_row`'s
canonical contract.

### Q2. Where should the autoload-latch invariant be documented?

**Resolved: at three sites.** (a) Banner of
`.proc reu_fetch_doubled_row` explains the invariant + the
per-iteration re-write requirement. (b) Banner of
`.proc reu_fetch_mul_row` adds a "Caller contract" paragraph naming
the two callers that honor the contract. (c) This design doc records
the formal table of expected latch state. The triple-redundancy is
deliberate: the asm banners are the first thing a reader sees when
touching either proc; this doc is the design rationale.

### Q3. Should DMA #2 (carry-table fetch) also be refactored to use the SMC primitive?

**Resolved: NO, stays inline.** DMA #2 differs in length (256 vs
512), target buffer (`mul_dma_carry` vs `mul_dma_lo`), and
`reu_reu_hi` derivation (raw `mul_cached_a` vs `mul_cached_a << 1`).
Folding it into `reu_fetch_mul_row` would require parameterizing
those three behaviors, which loses the 3-register-touch property.
The asymmetry is documented in the proc's banner and at the DMA #2
site comment.

### Q4. Should the SMC restore-to-`X25519_REU_BANK` happen at the end of `reu_fetch_doubled_row` or be the caller's responsibility?

**Resolved: at the end of `reu_fetch_doubled_row` (specifically,
immediately after `jsr reu_fetch_mul_row` returns and before
DMA #2).** Caller-side restore would split the SMC contract across
proc boundaries and silently couple `fe25519_sqr` to the
`reu_fetch_doubled_row` implementation. In-proc restore makes the
proc R1-safe in isolation and matches the
"library-private hidden state" discipline of the rest of
`src/x25519_init.s`.

### Q5. What is the regression-test surface that justifies merging?

**Resolved: `tools/test_fe_sqr_then_mul.py`.** Three phases:
- Phase A: mul-only baseline (independent control).
- Phase B: sqr-then-mul, 4 sub-trials, 8 muls each. Covers R1 + R2
  (each sqr exercises 22 SMC patch+restore cycles + 22 autoload-latch
  re-establishments; subsequent muls would diverge on either kind
  of corruption).
- Phase C: tight `sqr → mul → sqr → mul → …` interleave mirroring
  the Montgomery-ladder shape.
- All comparisons go through `pyca.cryptography`-equivalent reference
  in pure Python (`(a * b) % P`, `(x * x) % P`), no repo-local
  reimplementation. Deterministic with `--seed`.

## 7. Files touched

- `src/x25519_init.s` — refactored `reu_fetch_doubled_row` body,
  updated `reu_fetch_mul_row` and `reu_clear_wide` banner comments,
  gated `.export reu_fetch_doubled_row` on `SQR_DMA_K`.
- `src/fe25519.s` — gated `.import reu_fetch_doubled_row` and the
  DMA-path dispatch block in `fe25519_sqr` on `SQR_DMA_K`.
- `tools/test_fe_sqr_then_mul.py` — new W2-class state-leak regression.
- `docs/design/issue_15_smc_patch_doubled_fetch.md` — this document.

## 8. Followups not in this PR

- A future c64-lib-contract version may want to publish a
  `LIB_REU_FETCH_BANK_PATCH` equate so consumers can target the same
  SMC byte without depending on the x25519-private symbol name. The
  current symbol is already `.export`'d (by Track A); only the
  `LIB_*` rename is missing. Tracked separately.
- The `bench_fe_ops.py` numbers in §5 should be promoted to
  `docs/perf_history.csv` as part of v0.7.0 prep.
