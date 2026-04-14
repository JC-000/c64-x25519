# CT_ANALYSIS — Constant-Time Audit for c64-x25519

Status: **Phases 0–5b landed (uncommitted)** — tracking issue
[#20](https://github.com/JC-000/c64-x25519/issues/20).

This document catalogues every currently-known secret-dependent branch and
every `(zp),y` indirect-indexed load in the X25519 library, records the
baseline and post-fix performance, and tracks follow-up work.

**Current state:** L1–L18 are fixed in the working tree (branchless
quarter-square in `mul_8x8`, branchless CT mult66 rewrite of
`fe25519_sqr`'s inner bodies, and zero-skip removal across `fe25519_mul`
and `fe25519_sqr`). L19–L22 (carry-cascade short-circuits) remain `leak`
and are tracked below as **must-fix** follow-ups before the library can
be certified CT-clean for network-facing deployment.

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
| L19 | src/fe25519.s:1111    | branch      | **med**  | **leak (must-fix)** | `bne @sqr_dma_prop_a` — DMA carry-prop short-circuit  |
| L20 | src/fe25519.s:1133    | branch      | **med**  | **leak (must-fix)** | `bne @sqr_dma_prop_b` — DMA carry-prop short-circuit  |
| L21 | src/fe25519.s:964     | branch      | **med**  | **leak (must-fix)** | `beq @sqr_next_j` — mult66 accum carry short-circuit A|
| L22 | src/fe25519.s:1054    | branch      | **med**  | **leak (must-fix)** | `beq @sqr_next_j_b` — mult66 accum carry short-circuit B |

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

- **L19-L22 — deferred carry-cascade leaks, must-fix follow-ups**. See
  the "Follow-ups" section below. These are not local fixes — both
  require whole-procedure restructuring of the carry-propagate path.

### Follow-ups

**Must-fix (blocks CT-clean certification for network-facing use):**

1. **L19/L20** — `fe25519_sqr` DMA carry-cascade short-circuit. The
   `bne @sqr_dma_prop_a/b` path only fires when the accumulate
   generates a carry out of `fe_wide[i+j+1]`. It leaks whether a
   secret-derived product rolled the 16-bit accumulator into the
   next limb. Fix: replace the opportunistic `sec/lda/adc #0/bcs`
   cascade with an unconditional full-width ripple up to the end of
   `fe_wide` (at most 64 bytes). Estimated cost: +300-500 jiffies per
   scalarmult depending on how tightly the ripple unrolls.

2. **L21/L22** — `fe25519_sqr` mult66 accum combined-carry
   short-circuit. `beq @sqr_next_j/_b` fires when the doubled product
   plus the accumulate produced zero combined carry. Same fix shape
   as L19/L20 (unconditional ripple); may share the same helper
   subroutine. Estimated cost: +150-300 jiffies.

   **Combined L19-L22 estimated cost: +400-800 jiffies** depending on
   how much ripple sharing is possible between the mult66 and DMA
   paths. Target for a Phase 6 pass.

**Queued performance-recovery options** (user accepted the current
+7.9% regression for v0.2.0; recover in a later perf-recovery pass):

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
  Gates future edits against CT regression.
- **Audit `x25519_scalarmult` itself** for scalar-bit-dependent
  branches in the Montgomery ladder / cswap. The ladder is the next
  layer up from `fe25519_*`; any bit-conditional branching there
  would defeat the field-op CT fixes.

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
- **Phase 6 (pending)** — fix **L19-L22** carry-cascade short-
  circuits. Whole-procedure ripple restructuring required. See
  Follow-ups above.

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
| Post-Phase 5b (L16–L18)   | **10,270** | **+750 (+7.9 %)** | **accepted for v0.2.0**         |

### Regression budget (original plan) vs. actual

| Bound                | Jiffies | Actual (+750) | Status                  |
|----------------------|---------|---------------|-------------------------|
| Soft (target)        | ≤ +200  | exceeded      | breach                  |
| Hard (ceiling)       | ≤ +400  | exceeded      | breach                  |
| Over hard ceiling    | > +400  | **yes**       | design review triggered |

**Design-review decision (recorded here):** the +7.9 % regression was
**accepted** for v0.2.0 to ship a working end-to-end CT remediation of
L1–L18 with minimal delay. Options 2/3/4 in the Follow-ups section are
queued for a later perf-recovery pass; the target is to land v0.3.0
under +4 % relative to the pristine 9,520 baseline after applying
patch-hoisting and register-state tightening. The library remains ~44 %
faster than the original pre-optimization baseline (~18,000 jiffies).

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
