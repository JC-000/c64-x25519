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
- **REU:** **512 KB REU required** for the default build (a Commodore
  1750 or equivalent, or any REU/compatible with at least 6 banks of
  64 KB). The library pre-computes full 8x8->16 multiplication tables
  into REU banks 0-5. Two build variants lower this: `lib-x25519-1764`
  drops the requirement to 256 KB (§4.7), and `lib-x25519-onchip`
  removes it entirely — that profile issues no REU traffic at all and
  runs on a stock expansion-less C64, at a stock-clock speed cost
  (§4.11).
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

Per c64-lib-contract SPEC §4 (v0.8+, issue #70), the library sources
emit only `LIB_X25519_`-prefixed segments: hot code in
`LIB_X25519_CODE`, mutable data in `LIB_X25519_DATA` (page-aligned;
CT-load-bearing `align = 256`), and init-only code in
`LIB_X25519_INIT_CODE` (issue #68). Only `src/main.s` — the test
harness, not part of the library — uses the plain `CODE` segment.

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

`your_config.cfg` MUST declare the three library segments (v0.8+):
`LIB_X25519_CODE`, `LIB_X25519_DATA` (with `align = 256` — a CT
invariant, see §6), and `LIB_X25519_INIT_CODE` (see §4.10) — ld65
hard-errors on any input segment without a memory-area assignment.
Your own code and data can use whatever segment names you like
(plain `CODE`/`DATA` included). Start from
`cfg/x25519-example.cfg`, which declares all three with the correct
ordering (file-emitting segments before bss-type ones).

**Cfg attributes the library depends on** (contract #63 class: the
consumer authors `SEGMENTS{}`, the library silently depends on it —
know each one's failure mode; measured on ld65 V2.18):

| Segment / region | Required attribute | If wrong |
|---|---|---|
| `LIB_X25519_DATA` | `align = 256` | **Hard link error** (`lderror` asserts in `src/data.s` / `src/reu_config.s`: "must be page-aligned (CT invariant)"). Cannot ship misaligned. |
| `LIB_X25519_DATA` | file-emitting `type` (`rw`), in a file-backed area | `type = bss` links with only a **warning** ("segment with type 'bss' contains initialized data") and silently drops ~3.7 KB of tables, constants, and buffers from the PRG — the binary shrinks and every field op reads garbage. |
| `LIB_X25519_INIT_CODE` | last file-emitting segment, declared **before** any bss-type segment | Links **clean with zero diagnostics**; the init code loads `__BSS_SIZE__` bytes below its linked address and `jsr sqtab_init` executes consumer data (design-doc R5). No machine check exists — ordering discipline only. |
| `SQTAB` MEMORY region | base equal to `LIB_SHARED_SQTAB_BASE` (default `$7800`), 1 KB reserved | **Fully silent.** No source emits into the SQTAB segment; `sqtab_lo`/`sqtab_hi` are equates off `LIB_SHARED_SQTAB_BASE`, and `sqtab_init` writes 1 KB at the *equate* address no matter what the cfg reserves. Moving/dropping the region, or growing MAIN past `$7800`, without the matching `-D LIB_SHARED_SQTAB_BASE=` override = clean link + 1 KB overwrite of live data at init. Keep the MEMORY block and the `-D` value in lockstep. |

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
make lib                # produces build/lib/
make lib-verify         # smoke-tests the archive links against a stub
make lib-verify-shared  # same, for the four §8.x SHARED_* deferral builds
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

1. **Override via `ca65 -D`** (recommended). Pass `-D
   fe25519_src1=$40` on the `ca65` command line when building the
   library. All translation units that include `zp_config.s` see the
   override. The library must be rebuilt from source with the same
   `-D` values for every `.o` file; the slot value is baked in at
   assemble time. (`-D name[=value]` is ca65's actual symbol-define
   flag per SPEC v0.7.1 §2 — `--asm-define` is `cl65`'s spelling and
   is rejected by a direct `ca65` invocation.)

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
[c64-lib-contract §1](https://github.com/JC-000/c64-lib-contract/blob/master/SPEC.md#1-version-identification)
(v0.7.0 library-prefixed forms):

| Symbol | Current value | Semantics |
|---|---|---|
| `LIB_X25519_VERSION_MAJOR` | `0` | semver major (breaking ABI change) |
| `LIB_X25519_VERSION_MINOR` | `10` | semver minor (additive ABI change) |
| `LIB_X25519_VERSION_PATCH` | `0` | semver patch (no ABI change) |
| `LIB_X25519_ABI_VERSION`   | `2` | monotonic generation counter for the exported surface (contract v0.7.5) — bumped on any breaking export change, independent of MAJOR; the load-bearing consumer breakage gate pre-1.0. `1 → 2` at v0.10.0 acknowledges the v0.9.0 `LIB_SHARED_PRIMITIVES_*` export removal |

Consumers should `.import` these and gate with `.assert`/`lderror`
(SPEC v0.8.1 §1):

```ca65
.import LIB_X25519_VERSION_MAJOR, LIB_X25519_VERSION_MINOR
.assert (LIB_X25519_VERSION_MAJOR > 0) .or (LIB_X25519_VERSION_MINOR >= 10), lderror, "this consumer needs c64-x25519 v0.10 or later"
```

And the load-bearing breakage gate on the exported-surface generation:

```ca65
.import LIB_X25519_ABI_VERSION
.assert LIB_X25519_ABI_VERSION = 2, lderror, "c64-x25519 exported-surface generation changed; re-check the integration"
```

(Snippets are deliberately single-line: ca65 rejects `\` line
continuation with `Invalid input character` unless the consumer
enables `.linecont +`.)

**Not `.if`/`.error`** — an `.import`ed symbol has no value until
link, so ca65 rejects an `.if` guard outright with `Constant
expression expected`; an `.if`-based version gate never assembles at
all. `.assert` with the `lderror` action defers evaluation to ld65.
The guard therefore fires at link rather than assemble time — still
before the multi-minute VICE test cycle and before anything runs —
complementing git-submodule SHA pinning with a defense-in-depth
assert.

The unprefixed `LIB_VERSION_{MAJOR,MINOR,PATCH}` / `LIB_ABI_VERSION`
aliases are still exported by default but **deprecated** (contract
v0.7.0; removed at contract v1.0): they are identical across every
contract library, so two libraries in one link collide on them. A
consumer composing c64-x25519 with any other contract library builds
every library — and assembles its own imports — with
`ca65 -D LIB_NO_BARE_EXPORTS=1`, which suppresses the bare aliases,
and uses the prefixed forms only.

The equates live in `src/lib_version.s`, a translation unit that
exports *nothing else* (SPEC v0.7.0 §1 TU isolation): ld65 links whole
object members, so the deprecated bare names must not share a member
with symbols a consumer legitimately imports. The §4.4/§4.7 manifest
surface lives in `src/lib_manifest.s`.

## 4.4 Aggregate manifest equates

Per [c64-lib-contract §5](https://github.com/JC-000/c64-lib-contract/blob/master/SPEC.md#5-aggregate-manifest-equates),
the library exports four integer equates that let a consumer cfg do
assemble-time fit / collision checks before kicking off a long
compile + VICE test cycle:

| Symbol | Default value | What it reports |
|---|---|---|
| `LIB_X25519_ZP_USAGE_BYTES` | `85` | Total bytes of ZP slots the library claims (sum of `.exportzp`-ed slots in `src/zp_config.s` + the pinned `fe_wide` region) |
| `LIB_X25519_REU_BANKS_USED` | `$3B` default / `$03` for `lib-x25519-1764` / `0` for `lib-x25519-onchip` | Bitmask of REU banks claimed for mul tables. **Default build** (banks 0, 1, 3, 4, 5): `$3B << X25519_REU_BANK`. **1764 variant** (`make lib-x25519-1764`, `SQR_DMA_K=0`): `$03 << X25519_REU_BANK` — banks 0, 1 only, drops the doubled-table cluster. Bank 2 is never claimed in either build. **onchip variant** (`make lib-x25519-onchip`, `X25519_ONCHIP_MUL=1`): plain `0` — no shift, no banks. Per SPEC §5 the zero *is* the "no REU" declaration, not an unset field; see §4.11. See [`REU_USAGE_ANALYSIS.md`](REU_USAGE_ANALYSIS.md) §"Group B SHIPPED" for the 1764 rationale + measured trade-offs |
| `LIB_X25519_RESIDENT_BYTES` | `8383` default / `8247` for `lib-x25519-1764` / `8207` for `lib-x25519-onchip` | Approximate code + data + sqtab footprint that must remain CPU-resident. Dropped from 9209/8895 at the issue-#68 cold-segment split — the init-only code is now counted in `LIB_X25519_COLD_BYTES` (SPEC §5 disjoint partition; see §4.10). All three figures od65-measured; the onchip value has been measured-exact since the profile shipped in v0.8.0 |
| `LIB_X25519_COLD_BYTES` | `826` default / `648` for `lib-x25519-1764` / `160` for `lib-x25519-onchip` | Approximate footprint a consumer MAY reclaim/overlay after init — the `LIB_X25519_INIT_CODE` segment (issue #68; see §4.10). The onchip segment holds `sqtab_init` alone, so it is much smaller |

The values are approximate ("within 5% is fine" per SPEC §5), though
all nine profile figures are currently od65-measured exact. The
library author refreshes them when a release substantively changes
any one of them; `make lib-x25519-onchip` / `lib-x25519-1764` print
the per-object segsize dump used for the refresh.

**Consumer-side collision check** (composing c64-x25519 with
c64-nist-curves):

```ca65
.import LIB_NISTCURVES_REU_BANKS_USED
.import LIB_X25519_REU_BANKS_USED
.assert (LIB_NISTCURVES_REU_BANKS_USED & LIB_X25519_REU_BANKS_USED) = 0, \
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

Override base via `ca65 -D LIB_SHARED_SQTAB_BASE=$N`
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

The library exports a §5 manifest bitmask of the shared primitives
this build *owns*. Per c64-lib-contract SPEC v0.4.0 §8.0 the mask is
**conditional**: each primitive's bit is set iff the build did NOT
define that primitive's deferral switch, so a build that defers a
primitive to a canonical provider drops the bit. For the sqtab bit:

```ca65
LIB_SHARED_PRIMITIVES_SQTAB  = $0001     ; c64-lib-contract §8.1 bit
; set in LIB_X25519_SHARED_PRIMITIVES unless SHARED_SQTAB_INIT is defined
```

The per-primitive bit constants (`LIB_SHARED_PRIMITIVES_SQTAB` etc.)
are **assemble-time equates, not link symbols** (issues #77/#78):
every §8 adopter carries the same names and values, and only exported
symbols can collide at link time. They arrive via `x25519.inc` as
`.ifndef`-guarded local equates; do not `.import` them.

A consumer composing c64-x25519 with another sqtab-using library can
detect the unhandled-double-build case at link time (the operands are
imported, so evaluation defers to ld65 — `lderror` per SPEC v0.8.1):

```ca65
.import LIB_X25519_SHARED_PRIMITIVES
.import LIB_OTHER_SHARED_PRIMITIVES
.assert (LIB_X25519_SHARED_PRIMITIVES & LIB_OTHER_SHARED_PRIMITIVES) = 0, lderror, "both libs claim a §8 primitive; define SHARED_SQTAB_INIT in one"
```

With the conditional mask this assert *passes* once exactly one lib
owns each shared primitive — the deferring side's bit drops out
instead of tripping the assert on legitimate sharing
(c64-lib-contract#21).

**Companion mask `LIB_X25519_SHARED_CONSUMES`** (SPEC v0.5.0,
issues #78/#81): bit set iff this build configuration *consumes* the
primitive at all. A `SHARED_*` deferral switch clears the ownership
bit but NOT the consumes bit (the build still reads the primitive and
needs exactly one owner in the link plus boot-time init); a profile
gate (`X25519_ONCHIP_MUL`) clears both. This distinguishes the two
builds that both report `LIB_X25519_SHARED_PRIMITIVES = $0005`:

| Build | `SHARED_PRIMITIVES` | `SHARED_CONSUMES` |
|---|---|---|
| standalone default / 1764 | `$0007` | `$0007` |
| any `SHARED_*` deferral | bit(s) dropped | `$0007` |
| `X25519_ONCHIP_MUL` profile | `$0005` | `$0005` |

The consumer-side coverage assert then closes the composition story —
every consumed primitive has an owner somewhere in the link:

```ca65
.import LIB_X25519_SHARED_CONSUMES, LIB_OTHER_SHARED_CONSUMES
.assert ((LIB_X25519_SHARED_CONSUMES | LIB_OTHER_SHARED_CONSUMES) & ~(LIB_X25519_SHARED_PRIMITIVES | LIB_OTHER_SHARED_PRIMITIVES)) = 0, lderror, "consumed shared primitive with no owner in the link"
```

(Bitwise `&`/`|`/`~`, not the boolean `.and`/`.or` — on multi-bit
masks the boolean forms collapse operands to 0/1 and pass/fail on the
wrong condition; c64-lib-contract#41.)

The library pins the adopter-side subset invariant
(`OWNED ⊆ CONSUMED`) at assemble time in `src/lib_manifest.s`.

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
| `LIB_X25519_RESIDENT_BYTES` | `8383` | `8247` |
| `LIB_X25519_COLD_BYTES` | `826` | `648` |
| `LIB_X25519_ZP_USAGE_BYTES` | `85` | `85` (unchanged) |
| `LIB_VERSION_*` | `0.7.x` | `0.7.x` (same source tree) |

The `RESIDENT_BYTES` pair was `9224` / `9046` before the issue-#68
cold-segment split moved the init-only procs into
`LIB_X25519_INIT_CODE`; the `−178 B CODE` figure quoted above and in
`docs/REU_USAGE_ANALYSIS.md` is the difference between those two
pre-split values. Post-split the two partitions are disjoint (SPEC §5)
and must be compared separately — see §4.4 and §4.10.

Mechanism: a single `-D SQR_DMA_K=0` define (threaded through
`$(CA65FLAGS)` in the Makefile) makes `fe25519_sqr`'s `bcs
@sqr_use_mult66` always taken, so the DMA dispatch never fires. The
matching `.if ::SQR_DMA_K` guards in `src/x25519_init.s:reu_mul_init`
and `src/lib_manifest.s` then gate out the doubled-table generation
+ stash sections and re-emit the smaller bank/resident equates.

The default build is unchanged at the source level — the variant is
opt-in. Downstream projects vendoring the source can rebuild either
form from the same tree by toggling the make target.

See [`docs/REU_USAGE_ANALYSIS.md`](REU_USAGE_ANALYSIS.md) for the
full cost-benefit analysis and the measured A/B results.

## 4.8 Shared REU multiplication table (c64-lib-contract §8.2)

c64-x25519 v0.7-prep adopts the **c64-lib-contract §8.2 shared-primitives
clause** for the 128 KB 8×8→16 REU multiplication table. The two REU
banks holding `(a, b) → a × b` rows are placed via a single shared
equate that every adopter agrees on, so multi-lib PRGs claim one
canonical bank pair instead of duplicating.

The shared equate, defaulted in `src/reu_config.s`:

```ca65
.ifndef LIB_SHARED_REU_MUL_BANK
  LIB_SHARED_REU_MUL_BANK = X25519_REU_BANK   ; (default $00)
.endif
.ifndef LIB_SHARED_REU_MUL_OFFSET
  LIB_SHARED_REU_MUL_OFFSET = $0000
.endif
LIB_SHARED_REU_MUL_BANKS_USED = \
    (1 .shl LIB_SHARED_REU_MUL_BANK) | \
    (1 .shl (LIB_SHARED_REU_MUL_BANK + 1))
.assert LIB_SHARED_REU_MUL_OFFSET = $0000, error, ...
.assert LIB_SHARED_REU_MUL_BANK < $FE,    error, ...
```

Override the base bank via `ca65 -D LIB_SHARED_REU_MUL_BANK=$N`
(applied to every library translation unit). `_OFFSET` is pinned to
`$0000` per a v0.x.0 SPEC constraint; loosen only on a justified non-
zero need from a future adopter. `_BANKS_USED` is a derived equate
naming both claimed banks (`base` and `base + 1`) as a single mask;
consumers compose it into their REU-region `.assert` budget.

In addition to the placement equates, `src/reu_config.s` publishes the
ZP scratch + page-aligned staging-buffer surface:

```ca65
LIB_SHARED_REU_MUL_ZP_INIT_A / _B    ; alias reu_init_a / _b
LIB_SHARED_REU_MUL_STAGE_LO / _HI    ; alias mul_dma_lo / mul_dma_hi
                                     ; (page-aligned, _HI = _LO + $0100)
```

with the page-alignment and adjacency asserts the §8.2 fetch primitive's
4×-unrolled `abs,y` loop depends on.

### Canonical init entry

```
reu_mul_tables_init = reu_mul_init   ; (alias, same proc)
```

Both names resolve to the same routine. `reu_mul_tables_init` is the
c64-lib-contract canonical name; `reu_mul_init` is the library's
historical name.

### `SHARED_REU_MUL_INIT` migration gate

When a multi-lib PRG wants exactly one of the linked libraries to own
the table-build, pass `-D SHARED_REU_MUL_INIT=1` to every c64-x25519
translation unit at build time. With that define set:

- c64-x25519's `reu_mul_init` body is gated out (the whole proc,
  including the doubled-banks generation under `.if ::SQR_DMA_K`).
- The host program is responsible for calling the canonical
  `reu_mul_tables_init` from another library before any c64-x25519
  field op runs.
- **Caveat for SQR_DMA_K > 0 consumers**: the canonical init populates
  the un-doubled banks only. x25519's pre-doubled rows in banks +3..+5
  are NOT generated by the canonical init (per SPEC §8.2: the canonical
  init "MUST NOT touch those banks"). A consumer that defines
  `SHARED_REU_MUL_INIT` with `SQR_DMA_K > 0` must therefore either
  build c64-x25519 as the 1764-variant (`make lib-x25519-1764`,
  `SQR_DMA_K = 0`) so the doubled tables are never read, or ship its
  own library-private doubled-bank init that re-reads the un-doubled
  banks row-by-row and re-runs the doubling step. This case is tracked
  by [c64-lib-contract issue #15](https://github.com/JC-000/c64-lib-contract/issues/15)'s
  follow-up SMC-parameterised shared fetch.

Standalone builds (no `-D SHARED_REU_MUL_INIT`) build the table
themselves, as before. **This is the default.**

### SMC patch label export (unlocks #15 refactor)

```ca65
reu_fetch_mul_row_bank_patch := reu_fetch_mul_row::bank_lda + 1
```

Address of the immediate-operand byte of the `lda #X25519_REU_BANK`
instruction inside `reu_fetch_mul_row`. An SMC caller can `sta` here
to retarget the fetch to a different REU bank base without rebuilding
the library. No-op for canonical callers; consumed today by
`reu_fetch_doubled_row`'s DMA #1 (see §4.10) to retarget to
`X25519_REU_BANK_DOUBLED` for one call, then restore. The label is a
regular local (not `@cheap`) per ca65's `proc::label` scope rules.

### Symbolic bank names

For libraries / consumers that need to address the doubled-table or
carry-table banks symbolically (instead of by literal offset):

```ca65
X25519_REU_BANK_DOUBLED = X25519_REU_BANK + 4
X25519_REU_BANK_CARRY   = X25519_REU_BANK + 3
```

Both are exported from `src/reu_config.s`. Used internally by
`reu_fetch_doubled_row`; published for consumers that may want to
SMC-patch against them.

### `LIB_X25519_SHARED_PRIMITIVES` manifest

The §5 manifest bitmask covers three §8.x primitives at v0.7-prep
(§8.1 + §8.2 + the SPEC v0.4.0 §8.3 multiply body), constructed
conditionally per §8.0 — a standalone build owns all three:

```ca65
LIB_SHARED_PRIMITIVES_SQTAB      = $0001   ; §8.1, dropped by SHARED_SQTAB_INIT
LIB_SHARED_PRIMITIVES_REU_MUL    = $0002   ; §8.2, dropped by SHARED_REU_MUL_INIT
LIB_SHARED_PRIMITIVES_CT_MUL_8X8 = $0004   ; §8.3, dropped by SHARED_CT_MUL_8X8
LIB_X25519_SHARED_PRIMITIVES     = $0007   ; standalone build (no switches)
```

Each bit drops out of the mask when its deferral switch is defined at
build time, so an integrated build that defers a primitive to a
canonical provider reports only what it actually owns. A standalone
`lib-x25519-onchip` build reports `$0005` instead: it *omits* the
§8.2 bit rather than deferring it, because that profile builds no REU
table at all — see §4.11 for why omission and deferral are not the
same declaration. The
`.and`-against-sibling-manifest `.assert` pattern from §4.6 applies
identically — and is satisfiable under legitimate sharing precisely
because of the conditional construction.

## 4.9 Precalc-table enumeration (c64-lib-contract §8.0 step-6)

c64-x25519 ships [`docs/precalc-tables.md`](precalc-tables.md) plus
`LIB_PRECALC_TABLE` macro invocations in `src/lib_manifest.s` satisfying
SPEC §8.0's catch-loop intake step. Each precalculated table that meets
the §8.0 floor (≥ 256 B AND one of: REU-resident, hot-loop-read,
page-aligned) is enumerated in both forms:

- the doc captures shape + classification + the load-bearing
  *rationale* for the classification;
- the macro emits, per table, the prefixed exported triple
  `LIB_X25519_PRECALC_<name>_{SIZE,REGION,SHARED}` (SPEC v0.7.0 §8.4
  fifth argument) plus — unless the build defines
  `LIB_NO_BARE_EXPORTS` — the deprecated bare triple
  `LIB_PRECALC_<name>_*`. Cross-adopter audits grep via
  `od65 --dump-exports build/lib/lib_manifest.o | grep _PRECALC_` —
  the pattern is `_PRECALC_`, which matches both forms; the old
  `LIB_PRECALC_` pattern silently misses every prefixed export. Note
  `od65` reads objects, not archives: pointed at a `.a` it prints
  `(no xo65 object file)` and exits 0, so audit the extracted member
  (or the shipped per-object files), never the archive itself
  (SPEC v0.7.2).

Three tables are enumerated today: `sqtab` (1024 B, RAM, shared per
§8.1), `reu_mul` (131072 B, REU, shared per §8.2), `reu_mul_doubled`
(196608 B = 3 REU banks × 64 KB, private — gated on `SQR_DMA_K`; the
rationale field flags the c448/Ed448 re-classification trigger
explicitly so a future audit can re-classify).

`src/precalc_table.inc` is a verbatim copy of the canonical macro
source from c64-lib-contract SPEC §8.0; updates land via coordinated
cross-repo PR — do not edit locally.

## 4.10 Cold-segment split: reclaiming init-only code (issue #68)

The init-only procs — `sqtab_init` / `mul_tables_init`,
`reu_mul_init` / `reu_mul_tables_init`, and `reu_probe` — live in a
dedicated ld65 segment, **`LIB_X25519_INIT_CODE`** (SPEC §4 naming),
sized `LIB_X25519_COLD_BYTES` (826 B default build / 648 B
`lib-x25519-1764`). Everything runtime-hot — the field arithmetic, the
ladder, the REU fetch helpers, and the §8.3 `ct_mul_8x8` body — stays
in `LIB_X25519_CODE` (plain `CODE` prior to the issue-#70 SPEC §4
segment-prefix migration).

**Your cfg MUST declare the segment** (see `cfg/x25519-example.cfg`
constraint 5): ld65 hard-errors on any input segment without a memory
area. Declare it as the **last file-emitting segment** in MAIN,
**before any bss-type segment**:

```
LIB_X25519_INIT_CODE: load = MAIN, type = rw, optional = yes, define = yes;
BSS:                  load = MAIN, type = bss, optional = yes, define = yes;
```

The ordering constraint is load-bearing: ld65 writes no file bytes
for bss-type segments, so a file-backed segment declared *after* a
non-empty BSS loads `__BSS_SIZE__` bytes below its linked address —
silent runtime corruption with no link error.

**Reclaiming.** After your boot sequence has called `sqtab_init` and
`reu_mul_init` (and `reu_probe`, if you use it — it must run *before*
the first `reu_mul_init`), the segment's RAM is dead and you may reuse
it. With `define = yes`, ld65 exports the window symbolically:

```ca65
.import __LIB_X25519_INIT_CODE_LOAD__, __LIB_X25519_INIT_CODE_SIZE__
; reuse [__LIB_X25519_INIT_CODE_LOAD__,
;        __LIB_X25519_INIT_CODE_LOAD__ + __LIB_X25519_INIT_CODE_SIZE__)
```

Rules:

1. **Never call an init entry point after reclaim.** That includes a
   "re-init after REU hot-swap" pattern — reload the segment first.
2. The reclaim window is exactly `[__LOAD__, __LOAD__ + __SIZE__)` —
   contiguous by construction. (With an empty BSS, as in the shipped
   cfgs, it also abuts the `$7800` sqtab floor; with consumer BSS
   after it, the window simply ends where BSS's address space begins.)
3. The §8.3 `ct_mul_8x8` body is deliberately **not** in this segment.
   In the default and `lib-x25519-1764` profiles it is boot-only
   inside this library, but it still stays resident for two reasons: a
   composed build in which c64-x25519 is the ct_mul_8x8 owner takes
   *runtime* calls from deferring siblings, and
   `tools/ct_mul_brute_check.py` exercises the body from the live
   image. Under `lib-x25519-onchip` (§4.11) it is not boot-only at
   all — the row generator calls it on the ladder hot path — so
   residency is mandatory there. Reclaiming never touches the
   shared-primitive surface in any profile.
4. Deferral builds (`SHARED_SQTAB_INIT` and/or `SHARED_REU_MUL_INIT`)
   shrink or empty the segment; `optional = yes` keeps such links
   working. Gate asymmetry to know: under `SHARED_SQTAB_INIT` the
   library still exports `sqtab_init`/`mul_tables_init` as an `rts`
   stub, but under `SHARED_REU_MUL_INIT` the `reu_mul_init`/
   `reu_mul_tables_init` exports are gated out entirely — your
   shared-primitives module provides the canonical
   `reu_mul_tables_init` (and the `LIB_SHARED_REU_MUL_ZP_INIT_A/B`
   equates, which the deferral build no longer exports) instead, per
   §4.8; the x25519-private `reu_mul_init` name is not part of the
   deferral surface at all. `make lib-verify-shared` proves each
   deferral build links in exactly this composed shape: it links the
   stub against a stand-in provider
   (`tests/lib_linkage/shared_provider_stub.s`), asserts the deferred
   x25519-own exports are absent, and checks the §8.0 conditional
   mask value per profile ($0006 / $0005 / $0003 / $0000).
5. The standalone `make` build reclaims nothing — the segment loads
   and runs in place; behaviour is identical to pre-split releases.

**Note for downstream consumers cross-checking via `.import + .assert`**:
ca65's 6502 target has no `: far` `.import` hint, so equates whose
value exceeds `$FFFF` (like `LIB_PRECALC_reu_mul_SIZE = 131072`) cannot
be `.import`-ed at all on 6502 — see
[c64-lib-contract issue #18](https://github.com/JC-000/c64-lib-contract/issues/18).
Use `od65 --dump-exports` for cross-checks of large-value equates.
The presence-check workaround in `tests/lib_linkage/lib_linkage_stub.s`
is documented inline.

## 4.11 The `lib-x25519-onchip` build variant (issue #72)

`make lib-x25519-onchip` produces a parallel archive under
`build-onchip/lib/` in which `fe25519_mul` computes its multiplication
rows **on the 6502** instead of fetching them from the REU. It is the
library's first configuration that issues no REU traffic at all: it
runs on a stock, expansion-less C64.

```sh
make lib-x25519-onchip     # build the variant
ls build-onchip/lib/       # libx25519.a + .o files + x25519.inc + cfg
```

Mechanism: `-D X25519_ONCHIP_MUL=1` (threaded through `$(CA65FLAGS)`)
swaps the per-row DMA FETCH in `fe25519_mul` for a 32-iteration
generator built on the c64-lib-contract §8.3 `ct_mul_8x8` body, and
forces `SQR_DMA_K = 0` so `fe25519_sqr` takes the same measured
mult66 path as the 1764 variant. The same define gates out
`reu_mul_init` / `reu_mul_tables_init`, `reu_fetch_mul_row`,
`reu_probe`, the §8.2 export block, and the defensive `$DFxx` register
writes at the field-op and scalarmult entry points — `$DF00-$DFFF` is
*not* unconditionally free I/O2 space on a REU-less host, since GeoRAM
and Ethernet cartridges decode it.

The generator is constant-time, unlike the c64-nist-curves
`FP_ONCHIP_MUL` generator this profile is modelled on: that one is
allowed to skip zero bytes because ECDSA verify runs on public inputs,
and x25519 has no public-input operation. See
[`CT_ANALYSIS.md`](CT_ANALYSIS.md) entries **L30a-d** for the audit and
`docs/design/issue_72_onchip_mul.md` for the design.

**Consumer-side define.** Downstream code that `.include`s
`x25519.inc` against this archive must define the same symbol before
the include:

```sh
ca65 -D X25519_ONCHIP_MUL=1 -o build/app.o src/app.s
```

The header's REU-side import surface is `.if`-gated on it. Without the
define, `x25519.inc` requests `reu_mul_init`,
`reu_mul_tables_init`, `reu_fetch_mul_row_bank_patch`,
`X25519_REU_BANK` / `X25519_REU_OFFSET`, the `LIB_SHARED_REU_MUL_*`
placement equates, and the derived symbolic bank names
(`X25519_REU_BANK_DOUBLED` / `_CARRY`) — none of which exist in the
onchip archive — and the link fails on unresolved externals. The default (`0`) leaves the
header byte-identical to its pre-#72 surface, so existing consumers
need no change.

**Boot obligation: `sqtab_init` only.**

```ca65
jsr sqtab_init          ; the whole init contract for this profile
; no reu_probe, no reu_mul_init, no bank claims
```

There is no REU probe because there is nothing to probe for, and a
probe would be actively harmful — a status poll of a nonexistent REU
is exactly the kind of thing that hangs a stock machine. This is also
why link-level symbol absence is necessary but not sufficient
evidence: the profile's acceptance gate includes running the
differential suite in a VICE instance with no REU attached.

**Manifest deltas.** Relative to the default build:

| Equate | Default build | onchip variant |
|---|---|---|
| `LIB_X25519_REU_BANKS_USED` | `$3B` (banks 0, 1, 3, 4, 5) | `0` |
| `LIB_X25519_SHARED_PRIMITIVES` | `$0007` (§8.1 + §8.2 + §8.3) | `$0005` (§8.1 + §8.3) |
| `LIB_X25519_RESIDENT_BYTES` | `8383` | `8207` |
| `LIB_X25519_COLD_BYTES` | `826` | `160` |
| `LIB_X25519_ZP_USAGE_BYTES` | `85` | `85` (unchanged — the generator allocates no new ZP) |
| `LIB_PRECALC_*` exports | `sqtab`, `reu_mul`, `reu_mul_doubled` | `sqtab` only |

Two of these carry contract meaning worth spelling out:

- **`LIB_X25519_REU_BANKS_USED = 0` is the declaration, not an
  omission.** SPEC §5 specifies "zero if no REU", so a consumer's
  `.and`-against-sibling collision assert reads it correctly with no
  special case: this library collides with nothing.
- **`LIB_X25519_SHARED_PRIMITIVES = $0005` drops §8.2 by omission, not
  by deferral.** The profile does not define `SHARED_REU_MUL_INIT`,
  because that switch means "some canonical provider owns the REU mul
  table" — a claim that would be false here. Under this profile there
  is no table and no provider, so the bit is simply left out of the
  mask expression per SPEC §8.0's "OR only the primitives this lib
  uses". (c64-nist-curves' onchip manifest still claims §8.2; that is
  a known inconsistency in the sibling library, deliberately not
  replicated here.) §8.1 stays because the generator reads `sqtab` on
  every single product — under this profile the table moves firmly
  into the resident hot set.
- The `RESIDENT`/`COLD` figures (`8207`/`160`) are od65-measured —
  exact since the profile shipped in v0.8.0 (`src/lib_manifest.s`
  records the measurement provenance); `make lib-x25519-onchip`
  prints the segsize dump for re-verification at the end of its run.

**Trade-off, and who should use this.** On a stock 1 MHz C64 the
onchip profile is **slower** than the default build, unavoidably:
REU DMA hands the 6502 a finished product row it would otherwise have
to compute, 1,024 products at a time. Measured cost is
**(VICE measurement pending)**.

The profile targets accelerated hosts. REU DMA runs at the ~1 MHz bus
rate no matter how fast the CPU is clocked, so on a turbo machine
every row fetch is a fixed wall-clock stall that does not shrink as
the CPU speeds up — a speed-invariant floor under the whole
scalarmult. The generator has no such floor: it is CPU work, and it
scales with the clock. Above the crossover clock the profile wins;
below it, it loses. The crossover figure and the underlying per-row
DMA stall measurement are **(VICE measurement pending)**, and every
wall-clock claim is additionally gated on a hardware A/B at 16 / 48 /
64 MHz on real accelerated hardware, which has not been run.

**If you are targeting a stock-clock C64, use the default build**
(or `lib-x25519-1764` if REU size is the constraint). Choose the
onchip profile when you have a turbo host, or when you have no REU at
all and the slower scalarmult is acceptable.

The default build is unchanged at the source level — the variant is
opt-in, and the profile is a pure `.ifdef` swap inside the existing
segments, with no §4 segment split of its own. Downstream projects
vendoring the source can rebuild any of the three forms from the same
tree by toggling the make target.

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
                (resident LIB_X25519_CODE first; LIB_X25519_INIT_CODE
                 last in MAIN — reclaimable after init, see §4.10)
$1800-$1Axx     page-aligned field buffers (fe_tmp*, x25_*)
$1B00-$1DFF     mul_dma_lo/hi/carry (REU DMA staging)
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

Cycle-exact numbers as of v0.7.0 (2026-07-16). Measured via the CIA1
32-bit cycle counter (`bench_cycles_*` in `src/util.s`); reproducible
deterministically under VICE warp, hardware-confirmed on Ultimate-64
NTSC.

### Default build (`make`, `make lib`)

| Operation                       | Cycles      | Jiffies     | Wall-time NTSC | PAL    |
| ------------------------------- | ----------: | ----------: | -------------: | -----: |
| `x25519_scalarmult` (basepoint) | 263,581,957 |    15,463.5 |       ~257.7 s | ~309.3 s |
| `fe25519_mul`     (batch=200)   |      94,733 |       5.558 |              — | —      |
| `fe25519_sqr`     (batch=200)   |     103,512 |       6.073 |              — | —      |
| `fe25519_mul_a24` (batch=200)   |       7,595 |       0.446 |              — | —      |
| `fe25519_add`                   |       2,192 |       0.129 |              — | —      |
| `fe25519_sub`                   |       1,664 |       0.098 |              — | —      |
| `fe25519_reduce_final`          |       2,996 |       0.176 |              — | —      |
| `fe25519_cswap`                 |       1,515 |       0.089 |              — | —      |
| `fe25519_inv` (single-call avg) | 29,170,252  |     1,711.3 |              — | —      |

### 1764 build variant (`make lib-x25519-1764`)

For consumers targeting a stock 1764 (256 KB REU). Trade: +15.3 %
scalarmult cost for −192 KB REU + −314 B CODE; see §4.7 and
`docs/REU_USAGE_ANALYSIS.md`.

| Operation                       | Cycles      | Jiffies     | Δ vs default |
| ------------------------------- | ----------: | ----------: | -----------: |
| `x25519_scalarmult` (basepoint) | 303,821,006 |    17,824.2 | +15.3 %      |
| `fe25519_sqr`     (batch=200)   |     135,071 |       7.924 | +30.5 %      |
| `fe25519_mul`     (batch=200)   |      94,733 |       5.558 | 0 (mul path unchanged) |
| Other ops                       |   unchanged |   unchanged | 0            |

### onchip build variant (`make lib-x25519-onchip`)

For turbo hosts, and for hosts with no REU at all. Trade: a **slower**
scalarmult at stock 1 MHz in exchange for removing the REU entirely
and removing the DMA wall-clock floor that does not scale with CPU
clock; see §4.11 and `docs/design/issue_72_onchip_mul.md`.

| Operation                       | Cycles | Jiffies | Δ vs default |
| ------------------------------- | -----: | ------: | -----------: |
| `x25519_scalarmult` (basepoint) | (VICE measurement pending) | (VICE measurement pending) | (pending) |
| `fe25519_mul`     (batch=200)   | (VICE measurement pending) | (VICE measurement pending) | (pending) |
| `fe25519_sqr`     (batch=200)   | (VICE measurement pending) | (VICE measurement pending) | same mult66 path as the 1764 variant (`SQR_DMA_K = 0`) |

The turbo crossover clock depends on the true per-row DMA stall, which
is itself **(VICE measurement pending)** — the estimate in
`docs/REU_USAGE_ANALYSIS.md` and the transfer-rate calculation
disagree by roughly 3x, so no crossover figure is quoted here until it
is measured directly. All VICE figures are cycle-exact at 1 MHz only;
wall-clock claims for accelerated hosts are gated on the deferred
hardware A/B at 16 / 48 / 64 MHz.

### Historical baselines

| Release | Scalarmult (jif) | Δ vs v0.3.0 baseline       | Note                                   |
| ------- | ---------------: | -------------------------- | -------------------------------------- |
| v0.1.0  |            9,520 |                            | Pre-CT-closure baseline                |
| v0.2.0  |           12,485 | +3.4 % (vs v0.3.0)         | L1-L22 full CT closure (+31.1 % cost)  |
| v0.3.0  |           12,070 | (baseline)                 | Perf recovery + L23/L24 closure        |
| v0.4.0  |           15,350 | +27.2 %                    | L25-L29 full CT closure + state defences |
| v0.5.0  |           15,350 | +27.2 %                    | c64-lib-contract §1/§2/§3/§5 (no behaviour change) |
| v0.6.0  |           15,352 | +27.2 %                    | Group C bank-2 drop (-51 B), §8 sqtab adoption, bench rehab (RAM only; runtime within 0.02 %) |
| v0.7.0  |           15,463 | +28.1 %                    | RFC 7748 decode fix (#64) + §8.2/§8.3 shared-primitives completion; +0.73 % = issue-15 SMC-patch delegation + 768 cy #64 init copy |

The +0.02 % shift across v0.5.0 → v0.6.0 is pure code-layout noise
from the bank-2 stash removal (commit `71cc1aa`); no CT or correctness
change. The +0.73 % across v0.6.0 → v0.7.0 is the issue-15 refactor's
`fe25519_sqr` delegation cost (within its ≤ 2 % gate) plus one
`fe25519_copy` per call for the #64 fix. RFC 7748 vec-0 PASS at every
release.

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
