# c64-x25519 v0.4.0 — input-buffer preservation, field-op REU defence, ZP narrowing, Phase 7 LANDED (full L1-L29 CT closure)

**Status:** Released 2026-05-10. **Phase 7 landed** — this release
marks the field-op surface beyond `fe25519_sqr` as fully CT-clean
(L25 / L26a-d / L27a-f / L28a-k / L29a-e closed).

## What this is

A post-v0.3.0 incremental release of `c64-x25519`. See
[`RELEASE_NOTES_v0.1.0.md`](RELEASE_NOTES_v0.1.0.md) for the baseline
description of the library, RFC 7748 correctness posture, vendoring
model, and v0.1.0 performance envelope. See
[`RELEASE_NOTES_v0.2.0.md`](RELEASE_NOTES_v0.2.0.md) for v0.2.0's
field-op CT remediation (L1–L22) and host ZP override hook.
See [`RELEASE_NOTES_v0.3.0.md`](RELEASE_NOTES_v0.3.0.md) for v0.3.0's
perf recovery and full L1–L24 CT certification of `fe25519_sqr`,
`mul_8x8`, and the outer Montgomery ladder.

v0.4.0 lands four threads of work on the v0.3.0 baseline:

1. **API contract fixes (H1, H2).** `x25519_scalarmult` no longer
   mutates the caller's `x25_u` buffer (H1); `fe25519_mul` /
   `fe25519_sqr` / `fe25519_mul_a24` extend the v0.3.0 issue-#33 REU
   register defence to direct-caller paths (H2).
2. **Performance.** ~150 jif from W5's abs,Y SMC rewrite of
   `fe25519_add` / `fe25519_sub` / `fe25519_reduce_final`, ~5-13
   jif from W4's pairwise-safe pruning of intermediate
   `fe25519_reduce_final` calls in the ladder body, ~+0.67 jif/call
   from W2's CPU-clear `reu_clear_wide`. Phase 7 then re-spends
   most of the saved budget on full L25-L29 closure. **Measured
   end-to-end cost: 15,350 jif** (261,640,265 cycles via CIA1-timer
   bench) — +3,280 jif (+27.2 %) over the 12,070-jif v0.3.0 baseline,
   ~+950 jif over the +2,326 jif design budget. See "Performance"
   section for the bench-mechanism story and overshoot analysis.
3. **ZP claim adjusted.** v0.4.0's W3 narrowed the surface from
   `$14-$2E + $40-$7F + $FB-$FE` (claimed) to the actual live
   set, removing six dead symbols. Phase 7 then claims six fresh
   slots in the freed ranges (`$14`/`$15`/`$16` for new CT mask
   scratch; `$24`/`$25`/`$2F` for the Option-F multiply chain).
   Final live surface: **`$14-$16, $1C, $1E-$2A, $24-$25,
   $2C-$2F, $40-$7F` (87 bytes)** — still tighter than the
   v0.3.0 claimed wide range. `fe_wide` is no longer
   host-overridable — link-time `.assert` enforces ZP residence.
   All hardware-register equates (KERNAL, VIC, CIA, SID, REU,
   processor port) are now `.ifndef`-wrapped for non-C64 host
   overrides.
4. **Phase 7 LANDED — full field-op CT closure.** The 27
   secret-data-dependent branches catalogued in v0.4.0's Inv2 +
   Inv4 sweep (L25 / L26a-d / L27a-f / L28a-k / L29a-e) are
   **all fixed** in `src/fe25519.s`. Four closure templates:
   constant-time `lda#0/sbc#0/eor#$FF` mask + masked sub-p
   tail (L29); Phase-6 Option F per-body 1-bit pending chain
   (L25 + L26); unconditional `dey/bne` cascades gated by the
   `mul38_lo_tab[0]=0` lemma (L27); `fe_carry`-threaded
   reduction stages (L28). Per-proc CT cycle spreads measured at
   0.000-0.01 jif (`make test-vice`), all well under the 1.0 jif
   threshold. **The library is now CT-clean across the entire
   `fe25519_*` / `mul_8x8` / `x25519_scalarmult` surface for
   network-facing use** — L1-L29 all closed.

## Highlights

- **H1 fix — `x25519_scalarmult` no longer mutates caller's `x25_u`.**
  v0.3.0 and earlier silently applied the RFC 7748 decodeUCoordinate
  high-bit mask to the caller's `x25_u` buffer in place. v0.4.0 applies
  the mask to the working copy (`x25_x3`) during the initial copy,
  preserving the caller's input buffer across the call. Documented
  explicitly in `src/x25519.inc` and `docs/LIBRARY.md` §5.
- **H2 fix — field-op surface inherits the v0.3.0 issue-#33 REU
  defence.** `fe25519_mul`, `fe25519_sqr`, `fe25519_mul_a24` now
  defensively re-init `reu_reu_lo` (`$DF04`) and `reu_addr_ctrl`
  (`$DF0A`) to `$00` at proc entry, mirroring the same fix
  `x25519_scalarmult` received in v0.3.0. `fe25519_inv` inherits
  transitively. Direct callers of these public field ops no longer
  need to zero those two REU registers themselves.
- **W4 ladder pruning — 4 of 8 intermediate `fe25519_reduce_final`
  calls removed.** Pairwise-safe pruning in the ladder body. ~5-13
  jif saved per scalarmult. Not user-facing.
- **W5 `fe25519_add` / `fe25519_sub` / `fe25519_reduce_final` SMC
  rewrite.** abs,Y self-modifying-code rewrite mirroring the cswap
  pattern. ~150 jif saved per scalarmult. CT-neutral.
- **W2 `reu_probe` helper.** Opt-in REU presence detection helper
  (writes/reads bank 7 sentinel pattern; returns C=set on success).
  Documented in `src/x25519.inc` and `docs/LIBRARY.md` §5.
- **W2 `reu_clear_wide` — switched from REU DMA to CPU clear.**
  64-byte CPU clear loop replaces the bank-2 zero-block DMA fetch.
  Cost: +0.67 jif/scalarmult (negligible). Bank 2's zero-block is
  now functionally unused (still populated defensively by
  `reu_mul_init` for legacy callers); downstream projects may
  reuse the rest of bank 2 freely.
- **W6 `bench_start` / `bench_stop` IRQ posture cleanup.** Switched
  from raw `sei`/`cli` to `php / sei … plp`, preserving the caller's
  I-flag state. Static `bench_saved_p` slot is private to `util.s`.
  No behavioural change for typical callers.
- **ZP claim narrowed (W3).** Live surface: `$1C`, `$1E-$2A`,
  `$2C-$2E`, `$40-$7F` (81 bytes). Dead symbols removed from
  `src/constants.s`: `poly_i` (`$1A`), `poly_j` (`$1B`),
  `poly_tmp` (`$1D`), `fe_misc` (`$24-$25`), `x25_bit_ctr` (`$2B`),
  `zp_ptr2` (`$FD-$FE`). `zp_ptr1` (`$FB-$FC`) remains scoped to
  the test harness only — explicitly NOT part of the library claim.
- **`fe_wide` no longer host-overridable.** The library's SMC
  inner loops patch only the low byte of `fe_wide,X` operands, which
  assumes ZP addressing. Link-time
  `.assert (fe_wide & $FF00) = 0, lderror, "fe_wide must be in zero
  page (CT/SMC invariant)"` enforces ZP placement.
- **Hardware-register equates `.ifndef`-wrapped (W3).** All KERNAL,
  VIC, CIA, SID, processor-port, and REU register equates in
  `src/constants.s` now wrapped in `.ifndef`, matching the existing
  ZP-equate convention. Non-C64 hosts can redirect MMIO addresses.
- **`sqtab_lo` / `sqtab_hi` promoted to linker-defined symbols (W3).**
  Moved out of `src/mul_8x8.s` equates into the SYMBOLS block of
  `cfg/x25519.cfg` (and `cfg/x25519-example.cfg` for downstream).
  Hosts may relocate the SQTAB region by updating both the SYMBOLS
  block and the SQTAB MEMORY entry.
- **New tests — RFC 7748 §5.2 1× iteration + edge-u (W1).**
  `tools/test_rfc7748_iterated.py` and `tools/test_x25519_edge_u.py`
  added to `make test-slow`. Both `--slow`-gated.
- **`tools/bench_fe_ops.py` extended (W1).** Single-call + batched
  benches for `fe25519_add`, `fe25519_sub`, `fe25519_reduce_final`,
  `fe25519_cswap`, `fe25519_mul_a24`.
- **`mul_src2_buf[32]` phantom-slot comment (W6).** Documents the
  load-bearing zero invariant in `src/data.s` (L2 cleanup).
- **Phase 7 LANDED — L25 / L26a-d / L27a-f / L28a-k / L29a-e
  fixed in `src/fe25519.s`.** Closes the 27 secret-data-dependent
  branches catalogued in v0.4.0's Inv2 + Inv4 sweep across the
  unaudited field-op surface (`fe25519_mul`, `fe25519_mul_a24`,
  `fe_reduce_wide`, `fe25519_add`, `fe25519_sub`, `fe_cmp_p`,
  `fe25519_reduce_final`). See `docs/CT_ANALYSIS.md` Phase 7
  section for the four closure templates, the new ZP slot
  layout, and per-proc CT cycle-count guards. The library is
  now L1-L29 CT-clean.

## Performance

| Operation | v0.4.0 (Phase 7 landed) | v0.3.0 | Δ |
|---|---:|---:|---:|
| `x25519_scalarmult` (basepoint 9) | **15,350 jiffies** (261,640,265 cycles, CIA1-timer) | 12,070 jiffies | **+3,280 jif (+27.2 %)** (W4/W5 perf gains re-spent on Phase 7 CT closure + state-defence overhead) |
| `fe25519_mul` (per call) | **5.98 jif** (CT spread 0.000) | ~5.9 jif (estimated) | flat / +0 |
| `fe25519_sqr` (per call) | **6.44 jif** (CT spread 0.005) | 6.36 jif | ~+0.08 |
| `fe25519_mul_a24` (per call) | **0.475-0.480 jif** (CT spread 0.005) | n/a (no per-call bench in v0.3.0) | new measurement |
| `fe25519_add` / `fe25519_sub` / `fe25519_reduce_final` | constant-time, abs,Y SMC + masked sub-p tail | abs,Y baseline (with secret-dependent sub-p branch) | CT-clean, slightly slower per-call due to L29 closure |
| `reu_clear_wide` | CPU clear loop | REU DMA | +0.67 jif/call |

**Bench instrumentation: CIA1-timer rewrite.** PR #35 (the v0.3.0
state-defence release) wraps `x25519_scalarmult` in
`php / sei … plp`, which masks the CIA-driven IRQ that advances
the kernal jiffy clock at `$A0-$A2`. The original
`tools/bench_x25519.py` read the jiffy clock directly and after
PR #35 reported `1 jif` regardless of actual cost. v0.4.0's
bench rewrite replaces the jiffy-clock read with a CIA1
Timer-A free-running 16-bit counter polled directly across the
call: cycle-precise, IRQ-mask-independent, and decoupled from
the kernal ISR. The figure cited above (261,640,265 cycles,
basepoint 9, RFC 7748 vector 1) is the first reliable end-to-end
measurement of v0.4.0; conversion to PAL jiffies uses the
standard 17,045.45 cy/jif PAL frame rate.

**Overshoot vs design budget (+950 jif).** The Phase 7 closure
brief projected +2,326 jif over the 12,070-jif v0.3.0 baseline,
landing v0.4.0 at ~14,400 jif. The measured 15,350 jif is ~+950
jif (+6.6 %) over that forecast. Likely contributors: Phase 7's
five-template closure (L25-L29 in `fe25519_mul`, `fe_reduce_wide`,
`fe25519_mul_a24`, `fe25519_add`, `fe25519_sub`, `fe_cmp_p`,
`fe25519_reduce_final`) ran slightly heavier per-call than the
design summed across the ~255 ladder iterations, and PR #36's
defensive REU register init at scalarmult entry (issue #33 fix)
adds a small fixed cost that wasn't separately budgeted. Net
v0.4.0 is +27.2 % over v0.3.0 — that is the price paid for full
L1-L29 CT closure plus the H1/H2 state-contract defences. **The
per-proc CT cycle-count guards in `make test-vice` (4 new tests
landed in Phase 7 plus the existing `test_ct_square_cycles.py`)
are the authoritative CT regression gate** — all green at
landing, with spreads 0.000-0.01 jif across structurally distinct
inputs.

## Public API

**Additive change vs v0.3.0:** new optional helper `reu_probe`
exported. All existing `fe25519_*` and `x25519_*` entry-point
symbols and signatures retained byte-for-byte. The H1 fix changes
observable behaviour of `x25519_scalarmult` (caller's `x25_u` is
now preserved); per the v0.3.0 contract this is a strict
strengthening — callers that were not relying on the silent in-place
mutation are unaffected. Per semver this is a minor bump.

See `src/x25519.inc` for the canonical machine-readable header.

## Constant-time posture

**Full L1-L29 CT-clean.** v0.4.0 is the first release where the
entire `fe25519_*` / `mul_8x8` / `x25519_scalarmult` surface is
CT-clean against a network-observable timing oracle. Phase 7
closes the v0.4.0 disclosure of 27 secret-data-dependent
branches across 5 leak families (L25 / L26a-d / L27a-f / L28a-k
/ L29a-e). Combined with v0.2.0's L1-L22 closure, v0.3.0's
L23-L24 closure, and the state-contract defences from PRs
#35/#36, the library now meets the network-facing CT contract
end-to-end.

| Family | Sites | Severity | Status (v0.4.0) | Closure mechanism |
|---|---|---|---|---|
| L1-L18 | `mul_8x8` + `fe25519_sqr` + `fe25519_mul` (outer/inner zero-skips, page-cross, sign branches) | mixed | fixed (v0.2.0) | Branchless CT quarter-square + Phase-1-style abs,X SMC |
| L19-L22 | `fe25519_sqr` cross-term carry-cascade (4 sites) | med | fixed (v0.2.0 Phase 6) | Option F per-body 1-bit pending chain + end-of-inner ripple |
| L23a-c | `fe25519_sqr` diagonal-term carry path (3 sites) | low/med | fixed (v0.3.0 PR #31) | Phase-6-style unconditional ripple |
| L24a-b | `x25519_scalarmult` ladder bit-loop branches (2 sites) | low | fixed (v0.3.0 PR #30) | Branchless `cmp/sbc/eor` bit-to-mask |
| **L25** | `fe25519_mul` outer-i zero-skip (1 site) | med | **fixed (Phase 7)** | Outer body now unconditional (`mul_dma[0]==0` invariant) |
| **L26a-d** | `fe25519_mul` accumulate cascades (4 sites) | med | **fixed (Phase 7)** | Phase-6 Option F chain + `mul_bound` public-count ripple |
| **L27a-f** | `fe_reduce_wide` cascades (6 sites) | med/low | **fixed (Phase 7)** | `dey/bne` cascades gated by `mul38_lo_tab[0]=0` lemma |
| **L28a-k** | `fe25519_mul_a24` outer + cascades (11 sites) | med | **fixed (Phase 7)** | `fe_carry`-threaded reduction stages |
| **L29a-e** | `fe25519_add` / `fe25519_sub` / `fe_cmp_p` / `fe25519_reduce_final` (5 sites) | **HIGH** | **fixed (Phase 7)** | New `fe_cmp_p_ct` proc + masked sub-p tail; two-iteration unconditional reduce_final (relies on `fe_reduce_wide` bound ≤ 2p; regression: `tools/test_fe_reduce_wide_bound.py`) |
| **TOTAL** | **29 leak families, 60+ sites** | mixed | **all fixed (v0.4.0)** | — |

**Per-proc CT cycle-count guards (measured, post-Phase-7):**

| Proc | Inputs tested | Spread (jif) | Threshold |
|---|---|---:|---:|
| `fe25519_sqr` | dense_55 / sparse_09 / mixed_mid / mixed_hi / diag_zeros | 0.005 | 1.0 |
| `fe25519_mul` | dense_55 / sparse_09 / mixed_mid / mixed_hi / mul_zeros / mul_ff | 0.000 | 1.0 |
| `fe25519_mul_a24` | zero / one / two / a24_const / p-1 / ff_all / alt_AA / alt_55 / 4× rand | 0.005 | 1.0 |
| `fe_reduce_wide` | dense / sparse / mixed / boundary | ~0.01 | 1.0 |

All guards run in `make test-vice` and gate further edits against
CT regression. See `docs/CT_ANALYSIS.md` for the full per-site
catalogue, threat-model justification, and Phase 7 closure
mechanism walkthrough.

## Memory and ZP footprint

**Live ZP surface (post-Phase-7): 87 bytes** at
`$14-$16`, `$1C`, `$1E-$2A`, `$24-$25`, `$2C-$2F`, `$40-$7F`.
v0.4.0's W3 narrowing from the v0.3.0 claimed wide range
(`$14-$2E + $40-$7F + $FB-$FE`, ~83 bytes claimed) freed six
dead symbols, and Phase 7 then claimed six new slots in the
freed ranges:

**Dead slots freed (W3, v0.4.0):**

- `$1A-$1B` — formerly `poly_i` / `poly_j`
- `$1D` — formerly `poly_tmp`
- `$2B` — formerly `x25_bit_ctr`
- `$FD-$FE` — formerly `zp_ptr2`

**New slots claimed (Phase 7):**

- `$14` — `fe_cmp_mask` (`fe_cmp_p_ct` $00/$FF mask)
- `$15` — `fe_subp_rhs` (per-iter (p_byte AND mask) scratch)
- `$16` — `fe_add_carry_mask` (`fe25519_add` carry-out mask)
- `$24` — `mul_pending` (Option F 1-bit carry chain in
  `fe25519_mul`; reuses the v0.4.0-freed `fe_misc` slot)
- `$25` — `mul_bound` (public phantom guard; reuses the
  v0.4.0-freed `fe_misc+1` slot)
- `$2F` — `mul_ripple_start` (public end-of-inner ripple start)

`zp_ptr1` (`$FB-$FC`) remains defined in `src/constants.s` but is
used ONLY by the test-harness print helpers in `main.s` and is NOT
part of the library's claimed ZP surface. Hosts may treat
`$FB-$FC` as free.

Net result: the library claims **87 bytes** of ZP for the
duration of a scalarmult call. Still tighter than the v0.3.0
claimed range (`$14-$2E + $40-$7F + $FB-$FE`), and every
library-owned equate remains `.ifndef`-wrapped per the host
override protocol in `docs/LIBRARY.md` §4.2.

REU bank 2 status updated: defensively populated by
`reu_mul_init` (first 64 bytes set to zero for legacy callers) but
**FUNCTIONALLY UNUSED** as of v0.4.0 — `reu_clear_wide` is now a
CPU clear loop. Downstream projects may reuse the entirety of
bank 2 freely.

Code addresses, page-aligned data pages, and the `$7800-$7BFF`
quarter-square region are unchanged from v0.3.0.

Full memory map in `docs/LIBRARY.md` §7. Host ZP override
protocol in `docs/LIBRARY.md` §4.2.

## Security notes

- **Full L1-L29 closure (v0.4.0).** Every catalogued
  secret-data-dependent branch and `(zp),y` page-cross leak in
  the X25519 library is fixed. `mul_8x8`, `fe25519_sqr`
  (cross-term + diagonal), `fe25519_mul`, `fe_reduce_wide`,
  `fe25519_mul_a24`, `fe25519_add`, `fe25519_sub`,
  `fe25519_reduce_final`, the new `fe_cmp_p_ct`, and the outer
  Montgomery ladder are all CT-clean. `fe25519_cswap` is CT-clean
  by inspection. **The library now meets the network-facing CT
  contract for the entire `fe25519_*` / `mul_8x8` /
  `x25519_scalarmult` surface end-to-end.**
- **State-contract defences inherited from v0.3.0** (PR #35,
  PR #36): `x25519_scalarmult` self-masks IRQs via
  `php / sei … plp`, and defensively zeros `reu_reu_lo` ($DF04)
  + `reu_addr_ctrl` ($DF0A) at entry. Phase 7 + v0.4.0 H2
  extends the latter to direct callers of `fe25519_mul` /
  `fe25519_sqr` / `fe25519_mul_a24`.
- **No RNG.** Key generation remains the caller's responsibility.
- **No KDF / HKDF / AEAD.** Raw scalar multiplication only.
- **X25519 only.** No Ed25519, no X448, no hash functions.

## Testing and audit

Test-suite posture extended in v0.4.0:

- `tools/test_rfc7748_iterated.py` — RFC 7748 §5.2 1× iteration
  test (gated on `--slow`, in `make test-slow`).
- `tools/test_x25519_edge_u.py` — edge-u tests (0, 1, p-1, low-order
  points), gated on `--slow`, in `make test-slow`.
- `tools/bench_fe_ops.py` extended with single-call + batched
  benches for `fe25519_add` / `fe25519_sub` /
  `fe25519_reduce_final` / `fe25519_cswap` / `fe25519_mul_a24`.

pyca/cryptography remains the external differential reference.

- `make test` — fast Python-only reference self-test (no VICE)
- `make test-slow` — full VICE-driven suite (now includes the
  new v0.4.0 tests)
- `make test-vice` — quick VICE sanity check

## Known limitations

- **End-to-end scalarmult bench instrumentation reworked in
  v0.4.0.** PR #35's `php / sei … plp` masks the kernal jiffy
  clock IRQ for the duration of the call, which broke the
  original `tools/bench_x25519.py` (jiffy-clock-based). v0.4.0
  replaces it with a CIA1 Timer-A polled-counter implementation:
  cycle-precise, IRQ-mask-independent. Measured v0.4.0 cost:
  15,350 jif / 261,640,265 cycles on basepoint 9. Per-proc CT
  cycle-count guards (`make test-vice`) remain the authoritative
  CT regression surface.
- **REU still mandatory.** No pure-6502 fallback. `reu_probe` is
  available for hosts that cannot guarantee REU presence; behaviour
  on a non-REU system after `reu_probe` returns C=clear is
  caller-defined (the library has no fallback).
- **Interrupts.** `x25519_scalarmult` self-masks IRQ via
  `php / sei … plp` (PR #35, v0.3.0). Other library entry points do
  not self-mask; callers are responsible.
- **REU register state.** The library leaves REU registers in a
  non-default state on return (configured for `reu_fetch_mul_row`).

## Migration notes from v0.3.0

**No source change is required for downstream callers in the
common case.** The H1 fix (caller's `x25_u` no longer mutated)
is a strict strengthening of the contract — callers that did not
rely on the silent in-place mutation are unaffected. The H2 fix
(field-op REU register defence) is an internal robustness change.
The W5 SMC rewrite, W4 reduce_final pruning, W2 `reu_clear_wide`
CPU clear, W6 bench IRQ posture, and the Phase 7 CT closures are
all internal — the only observable behavioural change for
downstream callers is the H1 contract strengthening.

**For network-facing downstream consumers (`c64-https`,
`c64-wireguard`), v0.4.0 is the first release that ships a fully
CT-clean library** — Phase 7 closes the v0.4.0-disclosed L25-L29
families. The WireGuard handshake timing oracle and the TLS
handshake timing oracle described in the v0.2.0 threat-model
section no longer apply.

To move a vendored copy from v0.3.0 to v0.4.0:

1. Bump `version:` / `tag:` / `release_notes:` / `tarball_sha256:`
   in your `ORIGIN.txt`.
2. Re-vendor `src/*.s`, `src/x25519.inc`, `cfg/x25519-example.cfg`,
   `docs/LIBRARY.md`, `docs/CT_ANALYSIS.md`,
   `docs/RELEASE_NOTES_v0.4.0.md`, `LICENSE`, and
   `ORIGIN.txt.template` from the v0.4.0 tarball.
3. Re-assemble with your existing `ca65` invocation.

Behavioural changes vs v0.3.0:

- **`x25519_scalarmult` no longer mutates `x25_u`.** Hosts that were
  silently relying on the v0.3.0 mutation behaviour need to apply
  the high-bit mask themselves before storing the peer public key
  for later reuse. Hosts that re-load `x25_u` from a backing store
  before each call are unaffected.
- **`fe25519_mul` / `fe25519_sqr` / `fe25519_mul_a24` now defensively
  zero `$DF04` / `$DF0A` at entry.** Direct callers can drop their
  own pre-call zeroing of those registers.
- **ZP claim adjusted.** v0.4.0's W3 freed six dead symbols
  (`$1A-$1B` / `$1D` / `$2B` / `$FD-$FE`); Phase 7 then claimed
  six new slots in the freed ranges (`$14`/`$15`/`$16` and
  `$24`/`$25`/`$2F`). Final live surface: `$14-$16, $1C,
  $1E-$2A, $24-$25, $2C-$2F, $40-$7F` (87 bytes). Hosts that
  were using the formerly-claimed-but-actually-dead slots can
  now use them officially; hosts that need the new Phase 7
  slots should override via the `.ifndef` protocol in
  `docs/LIBRARY.md` §4.2.
- **`fe_wide` no longer host-overridable.** Hosts that were
  relocating `fe_wide` outside `$40-$7F` (rare; the SMC contract
  silently broke any such host) now hit a link-time `.assert`
  instead. Recommended fix: keep `fe_wide` at `$40-$7F` and move
  the host's own ZP scratch to a different range.
- **`reu_probe` available.** Hosts targeting mixed C64 hardware
  (1750 / 1764 / 17xx clones / non-REU systems) can call
  `reu_probe` before `sqtab_init` / `reu_mul_init`.

**Migration guidance for downstream consumers (`c64-https`,
`c64-wireguard`):**

- `c64-https` — review any code path that re-uses `x25_u` across
  multiple scalarmults (peer public keys for handshake retries);
  v0.4.0 simplifies this — no longer need to re-load from a backing
  store before each call. The H2 fix protects against
  cross-library REU register residue from sibling crypto libs that
  share the REU surface. With Phase 7 landed, the TLS handshake
  no longer leaks `fe_cmp_p` / `fe25519_reduce_final` timing.
- `c64-wireguard` — same H1 simplification. **Phase 7 closure
  removes the WireGuard handshake timing oracle for L25-L29.**
  v0.4.0 is the recommended baseline for any WireGuard
  deployment that may face a network-side timing attacker — the
  field-op surface now meets the same CT contract as
  `fe25519_sqr` / `mul_8x8` did in v0.3.0.

## Phase 7 closure language (verbatim, for downstream re-quoting)

> v0.4.0 closes the 27 secret-data-dependent branches catalogued
> across 5 leak families (L25 / L26a-d / L27a-f / L28a-k /
> L29a-e) in the previously-unaudited part of `src/fe25519.s` —
> `fe25519_mul`, `fe25519_mul_a24`, `fe_reduce_wide`,
> `fe25519_add`, `fe25519_sub`, `fe_cmp_p`, and
> `fe25519_reduce_final`. With Phase 7 landed, the entire
> `fe25519_*` / `mul_8x8` / `x25519_scalarmult` surface is
> CT-clean against a network-observable timing oracle. The four
> closure templates are: (1) `lda#0/sbc#0/eor#$FF` bit-to-mask
> idiom + new `fe_cmp_p_ct` proc + masked sub-p tail (L29);
> (2) Phase-6 Option F per-body 1-bit pending chain (L25 + L26
> in `fe25519_mul`); (3) unconditional `dey/bne` cascades gated
> by the `mul38_lo_tab[0]=0` lemma (L27 in `fe_reduce_wide`);
> (4) `fe_carry`-threaded reduction stages with public-count
> ripples (L28 in `fe25519_mul_a24`). Per-proc CT cycle spreads
> measured at 0.000-0.01 jif under `make test-vice`. See
> `docs/CT_ANALYSIS.md` Phase 7 section for the per-site
> catalogue and closure mechanism walkthrough.

## Full commit list (v0.3.0..v0.4.0)

Reproduce with `git log --format="%h %s" v0.3.0..v0.4.0`:

- `47c0ad2` feat(v0.4.0): CIA-timer scalarmult bench + wire CT tests + record measured perf (#39)
- `e11d153` feat(v0.4.0): full L1-L29 CT closure + resolution sweep (#38)
- `e538330` chore: untrack per-project Serena state; memories now centralized
- `83e1b3a` docs(post-#36): update LIBRARY.md, README, and Serena memories
- `aba4f95` fix(state): defensive REU register init at scalarmult entry (issue #33) (#36)
- `35351c9` feat(ct/defence): wrap x25519_scalarmult in php/sei...plp (#35)
- `c0f20b1` docs: fill v0.3.0 tarball SHA256 + size (#32)

## Tarball

**c64-x25519-v0.4.0.tar.gz** — source distribution (ca65/ld65-compatible assembly + docs + linker config example + LICENSE + ORIGIN.txt.template)

- Size: **77,365 bytes**
- SHA256: `74e3d252760c15de34c35a2e3419bab4de999f2fb084182fe3b6c423047192fe`
- Download: https://github.com/JC-000/c64-x25519/releases/download/v0.4.0/c64-x25519-v0.4.0.tar.gz

Built reproducibly from the v0.4.0 tag with `git archive --prefix=c64-x25519-v0.4.0/ --format=tar v0.4.0 <vendoring file list> | gzip -n -9`. The file list is the one in the v0.3.0-to-v0.4.0 migration block above: `src/*.s`, `src/x25519.inc`, `cfg/x25519-example.cfg`, `docs/LIBRARY.md`, `docs/CT_ANALYSIS.md`, `docs/RELEASE_NOTES_v0.4.0.md`, `LICENSE`, `ORIGIN.txt.template`.

Downstream vendoring: extract into your project, fill in
`ORIGIN.txt` from the template, and run `ca65` against `src/*.s`.
See `docs/LIBRARY.md` §4 and §4.1 for the full integration guide,
§4.2 for the host ZP override protocol, and the "Phase 7
disclosure language" section above for re-quotable text.
