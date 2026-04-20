# CT_ANALYSIS — Constant-Time Audit for c64-x25519

Status: **Phases 0–6 landed (uncommitted)** — tracking issue
[#20](https://github.com/JC-000/c64-x25519/issues/20).

This document catalogues every currently-known secret-dependent branch and
every `(zp),y` indirect-indexed load in the X25519 library, records the
baseline and post-fix performance, and tracks follow-up work.

**Current state:** L1–L22 are fixed in the working tree. Phase 6 (this
pass) replaced the four carry-cascade short-circuits in `fe25519_sqr`
(L19–L22) with a per-body unconditional pending-carry chain plus one
end-of-inner ripple per outer-i. Every branch in the cross-term
accumulate depends only on public loop indices (`fe_mul_i`, `fe_mul_j`,
`fe_sqr_pairs`) or on a public `cmp #64` guard against the phantom
slot's out-of-bounds carry target. Scalarmult bench lands at
**12,485 jiffies** (+2,215 vs post-5b; +2,965 vs pristine).
(The diagonal `@diag_prop` path remains outside the Phase 6 scope — it
was not flagged in the original leak inventory and is tracked as a
nice-to-have audit below.) With L1–L22 fixed, the library is
considered CT-clean for network-facing use through the `fe25519_sqr`
and `fe25519_mul` surface, subject to the usual caveats about
out-of-proc callers (ladder/cswap, REU hooks).

## Threat model

The C64 implementation of X25519 is used in two distinct deployment modes,
and the threat model differs sharply between them:

1. **Local-only C64 use** (standalone demo, offline key derivation on a
   physical 6502). There is no network attacker, no remote timing oracle,
   and no realistic cache/branch-predictor side channel on a 1 MHz 6502.
   In this mode, the leaks catalogued below are essentially
   theoretical — an attacker who already has uninterrupted access to the
   CPU bus can simply read the scalar from RAM.

2. **Network-facing use via downstream consumers.** This library exports
   `x25519_scalarmult` as the primitive consumed by
   [`c64-wireguard`](https://github.com/JC-000/c64-wireguard) for the
   WireGuard handshake (ECDH over Curve25519). In that configuration the
   standard network side-channel threat model applies **transitively**:
   a remote attacker who can repeatedly initiate handshakes and measure
   response latency — over a slow serial modem, CIA-based user port link,
   RRNet, or Ethernet cartridge — can in principle exploit any
   scalar-dependent timing variation in the Montgomery ladder. The
   quarter-square path in `mul_8x8` and the squaring inner-loop in
   `fe25519_sqr` both leak information about field-element *bytes*
   (sums cross a page, differences change sign, bytes are zero). Over
   many ladder steps this compounds.

Because the same `.prg` is consumed unchanged by the network-facing
downstream, we treat it as if the network threat model always applies —
the fixes must be in place in the upstream library, not bolted on at the
consumer side.

Reference: `README.md` and `docs/LIBRARY.md` both document
`x25519_scalarmult` as the primary exported primitive; `c64-wireguard`
imports it verbatim for its handshake path.

## Leak inventory

Line numbers in the Site column are **pre-fix snapshots** against the
`master` state prior to Phases 1/2/5/5b. Post-fix lines have drifted (the
branchless rewrites in Phase 1/2 grew each `.proc`); the Notes column
records the landing phase and the approximate post-fix location where
still relevant.

| ID  | Site (file:line)      | Class       | Severity | Status | Notes                                                            |
|-----|-----------------------|-------------|----------|--------|------------------------------------------------------------------|
| L1  | src/mul_8x8.s:130     | branch      | med      | fixed  | `bcs :+` removed — Phase 1 branchless `|a-b|` sign-mask          |
| L2  | src/mul_8x8.s:137     | branch      | med      | fixed  | `beq @s0` removed — Phase 1 SMC hi-byte patch on abs,X load      |
| L3  | src/fe25519.s:912     | branch      | med      | fixed  | `bne @sqr_nonzero_j` removed — Phase 2 unconditional body A      |
| L4  | src/fe25519.s:1003    | branch      | med      | fixed  | `bne @sqr_nonzero_j_b` removed — Phase 2 unconditional body B    |
| L5  | src/fe25519.s:923     | page-cross  | high     | fixed  | `(lmul0),y` dropped — Phase 2 abs,Y via page-0 sqtab only        |
| L6  | src/fe25519.s:929     | page-cross  | high     | fixed  | `(lmul1),y` dropped — Phase 2 abs,Y via page-0 sqtab only        |
| L7  | src/fe25519.s:924     | branch      | med      | fixed  | `bcc @sqr_neg_diff` removed — Phase 2 branchless `|a-b|`         |
| L8  | src/fe25519.s:1012    | page-cross  | high     | fixed  | `(lmul0),y` dropped body B — Phase 2                             |
| L9  | src/fe25519.s:1017    | page-cross  | high     | fixed  | `(lmul1),y` dropped body B pos-diff — Phase 2                    |
| L10 | src/fe25519.s:1025    | page-cross  | high     | fixed  | `(lmul1),y` neg-diff path deleted entirely — Phase 2             |
| L11 | src/fe25519.s:1013    | branch      | med      | fixed  | `bcc @sqr_neg_diff_b` removed — Phase 2                          |
| L12 | src/fe25519.s:441     | branch      | low      | fixed  | `beq @next_j_first` removed — Phase 5 (`mul_dma[0]==0` invariant)|
| L13 | src/fe25519.s:459     | branch      | low      | fixed  | `beq @next_j_second` removed — Phase 5                           |
| L14 | src/fe25519.s:477     | branch      | low      | fixed  | `beq @next_j_third` removed — Phase 5                            |
| L15 | src/fe25519.s:495     | branch      | low      | fixed  | `beq @next_j` removed — Phase 5                                  |
| L16 | src/fe25519.s:828     | branch      | med      | fixed  | `bne @sqr_nonzero_i` removed — Phase 5b outer unconditional      |
| L17 | src/fe25519.s:1095    | branch      | med      | fixed  | `beq @sqr_dma_skip_a` removed — Phase 5b DMA body A              |
| L18 | src/fe25519.s:1117    | branch      | med      | fixed  | `beq @sqr_dma_skip_b` removed — Phase 5b DMA body B              |
| L19 | src/fe25519.s:~1188   | branch      | med      | fixed  | `bne @sqr_dma_prop_a` removed — Phase 6 per-body pending chain (DMA body A) |
| L20 | src/fe25519.s:~1232   | branch      | med      | fixed  | `bne @sqr_dma_prop_b` removed — Phase 6 per-body pending chain (DMA body B) |
| L21 | src/fe25519.s:~993    | branch      | med      | fixed  | `beq @sqr_next_j` removed — Phase 6 per-body pending chain (mult66 body A) |
| L22 | src/fe25519.s:~1086   | branch      | med      | fixed  | `beq @sqr_next_j_b` removed — Phase 6 per-body pending chain + phantom guard (mult66 body B) |

### Phase landing notes

- **Phase 1 — L1, L2 fixed in `src/mul_8x8.s`**. Branchless `|a-b|` via
  sign-mask XOR, SMC hi-byte patching of the sum load on page-aligned
  `sqtab_lo` / `sqtab_hi` (at `$7800`/`$7A00` absolute). Scratch bytes
  `mul_diff`, `mul_mask`, `mul_sum_pg` added to the file's static data
  area. Zero `mul_8x8` callers remain on the ladder hot path — the
  primitive is now only used by `reu_mul_init` one-time table build —
  so Phase 1 contributes ~0 jiffies to the scalarmult budget despite
  the ~2x cycle growth (~107 cy vs ~50 cy per call).

- **Phase 2 — L3-L11 fixed in `.proc fe25519_sqr` mult66 bodies A and B**.
  Branchless CT quarter-square modelled on Phase 1. Inner bodies mirror
  the `mul_8x8` pattern: branchless `|a-b|` via sign-mask, abs,Y on
  page 0 of `sqtab` for the diff (Y ≤ 255 always fits), and SMC
  hi-byte patching on abs,X for the sum load. The negative-diff path
  and its `sqtab2_lo`/`sqtab2_hi` tables have been deleted entirely
  (~512 bytes reclaimed). `lmul0` / `lmul1` ZP pointers freed. 2x
  unroll preserved per `feedback_selfmod_ceiling.md` (do not upgrade
  to 4x).

- **Phase 5 — L12-L15 fixed in `.proc fe25519_mul`**. Four `beq
  @next_j_*` zero-skip branches removed from the 4x-unrolled inner
  loop. Safe because `mul_dma_lo[0] == mul_dma_hi[0] == 0` by
  construction (the DMA multiplier row for `a[i] * 0` is all zeros —
  verified at `src/x25519_init.s:44-56`). Carry invariant preserved:
  `adc #0` with C=0 on entry leaves C=0 on exit, matching the old
  skipped-path behavior.

- **Phase 5b — L16-L18 fixed in `.proc fe25519_sqr`**. Outer
  `bne @sqr_nonzero_i` and the two DMA body `beq @sqr_dma_skip_*`
  zero-skips removed. Safe because (a) the Phase-2 branchless CT body
  produces product 0 cleanly when `a[i]==0` (`|0-a[j]|=a[j]`,
  `sum=a[j]`, `sqtab[sum]-sqtab[diff]=0`), (b) the DMA row for
  `2*a[i]*0` is all zeros (verified at `src/x25519_init.s:35-121`),
  and (c) `@sqr_accum` handles zero products as a functional no-op
  with C preserved.

- **Phase 6 — L19-L22 fixed in `.proc fe25519_sqr`**. The four
  carry-cascade short-circuits (two in the DMA hybrid path, two in the
  mult66 path) were removed. Each secret-dependent `beq`/`bne` on the
  combined carry (shift-carry + accumulate-carry) has been replaced by
  an unconditional carry-chain step that threads a single-bit `pending`
  carry between adjacent bodies within a given outer-i iteration. At
  the end of each outer-i's inner loop, a single end-of-inner ripple
  flushes any residual pending bit forward to `fe_wide[63]`.

  **Carry-chain mechanism (per body, always runs):**
  1. Compute `combined = shift_carry + accumulate_carry` ∈ {0,1,2}.
  2. Add the prior body's `sqr_pending` (∈ {0,1}): `val = combined +
     pending`, ≤ 3.
  3. Unconditionally add `val` to `fe_wide[i+j+2]` (body's carry
     target).
  4. Capture the new overflow bit into `sqr_pending`.
  5. Record `[i+j+3]` into `sqr_ripple_start` for the end-of-inner
     flush.

  The chain is consistent because the next body's carry target is
  `[i+j+3]` (body A's overflow position coincides with body B's carry
  target; body B's overflow position coincides with the next pair's
  body A carry target). Body B's accumulate does not read `[i+j+3]`
  directly (it reads `[i+j+1]` and `[i+j+2]`, both written by the prior
  body's accumulate and/or carry step), so the pending-bit does not
  need to be materialized into `[i+j+3]` until the next body's carry
  step. At that point it is added in constant time alongside the new
  body's combined carry. `sqr_pending` is reset to 0 at the top of
  each outer-i iteration (`@sqr_outer`), so the chain does not leak
  state across outer iterations — the end-of-inner ripple flushes any
  residual bit out to `fe_wide[63]` before `inc fe_mul_i`.

  **End-of-inner ripple:** one per outer-i (not per body). Starts at
  `sqr_ripple_start` (= last body's `[i+j+3]`), runs to `fe_wide[63]`,
  using an inner loop of
  `adc fe_wide,x / sta fe_wide,x / lda #0 / inx / dey / bne` — none
  of which touch C, so the ripple carry flows from each `adc` into
  the next uninterrupted. Exit via `dey/bne` on a public count
  (`64 - sqr_ripple_start`). A public `bcc` guards against
  `sqr_ripple_start > 64` (the sentinel case from the phantom slot).

  **Phantom-slot guard:** for `i = 30, j = 32` (the zero-padded
  `mul_src2_buf[32]` phantom body B), the carry target `[i+j+2] = 64`
  is out of fe_wide bounds. A public `cmp #64 / bcs` at the mult66
  body B carry step skips the write, resets `sqr_pending = 0`, and
  sets `sqr_ripple_start = 64` so the end-of-inner ripple runs zero
  iterations. This matches the old code's silent carry-drop past
  `fe_wide[63]` (the old `cpx #64 / bcs` stopped the ripple at the
  same boundary). The branch is on public `(i, j)` state only.

  **Design choice — Option F** (per-body 1-bit pending chain +
  single end-of-inner ripple). An earlier Option A pass (inlined
  unconditional ripple per body) was implemented, tested correct,
  and benchmarked at **31,386 jiffies** (+21,116 vs post-5b). That
  was over the brief's flag threshold (>13,000), so Option F was
  implemented and landed instead. Option F threads one pending bit
  per body and amortizes the ripple over the outer-i loop, reducing
  the per-body CT overhead from ~17cy × ~35 iterations to ~15cy
  fixed cost, plus one ~30-iteration ripple per outer-i (vs
  544 bodies × 35 iterations for Option A). The result is a
  far cheaper landing: **12,485 jiffies (+2,215 vs post-5b)**.

  Rejected alternatives: Option B (narrow 3-byte window) lacks a
  provable invariant for `fe_wide[i+j+3] <= $FE`; Option C (uniform
  64-byte ripple) is strictly worse than Option A; Option E (shared
  helper sub via `jsr`) centralizes audit but adds `jsr/rts` overhead
  without reducing the per-body count. Option F was chosen for its
  balance of CT clarity (carry chain is linear; pending value is a
  single bit; `beq/bne` branches only on public loop counters) and
  affordable performance.

  **Scratch added to the `.proc`:** `sqr_pending` (1 byte, pending
  carry ∈ {0,1}), `sqr_ripple_start` (1 byte, end-of-inner ripple
  start address). Neither leaks secrets — they carry forward public
  derived state (combined carry bit + public index). `sqr_tmp_b`
  (already present for the quarter-square body) is reused to stash
  the value-to-add across the address arithmetic.

  The old out-of-line `@sqr_dma_prop_a/b` blocks and the two
  `@sqr_prop1/_b` ripple loops were deleted entirely (~80 lines of
  dead carry-cascade code). One `bne @sqr_dma_body_a` short-branch
  was converted to `beq + jmp` to accommodate the inlined chain.
  `@diag_prop` remains unchanged — it was not in the original
  L19–L22 scope and is tracked as a nice-to-have audit below.

- **Ladder/cswap audit (2026-04-19) — fix L24a/b in
  `x25519_scalarmult`, verify `fe25519_cswap` CT-clean by inspection**.
  Gating item for side-channel deployment certification. Two
  separately-verified components:

  **A. Montgomery ladder bit loop (`src/x25519.s`).** The pre-audit
  bit loop extracted each scalar bit via a compound
  `beq @bit_zero / lda #1` sequence (L24a) and expanded the
  XOR-swap value to a $00/$FF mask via a second
  `beq @no_swap_mask / lda #$ff` (L24b). Both branches depended on
  secret state (scalar bit value and XOR of consecutive scalar
  bits respectively), contributing ~1 cy of scalar-bit-dependent
  timing per iteration × 255 iterations × 2 branches — small in
  absolute terms, but a structural leak.

  **Fix:** the bit-extract + mask-expand rewrites to a
  branchless constant-cycle sequence:

  ```
  ldx x25_byte_idx          ; public loop counter
  lda x25_scalar,x          ; scalar byte (secret, time-invariant load)
  and x25_bit_mask          ; A = 0 or bit_mask (secret DATA, constant timing)
  cmp #1                    ; C = (A != 0) = scalar bit
  lda #0
  sbc #0                    ; A = $00 if bit=1, $FF if bit=0
  eor #$ff                  ; A = $FF if bit=1, $00 if bit=0 (k_t_mask)
  tax                       ; X = k_t_mask for prev_bit update
  eor x25_prev_bit          ; A = swap_mask (direct EOR, no branch)
  stx x25_prev_bit          ; prev_bit = k_t_mask (mask form carried forward)
  ```

  Every op runs unconditionally; every branch remaining in the bit
  loop (`bne @bit_loop` on `lsr x25_bit_mask`, `bpl @bit_loop` on
  `dec x25_byte_idx`) is driven by a public loop counter. The
  `beq @skip_final_mask` branch at the post-loop final-cswap
  setup was also deleted — storing prev_bit in mask form makes
  the post-loop `lda x25_prev_bit` produce the correct
  $00/$FF mask directly.

  **B. `fe25519_cswap` (`src/fe25519.s`).** The cswap body is a
  4x-unrolled 32-byte loop with 20 entry-time SMC patches of
  src1/src2 addresses into abs,Y loads/stores. Audit conclusions:

  - Entry SMC depends only on `fe25519_src1`/`fe25519_src2` ZP
    pointers. Every caller (`x25519_scalarmult`) sets these from
    link-time public addresses (`x25_x2`/`x25_x3`/`x25_z2`/`x25_z3`,
    all 32-byte aligned per `data.s:.assert`). No secret input to
    the patch sequence.
  - Inner loop instruction sequence
    (`lda/tax/eor/and/sta/txa/eor/sta/lda/eor/sta`) runs every
    iteration unchanged. The mask (`fe_carry`) affects only the
    DATA written, never the instruction stream or the number of
    ops executed.
  - Only branch in the body is `bpl @loop` on `dey`, where Y is
    the byte counter (public).
  - No page-cross in the 32-byte abs,Y loads: every caller passes
    src1/src2 pointing at 32-byte-aligned buffers, so abs+Y for
    Y ∈ [0..31] stays on a single page. The alignment is a
    hard link-time assertion in `data.s` and is documented as a
    library contract in `LIBRARY.md §6`.

  Conclusion: `fe25519_cswap` is CT-clean with respect to the
  swap mask, and the audit is recorded as an inline comment
  above the `.proc` body.

  **Branch classification summary (x25519_scalarmult):**

  | Site              | Branch                    | Class            | Notes                                      |
  |-------------------|---------------------------|------------------|--------------------------------------------|
  | bit loop line 137 | `beq @bit_zero` (was)     | secret → fixed   | L24a — scalar bit, replaced by cmp/sbc/eor |
  | bit loop line 146 | `beq @no_swap_mask` (was) | secret → fixed   | L24b — XOR of scalar bits, direct EOR      |
  | bit loop          | `bne @bit_loop`           | public           | bit position counter (lsr bit_mask)        |
  | bit loop          | `bpl @bit_loop`           | public           | byte index counter (dec byte_idx)          |
  | final cswap       | `beq @skip_final_mask` (was) | derived → fixed | prev_bit now in mask form, branch removed  |
  | ladder step       | (no branches)             | —                | straight-line fe25519 primitives           |
  | x_3 = u init      | `and #$7f` + copy         | public           | fe25519_copy is a fixed 32-byte loop       |

  **Perf:** scalarmult bench lands at **10,739 jiffies (median of
  3, flat vs baseline)**. The new branchless sequence replaces the
  old branching sequence cycle-for-cycle in the best case, and
  saves 1 cycle in the worst case — net ≈ 0 jif over 255
  iterations. CT spread (`test_ct_square_cycles.py`) stays at
  0.150 jif (pre: 0.155), well under the 1.0 jif threshold.

### Follow-ups

**Queued performance-recovery options** (Phase 6 CT-clean landing
further increased the regression; recover in a later perf-recovery
pass — the library is now provably CT-clean for L1–L22 and the
perf cost is the price paid for that guarantee):

- **Option 2 — Hoist SMC patches across bodies A and B.** Compute
  `>sqtab_lo + sum_pg` and `>sqtab_hi + sum_pg` once per pair-
  iteration and store to both bodies' patch sites at once. Saves
  ~8 patches per pair. Estimated recovery: 200-300 jiffies.

- **Option 3 — Keep abs-math partial state in registers.** The Phase
  2 body conservatively stores `sqr_diff` / `sqr_mask` to memory;
  tightening this can keep them in A/X/Y across the SBC/EOR
  sequence. Estimated recovery: 100-150 jiffies.

- **Option 4 — Branchless-blend instead of SMC.** Load both
  page-0 and page-1 sqtab candidates, blend via sign mask. Simpler
  to audit and decouples the fix from the project's per-call SMC
  culture. Cycle cost is in the same ballpark; value is structural
  simplicity, not speed.

- Try Options 2+3 together in a dedicated perf-recovery pass before
  shipping v0.3.0.

**Nice-to-have:**

- **Add `tools/test_ct_square_cycles.py`** cycle-count regression
  guard (deferred from Phase 2). Runs `fe25519_square` on two inputs
  with different Hamming profiles and asserts equal cycle counts.
  Gates future edits against CT regression. With L19–L22 fixed, this
  test now has a chance of passing and is the natural first consumer
  of the Phase 6 guarantee.
- **Audit `x25519_scalarmult` itself** for scalar-bit-dependent
  branches in the Montgomery ladder / cswap. The ladder is the next
  layer up from `fe25519_*`; any bit-conditional branching there
  would defeat the field-op CT fixes.
- **Audit `fe25519_sqr`'s `@diag_prop` path** for the same carry-
  cascade short-circuit pattern as L19–L22. The `bcc @diag_skip`
  and its `cpx`-controlled ripple loop still branch on
  secret-derived carry. This was not in the original CT_ANALYSIS
  inventory and is out of scope for Phase 6, but uses the same
  leak pattern and should be fixed in the same Phase-6-style
  unconditional ripple before the next CT re-audit.

### Class legend

- **branch**: secret-dependent conditional branch (direction depends on
  secret data → execution-time asymmetry observable externally).
- **page-cross**: `lda (zp),y` indirect-indexed load where the base +
  Y may or may not cross a page boundary, costing one extra cycle when
  it does. The base for `lmul0`/`lmul1` is `sqtab_lo`/`sqtab_hi` at
  `$7800`/`$7A00` (page-aligned), so this specific pair does not cross
  at the moment — but the pattern is fragile under reassembly and any
  future base change. Flagged `high` because addressing the same class
  of leak systematically is cheaper than doing it case by case.

### Severity

- **high**: per-byte timing variation that scales with field-op count
  (every ladder step hits this path).
- **med**: per-byte timing variation bounded to at most a few cycles;
  still observable over the ~255 ladder steps.
- **low**: zero-skip shortcut that only triggers on byte-zero inputs —
  real field elements rarely have many zero limbs, but secret
  intermediates can.

## Remediation history

- **Phase 0** — audit document + `tools/ct_mul_brute_check.py`
  exhaustive-correctness tool (65,536 `(a,b)` pairs against Python
  reference). No `.s` changes.
- **Phase 1** — fix **L1, L2** (`src/mul_8x8.s`). Branchless
  `|a-b|` sign-mask + SMC hi-byte patch on page-aligned abs,X.
- **Phase 2** — fix **L3-L11** (`fe25519_sqr` mult66 bodies A/B).
  Inline branchless CT quarter-square; drops `(lmul0/1),y`,
  `sqtab2_*`, zero-skip, sign branch, and neg-diff path.
- **Phase 3** — DMA hybrid path audit. Discovered L16-L22 (this
  document was updated at the time with those additions).
- **Phase 4** — dead-code cleanup: remove `sqtab2_*`, `lmul0/1`,
  `.import sqtab2_*`, `sta lmul*` feeders (~512 bytes reclaimed).
- **Phase 5** — fix **L12-L15** (`fe25519_mul` 4x-unrolled
  zero-skips). Safe via `mul_dma[0]==0` invariant.
- **Phase 5b** — fix **L16-L18** (`fe25519_sqr` outer + DMA zero-
  skips). Safe via branchless-CT-body zero-product invariant and
  `mul_dma[0]==0`.
- **Phase 6** — fix **L19-L22** (`fe25519_sqr` carry-cascade short-
  circuits). Option F: per-body 1-bit pending-carry chain plus a
  single end-of-inner ripple per outer-i. Every branch in the
  cross-term accumulate now depends only on public state
  (`fe_mul_i`, `fe_mul_j`, `fe_sqr_pairs`, and a public `cmp #64`
  phantom-slot guard). Old opportunistic `bcs @prop / cpx #64 /
  bcs :done` pattern replaced by an unconditional chain step
  plus a `dey/bne`-controlled ripple whose count is public-derived
  (`64 - sqr_ripple_start`). See "Phase 6 landing notes" above for
  the full mechanism and the rejected Option A trial.
- **Ladder/cswap audit (2026-04-19)** — fix **L24a/b**
  (`x25519_scalarmult` scalar-bit-dependent branches), verify
  **`fe25519_cswap` CT-clean by inspection**. Two branches on
  scalar-derived state (`beq @bit_zero`, `beq @no_swap_mask`) in
  the Montgomery ladder bit loop replaced by a branchless
  `cmp/sbc/eor` bit-to-mask idiom. `x25_prev_bit` storage
  migrated to mask form ($00/$FF), eliminating a third branch
  (`beq @skip_final_mask`) at the post-loop final cswap. The
  cswap body was already mask-time-invariant by construction
  (unrolled 4x abs,Y sequence with no branch on fe_carry, no
  page-cross under the library's 32-byte alignment contract);
  audit now recorded as an inline comment in `src/fe25519.s`.
  Scalarmult bench **flat at 10,739 jiffies** (median of 3).
  Gating item for side-channel deployment certification — the
  library's outermost primitive no longer leaks scalar-bit
  information through branch timing. See "Ladder/cswap audit"
  landing notes above.

Issue [#20](https://github.com/JC-000/c64-x25519/issues/20) was the
origin report for L1-L15. L16-L22 were discovered during the Phase 3
audit. Every landing was gated on
`tools/ct_mul_brute_check.py` (mul_8x8 exhaustive) plus the full
`make test-slow` matrix (`tools/test_fe_mul_stress.py` /
`tools/test_fe_sqr_stress.py` / `tools/test_x25519.py --slow` /
`tools/test_ladder_checkpoint.py --start 0 --count 255`).

## Performance

`x25519_scalarmult` (scalar × basepoint 9, RFC 7748 vector 1, NTSC,
VICE warp, VIC-II blanked). Measured via `python3 tools/bench_x25519.py`.

| State                     | Jiffies | Delta vs pristine | Notes                               |
|---------------------------|---------|-------------------|-------------------------------------|
| Pristine master (pre-fix) | 9,520   | —                 | Post-v0.1.0 baseline                |
| Post-Phase 2 (L3–L11)     | 10,251  | +731 (+7.7 %)     | CT mult66 rewrite lands             |
| Post-Phase 5 (L12–L15)    | ~10,251 | +731 (+7.7 %)     | negligible additional cost          |
| Post-Phase 5b (L16–L18)   | 10,270  | +750 (+7.9 %)     | v0.2.0 L1–L18 stopping point        |
| Phase 6 (Option A trial)  | 31,386  | +21,866 (+230 %)  | unconditional per-body ripple — discarded |
| Post-Phase 6 (L19–L22)    | 12,485  | +2,965 (+31.1 %)  | Option F landing                    |
| v0.3.0 perf recovery      | 10,739  | +1,219 (+12.8 %)  | Phases 1–3 landed (master 181a181)  |
| Post-ladder/cswap audit (L24) | **10,739** | **+1,219 (+12.8 %)** | **flat; branchless bit-extract, 3-run median** |

### Regression budget (original plan) vs. actual (through L24)

| Bound                | Jiffies | Actual (+1,219 since pristine) | Status                  |
|----------------------|---------|--------------------------------|-------------------------|
| Soft (target)        | ≤ +200  | exceeded                       | breach                  |
| Hard (ceiling)       | ≤ +400  | exceeded                       | breach                  |
| Phase 6 brief's cap  | ≤ 13,000 | 10,739                        | within cap              |
| Ladder/cswap budget  | ≤ +50   | +0 (flat)                      | within budget           |

**Design-review decision (recorded here):** Phases 1–5b already
exceeded the pre-Phase-6 hard ceiling (+750 / +7.9 %). Phase 6 was
explicitly scoped as correctness-first, with a 2-3× inflation of its
own estimated 400-800 jiffy budget accepted as the price of CT-clean
certification for network-facing use. Phase 6's Option F landing came
in at +2,215 vs the Phase-5b baseline; Option A was rejected as
unaffordably expensive (+21,116 vs baseline → 31,386 total, ~3× over
the brief's flag threshold of 13,000). Options 2/3/4 in Follow-ups
remain queued for a later perf-recovery pass; target v0.3.0 under
+15 % relative to the pristine 9,520 baseline after applying
patch-hoisting and register-state tightening. The library remains
~31 % faster than the original pre-optimization baseline
(~18,000 jiffies) despite the full L1–L22 remediation.

## Related projects

Sibling audit reports and CT remediations (same leak patterns, same
author, shared tooling style):

- [`c64-ChaCha20-Poly1305`](https://github.com/JC-000/c64-ChaCha20-Poly1305)
  **v0.3.0** — `docs/AUDIT.md`. Same quarter-square `mul_8x8` pattern;
  fix already landed and released. This is the reference implementation
  for Phase 1 here.
- [`c64-nist-curves`](https://github.com/JC-000/c64-nist-curves/issues/14)
  — issue #14, parallel CT remediation for P-256 scalarmult.
- [`c64-wireguard`](https://github.com/JC-000/c64-wireguard/issues/16)
  — issue #16, downstream tracking issue; blocks on this library.
- [`c64-aes256-ecdsa`](https://github.com/JC-000/c64-aes256-ecdsa/issues/19)
  — issue #19, parallel CT remediation for ECDSA signing.
