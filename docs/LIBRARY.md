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
- **Zero page:** the library owns `$14-$16`, `$1C`, `$1E-$2A`,
  `$2C-$2F`, and `$40-$7F` while running (85 bytes total,
  post-Phase-7). `$FB-$FE` is reserved for the test
  harness only and is NOT part of the library's claimed ZP
  surface. See `src/x25519.inc` for the full map. Each
  library-owned ZP equate in `src/constants.s` is wrapped in
  `.ifndef` so a host project composing multiple c64 crypto
  libraries can pre-define its own ZP layout before
  `.include`'ing `constants.s`; see §4.2.

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

## 4.1 Vendoring via the library archive

For downstream projects, the cleanest way to integrate is to build a
ca65/ld65 **library archive** and vendor it alongside the public header
and a linker-config fragment:

```
make lib          # produces build/lib/
make lib-verify   # smoke-tests the archive links against a stub
```

`make lib` produces `build/lib/`:

```
build/lib/
  libx25519.a                # ca65 archive (6 members)
  fe25519.o
  x25519.o
  x25519_init.o
  mul_8x8.o
  data.o
  util.o
  x25519.inc                 # public header copy
  cfg/x25519-example.cfg     # starter linker config fragment
```

The `libx25519.a` archive contains six members: `fe25519`, `x25519`,
`x25519_init`, `mul_8x8`, `data`, `util`. Individual `.o` files are
included alongside for callers who prefer not to link via archive.

To link against the archive from a downstream project, start from
`build/lib/cfg/x25519-example.cfg`, adjust for your memory layout,
and link:

```
ld65 -C your_config.cfg -o your_app.prg your_app.o build/lib/libx25519.a
```

**Important subtlety — archive-member resolution.** ld65 only pulls
an archive member into the link if some symbol from that member is
referenced. If your application does not reference any symbol from
a given library module (for example `util.o`, which provides
`vic_blank` / `bench_start`), that module will silently **not** be
linked. To force all library modules into the link, reference at
least one public symbol from each.

The canonical example of this technique is
`tests/lib_linkage/lib_linkage_stub.s`, which uses a `public_refs`
address table to force resolution of every library member. Use it as
a reference when building your own downstream integration.

`make lib-verify` runs this stub, links it against `libx25519.a`
via the example cfg, and greps the linked label file for a set of
sentinel public symbols. If the archive is broken (missing member,
unresolved import, name typo), `make lib-verify` fails — so running
it in CI provides a cheap smoke test that the archive is actually
usable.

## 4.2 Overriding the zero-page layout

Every library-owned ZP equate lives in `src/zp_config.s` (per
[c64-lib-contract §2](https://github.com/JC-000/c64-lib-contract/blob/master/SPEC.md#2-zero-page-contract))
and is wrapped in `.ifndef <name>` / `.endif`, so a host project that
wants to place the library's ZP scratch at different addresses can:

1. **Override via `--asm-define`** (recommended). Pass `--asm-define
   fe25519_src1=$40` on the `ca65` command line when building the
   library. All translation units that include `zp_config.s` see the
   override. The library must be rebuilt from source with the same
   `--asm-define` values for every `.o` file; the slot value is baked
   in at assemble time.

2. **Override via a wrapper `.s` file.** Pre-define the equate, then
   `.include "zp_config.s"` (or `.include "constants.s"`, which
   transitively pulls in `zp_config.s`).

3. **Reference from consumer modules via `.importzp`.** `zp_config.s`
   `.exportzp`-s every slot it owns, so a consumer module that wants
   to read the same address the library writes can simply
   `.importzp fe25519_src1` from its own `.s` files without
   `.include`-ing `constants.s` (which would also drag in BASIC /
   KERNAL / VIC / SID / CIA / REU hardware equates).

Wrapped equates (all inside `src/zp_config.s`, also `.exportzp`-ed):

- General scratch: `zp_ptr1`, `zp_tmp1`, `zp_tmp2`
- fe25519 working: `fe25519_src1`, `fe25519_src2`, `fe25519_dst`,
  `fe_carry`, `fe_loop`, `fe_mul_i`, `fe_mul_j`
- Phase 7 CT scratch (`fe25519_add` / `fe25519_sub` / `fe_cmp_p_ct`
  / `fe25519_reduce_final`): `fe_cmp_mask` (`$14`),
  `fe_subp_rhs` (`$15`), `fe_add_carry_mask` (`$16`)
- Phase 7 multiply chain: `mul_pending` (`$24`), `mul_bound`
  (`$25`), `mul_ripple_start` (`$2F`)
- x25519 working: `x25_prev_bit`, `x25_byte_idx`, `x25_bit_mask`,
  `fe_sqr_pairs`
- mul_8x8 working (reused by fe25519): `poly_carry`
- Wide product buffer: `fe_wide` (32-byte ZP region at `$40..$7F`,
  declared in `src/constants.s` with a hard-asserted link check —
  NOT host-overridable; CT/SMC invariant)

Non-library equates are **not** wrapped: KERNAL routines (`chrout`,
`getin`), hardware registers (`vic_*`, `cia1_*`, `sid_*`, `proc_port`),
KERNAL-defined system ZP (`kbd_buf_count`, `jiffy_clock`), REU
registers (`reu_*`), and the build-time threshold constant
`SQR_DMA_K` — the host cannot relocate any of these.

Example: to move `fe_wide` from `$40..$7F` to `$60..$9F` in a host
project that needs `$40..$5F` for its own data:

```ca65
; host_zp.inc — included before constants.s
fe_wide = $60

; host_app.s
.include "host_zp.inc"      ; pre-define fe_wide
.include "x25519.inc"       ; pulls in constants.s; our fe_wide wins
```

This pattern is consistent with the sibling c64 crypto libraries
(`c64-ChaCha20-Poly1305`'s `lib/constants_lib.s`) so a downstream
project composing multiple libraries has a single, uniform override
mechanism for the ZP layer.

Note that the outer `.ifndef CONSTANTS_S_INCLUDED` guard is
independent of the per-equate guards: it prevents the file from
being assembled twice if `.include`'d from multiple compilation
units. Host overrides must be defined *before* the first `.include
"constants.s"`.

## 4.3 Version constants

The library exports four integer equates per
[c64-lib-contract §1](https://github.com/JC-000/c64-lib-contract/blob/master/SPEC.md#1-version-identification):

| Symbol | Current value | Semantics |
|---|---|---|
| `LIB_VERSION_MAJOR` | `0` | semver major (breaking ABI change) |
| `LIB_VERSION_MINOR` | `5` | semver minor (additive ABI change) |
| `LIB_VERSION_PATCH` | `0` | semver patch (no ABI change) |
| `LIB_ABI_VERSION`   | `1` | coarse ABI compat level — tracks MAJOR |

Consumers should `.import` these and `.if`-guard at assemble time
against an unsupported library version:

```ca65
.import LIB_VERSION_MAJOR, LIB_VERSION_MINOR
.if LIB_VERSION_MAJOR <> 0 .or LIB_VERSION_MINOR < 5
    .error "this consumer needs c64-x25519 v0.5 or later"
.endif
```

The guard fires before the 30-minute link/test cycle, complementing
git-submodule SHA pinning with a defense-in-depth assert. The
equates live in `src/lib_version.s`.

## 4.4 Aggregate manifest equates

Per [c64-lib-contract §5](https://github.com/JC-000/c64-lib-contract/blob/master/SPEC.md#5-aggregate-manifest-equates),
the library exports four integer equates that let a consumer cfg do
assemble-time fit / collision checks before kicking off a long
compile + VICE test cycle:

| Symbol | Default value | What it reports |
|---|---|---|
| `LIB_X25519_ZP_USAGE_BYTES` | `85` | Total bytes of ZP slots the library claims (sum of `.exportzp`-ed slots in `src/zp_config.s` + the pinned `fe_wide` region) |
| `LIB_X25519_REU_BANKS_USED` | `$3B` default / `$03` for `lib-x25519-1764` | Bitmask of REU banks claimed for mul tables. **Default build** (banks 0, 1, 3, 4, 5): `$3B << X25519_REU_BANK`. **1764 variant** (`make lib-x25519-1764`, `SQR_DMA_K=0`): `$03 << X25519_REU_BANK` — banks 0, 1 only, drops the doubled-table cluster. Bank 2 is never claimed in either build. See [`REU_USAGE_ANALYSIS.md`](REU_USAGE_ANALYSIS.md) §"Group B SHIPPED" for the variant rationale + measured trade-offs |
| `LIB_X25519_RESIDENT_BYTES` | `9224` default / `9046` for `lib-x25519-1764` | Approximate code + data + sqtab footprint that must remain CPU-resident. Default −51 B vs v0.5.0 after bank-2 stash removal; 1764 variant −178 B further after the gated-out doubled-table init |
| `LIB_X25519_COLD_BYTES` | `0` | Approximate footprint that a consumer MAY overlay-page (currently 0 — no overlay candidates) |

The values are approximate ("within 5% is fine" per SPEC §5). The
library author refreshes them when a release substantively changes
any one of them.

**Consumer-side collision check** (composing c64-x25519 with
c64-nist-curves):

```ca65
.import LIB_NISTCURVES_REU_BANKS_USED
.import LIB_X25519_REU_BANKS_USED
.assert (LIB_NISTCURVES_REU_BANKS_USED .and LIB_X25519_REU_BANKS_USED) = 0, \
        error, "REU bank collision: relocate one library with -D"
```

**Consumer-side fit check** (against a ld65-published region size):

```ca65
.import LIB_X25519_RESIDENT_BYTES
.import __CRYPTO_HOT_SIZE__
.assert LIB_X25519_RESIDENT_BYTES < __CRYPTO_HOT_SIZE__, \
        error, "c64-x25519 does not fit in CRYPTO_HOT region"
```

## 4.5 Overriding the REU bank base

The library claims five REU banks for its precomputed multiplication
tables, within a six-bank allocation window (banks 0–5 at the default
base; bank 2 in the window is *not* claimed — see allocation table
below). Bank 7 is transiently touched by `reu_probe`. A consumer that
uses the REU for other purposes (P-256 precompute, ChaCha20 scratch,
etc.) can relocate the library's bank claim via `src/reu_config.s`
(per [c64-lib-contract §3](https://github.com/JC-000/c64-lib-contract/blob/master/SPEC.md#3-reu-layout-contract)).

Two exported equates, both `.ifndef`-guarded:

| Symbol | Default | What it controls |
|---|---|---|
| `X25519_REU_BANK` | `0` | Base bank for all six tables |
| `X25519_REU_OFFSET` | `$0000` | Within-bank base offset (currently must remain `$0000`; tables span full banks) |

**Bank allocation, relative to `X25519_REU_BANK`:**

```
  bank + 0   : 8x8->16 mul tables, lo+hi, for a =   0..127  (full bank)
  bank + 1   : 8x8->16 mul tables, lo+hi, for a = 128..255  (full bank)
  bank + 2   : unused (legacy reu_clear_wide stash removed in v0.6 prep)
  bank + 3   : 17th-bit carry bytes for doubled tables (256 B/row)
  bank + 4   : pre-doubled mul tables, lo+hi, a =   0..127  (full bank)
  bank + 5   : pre-doubled mul tables, lo+hi, a = 128..255  (full bank)
```

The library also transiently touches `bank + 7` during `reu_probe`,
restoring it before the probe returns.

**Override usage:**

```sh
ca65 -D X25519_REU_BANK=3 -o build/x25519_init.o src/x25519_init.s
# ...rebuild every library .o with the same -D, then re-archive.
```

The override must be applied to every library translation unit
because the bank constant is baked in at assemble time. The
library's own `make` / `make lib` always uses the default. Consumer
projects rebuild from source with their preferred bank base.

`X25519_REU_OFFSET` is published as a contract-compliance equate;
the current library implementation places each table at offset 0
within its bank, so the override has no effect today. It exists so
consumers can assert against it; a future release may honor it.

## 4.6 Shared quarter-square table (c64-lib-contract §8.1)

c64-x25519 v0.6 adopts the **c64-lib-contract §8.1 shared-primitives
clause** for the 8×8 quarter-square multiplication table. The 1024-
byte `sqtab_lo` / `sqtab_hi` region is now placed via a single shared
equate that every adopter agrees on, so multi-lib PRGs link one
canonical table instead of N copies at N addresses.

The shared equate, defaulted in `src/constants.s`:

```ca65
.ifndef LIB_SHARED_SQTAB_BASE
  LIB_SHARED_SQTAB_BASE = $7800
.endif
sqtab_lo = LIB_SHARED_SQTAB_BASE
sqtab_hi = LIB_SHARED_SQTAB_BASE + $0200
.assert (sqtab_lo & $00ff) = 0, error, "must be page-aligned"
.assert sqtab_hi = sqtab_lo + $0200, error, "SMC dispatch contract"
```

Override base via `ca65 --asm-define LIB_SHARED_SQTAB_BASE=$N`
(applied to every library translation unit). The asserts catch any
override that breaks page-alignment or the +`$0200` lo→hi delta that
`mul_8x8`'s SMC dispatch depends on.

### Canonical init entry

```
mul_tables_init  = sqtab_init     ; (alias, same proc)
```

Both names resolve to the same routine. `mul_tables_init` is the
c64-lib-contract canonical name; `sqtab_init` is the library's
historical name. New code should use `mul_tables_init`.

### `SHARED_SQTAB_INIT` migration gate

When a multi-lib PRG wants exactly one of the linked libraries to own
the table-build, pass `-D SHARED_SQTAB_INIT=1` to every c64-x25519
translation unit at build time. With that define set:

- c64-x25519's `sqtab_init` / `mul_tables_init` body collapses to an
  immediate `rts`. The public symbol still resolves, so existing
  callers don't break.
- The host program is responsible for calling some other library's
  `mul_tables_init` (e.g., c64-https's canonical implementation)
  before any c64-x25519 field op runs.

Standalone builds (no `-D SHARED_SQTAB_INIT`) build the table
themselves, as before. **This is the default**; nothing changes for a
single-lib consumer.

### `LIB_X25519_SHARED_PRIMITIVES` manifest

The library exports a §5 manifest bitmask of the shared primitives it
consumes:

```ca65
LIB_SHARED_PRIMITIVES_SQTAB  = $0001     ; c64-lib-contract §8.1 bit
LIB_X25519_SHARED_PRIMITIVES = LIB_SHARED_PRIMITIVES_SQTAB
```

A consumer composing c64-x25519 with another sqtab-using library can
detect the unhandled-double-build case at assemble time:

```ca65
.import LIB_X25519_SHARED_PRIMITIVES
.import LIB_OTHER_SHARED_PRIMITIVES
.assert (LIB_X25519_SHARED_PRIMITIVES .and \
         LIB_OTHER_SHARED_PRIMITIVES) = 0, error, \
        "both libs claim a §8 primitive; define SHARED_SQTAB_INIT in one"
```

## 4.7 The `lib-x25519-1764` build variant (v0.6+)

For consumers targeting a stock 1764 (256 KB REU) instead of the
default 1750 (512 KB), `make lib-x25519-1764` produces a parallel
archive under `build-1764/lib/` that drops the pre-doubled
multiplication tables in banks 3/4/5. Trade: **+16.2 % scalarmult
cost in exchange for −192 KB REU + −178 B CODE**, plus the minimum
REU spec drops from 512 KB to 256 KB.

```sh
make lib-x25519-1764      # build the variant
ls build-1764/lib/        # libx25519.a + .o files + x25519.inc + cfg
```

Manifest equates in the variant archive report the smaller claim:

| Equate | Default build | 1764 variant |
|---|---|---|
| `LIB_X25519_REU_BANKS_USED` | `$3B` (banks 0, 1, 3, 4, 5) | `$03` (banks 0, 1) |
| `LIB_X25519_RESIDENT_BYTES` | `9224` | `9046` |
| `LIB_X25519_ZP_USAGE_BYTES` | `85` | `85` (unchanged) |
| `LIB_VERSION_*` | `0.6.x` | `0.6.x` (same source tree) |

Mechanism: a single `-D SQR_DMA_K=0` define (threaded through
`$(CA65FLAGS)` in the Makefile) makes `fe25519_sqr`'s `bcs
@sqr_use_mult66` always taken, so the DMA dispatch never fires. The
matching `.if ::SQR_DMA_K` guards in `src/x25519_init.s:reu_mul_init`
and `src/lib_version.s` then gate out the doubled-table generation
+ stash sections and re-emit the smaller bank/resident equates.

The default build is unchanged at the source level — the variant is
opt-in. Downstream projects vendoring the source can rebuild either
form from the same tree by toggling the make target.

See [`docs/REU_USAGE_ANALYSIS.md`](REU_USAGE_ANALYSIS.md) for the
full cost-benefit analysis and the measured A/B results.

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
| `vic_blank` / `vic_unblank` | Toggle VIC-II display (speed)           |
| `bench_start` / `bench_stop` | Jiffy-clock timing                     |

All `fe25519_*` routines take operand pointers in ZP slots `fe25519_src1` (`$1E`),
`fe25519_src2` (`$20`), `fe25519_dst` (`$22`). Fill those, then `jsr`.

## 6. Buffer alignment contract

**32-byte field buffers MUST be page-aligned to one of the offsets
`$00, $20, $40, $60, $80, $A0, $C0, $E0` within a 256-byte page.**

This is a hard requirement of the optimized routines
(`fe25519_add`, `fe25519_sub`, `fe25519_reduce_final`) which use
self-modifying `abs,Y` addressing and depend on `Y in [0..31]` never
crossing a page boundary. Violating this alignment will produce
silently wrong results.

All library-provided buffers (`x25_scalar`, `x25_u`, `x25_result`,
`fe25519_tmp{1,2,3}` and `fe25519_tmp4`, `x25_a/b/da/cb/e`, `x25_x2/x3`, `x25_z2/z3`) are
allocated with the correct alignment in `src/data.s`. If you add
your own field buffers, use `.align 32` followed by `.res 32, 0`.

## 7. Memory map

```
$0001           proc_port (BASIC ROM banked out)
$0014-$0016     fe_cmp_mask / fe_subp_rhs / fe_add_carry_mask (Phase 7 CT scratch)
$001C           poly_carry (mul_8x8 / fe25519 reuse)
$001E-$002A     fe25519_src1/src2/dst, fe_carry, fe_loop, fe_mul_i/j, x25_prev_bit, x25_byte_idx, x25_bit_mask
$0024-$0025     mul_pending / mul_bound (Phase 7, in freed fe_misc range)
$002C-$002F     x25 scratch + fe_sqr_pairs + mul_ripple_start
$0040-$007F     fe_wide (32-byte ZP product accumulator; ZP-pinned by .assert)
$00A0-$00A2     jiffy clock (read by bench_*; masked under x25519_scalarmult sei)
$00C6           kbd buffer count (test harness only)
$00FB-$00FC     zp_ptr1 (test harness only — NOT part of library ZP claim)
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
REU bank 2      unused (legacy zero stash removed in v0.6 prep)
REU bank 3      17th-bit carry tables for fe25519_sqr
REU bank 4-5    2*a*b low/high tables for fe25519_sqr
```

Exact addresses can be read from `build/labels.txt` after a build.

## 8. Performance

Cycle-exact numbers as of v0.6.0 (2026-05-20). Measured via the CIA1
32-bit cycle counter (`bench_cycles_*` in `src/util.s`); reproducible
deterministically under VICE warp, hardware-confirmed on Ultimate-64
NTSC.

### Default build (`make`, `make lib`)

| Operation                       | Cycles      | Jiffies     | Wall-time NTSC | PAL    |
| ------------------------------- | ----------: | ----------: | -------------: | -----: |
| `x25519_scalarmult` (basepoint) | 261,681,380 |    15,352.0 |       ~255.9 s | ~307.1 s |
| `fe25519_mul`     (batch=200)   |      94,737 |       5.558 |              — | —      |
| `fe25519_sqr`     (batch=200)   |     102,023 |       5.985 |              — | —      |
| `fe25519_mul_a24` (batch=200)   |       7,569 |       0.444 |              — | —      |
| `fe25519_add`                   |       2,192 |       0.129 |              — | —      |
| `fe25519_sub`                   |       1,664 |       0.098 |              — | —      |
| `fe25519_reduce_final`          |       2,996 |       0.176 |              — | —      |
| `fe25519_cswap`                 |       1,522 |       0.089 |              — | —      |
| `fe25519_inv` (single-call avg) | ≈28,766,000 |     1,687.6 |              — | —      |

### 1764 build variant (`make lib-x25519-1764`)

For consumers targeting a stock 1764 (256 KB REU). Trade: +16.2 %
scalarmult cost for −192 KB REU + −178 B CODE; see §4.7 and
`docs/REU_USAGE_ANALYSIS.md`.

| Operation                       | Cycles      | Jiffies     | Δ vs default |
| ------------------------------- | ----------: | ----------: | -----------: |
| `x25519_scalarmult` (basepoint) | 304,179,528 |    17,845.2 | +16.2 %      |
| `fe25519_sqr`     (batch=200)   |     135,381 |       7.939 | +32.7 %      |
| `fe25519_mul`     (batch=200)   |      94,737 |       5.558 | 0 (mul path unchanged) |
| Other ops                       |   unchanged |   unchanged | 0            |

### Historical baselines

| Release | Scalarmult (jif) | Δ vs v0.3.0 baseline       | Note                                   |
| ------- | ---------------: | -------------------------- | -------------------------------------- |
| v0.1.0  |            9,520 |                            | Pre-CT-closure baseline                |
| v0.2.0  |           12,485 | +3.4 % (vs v0.3.0)         | L1-L22 full CT closure (+31.1 % cost)  |
| v0.3.0  |           12,070 | (baseline)                 | Perf recovery + L23/L24 closure        |
| v0.4.0  |           15,350 | +27.2 %                    | L25-L29 full CT closure + state defences |
| v0.5.0  |           15,350 | +27.2 %                    | c64-lib-contract §1/§2/§3/§5 (no behaviour change) |
| v0.6.0  |           15,352 | +27.2 %                    | Group C bank-2 drop (-51 B), §8 sqtab adoption, bench rehab (RAM only; runtime within 0.02 %) |

The +0.02 % shift across v0.5.0 → v0.6.0 is pure code-layout noise
from the bank-2 stash removal (commit `71cc1aa`); no CT or correctness
change. RFC 7748 vec-0 PASS at every release.

The append-only perf log lives at [`docs/perf_history.csv`](perf_history.csv)
and is consumed by `tools/perf_diff.py` for diff tables. Run
`make bench-record` to append a row for the current source tree;
`make perf-diff` for the markdown delta vs the previous row.

### Methodology

- VIC-II blanked (`jsr vic_blank` before the timed region); a display-
  active run costs ~20-25 % more cycles due to VIC-II DMA badlines.
- `x25519_scalarmult` self-masks IRQs internally (PR #35 `php / sei …
  plp` wrap), so the kernal jiffy clock at `$A0-$A2` is frozen during
  the call. Use `bench_cycles_start` / `bench_cycles_stop` (CIA1 phi2
  counter, sei-safe) for any timing through `scalarmult`. The older
  `bench_start` / `bench_stop` jiffy helpers were restored to a
  self-contained `php / plp` shape in v0.6.0 (#55) and now work for
  non-scalarmult callers; **the v0.4.0 / v0.5.0 README numbers for
  `fe25519_*` per-op timings were stale from before that regression**.
- Per-op batch averages divide CIA1 cycles for 200 back-to-back
  calls by 200, after subtracting the constant per-batch scaffold
  (jsr/dec/bne ≈ 14 cy/iter, well below the per-op noise floor).
- One scalar multiplication performs **5 mul + 1 mul_a24 + 4 sqr**
  per ladder step × 255 bit positions, plus **254 sqr + 11 mul** in
  `fe25519_inv` (Fermat addition chain for 2^255 - 21) = roughly
  **1,286 muls + 1,274 sqrs** total. (The "763 sqrs" figure that
  appeared in `tools/bench_fe_mul.py` comments through v0.5.0 was
  stale — corrected in v0.6.0 via the SQR_DMA_K=0 A/B measurement;
  see `docs/REU_USAGE_ANALYSIS.md`.)
- All per-proc CT cycle-count guards (`tools/test_ct_*_cycles.py`
  in `make test-vice` / `test-slow`) report measured spreads ≤ 0.005
  jif/call across structurally distinct inputs, well under the 1.0
  jif threshold. **These guards were silently trivially passing
  (0 jif spread = 0 < 1.0) from PR #39 through v0.5.0**; they
  actually measure as of v0.6.0 (#55).

- **Full side-channel posture (v0.4.0).** All 29 catalogued leak
  families (L1-L29 in `docs/CT_ANALYSIS.md`) are now closed.
  L1-L22 landed in v0.2.0 (branchless CT `mul_8x8` + `fe25519_sqr`
  mult66 rewrite + zero-skip removal + Phase 6 carry-chain).
  L23a/b/c landed in v0.3.0 (PR #31, `fe25519_sqr` `@diag_prop`
  diagonal carry path Phase-6-style unconditional ripple).
  L24a/b landed in v0.3.0 (PR #30, branchless `cmp/sbc/eor`
  bit-to-mask in the `x25519_scalarmult` Montgomery ladder
  bit loop). **L25 / L26a-d / L27a-f / L28a-k / L29a-e land in
  v0.4.0 (Phase 7)** — closes the field-op surface beyond
  `fe25519_sqr`: `fe25519_mul`, `fe_reduce_wide`,
  `fe25519_mul_a24`, `fe25519_add`, `fe25519_sub`, `fe_cmp_p`,
  `fe25519_reduce_final` all rewritten with the four Phase 7
  closure templates (`lda#0/sbc#0/eor#$FF` mask + masked sub-p
  tail; Phase-6 Option F per-body pending chain;
  `dey/bne` cascades gated by `mul38_lo_tab[0]=0`;
  `fe_carry`-threaded reduction stages). `fe25519_cswap` remains
  CT-clean by inspection. v0.4.0 is the first release where the
  **entire `fe25519_*` / `mul_8x8` / `x25519_scalarmult` surface
  is CT-clean** for network-facing deployments where the scalar
  is a long-lived ECDH private key. Per-proc CT cycle-count
  guards in `make test-vice` (4 new in Phase 7 plus
  `test_ct_square_cycles.py`) report spreads of 0.000-0.01 jif
  across structurally distinct inputs, all well under the
  1.0 jif threshold.
- **No RNG.** Key generation is the caller's job. The library does
  not seed or consume randomness. `x25519_base` expects the scalar
  to already be in `x25_scalar`.
- **No key derivation / HKDF / anything beyond the raw scalar mult.**
- **REU is mandatory.** There is no fallback to pure-6502 multiply.
- **Interrupts.** `x25519_scalarmult` is now wrapped in `php / sei …
  plp` (PR #35) — IRQs are library-masked for the full call and the
  caller's I-flag is restored on exit. NMIs are NOT masked by `sei`
  (RESTORE key, CIA2 TimerB, U64E firmware NMI hooks); if your host
  installs an NMI handler that touches the library's owned ZP bytes
  (`$1A-$2E`, `$40-$7F`), mask those NMI sources at their source for
  the duration of the call. The other library entry points
  (`fe25519_*`, `x25519_clamp`, `x25519_base`) do not self-mask;
  callers are responsible.
- **REU register state.** As of PR #36 (issue #33 fix),
  `x25519_scalarmult` defensively re-initialises `reu_reu_lo` ($DF04)
  and `reu_addr_ctrl` ($DF0A) to `$00` at entry, so caller residue
  on those two registers is harmless. The other REU registers
  (`reu_c64_lo/hi`, `reu_len_lo/hi`, `reu_reu_hi`, `reu_reu_bank`)
  are re-written by `reu_clear_wide` and the inlined per-row DMA in
  `fe25519_mul`, so caller residue on those is also tolerated.
  However, the library still leaves the REU registers in a
  non-default state on return (configured for `reu_fetch_mul_row`).
  If your host needs a clean post-call state for its own REU work,
  save `$DF02-$DF0A` before calling and restore afterward.

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
- Recent history:
  - **v0.3.0 (2026-04-19)** — perf-recovery + full-CT-certification
    release. Phases 1–3 rewrite `fe25519_sqr`'s hot path without
    touching any CT invariant: SMC-literal hoist + register-threaded
    abs-math (Phase 1, −247 jif), `SQR_DMA_K` retune 14→22 (Phase 2,
    −347 jif), chain-step address-math + ripple-setup fold (Phase 3,
    −1,152 jif). Phase 0 ships a CT cycle-count regression guard
    (`tools/test_ct_square_cycles.py`) running in `make test-slow` /
    `make test-vice`. Phases 4 and 5 investigated and SKIPPED (below
    100-jif ship threshold). On top of the perf recovery, two audit
    closures land: PR #31 closes L23a/b/c in `fe25519_sqr`'s
    `@diag_prop` diagonal-term carry path (Phase-6-style
    unconditional ripple, +1,330 jif); PR #30 closes L24a/b in the
    `x25519_scalarmult` Montgomery ladder bit loop (branchless
    `cmp/sbc/eor` bit-to-mask idiom, 0 jif). `fe25519_cswap` is
    verified CT-clean by inspection. **All 24 L1–L24 leaks are now
    closed** — first release with full field-op + outer-ladder
    side-channel posture. Net vs v0.2.0: −415 jif (−3.3 %) and
    fully CT-certified. ~32.9 % faster than the un-optimized
    ~18,000 jif baseline. Public API unchanged from v0.2.0.
  - **v0.2.0 (2026-04-19)** — full CT
    remediation of issue #20, Phases 0–6: L1–L22 all fixed.
    Branchless CT `mul_8x8`, inline CT `fe25519_sqr` mult66 rewrite,
    zero-skip removals across `fe25519_mul` / `fe25519_sqr`, and
    Option F pending-carry-chain elimination of the carry-cascade
    short-circuits. Correctness prioritized over performance;
    +31.1 % scalarmult regression accepted. See
    `docs/CT_ANALYSIS.md`.
  - **v0.1.0 (2026-04-13)** — tagged release. Phase 9 tables/unroll/
    alignment + Phase 10 mul/sqr/inv micro-opts + fe_reduce_wide
    carry fix.
- Benchmark history: 18,000 jiffies (pre-optimization) →
  9,520 jiffies (v0.1.0) → 12,485 jiffies (v0.2.0; full CT
  L1–L22) → 12,070 jiffies (v0.3.0; Phases 1–3 `fe25519_sqr`
  hot-path rewrite recovering 1,746 jif, plus L23 + L24 audit
  closures costing back ~1,330 jif for full field-op +
  outer-ladder CT posture).
