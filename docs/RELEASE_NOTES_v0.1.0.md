# c64-x25519 v0.1.0 — first stable release

**Status:** DRAFT (pre-tag). Freeze criteria: all v0.1.0 scope items closed, PR merged, tag pushed.

## What this is

An optimized X25519 (RFC 7748) implementation for the Commodore 64, written in ca65 assembly, with full Python-driven test harness using VICE emulator and the c64-test-harness package. This is the first release intended for external consumption by other c64 projects; prior commits were internal optimization work.

## Highlights

- **Full RFC 7748 correctness** — RFC 7748 §6.1 test vectors pass, plus randomized scalar/u-coord cross-checks against pyca/cryptography.
- **9,544 jiffies** per `x25519_scalarmult` on basepoint 9 with VIC-II blanked (~159.1s NTSC / ~190.9s PAL). **47.1% faster** than an un-optimized baseline.
- **1750 REU required.** The implementation uses 6 banks (0–5) of 1750 REU for pre-computed multiplication tables. A pure-RAM variant is planned for v0.2.0.
- **Public API stability.** The `fe25519_*` and `x25519_*` entry points are locked for the v0.1.0 series and follow semver.
- **Vendoring model.** Downstream C64 projects (c64-wireguard, c64-https, …) vendor this library as source + `ORIGIN.txt` provenance. See `docs/LIBRARY.md` for the integration guide.

## Performance

Measured on NTSC VICE (warp mode, VIC-II blanked, 1750 REU):

| Operation | Jiffies/call | NTSC wall | PAL wall |
|---|---:|---:|---:|
| `x25519_scalarmult` (basepoint 9) | 9,544 | ~159.1 s | ~190.9 s |
| `x25519_scalarmult` (dense RFC 7748 vec1) | ~10,600 | ~176.7 s | ~212.0 s |
| `fe25519_mul` | 4.03 | — | — |
| `fe25519_sqr` (random operand) | 4.11 | — | — |
| `fe25519_inv` | 1,150 | — | — |
| `fe25519_add` | 0.09 | — | — |
| `fe25519_sub` | 0.04 | — | — |
| `fe25519_cswap` | 0.09 | — | — |
| `fe25519_mul_a24` | 0.24 | — | — |

**Note on basepoint vs dense u-coordinate asymmetry**: basepoint 9 has u = `[9, 0×31]`. The 23 zero bytes trigger zero-skip fast paths in `fe25519_mul`, giving a ~10% advantage. Dense u-coordinates (real ECDH with a peer's public key) run ~10% slower and are the representative case. Both numbers are published for transparency.

## Public API

See `src/x25519.inc` for the authoritative header. Summary:

**Init routines (one-time at startup):**
- `sqtab_init` — build quarter-square table
- `reu_mul_init` — build REU mul tables (requires sqtab_init first)

**X25519 scalar multiplication:**
- `x25519_clamp` — RFC 7748 scalar clamping, in-place on `x25_scalar`
- `x25519_scalarmult` — `x25_result = x25_scalar * x25_u` on Curve25519
- `x25519_base` — `x25_result = x25_scalar * basepoint(9)` (convenience wrapper)

**Field arithmetic over GF(2²⁵⁵ − 19):**
- `fe25519_add`, `fe25519_sub`, `fe25519_mul`, `fe25519_sqr`, `fe25519_mul_a24`, `fe25519_inv`
- `fe25519_cswap`, `fe25519_reduce_final`
- `fe25519_copy`, `fe25519_zero`, `fe25519_one`

**Utilities (from `src/util.s`):**
- `bench_start`, `bench_stop`, `bench_ticks` — jiffy timing
- `vic_blank`, `vic_unblank` — VIC-II display control (~25% perf win during crypto)

**Not public API (debug / internal / may change without notice):**
- `x25519_ladder_step` — debug-only ladder single-step entry for differential testing harnesses
- `mul_8x8`, `poly_prod_lo`, `poly_prod_hi`, `sqtab_lo`, `sqtab_hi` — mul primitive + globals
- `mul_by_38`, `reu_fetch_*`, `reu_clear_wide` — internal helpers
- `mul_dma_*`, `sqtab2_*`, `mul38_*_tab`, `sqr_*`, `a24_b*`, `mul_cached_a`, `mul_src2_buf` — optimization tables and scratch buffers

Symbols not listed above are internal implementation details. Do not rely on them.

## Memory and ZP footprint

- **Zero page:** `$14-$2E`, `$40-$7F`, `$FB-$FE` owned while running
- **RAM:** code from `$0900` upward; page-aligned data pages for field buffers; `$7800-$7BFF` for the quarter-square table
- **REU:** banks 0–5 of 1750 REU (384 KB)

Full memory map in `docs/LIBRARY.md` §7.

## Security notes

- **Not constant-time.** `fe25519_cswap` takes the same time regardless of its mask and the Montgomery ladder visits every bit, but the per-byte REU fetch and inner loop timing is data-dependent at the microsecond level. **Not suitable against adversaries with fine-grained timing or EM side-channel access.** Suitable against network-observable attackers.
- **No RNG.** Key generation is the caller's responsibility. The library does not seed or consume randomness.
- **No KDF / HKDF / AEAD.** Raw scalar multiplication only.
- **No Ed25519 / X448 / hash functions.**

## Testing and audit

The test suite uses pyca/cryptography (an external audited reference) for differential testing of all cryptographic results. Repo-local Python reimplementations of the same algorithm can share bugs with the assembly SUT; validating against an external audited library avoids that class of failure.

- `make test` — fast Python-only reference self-test (no VICE)
- `make test-slow` — full VICE-driven suite: clamp, scalarmult, RFC vectors, per-step ladder checkpoints (255 steps), random scalars + random u-coords, field op stress tests, carry-propagation regression
- `make test-vice` — quick VICE sanity check

At release time, `make test-slow` produces **847 assertions across 11 test files, 0 failures**:

| Test | Assertions |
|---|---:|
| `test_fe25519.py` | 64 |
| `test_fe_mul_stress.py` | 128 |
| `test_fe_sqr_stress.py` | 49 |
| `test_fe_reduce_wide_carry.py` | 3 |
| `test_opt_sqr.py` | 19 |
| `test_opt_karatsuba.py` | 53 |
| `test_opt_fast_mul.py` | 35 |
| `test_opt_vic_reduce38.py` | 68 |
| `test_mul38_tables.py` | 256 |
| `test_x25519.py --slow` | 27 (RFC vec1+vec2, basepoint, clamp, 10 random scalars, 10 random u-coords) |
| `test_ladder_checkpoint.py --start 0 --count 255` | 255 |

### Latent bug fixed during v0.1.0 prep

Differential testing with `--slow --seed 3115981863` uncovered a latent `fe_reduce_wide` carry-propagation bug where `cpx #32` was clobbering the carry flag between `adc #0` and the loop back-branch, silently dropping propagating +1 bits on specific input cascades. Fixed in commit `48092b5` via `inc fe_wide,x ; bne @done` pattern (same as existing `fe25519_mul_a24.@prop_b3{2,3,4}`). Perf-neutral. A permanent regression test (`tools/test_fe_reduce_wide_carry.py`) prevents recurrence; an audit of all other `adc #0` sites in `src/*.s` confirmed zero other instances of the bug pattern.

## Building the library archive

```
make lib          # builds build/lib/libx25519.a + individual .o files
make lib-verify   # smoke-tests that the archive links against a stub main
```

Downstream projects vendor the output of `make lib` plus `docs/LIBRARY.md` and `src/x25519.inc` alongside an `ORIGIN.txt` provenance file. See `docs/LIBRARY.md` §4 for the integration guide.

## Known limitations

- **REU is mandatory.** No pure-6502 fallback. (Planned for v0.2.0.)
- **Timing is not constant** (see security notes).
- **Interrupts.** Run with `sei` for consistent timing.
- **REU register state.** The library leaves REU registers in a non-default state.

## Acknowledgments

Optimization work across Phases 1–10 (2026-03 through 2026-04). Latent carry bug discovered and fixed via differential testing against pyca/cryptography, enabled by test-hardening work in PR #13.

## Full commit list (v0.1.0 range)

Recent v0.1.0 packaging commits (see `git log feat/v0.1.0-packaging` for the authoritative list):

- `f1470b5` feat: relocatable library archive (make lib / make lib-verify)
- `3cfba0e` feat: compile-time alignment assertions for field buffers
- `64b6494` Merge pull request #16 from JC-000/worktree-fe25519-mul-opt
- `f336fec` docs: update Phase 10 benchmarks in LIBRARY.md and x25519.inc
- `fa7c31e` perf(phase 10): fe_mul / fe_sqr / fe_inv micro-opts (-3.0%)

The v0.1.0 packaging docs commit SHA will be appended at tag time.
