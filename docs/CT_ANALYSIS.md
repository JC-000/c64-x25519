# CT_ANALYSIS — Constant-Time Audit for c64-x25519

Status: **Phases 0–7 landed: L1–L29 CT-clean** — tracking issue
[#20](https://github.com/JC-000/c64-x25519/issues/20).

This document catalogues every currently-known secret-dependent branch and
every `(zp),y` indirect-indexed load in the X25519 library, records the
baseline and post-fix performance, and tracks follow-up work.

**Current state:** L1–L29 are fixed in the working tree. Phases 0–6 +
the @diag_prop and ladder/cswap audits closed L1–L24 across `mul_8x8`,
`fe25519_sqr` (cross-term + diagonal), and the outer Montgomery
ladder. Phase 7 (post-v0.4.0 sweep) closes L25 / L26a-d / L27a-f /
L28a-k / L29a-e — the field-op surface beyond `fe25519_sqr`:
`fe25519_mul`, `fe_reduce_wide`, `fe25519_mul_a24`, `fe25519_add`,
`fe25519_sub`, `fe_cmp_p`, and `fe25519_reduce_final`. With L1–L29
fixed, the library is now CT-clean across the entire `fe25519_*` /
`mul_8x8` / `x25519_scalarmult` surface for network-facing use,
subject to the usual caveats about caller-installed ISRs and host
NMI hooks documented in `docs/LIBRARY.md` §9.

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
| L23a | src/fe25519.s:~1316  | branch      | low      | fixed  | `beq @diag_skip` on secret `a[i]==0` — @diag_prop audit (2026-04-19), unconditional via `sqr_lo[0]=sqr_hi[0]=0` zero-product |
| L23b | src/fe25519.s:~1337  | branch      | med      | fixed  | `bcc @diag_skip` on diag-add carry — @diag_prop audit, replaced by unconditional ripple |
| L23c | src/fe25519.s:~1352  | branch      | med      | fixed  | `bcs @diag_prop` cascade (ripple length tied to secret data) — @diag_prop audit, replaced by public-count ripple |
| L24a | src/x25519.s:~137    | branch      | low      | fixed  | `beq @bit_zero` scalar-bit branch — replaced by branchless `cmp/sbc/eor` bit-to-mask (PR #30) |
| L24b | src/x25519.s:~146    | branch      | low      | fixed  | `beq @no_swap_mask` XOR-of-bits branch — direct EOR + mask-form `x25_prev_bit` (PR #30) |
| L25  | src/fe25519.s:~568   | branch      | med      | fixed  | `fe25519_mul` outer-i zero-skip on secret `a[i]==0` — Phase 7, outer body now unconditional; safe via `mul_dma[0]==0` invariant + Phase-6 chain |
| L26a | src/fe25519.s:~625   | branch      | med      | fixed  | `fe25519_mul` accumulate-cascade short-circuit (body 1) — Phase 7, replaced by Phase-6 Option F per-body 1-bit pending chain |
| L26b | src/fe25519.s:~660   | branch      | med      | fixed  | `fe25519_mul` accumulate-cascade short-circuit (body 2) — Phase 7, same chain pattern |
| L26c | src/fe25519.s:~695   | branch      | med      | fixed  | `fe25519_mul` accumulate-cascade short-circuit (body 3) — Phase 7, same chain pattern |
| L26d | src/fe25519.s:~730   | branch      | med      | fixed  | `fe25519_mul` accumulate-cascade short-circuit (body 4) — Phase 7, end-of-inner ripple uses public count `63 - fe_mul_i` (`mul_bound`); phantom guard via `cmp mul_bound / bcs` |
| L27a | src/fe25519.s:~935   | branch      | med      | fixed  | `fe_reduce_wide` first-pass cascade short-circuit — Phase 7, unconditional `dey/bne` cascade gated by `mul38_lo_tab[0]=0` lemma (no carry past zero limb) |
| L27b | src/fe25519.s:~970   | branch      | med      | fixed  | `fe_reduce_wide` second-pass cascade short-circuit — Phase 7, same pattern |
| L27c | src/fe25519.s:~1000  | branch      | low      | fixed  | `fe_reduce_wide` propagate-carry-on-zero short-circuit — Phase 7, unconditional |
| L27d | src/fe25519.s:~1025  | branch      | low      | fixed  | `fe_reduce_wide` post-mul38 carry-skip — Phase 7, unconditional |
| L27e | src/fe25519.s:~1050  | branch      | low      | fixed  | `fe_reduce_wide` final-limb carry-skip — Phase 7, unconditional |
| L27f | src/fe25519.s:~1075  | branch      | low      | fixed  | `fe_reduce_wide` end-of-pass cascade — Phase 7, public-count terminator. Output bound ≤ 2p enforced (regression: `tools/test_fe_reduce_wide_bound.py`) |
| L28a-k | src/fe25519.s:~1738+ | branch    | med      | fixed  | `fe25519_mul_a24` outer body + 11 cascade-short-circuit sites (4 stages × multi-byte ripples) — Phase 7, unconditional outer body and `fe_carry`-threaded reduction stages; cascades replaced by `dey/bne` public-count ripples |
| L29a | src/fe25519.s:~296   | branch      | **HIGH** | fixed  | `fe_cmp_p` early-exit byte comparison (~4,080 calls/scalarmult, 250 cy variance) — Phase 7, replaced by new `fe_cmp_p_ct` proc returning $00/$FF mask via `lda#0/sbc#0/eor#$FF` idiom; unconditional 32-byte scan |
| L29b | src/fe25519.s:~118   | branch      | med      | fixed  | `fe25519_add` carry-out short-circuit — Phase 7, captures carry to `fe_add_carry_mask` via `lda#0/sbc#0/eor#$FF`; masked sub-p driven by mask AND p_byte |
| L29c | src/fe25519.s:~209   | branch      | med      | fixed  | `fe25519_sub` borrow-handling branch — Phase 7, mirror of L29b idiom (sub-p → add-p via masked p_byte path) |
| L29d | src/fe25519.s:~346   | branch      | **HIGH** | fixed  | `fe25519_reduce_final` conditional sub-p — Phase 7, two-iteration unconditional masked-subp (works because `fe_reduce_wide` output bound ≤ 2p). Sufficiency regression: `tools/test_fe_reduce_wide_bound.py` |
| L29e | src/fe25519.s:~370   | branch      | med      | fixed  | `fe25519_reduce_final` byte-level cascade in mask propagation — Phase 7, unconditional via `fe_subp_rhs` per-iter scratch (= p_byte AND mask) |

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
  `@diag_prop` remained unchanged in Phase 6 — it was not in the
  original L19–L22 scope — and was closed later in the @diag_prop
  audit (see below).

- **@diag_prop audit (2026-04-19) — fix L23a/b/c in the diagonal
  term carry path**. The squaring diagonal (`a[i]^2` into
  `fe_wide[2*i..2*i+1]` + forward ripple) had three latent leaks
  not flagged in the original L1–L22 inventory:

  - **L23a**: `beq @diag_skip` short-circuited the entire diagonal
    body when `a[i] == 0`. Branch direction leaked a secret byte's
    zero-ness.
  - **L23b**: `bcc @diag_skip` skipped the carry-propagation phase
    when the 16-bit diag add did not overflow. Branch direction
    leaked whether `fe_wide[2*i..2*i+1] + a[i]^2` overflowed (a
    secret-derived condition).
  - **L23c**: `bcs @diag_prop` controlled a variable-length ripple
    whose iteration count depended on how many consecutive
    `fe_wide[k]` bytes were `$FF` — a secret-derived ripple length.

  **Fix:** the diagonal body now runs unconditionally per outer-i ∈
  [0, 31]; the `a[i]==0` case is handled by the zero-product
  invariant of `sqr_lo`/`sqr_hi` (both tables have value 0 at index
  0 by construction, so `a[i]=0` yields a functional no-op add).
  The 16-bit diag add captures its carry-out into the accumulator
  via `lda #0 / adc #0` (no branch). The forward ripple is an
  unconditional `dey / bne` loop whose count is `64 - (2*i + 2) =
  62 - 2*i`, derived entirely from the public counter `fe_mul_i`.
  A public `bcc` guards the `i = 31` edge where `2*i+2 = 64` lands
  exactly at fe_wide's end; in that case the ripple runs zero
  iterations, matching the old behavior of silently dropping any
  carry past `fe_wide[63]`.

  **Invariants (mirroring the Phase-6 style):**
  1. `@diag_outer` runs unconditionally per public `i ∈ [0, 31]`.
  2. The diag 16-bit add writes `fe_wide[2*i]` / `fe_wide[2*i+1]`
     unconditionally. Carry-out ∈ {0, 1} captured into A via
     `lda #0 / adc #0`.
  3. Ripple runs from `fe_wide[2*i+2]` through `fe_wide[63]` with a
     public iteration count `Y = 62 - 2*i`.
  4. Diagonal path does not interact with Phase-6 `sqr_pending`:
     the diagonal executes after `@sqr_cross_done`, i.e. after the
     cross-term end-of-inner ripple flushed any residual bit out
     to `fe_wide[63]`. Diagonal reuses `sqr_pending` and
     `sqr_ripple_start` only as scratch; writes are
     non-conflicting because cross-term is dead.
  5. The only `(zp),y` indirect load is `lda (fe25519_src1),y` with
     `Y = fe_mul_i` (public); base pointer is public.

  **Perf cost:** scalarmult bench moves from **10,740 → 12,070
  jiffies** (+1,330 jif, +12.4 %). The regression is dominated by
  the now-unconditional ripple (~31 iterations × 32 outer × 17 cy
  per iter × 1,529 squares). This exceeds the audit plan's
  projected +100–200 jif but lands well within the Phase-6-era
  budget pattern (+2,215 for L19–L22).

  **CT guard (new):** `tools/test_ct_square_cycles.py` gains a
  `diag_zeros` input (alternating 0x00 / 0x55 bytes) that
  specifically exercises the former `beq @diag_skip` zero-skip
  path. Post-audit it lands at the same per-call cycle count as
  `dense_55` (spread 0.04 jif), confirming the diagonal path no
  longer leaks on `a[i]`'s zero-ness.

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

- **Phase 7 — Field-op surface CT closure (LANDED)** — fix
  **L25 / L26a-d / L27a-f / L28a-k / L29a-e** in `src/fe25519.s`:
  the unaudited part of the field-op surface beyond `fe25519_sqr`
  and `mul_8x8`. Closes the v0.4.0 disclosure. With Phase 7 landed,
  `fe25519_mul`, `fe_reduce_wide`, `fe25519_mul_a24`, `fe25519_add`,
  `fe25519_sub`, `fe_cmp_p`, and `fe25519_reduce_final` are all CT
  clean — every branch in the field-op layer now depends only on
  public loop counters, link-time constants, or public derived
  state.

  **Mechanism — four templates, one per leak family:**

  1. **L29 (HIGH-severity outer surface).** New `fe_cmp_p_ct` proc
     scans all 32 limbs unconditionally and emits a $00/$FF mask via
     the `lda #0 / sbc #0 / eor #$FF` bit-to-mask idiom (same shape
     as the L24 ladder rewrite). `fe25519_add` and `fe25519_sub`
     capture carry-out into `fe_add_carry_mask` via the same idiom
     and drive an unconditional masked sub-p / masked add-p tail
     using `fe_subp_rhs` as per-iter scratch (= `p_byte AND mask`).
     `fe25519_reduce_final` runs **two iterations** of the
     unconditional masked sub-p — sufficient because
     `fe_reduce_wide` output is bounded by 2p (regression guard:
     `tools/test_fe_reduce_wide_bound.py`).

  2. **L25 + L26 (`fe25519_mul`).** Outer zero-skip dropped.
     Accumulate cascades replaced by the **Phase-6 Option F** chain:
     per-body 1-bit `mul_pending` carry threaded between adjacent
     bodies, single end-of-inner ripple per outer-i with iteration
     count `mul_bound = 63 - fe_mul_i` (public). Phantom-slot guard
     `cmp mul_bound / bcs` is on public `(i,j)` state only.

  3. **L27 (`fe_reduce_wide`).** All cascade short-circuits replaced
     by unconditional `dey/bne` cascades whose iteration count is
     derived from the public reduction-stage counter. Safety relies
     on the `mul38_lo_tab[0] = 0` lemma (no carry can propagate past
     the zero limb in any reduction step). Output bound <= 2p, the
     load-bearing precondition for L29d's two-iteration sufficiency,
     is the regression invariant guarded by
     `tools/test_fe_reduce_wide_bound.py`.

  4. **L28 (`fe25519_mul_a24`).** Outer body unconditional; the
     four reduction stages are threaded through `fe_carry` so each
     stage's carry-out is captured into the next stage's input
     without a branch. Cascades within each stage replaced by
     `dey/bne` public-count ripples.

  **New ZP slots (v0.4.0 + Phase 7).** Six bytes added to the
  library's claimed ZP surface, all `.ifndef`-wrapped per the host
  override protocol:

  - `$14` — `fe_cmp_mask` (`fe_cmp_p_ct` $00/$FF mask)
  - `$15` — `fe_subp_rhs` (per-iter (p_byte AND mask) scratch)
  - `$16` — `fe_add_carry_mask` (`fe25519_add` carry-out mask)
  - `$24` — `mul_pending` (Option F 1-bit carry chain in
    `fe25519_mul`)
  - `$25` — `mul_bound` (public phantom guard, = 63 - `fe_mul_i`)
  - `$2F` — `mul_ripple_start` (public end-of-inner ripple start)

  Live ZP grows from 81 to 87 bytes. `$14` / `$15` / `$16` are
  reused locally inside the new CT idioms (no cross-call
  semantics); `$24` / `$25` / `$2F` mirror the Phase-6
  `sqr_pending` / `sqr_ripple_start` shape but live in dedicated
  slots so the multiply and squaring chains don't alias.

  **H2 defensive REU init.** Phase 7 also (re-)installs the v0.4.0
  H2 fix: `fe25519_mul`, `fe25519_sqr`, and `fe25519_mul_a24` now
  zero `reu_reu_lo` ($DF04) and `reu_addr_ctrl` ($DF0A) at proc
  entry, mirroring the v0.3.0 PR #36 / issue #33 fix that
  `x25519_scalarmult` already received. Direct callers of these
  three procs no longer need to pre-zero those two registers
  themselves.

  **CT cycle-count guards (new).** Four regression tests added in
  `tools/`:

  - `tools/test_ct_mul_cycles.py` — `fe25519_mul` per-call spread
    across `dense_55 / sparse_09 / mixed_mid / mixed_hi /
    mul_zeros / mul_ff` inputs. **Measured: 0.000 jif spread**
    (5.98 jif/call across all 6 inputs).
  - `tools/test_ct_mul_a24_cycles.py` — `fe25519_mul_a24` per-call
    spread across 12 inputs (zero / one / two / a24_const / p-1 /
    ff_all / alt_AA / alt_55 / 4x rand). **Measured: 0.005 jif
    spread** (0.475-0.480 jif/call).
  - `tools/test_ct_reduce_wide_cycles.py` — `fe_reduce_wide`
    per-call spread. **Measured: ~0.01 jif spread**.
  - `tools/test_fe_reduce_wide_bound.py` — output-bound regression:
    asserts `fe_reduce_wide(x) <= 2p` for adversarially-shaped
    inputs (raw 64-byte products near 2^512 - 1). Required for
    L29d two-iteration sufficiency.

  Plus the existing `tools/test_ct_square_cycles.py`, which now
  also exercises the L23-related `diag_zeros` profile and lands at
  **0.005 jif spread**. All four CT guards are well under the
  1.0 jif threshold.

  **Perf (Phase 7 landing).** Pre-Phase-7 baseline: **12,070 jif**
  (v0.4.0 sweep state, pre-Phase-7-implementation). Phase 7
  design-time estimate (sum of family closures): **+2,326 jif**
  (~50 for L25, ~1,600 for L26, ~250-500 for L27, ~150-300
  for L28, ~1,500-2,200 for L29 — see v0.4.0 release notes
  Disclosure table). **Measured post-Phase-7 scalarmult cost:
  see "Bench instrumentation note" below**. The per-proc CT cycle
  spreads measured (0.005 / 0.005 / 0.005 / 0.01 jif) are
  consistent with each closure being constant-time on the
  per-call timing distribution.

  **Bench instrumentation note (post-PR-#35).** PR #35 wraps
  `x25519_scalarmult` in `php / sei … plp`, which masks the
  kernal jiffy clock IRQ for the duration of the call.
  `tools/bench_x25519.py` reads the kernal jiffy clock
  (`$A0-$A2`), so post-PR-#35 it reports `1 jif` regardless of
  the actual cycle count — the IRQ-masking that PR #35 installed
  prevents the IRQ ISR from advancing the jiffy clock during the
  call. The v0.4.0 finalization re-instrumented the bench on a
  CIA1 timer A→B chained 32-bit cycle counter (`bench_cycles_*`
  in `src/util.s`), which is unaffected by the I-flag and yields
  cycle-precise measurements regardless of the internal `sei`
  wrap. Phase 7's per-proc CT cycle spreads (measured via
  `bench_start / bench_stop` on individual `fe25519_*` procs that
  do **not** themselves mask IRQs) remain the authoritative CT
  regression guards. Measured end-to-end scalarmult on the
  RFC 7748 basepoint-9 vector at v0.4.0 tip: **261,640,265
  cycles ≈ 15,350 jif** with VIC blanked — +3,280 jif (+27.2 %)
  over the v0.3.0 12,070-jif baseline and ~+950 jif (+6.6 %)
  over the +2,326-jif Phase 7 design estimate. The overshoot
  is attributable to the combined cost of the L25-L29 closures
  plus the PR #36 defensive REU register init at scalarmult
  entry, neither of which was separately scoped in the original
  Phase 7 budget. RFC 7748 vector 1 PASS.

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
- ~~**Audit `x25519_scalarmult` itself** for scalar-bit-dependent
  branches in the Montgomery ladder / cswap.~~ — **closed
  2026-04-19** (PR #30). See L24a/b and the Ladder/cswap audit
  landing notes above.
- ~~**Audit `fe25519_sqr`'s `@diag_prop` path**~~ — **closed
  2026-04-19**. See L23a/b/c and the @diag_prop audit landing
  notes above. Fix applied in the same Phase-6-style unconditional
  ripple pattern.
- ~~**Audit the field-op surface beyond `fe25519_sqr`**~~ —
  **closed in Phase 7** (`fe25519_mul`, `fe_reduce_wide`,
  `fe25519_mul_a24`, `fe25519_add`, `fe25519_sub`, `fe_cmp_p`,
  `fe25519_reduce_final`). See L25-L29 entries and the Phase 7
  landing notes above. CT cycle-count guards landed alongside in
  `tools/test_ct_mul_cycles.py`, `tools/test_ct_mul_a24_cycles.py`,
  `tools/test_ct_reduce_wide_cycles.py`, and the
  output-bound regression `tools/test_fe_reduce_wide_bound.py`.
- **Re-instrument the end-to-end scalarmult bench under PR #35's
  `php / sei … plp` contract.** `tools/bench_x25519.py` reads the
  kernal jiffy clock, which is masked from advancing during the
  call after PR #35. The CT guard suite covers per-proc spreads,
  but a real end-to-end jiffy figure requires a non-IRQ-driven
  timer (e.g. CIA timer-A polled directly, or VICE binary-monitor
  cycle stamps). Open follow-up — does not block CT certification.

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
- **@diag_prop audit (2026-04-19)** — fix **L23a/b/c**
  (`fe25519_sqr` diagonal carry path). Three leaks closed in
  one pass via a Phase-6-style unconditional structure: the
  `beq @diag_skip` zero-skip on secret `a[i]`, the `bcc @diag_skip`
  skip on diag-add carry, and the `bcs @diag_prop` variable-length
  cascade. The rewrite runs `@diag_outer` unconditionally per
  public `i`, captures carry-out via `lda #0 / adc #0` (no branch),
  and replaces the cascade with an unconditional ripple whose
  count (`62 - 2*i`) is public. See "@diag_prop audit" landing
  notes above. `tools/test_ct_square_cycles.py` gains a
  `diag_zeros` input as CT regression guard for this path.
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
  Scalarmult bench **flat (median of 3; branchless sequence
  cycle-equivalent to old best-case branch path)**. Gating item
  for side-channel deployment certification — the library's
  outermost primitive no longer leaks scalar-bit information
  through branch timing. See "Ladder/cswap audit" landing notes
  above.
- **Phase 7 (post-v0.4.0)** — fix **L25 / L26a-d / L27a-f /
  L28a-k / L29a-e** in `src/fe25519.s`. Closes the v0.4.0
  KNOWN-OPEN disclosure of 27 secret-data-dependent branches
  across the unaudited part of the field-op surface
  (`fe25519_mul`, `fe_reduce_wide`, `fe25519_mul_a24`,
  `fe25519_add`, `fe25519_sub`, `fe_cmp_p`,
  `fe25519_reduce_final`). Four closure templates:
  (1) `lda#0/sbc#0/eor#$FF` bit-to-mask idiom + new
  `fe_cmp_p_ct` proc + masked sub-p tail (L29);
  (2) Phase-6 Option F per-body 1-bit pending chain + public
  end-of-inner ripple (L25 + L26 in `fe25519_mul`);
  (3) unconditional `dey/bne` cascades gated by the
  `mul38_lo_tab[0] = 0` lemma (L27 in `fe_reduce_wide`);
  (4) `fe_carry`-threaded reduction stages with public-count
  ripples (L28 in `fe25519_mul_a24`).
  Six new ZP slots claimed (`$14`/`$15`/`$16`/`$24`/`$25`/`$2F`),
  growing live ZP from 81 to 87 bytes. H2 defensive REU init
  (zero `$DF04` + `$DF0A` at proc entry) re-installed at
  `fe25519_mul`/`fe25519_sqr`/`fe25519_mul_a24` entry points.
  Four new CT cycle-count guards (`test_ct_mul_cycles`,
  `test_ct_mul_a24_cycles`, `test_ct_reduce_wide_cycles`,
  `test_fe_reduce_wide_bound`); per-proc spreads 0.000-0.01 jif,
  all <1.0 jif threshold. End-to-end scalarmult bench
  re-instrumented on a CIA1-timer 32-bit cycle counter
  (`bench_cycles_*`) to survive the PR-#35 `php/sei...plp`
  IRQ mask; measured **261,640,265 cycles ≈ 15,350 jif** on the
  RFC 7748 basepoint-9 vector with VIC blanked (+3,280 jif vs
  v0.3.0 12,070 jif baseline, ~+950 jif over the Phase 7 design
  budget — attributable to L25-L29 closures plus the PR #36
  defensive REU init).

Issue [#20](https://github.com/JC-000/c64-x25519/issues/20) was the
origin report for L1-L15. L16-L22 were discovered during the Phase 3
audit. L25-L29 were catalogued in the v0.4.0 sweep and closed in
Phase 7. Every landing was gated on `tools/ct_mul_brute_check.py`
(mul_8x8 exhaustive) plus the full `make test-slow` matrix
(`tools/test_fe_mul_stress.py` / `tools/test_fe_sqr_stress.py` /
`tools/test_x25519.py --slow` / `tools/test_ladder_checkpoint.py
--start 0 --count 255`) plus the per-proc CT cycle-count guards in
`make test-vice`.

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
| Post-@diag_prop (L23)     | 12,070  | +2,550 (+26.8 %)  | diagonal unconditional ripple; L1–L23 fixed (measured on diag branch alone) |
| Post-ladder/cswap audit (L24) | 10,739 | +1,219 (+12.8 %) | flat; branchless bit-extract, 3-run median (measured on ladder branch alone) |
| **Post-both audits (L23+L24)** | **~12,070** | **~+2,550 (~+26.8 %)** | **L1–L24 fixed; combined bench pending post-merge remeasurement** |
| Post-Phase 7 (L25-L29)         | **see note** | **see note**            | **L1-L29 fixed; bench instrumentation broken post-PR-#35 (jiffy clock masked); per-proc CT spreads 0.005-0.01 jif** |

### Regression budget (original plan) vs. actual (through L29)

| Bound                | Jiffies | Actual (since pristine) | Status                  |
|----------------------|---------|-------------------------|-------------------------|
| Soft (target)        | ≤ +200  | exceeded                | breach                  |
| Hard (ceiling)       | ≤ +400  | exceeded                | breach                  |
| Phase 6 brief's cap  | ≤ 13,000 | ~12,070 (pre-Phase-7)  | within cap              |
| Ladder/cswap budget  | ≤ +50   | +0 (flat)               | within budget           |
| Phase 7 design est.  | +2,326  | end-to-end bench broken; per-proc CT all CT-clean (≤ 0.01 jif spread) | bench remeasure deferred; CT regression guards green |

The v0.3.0 perf-recovery work (Phases 1–3 in the perf track, not the CT
track) closed ~1,746 jif of the Phase-6 regression against the
pristine baseline before the two audits landed. The @diag_prop audit
re-added +1,330 jif for the unconditional diagonal ripple — roughly
the cost of making ~49k diagonal passes (32 outer × 1,529 squares)
ripple unconditionally rather than short-circuiting on secret data.
The ladder/cswap audit was cycle-neutral (branchless bit-extract was
cycle-equivalent to the old best-case branch path). Net v0.3.0
state relative to v0.2.0 shipped (12,485 jif): slight improvement,
with 5 additional leaks closed (L23a/b/c, L24a/b) and field-op
surface + outer ladder now both fully CT-clean.

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

## State-contract defences (correctness, not CT)

These are **not** CT leak fixes — they are correctness defences against
caller state pollution that surface when the library is composed with
other REU consumers (e.g. sibling crypto libraries, NIC drivers). They
are documented here because the investigation that found them ran
alongside the CT audit work and used the same `tools/test_*` harness
discipline. They do **not** affect the L1–L24 timing-leak posture.

### S1 — IRQ-during-call defence (PR #35, landed 2026-05-06)

`x25519_scalarmult` runs ~12,000 jiffies. Without IRQ masking, a
mid-DMA IRQ could (a) interleave a partial REU multi-store register
write, corrupting an in-flight DMA, or (b) clobber a ZP byte the
library owns (`$1A-$2E`, `$40-$7F`) via a consumer ISR (UCI / RS-232 /
CIA timer). PR #35 wraps the proc in `php / sei … plp`, converting the
"caller must mask IRQs" contract into a library-enforced invariant.

**File:line.** `src/x25519.s:84-85` (entry), `src/x25519.s:272` (exit).

**Caveat.** `sei` only masks the I-flag — it does **not** mask NMI.
A consumer-installed NMI handler (RESTORE key, CIA2 RS-232, U64E
firmware hook) that touches `$1A-$2E` / `$40-$7F` would still corrupt
ladder state. Vanilla Kernal NMI is benign on this ZP range; custom
NMI handlers are caller responsibility (documented in `LIBRARY.md`).

### S2 — Caller REU register residue defence (issue #33, landed 2026-05-08)

`reu_clear_wide` (`src/x25519_init.s:316-336`) re-writes 6 of 8 REU
registers but skips `reu_reu_lo` (`$DF04`) and `reu_addr_ctrl`
(`$DF0A`), trusting they are still `$00` from `reu_mul_init`'s tail.
A caller writing those registers after init (e.g. a sibling library
DMAing into REU between a `reu_mul_init` and a later
`x25519_scalarmult`) leaves them non-zero. The first `reu_clear_wide`
inside `fe25519_mul` then DMAs from the wrong REU offset (or, with
`reu_addr_ctrl=$80` "hold C64 address", into a single byte), filling
the 64-byte `fe_wide` accumulator with garbage instead of zeros.

The schoolbook multiply silently accumulates `garbage + a*b`. The
ladder runs to completion in normal time and returns a
**deterministic but wrong** field element. Downstream symptoms in
network composition (e.g. c64-https TLS handshake, issue #33):
wrong shared secret → wrong key schedule → AEAD decrypt failure →
handshake stalls. **Not a hang in the ladder.** The earlier
issue-#33 digest of "stuck inside `x25519_scalarmult`" was already
disputed in the maintainer's 2026-04-22 retrace and was never
reproduced; the actual symptom is wrong-result, not hang.

**Repro (VICE, deterministic, ~15 s warp).** Set `reu_reu_lo=$5A`
before `jsr x25519_scalarmult`; result hash diverges from RFC 7748
§6.1 vec-1. Likewise `reu_addr_ctrl=$80`. See
`tools/test_issue33_adversarial.py` for the full 8-case suite
(clean, h1_audit, reu_low_dirty, reu_addr_ctrl_dirty, reu_full_dirty,
nmi_corrupts_zp40, irq_during_call, plus baseline). The
`irq_during_call` case is OK on master — confirms PR #35's `sei`
defence works.

**Fix.** Defensive register init at `x25519_scalarmult` entry
(immediately after the existing `php / sei` from PR #35):

```asm
lda #0
sta reu_reu_lo            ; $df04
sta reu_addr_ctrl         ; $df0a
```

**File:line.** `src/x25519.s:90-103` (the new block, after PR #35's
`sei` and before the ladder-state init).

**Cost.** 6 cycles + 5 bytes per scalarmult call. Impact on the
12,070-jiffy budget: < 0.001%, below measurement noise.

**CT impact.** None. The two stores are unconditional and run
before any secret-dependent code.

**Caveat.** This closes the `reu_reu_lo` / `reu_addr_ctrl` vector
specifically. Other `$DFxx` registers (`reu_c64_lo/hi`, `reu_len_lo/hi`,
`reu_reu_hi`, `reu_reu_bank`) are re-written by `reu_clear_wide` and
the inlined per-row DMA in `fe25519_mul`, so caller residue on those
registers is already harmless. The minimal repro for the bug used
`reu_reu_lo=$5A` alone (5 bytes of injected pre-state); see issue
investigation report.

### S3 — Autoload-latch invariant in `reu_fetch_doubled_row` (c64-lib-contract issue #15, landed PR #61)

PR #61 SMC-patches `reu_fetch_doubled_row`'s first 512-byte DMA to
delegate to the canonical §8.2 `reu_fetch_mul_row` primitive. The
canonical primitive is **3-register-touch** (writes only `reu_reu_hi`,
`reu_reu_bank`, `reu_command`) and **trusts the REU autoload latch**
to keep the other five registers canonical (`reu_c64_lo/hi`,
`reu_len_lo/hi`, `reu_reu_lo`, `reu_addr_ctrl`).

`fe25519_sqr` runs the doubled-fetch dispatch across 22 iterations
(`SQR_DMA_K = 22` default). The state machine across iterations is
non-trivial:

```
jsr reu_clear_wide          ; establishes canonical autoload latch
loop iter i = 1..K:
  jsr reu_fetch_doubled_row
    ; DMA #1: 512 B from banks +4/+5 → mul_dma_lo (SMC-patched
    ;         delegation to canonical reu_fetch_mul_row)
    ; DMA #2: 256 B from bank +3 → mul_dma_carry (inline; STOMPS
    ;         the autoload latch — writes c64_lo/hi=mul_dma_carry,
    ;         len_hi=1, etc.)
  ... use the fetched data ...
```

On iteration 1 the latch is canonical because `reu_clear_wide`
established it. **On iterations 2..K the latch is dirty** — DMA #2 of
iteration N stomped it before iteration N+1 runs. So DMA #1 of
iter N+1 explicitly re-writes the five dirty registers BEFORE the
SMC-patched JSR. **Those writes are load-bearing — not redundant with
`reu_clear_wide`'s restore tail**, because `reu_clear_wide` only runs
once per `fe25519_sqr` call, not once per inner iteration.

**Failure mode if the re-establish is elided.** Iter N+1 silently DMAs
256 bytes into `mul_dma_carry` instead of 512 bytes into `mul_dma_lo`.
Result: corrupted doubled-table data → wrong squaring outputs → same
root-cause class as the v0.4.0 W2 incident (`mul(1,1)-after-sqr(1) → 0`).

**Regression coverage.** `tools/test_fe_sqr_then_mul.py` drives
`fe25519_sqr(x); fe25519_mul(y, z)` sequences and asserts the mul
output matches `(y * z) mod (2^255 − 19)` per pyca. 60/60 cases pass
on master post-merge; bug class is permanently guarded.

**File:line.** `src/x25519_init.s` — banner blocks on:
`reu_fetch_doubled_row` ("Autoload-latch invariant (LOAD-BEARING — do
not break)"), `reu_fetch_mul_row` ("Caller contract" paragraph naming
the two valid callers), and `reu_clear_wide` ("restore-hazard story"
updated to point at DMA #2 specifically). The 5-register re-establish
itself is at the top of `reu_fetch_doubled_row`'s body.

**Cost.** +568.8 cy / +0.523 % on `fe25519_sqr` at `SQR_DMA_K = 22`
(within the ≤ 2 % gate). Zero-delta on `make lib-x25519-1764`
(SQR_DMA_K=0) — the entire doubled-fetch dispatch is gated out under
`.if ::SQR_DMA_K`. Library archive shrinks 1194 B at K=0 from
aggressive dead-code elimination of the now-unused `.proc`,
`.export`, `.import`, and call-site code.

**CT impact.** None. The 5-register re-establish writes are
unconditional and run before any secret-data-dependent code. The SMC
patch+restore window is also unconditional and bounded.

**Why this is in the state-contract section (not the CT section).**
The failure mode is silent doubled-table corruption mid-loop, not a
timing leak. But the surface symptom (wrong squaring output that
depends on which inner iteration corrupted the fetch) is
indistinguishable from a CT bias if a future regression bypassed
both the S3 invariant and the test_fe_sqr_then_mul.py guard — hence
co-located with S1/S2 here.

**Design doc:** [`docs/design/issue_15_smc_patch_doubled_fetch.md`](design/issue_15_smc_patch_doubled_fetch.md).

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
