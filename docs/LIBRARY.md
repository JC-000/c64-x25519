# c64-x25519 as a library

This document describes how to integrate the X25519 implementation in
`c64-x25519` into another Commodore 64 project. The machine-readable
header is `src/x25519.inc`; this file is the human-readable guide.

## 1. Requirements

- **CPU:** 6502 (stock C64).
- **Assembler:** ca65/ld65 (cc65 suite). The library uses ca65 syntax
  (`.include`, `.byte`, `.align`, `.repeat`). Each source file is
  assembled into its own `.o` and linked with `ld65`.
- **RAM:** BASIC ROM must be banked out (the library's test harness
  does this at startup by clearing bit 0 of `$01`). The library uses
  RAM from `$0900` upward for code plus several page-aligned data
  pages for field buffers and DMA staging, plus `$7800-$7BFF` for the
  quarter-square table.
- **REU:** **512 KB REU required** (a Commodore 1750 or equivalent,
  or any REU/compatible with at least 6 banks of 64 KB). The library
  pre-computes full 8x8->16 multiplication tables into REU banks 0-5.
- **Zero page:** the library owns `$14-$2E`, `$40-$7F`, and `$FB-$FE`
  while running. See `src/x25519.inc` for the full map.

## 2. Building

```
make              # builds build/x25519.prg (standalone test harness)
make clean
```

The build compiles each `.s` file separately and links them with `ld65`.
Label output is converted to VICE format in `build/labels.txt`.

## 3. Source file structure

| File | Purpose |
| --- | --- |
| `src/main.s` | Test harness: BASIC stub, entry point, screen/timer helpers |
| `src/x25519_init.s` | Library init: `reu_mul_init`, REU DMA helpers |
| `src/mul_8x8.s` | Quarter-square 8x8->16 multiply + `sqtab_init` |
| `src/fe25519.s` | Field arithmetic mod p = 2^255 - 19 |
| `src/x25519.s` | X25519 Montgomery ladder (RFC 7748) |
| `src/data.s` | Page-aligned buffers, lookup tables, constants |
| `src/constants.s` | ZP / hardware equates (`.include`'d, not compiled) |
| `src/x25519.inc` | Public API documentation header |
| `cfg/x25519.cfg` | ld65 linker configuration |

## 4. Integrating into another project

To use the library from another ca65 project, compile and link the
library source files alongside your own:

```
ca65 -o x25519_init.o  src/x25519_init.s
ca65 -o mul_8x8.o      src/mul_8x8.s
ca65 -o fe25519.o      src/fe25519.s
ca65 -o x25519.o       src/x25519.s
ca65 -o data.o         src/data.s
ca65 -o your_app.o     your_app.s
ld65 -C your_config.cfg -o app.prg \
    your_app.o x25519_init.o mul_8x8.o fe25519.o x25519.o data.o
```

In your source, `.import` the symbols you need:

```ca65
.import sqtab_init, reu_mul_init
.import x25519_base, x25519_clamp, x25519_scalarmult
.import x25_scalar, x25_u, x25_result
.import vic_blank, vic_unblank
```

Then at startup, before any field operation:

```ca65
        jsr sqtab_init           ; build quarter-square table @ $7800
        jsr reu_mul_init         ; build REU mul tables (takes ~1-2s)
```

To compute a public key:

```ca65
        ; Fill x25_scalar (32 bytes) with your secret key.
        ; x25519_base will clamp it in place.
        jsr vic_blank            ; optional, ~25% speedup
        jsr x25519_base          ; x25_result = scalar * basepoint
        jsr vic_unblank
        ; x25_result now holds the 32-byte public key (little-endian).
```

To compute a shared secret:

```ca65
        ; Fill x25_scalar with your private key (will be clamped).
        ; Fill x25_u      with the peer's public key (32 bytes LE).
        jsr x25519_clamp
        jsr vic_blank
        jsr x25519_scalarmult
        jsr vic_unblank
        ; x25_result = scalar * peer_public.
```

## 5. Public API

See `src/x25519.inc` for the full reference with calling conventions
and clobber lists. Summary:

| Symbol              | What it does                                   |
| ------------------- | ----------------------------------------------- |
| `sqtab_init`        | One-time: build quarter-square table            |
| `reu_mul_init`      | One-time: build REU mul tables (requires sqtab) |
| `x25519_clamp`      | RFC 7748 scalar clamping (in place)             |
| `x25519_scalarmult` | `result = scalar * u` on Curve25519             |
| `x25519_base`       | `result = scalar * basepoint(9)`                |
| `fe25519_add`            | Field add mod p                                 |
| `fe25519_sub`            | Field sub mod p                                 |
| `fe25519_mul`            | Field mul mod p (REU-accelerated)               |
| `fe25519_sqr`            | Field square mod p (REU-accelerated)            |
| `fe25519_mul_a24`        | `result = 121665 * a mod p`                     |
| `fe25519_inv`            | Modular inverse via Fermat's little theorem     |
| `fe25519_copy` / `fe25519_zero` / `fe25519_one` | trivial helpers                    |
| `fe25519_cswap`          | Conditional 32-byte swap                        |
| `fe25519_reduce_final`   | Canonicalize a value to `[0, p)`                |
| `fe_cmp_p`          | Compare `(fe25519_dst)` with `p`                     |
| `vic_blank` / `vic_unblank` | Toggle VIC-II display (speed)           |
| `bench_start` / `bench_stop` | Jiffy-clock timing                     |

All `fe25519_*` routines take operand pointers in ZP slots `fe25519_src1` (`$1E`),
`fe25519_src2` (`$20`), `fe25519_dst` (`$22`). Fill those, then `jsr`.

## 6. Buffer alignment contract

**32-byte field buffers MUST be page-aligned to one of the offsets
`$00, $20, $40, $60, $80, $A0, $C0, $E0` within a 256-byte page.**

This is a hard requirement of the optimized routines
(`fe25519_add`, `fe25519_sub`, `fe_cmp_p`, `fe25519_reduce_final`) which use
self-modifying `abs,Y` addressing and depend on `Y in [0..31]` never
crossing a page boundary. Violating this alignment will produce
silently wrong results.

All library-provided buffers (`x25_scalar`, `x25_u`, `x25_result`,
`fe25519_tmp1..4`, `x25_a/b/da/cb/e`, `x25_x2/x3`, `x25_z2/z3`) are
allocated with the correct alignment in `src/data.s`. If you add
your own field buffers, use `.align 32` followed by `.res 32, 0`.

## 7. Memory map

```
$0001           proc_port (BASIC ROM banked out)
$0014-$007F     ZP slots owned by library while running
$00A0-$00A2     jiffy clock (read by bench_*)
$00C6           kbd buffer count (test harness only)
$00FB-$00FE     zp_ptr1 / zp_ptr2 (general scratch)
$0801-$08FF     BASIC stub + boot (test harness)
$0900+          library code (mul_8x8, fe25519, x25519, ...)
$1800-$1Axx     page-aligned field buffers (fe_tmp*, x25_*)
$1B00-$1DFF     mul_dma_lo/hi/carry (REU DMA staging)
$1E00-$1FFF     sqtab2_lo/hi
$2000-$27FF     lookup tables (mul38, sqr, a24_*)
$2800+          strings / input buffer (test harness)
$7800-$7BFF     sqtab_lo / sqtab_hi  (built by sqtab_init)
$D000-$DFFF     I/O (VIC-II, CIA, SID, REU)
REU bank 0-1    a*b low/high tables
REU bank 2      (first 64 bytes) zero block for reu_clear_wide
REU bank 3      17th-bit carry tables for fe25519_sqr
REU bank 4-5    2*a*b low/high tables for fe25519_sqr
```

Exact addresses can be read from `build/labels.txt` after a build.

## 8. Performance

Latest (post-Phase-10: Phase 9 base plus fe_mul src1/src2 self-mod
patches and per-body `clc` removal in 4x-unrolled inner loop,
fe_sqr `@sqr_inner_dma` rewrite keeping `j` in X register, and a
critical carry-propagation fix in `fe_reduce_wide` for a latent
correctness bug on specific input cascades):

| Operation             | Jiffies | Wall-time NTSC | Wall-time PAL |
| --------------------- | ------: | -------------: | ------------: |
| `x25519_scalarmult`   |   9,520 |       ~158.7 s |      ~190.4 s |

This is ~47.1% faster than the original (un-optimized) baseline.
Timing is measured with VIC-II **blanked** (`jsr vic_blank` before
the call); running with the display enabled costs ~25% more cycles
due to VIC-II DMA badlines.

The 9,520 jiffy figure is for the basepoint (u = [9, 0×31]). The
23 zero bytes trigger zero-skip fast paths in `fe25519_mul`; a
dense u-coordinate (typical ECDH with a peer public key) runs
about 10% slower — use `tools/bench_fe_ops.py` to measure an RFC
7748 dense test vector for a representative number.

One scalar multiplication performs roughly 2,550 field multiplies +
~264 squarings for the inversion step.

## 9. Constraints and caveats

- **Timing is not constant.** `fe25519_cswap` takes the same time regardless
  of its mask, and the Montgomery ladder visits every bit, but the
  per-byte REU fetch routines' timing and the inner loops are data
  dependent at the microsecond level. This library is not suitable
  against side-channel adversaries with fine-grained timing or EM
  access. It **is** suitable against an attacker who only sees the
  wire output.
- **No RNG.** Key generation is the caller's job. The library does
  not seed or consume randomness. `x25519_base` expects the scalar
  to already be in `x25_scalar`.
- **No key derivation / HKDF / anything beyond the raw scalar mult.**
- **REU is mandatory.** There is no fallback to pure-6502 multiply.
- **Interrupts.** Run with `sei` for consistent timing. NMIs (RESTORE
  key, CIA2 TimerB) are not masked; if your host sets them up,
  consider masking them too for the duration of the call.
- **REU register state.** The library leaves the REU registers in
  a non-default state (configured for `reu_fetch_mul_row`). If your
  host also uses the REU, save `$DF02-$DF0A` before calling and
  restore afterward.

## 10. What is NOT included

- Random number generation (no RNG; caller supplies scalars).
- Key generation / serialization helpers beyond `x25519_base`.
- Ed25519 signatures, X448, any hash function.
- HKDF / KDFs / anything layered on top of X25519.

## 11. Testing and correctness

The test suite under `tools/test_*.py` drives the C64 code through a
VICE harness and cross-checks every result against an independent
reference — `tools/ref_x25519.py`, which wraps Python's
`cryptography.hazmat` library (pyca/cryptography). This is a
deliberate design choice: repo-local Python reimplementations of the
same algorithm can share bugs with the assembly SUT, so we validate
against an external, widely-audited source of truth instead.

- `make test` — fast path; runs `ref_x25519` self-test against RFC
  7748 §5.2 vectors 1 and 2 (no VICE required).
- `make test-slow` — full VICE-driven suite: clamp, scalarmult, full
  RFC vectors, per-step ladder checkpoints, random scalars and random
  u-coords (via `--random N`) cross-checked against the library
  reference. Runtime is dominated by VICE; each random scalarmult
  takes ~100 min under warp, so tune `--random` downward for CI.
- `make test-vice` — quick VICE sanity check: mul38 tables, field ops,
  stress tests.
- Stress tests for field ops (`test_fe_mul_stress`, `test_fe_sqr_stress`,
  etc.) use seeded PRNG inputs and assert — not print — on mismatch.

## 12. Version / provenance

- Upstream repository: `c64-x25519`, branch `master`.
- Recent optimization commits:
  - Phase 9 (tables + unroll + alignment): `8fa953c`, `381e3d6`,
    `14920b7`, `50c7b7b`
  - Phase 10 (mul/sqr/inv micro-opts + fe_reduce_wide carry fix):
    `48092b5`, `fa7c31e`
- Benchmark baseline: 9,520 jiffies / scalar mult (basepoint 9,
  VIC-II blanked).
