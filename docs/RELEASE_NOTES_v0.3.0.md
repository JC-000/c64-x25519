# c64-x25519 v0.3.0 — perf recovery + full CT certification (L1–L24)

**Status:** released 2026-04-19.

## What this is

A perf-recovery + full-CT-certification minor release of `c64-x25519`.
See [`RELEASE_NOTES_v0.1.0.md`](RELEASE_NOTES_v0.1.0.md) for the
baseline description of the library, its RFC 7748 correctness posture,
the vendoring model, and the v0.1.0 performance envelope. See
[`RELEASE_NOTES_v0.2.0.md`](RELEASE_NOTES_v0.2.0.md) for the v0.2.0
constant-time remediation of the field-op surface (L1–L22) and the
v0.2.0 ZP-override composition hook.

v0.3.0 lands **two independent bodies of work on the v0.2.0 baseline**:

1. **Perf recovery** (Phases 1–3) — rewrites `fe25519_sqr`'s hot path
   without touching any CT invariant, recovering a substantial portion
   of the v0.1.0→v0.2.0 scalarmult regression.
2. **Full CT certification** — closes the two outstanding audit items
   from v0.2.0: the `@diag_prop` diagonal-term path in `fe25519_sqr`
   (new leaks L23a/b/c) and the outer `x25519_scalarmult` Montgomery
   ladder (new leaks L24a/b), plus verification by inspection that
   `fe25519_cswap` is already CT-clean.

The net effect: v0.3.0 is **12,070 jiffies** on basepoint 9, which is
**−415 jif (−3.3 %) vs v0.2.0's shipped 12,485 jif** and **+26.8 %
vs v0.1.0's 9,520-jif baseline**. v0.3.0 is the first release with
full **field-op + outer-ladder side-channel posture** — the library's
outermost primitive no longer leaks scalar-bit information through
branch timing. Public API is unchanged.

## Highlights

- **Phase 0 — CT cycle-count regression guard (PR [#25](https://github.com/JC-000/c64-x25519/pull/25)).** Ships `tools/test_ct_square_cycles.py`: a batch-200 amortized cycle-count check that asserts `fe25519_sqr` runs to within 1 jif across structurally distinct inputs (`dense_55`, `sparse_09`, `mixed_mid`, `mixed_hi`; PR [#31](https://github.com/JC-000/c64-x25519/pull/31) later adds `diag_zeros`). Runs in `make test-slow` and `make test-vice`. If a future change to `fe25519_sqr`'s hot path accidentally makes it data-dependent, this guard catches it before release.
- **Phase 1 — mult66 SMC literal hoist + register-threaded abs-math (PR [#26](https://github.com/JC-000/c64-x25519/pull/26)).** Hoisted the self-modifying-code literal patches from the inner mult66 bodies into per-outer-iteration setup, and kept the absolute-value math in registers instead of bouncing through ZP. **−247 jif** on basepoint 9.
- **Phase 2 — SQR_DMA_K retune (14 → 22, PR [#27](https://github.com/JC-000/c64-x25519/pull/27)).** After Phase 5b (CT) removed zero-skips and Phase 1 tightened the mult66 bodies, the per-row DMA fixed cost's break-even against the mult66 path shifted significantly further out than the historical K=14. Empirical sweep found K=22 optimal on the current hot path. **−347 jif** on basepoint 9.
- **Phase 3 — chain-step address-math fold + ripple-setup fold (PR [#28](https://github.com/JC-000/c64-x25519/pull/28)).** The `i+j+2` chain-step offset was being recomputed every inner-body entry via a ZP increment + reload sequence; Phase 3 threads it through a register-resident cursor across the body chain. The end-of-inner ripple setup was similarly folded into the last body's exit state. **−1,152 jif on basepoint 9, far overshooting the plan's central estimate of −425.** Phase 3's PR includes a full 8-invariant walkthrough proving every L1–L22 fix from Phase 6 is preserved by the rewrite.
- **Phase 4 (cswap SMC hoist) investigated, SKIPPED.** Measurement showed only ~4 jif of real recovery vs the plan's projection of ~60+; the plan's estimate had an arithmetic error (~16× overestimate). Below the ship threshold.
- **Phase 5 (`fe25519_mul` Phase-1-analogue + two other candidates) investigated, SKIPPED.** Combined ceiling across all three sub-options was ~80 jif, below the 100-jif ship threshold. Unlike `fe25519_sqr`'s Phase-6 rewrite, `fe25519_mul`'s inner loop was already maximally tight and had no remaining redundancies to strip.
- **L24a/b closure — Montgomery ladder scalar-bit branches (PR [#30](https://github.com/JC-000/c64-x25519/pull/30)).** Two secret-dependent branches in the `x25519_scalarmult` bit loop (`beq @bit_zero` on the ANDed scalar-bit test; `beq @no_swap_mask` on the `k_t XOR prev_bit` swap-mask test) replaced with a branchless `cmp/sbc/eor` bit-to-mask idiom. `x25_prev_bit` migrated to mask form ($00/$FF), eliminating a third derived branch at the post-loop final-cswap setup. **Regression: 0 jif** (branchless sequence is cycle-equivalent to the old best-case branch path).
- **L23a/b/c closure — `@diag_prop` diagonal carry path (PR [#31](https://github.com/JC-000/c64-x25519/pull/31)).** Three secret-dependent branches in `fe25519_sqr`'s diagonal-term path (L23a: `beq @diag_skip` on secret `a[i] == 0`; L23b: `bcc @diag_skip` on the 16-bit diag-add carry-out; L23c: `bcs @diag_prop` variable-length cascade) rewritten as a Phase-6-style unconditional body + unconditional ripple with public count `62 - 2*i`. **Regression: +1,330 jif.** The CT guard's new `diag_zeros` input (alternating `0x00`/`0x55` bytes) exercises the former zero-skip path and confirms it no longer leaks.
- **`fe25519_cswap` — verified CT-clean by inspection (PR [#30](https://github.com/JC-000/c64-x25519/pull/30), audit comment only).** The unrolled-4× `abs,Y` inner loop is mask-time-invariant: every instruction executes every iteration; only the data written varies with the mask. 32-byte page alignment (hard-asserted in `src/data.s`) guarantees `Y ∈ [0..31]` never crosses a page boundary. No source change required.
- **Net state.** The perf recovery offsets most of the audit regression: v0.3.0 ships at **12,070 jif**, which is **−415 jif (−3.3 %) vs v0.2.0's 12,485 jif** and **+26.8 % vs v0.1.0's 9,520 jif** — faster than v0.2.0 *and* fully CT-certified.
- **Public API unchanged.** Every `fe25519_*` and `x25519_*` entry point retains its v0.1.0 / v0.2.0 signature and contract.

## Performance

| Operation | v0.3.0 | v0.2.0 | v0.1.0 | Δ vs v0.1.0 | Δ vs v0.2.0 |
|---|---:|---:|---:|---:|---:|
| `x25519_scalarmult` (basepoint 9) | **12,070 jiffies** (~201.2 s NTSC / ~241.4 s PAL) | 12,485 jiffies (~208.1 s NTSC) | 9,520 jiffies (~158.7 s NTSC) | **+26.8 %** | **−3.3 %** |
| `fe25519_mul` per-call | ~4.0 jiffies | ~4.0 jiffies | ~4.0 jiffies | flat | flat |
| `fe25519_sqr` per-call | **~6.36 jiffies** | ~5.4 jiffies (claimed; measured 6.235 at v0.2.0) | ~4.1 jiffies | +55 % | +2 % |
| CT cycle guard spread | **0.045 jif** | 0.155 jif (Phase 0 baseline) | — | — | **3× tighter** |

All measurements on stock C64 with VIC-II blanked (`jsr vic_blank`),
median of 3 runs via `tools/bench_x25519.py`.

The `fe25519_sqr` per-call cost grew from ~5.265 jif in the
Phase-3-only state to ~6.36 jif after the `@diag_prop` L23 fix added
an unconditional ripple (public count `62 - 2*i` per outer-i
iteration). This is a direct correctness-over-speed trade-off: the
former fast-path skipped the ripple when `a[i] == 0` or when the
16-bit diag add didn't carry, both secret-derived conditions. The
cost is ~1,330 jif at scalarmult scale (~1,529 calls to `fe25519_sqr`
per scalarmult × ~0.87 extra jif/call).

Phases 1–3 recover **1,746 jif** of the original v0.1.0→v0.2.0
regression; the L23 + L24 audit closures cost back **~1,330 jif**
(L24a/b was flat; L23a/b/c accounted for the full audit regression).
Net vs v0.2.0: −415 jif. The library is **~32.9 % faster than the
original un-optimized ~18,000-jiffy baseline** (vs ~31 % at v0.2.0
and ~47.1 % at v0.1.0).

## Public API

**UNCHANGED from v0.2.0.** See the v0.1.0 release notes "Public API"
section for the authoritative symbol list; `src/x25519.inc` remains
the machine-readable header. No symbols were added, removed, renamed,
or reordered. No entry-point contract (ZP inputs/outputs,
preserved-register sets, carry/flag invariants) was modified.

## Constant-time posture

**v0.3.0 is the first release with full field-op + outer-ladder
side-channel posture.** All 24 catalogued leaks (L1–L24) are now
closed:

- **L1–L22** (landed v0.2.0, preserved across v0.3.0 Phases 1–3):
  cross-term field-op surface across `mul_8x8`, `fe25519_mul`, and
  `fe25519_sqr`. Branchless CT quarter-square; inline CT mult66
  rewrite; zero-skip removals; Phase 6 unconditional per-body
  pending-carry chain plus end-of-inner ripple. Phase 3's correctness
  walkthrough (in PR #28) verifies the Phase 1 / 2 / 3 perf rewrites
  preserve every fix.
- **L23a/b/c** (new in v0.3.0, PR #31): `@diag_prop` diagonal-term
  carry path in `fe25519_sqr`. Unconditional body + unconditional
  ripple with public count, Phase-6-style. Verified by the new
  `diag_zeros` CT-guard input landing at the same per-call cycle
  count as `dense_55`.
- **L24a/b** (new in v0.3.0, PR #30): two scalar-bit-dependent
  branches in the `x25519_scalarmult` Montgomery ladder bit loop.
  Replaced by the standard branchless `cmp/sbc/eor` bit-to-mask
  idiom; `x25_prev_bit` migrated to mask form throughout, eliminating
  a third derived branch at the post-loop final-cswap setup.
- **`fe25519_cswap`** (audited v0.3.0 PR #30, no source change): the
  unrolled-4× `abs,Y` inner loop is mask-time-invariant by
  construction. Every instruction executes every iteration; only the
  data written varies with the mask. 32-byte page alignment
  (hard-asserted in `src/data.s`) guarantees no page-cross.

The field-op hot path contains no data-dependent branches and no
`(zp),y` indirect-indexed loads on secret operands. The outer ladder
no longer branches on scalar bits. The library's outermost primitive
no longer leaks scalar-bit information through branch timing.

See `docs/CT_ANALYSIS.md` for the full leak catalog and correctness
argument.

## New: CT regression guard

`tools/test_ct_square_cycles.py` (Phase 0, PR #25; extended by PR #31)
is a cycle-count regression guard specifically for `fe25519_sqr`'s
hot path. It:

- Runs five structurally distinct 32-byte inputs: `dense_55` (all
  `$55`), `sparse_09` (RFC basepoint-shape — mostly zero),
  `mixed_mid` (mid-bit-density alternating), `mixed_hi`
  (high-bit-density), and `diag_zeros` (alternating `0x00`/`0x55`
  bytes — added by PR #31 specifically to exercise the former
  `@diag_prop` zero-skip path).
- Squares each input 200 times in a batch on-C64 and divides by the
  batch count, amortizing jiffy-clock quantization noise.
- Asserts that the per-call jif cost is within 1 jif across all
  inputs.
- Runs as part of `make test-slow` and `make test-vice`.

Post-v0.3.0 baseline spread: **0.045 jif** across the five inputs
(threshold: 1.0 jif). The L23 fix tightened the per-call timing
distribution by ~3× relative to the pre-audit 0.150-jif spread,
because the former zero-skip and carry-skip variants are now gone.

## Memory and ZP footprint

Unchanged from v0.2.0 when the host does not override:

- **Zero page:** `$14-$2E`, `$40-$7F`, `$FB-$FE` owned while running
- **RAM:** code from `$0900` upward; page-aligned data pages for field
  buffers; `$7800-$7BFF` for the quarter-square table
- **REU:** banks 0–5 of 1750 REU (384 KB)

Full memory map in `docs/LIBRARY.md` §7. Host ZP override protocol is
unchanged from v0.2.0 — see `docs/LIBRARY.md` §4.2.

## Security notes

- **Full side-channel posture.** L1–L24 all closed. The field-op
  surface is CT-clean (L1–L22, preserved from v0.2.0 by the Phase 3
  walkthrough). The `@diag_prop` diagonal-term path is CT-clean
  (L23a/b/c, PR #31). The outer `x25519_scalarmult` Montgomery ladder
  is CT-clean (L24a/b, PR #30). `fe25519_cswap` is verified CT-clean
  by inspection (no source change needed).
- **No RNG.** Key generation remains the caller's responsibility.
- **No KDF / HKDF / AEAD.** Raw scalar multiplication only.
- **X25519 only.** No Ed25519, no X448, no hash functions.

## Testing and audit

Test-suite posture is unchanged from v0.2.0. pyca/cryptography
remains the external differential reference.

- `make test` — fast Python-only reference self-test (no VICE)
- `make test-slow` — full VICE-driven suite (includes the
  `test_ct_square_cycles.py` CT regression guard with the
  `diag_zeros` input)
- `make test-vice` — quick VICE sanity check (includes the CT
  regression guard)

## Known limitations

- **REU still mandatory.** No pure-6502 fallback yet. Still planned for
  a later release.
- **Interrupts.** Run with `sei` for consistent timing.
- **REU register state.** The library leaves REU registers in a
  non-default state.

## Migration notes from v0.2.0

**No source change is required for downstream callers.** The public
API is identical byte-for-byte. To move a vendored copy from v0.2.0
to v0.3.0:

1. Bump `version:` / `tag:` / `release_notes:` / `tarball_sha256:` in
   your `ORIGIN.txt`.
2. Re-vendor `src/*.s`, `src/x25519.inc`, `cfg/x25519-example.cfg`,
   `docs/LIBRARY.md`, `docs/RELEASE_NOTES_v0.3.0.md`, `LICENSE`, and
   `ORIGIN.txt.template` from the v0.3.0 tarball.
3. Re-assemble with your existing `ca65` invocation.

Observable behavioural changes vs v0.2.0:

- **Scalarmult timing:** 12,070 jif vs 12,485 jif — a net 3.3 %
  improvement from the perf recovery offsetting the audit regression.
- **CT certification:** v0.3.0 adds full outer-ladder side-channel
  posture to v0.2.0's field-op surface. Network-facing deployments
  no longer need to treat any audit item as pending.

No API change, no ZP-layout change.

## Full commit list (v0.2.0..master)

Reproduce with `git log --format="%h %s" v0.2.0..master`:

- `c32c390` audit(ct): close @diag_prop leak (L23a/b/c) with Phase-6-style chain (#31)
- `25e445e` audit(ct): close L24a/b scalar-bit branches in x25519_scalarmult; verify fe25519_cswap CT-clean (#30)
- `181a181` perf(sqr): fold chain-step address math + ripple setup (Phase 3) (#28)
- `4c375c0` perf(sqr): retune SQR_DMA_K from 14 to 22 (Phase 2) (#27)
- `5785c0e` perf(sqr): hoist mult66 SMC literals + keep abs-math in registers (Phase 1) (#26)
- `578f4d0` test(ct): add fe25519_sqr cycle-count regression guard (#25)

## Tarball

**c64-x25519-v0.3.0.tar.gz** — source distribution (ca65/ld65-compatible assembly + docs + linker config example + LICENSE + ORIGIN.txt.template)

- Size: **TBD** (filled via follow-up PR)
- SHA256: **TBD** (filled via follow-up PR; canonical SHA in the GitHub release body)
- Download: https://github.com/JC-000/c64-x25519/releases/download/v0.3.0/c64-x25519-v0.3.0.tar.gz

Downstream vendoring: extract into your project, fill in `ORIGIN.txt` from the template, and run `ca65` against `src/*.s`. See `docs/LIBRARY.md` §4 and §4.1 for the full integration guide, and §4.2 for the host ZP override protocol.
