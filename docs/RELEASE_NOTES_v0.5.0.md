# c64-x25519 v0.5.0 — c64-lib-contract §1/§2/§3/§5 adoption

**Status:** Released 2026-05-20. v0.5.0 is the library-ingestion
release: it ships the four sections of [c64-lib-contract](https://github.com/JC-000/c64-lib-contract)
required for consumer projects (c64-https, c64-wireguard) to compose
c64-x25519 alongside sibling crypto libraries without source patches.

## What this is

A post-v0.4.0 minor release with **no CT or correctness changes** and
**no performance change** at default configuration. v0.5.0 is purely
additive: new exports, new equates, new source files. Every public
symbol shipped in v0.4.0 remains, with the same value and same
semantics.

See [`RELEASE_NOTES_v0.4.0.md`](RELEASE_NOTES_v0.4.0.md) for the
v0.4.0 Phase 7 closure that this release builds on (full L1-L29 CT
posture across the entire `fe25519_*` / `mul_8x8` /
`x25519_scalarmult` surface). Older release notes:
[v0.3.0](RELEASE_NOTES_v0.3.0.md),
[v0.2.0](RELEASE_NOTES_v0.2.0.md),
[v0.1.0](RELEASE_NOTES_v0.1.0.md).

v0.5.0 implements four contract sections, all gated by closed-issue
GitHub PRs:

1. **§1 — Version identification.** Closes [#45](https://github.com/JC-000/c64-x25519/issues/45),
   landed via PR [#47](https://github.com/JC-000/c64-x25519/pull/47).
2. **§2 — Zero-page contract.** Closes [#44](https://github.com/JC-000/c64-x25519/issues/44),
   landed via PR [#48](https://github.com/JC-000/c64-x25519/pull/48).
3. **§3 — REU layout contract.** Closes [#43](https://github.com/JC-000/c64-x25519/issues/43),
   landed via PR [#49](https://github.com/JC-000/c64-x25519/pull/49).
4. **§5 — Aggregate manifest equates.** Closes [#46](https://github.com/JC-000/c64-x25519/issues/46),
   landed via PR [#50](https://github.com/JC-000/c64-x25519/pull/50).

Out of scope for v0.5.0 (deferred per the contract's adopters table):
**§4 segment naming** (no current consumer requires it) and **§6
build target variants** (the library is small enough that consumers
link the full archive).

---

## §1 — Version identification

New file: **`src/lib_version.s`**, compiled to its own `.o` and
linked into `libx25519.a`. Exports four integer equates as
absolute 16-bit symbols:

| Symbol | Value | Semantics |
|---|---|---|
| `LIB_VERSION_MAJOR` | `0` | semver major (breaking ABI change) |
| `LIB_VERSION_MINOR` | `5` | semver minor (additive ABI change) |
| `LIB_VERSION_PATCH` | `0` | semver patch (no ABI change) |
| `LIB_ABI_VERSION`   | `1` | coarse ABI compat level; tracks MAJOR |

The `.export NAME: abs` size override prevents ca65 from inferring
zeropage size from the small integer values, which would otherwise
produce link-time address-size-mismatch warnings against consumer
`.import` declarations that default to absolute.

**Consumer usage:**

```ca65
.import LIB_VERSION_MAJOR, LIB_VERSION_MINOR
.if LIB_VERSION_MAJOR <> 0 .or LIB_VERSION_MINOR < 5
    .error "this consumer needs c64-x25519 v0.5 or later"
.endif
```

The `.if`-guard fires at assemble time, before any link/test cycle —
defense-in-depth against an unsupported library version on top of
git-submodule SHA pinning.

---

## §2 — Zero-page contract

New file: **`src/zp_config.s`**, compiled to its own `.o`. Owns
every consumer-overridable ZP slot the library claims, with each
slot wrapped in `.ifndef <name>` / `.endif` (host-overridable via
ca65 `-D <slot>=$<addr>`) and `.exportzp`-ed for consumer
`.importzp`.

**Architecture.** `src/constants.s` becomes a thin wrapper that
`.include`s `zp_config.s` with `ZP_CONFIG_NO_EXPORTS = 1` set, so
the transitive-include path doesn't emit duplicate `.exportzp`
directives (which would error at link time as
`Duplicate external identifier`). Only `zp_config.o`, compiled as
its own translation unit without the flag, actually emits the
public exports. The wrapper pattern lets every library `.s` file
keep its `.include "constants.s"` unchanged.

**`src/main.s`** drops its old
`.exportzp fe25519_src1, fe25519_src2, fe25519_dst` (those exports
now live in `zp_config.o`). `fe_wide` stays exported from `main.s`
because it's still declared in `constants.s` (CT/SMC-pinned `$40`,
not movable, intentionally not in `zp_config.s`).

**Slots covered** (all `.exportzp`-ed by `zp_config.o`):

- General scratch: `zp_ptr1`, `zp_tmp1`, `zp_tmp2`
- fe25519 working: `fe25519_src1`, `fe25519_src2`, `fe25519_dst`,
  `mul_pending`, `mul_bound`, `fe_carry`, `fe_loop`, `fe_mul_i`,
  `fe_mul_j`, `mul_ripple_start`
- X25519 ladder working: `x25_prev_bit`, `x25_byte_idx`,
  `x25_bit_mask`, `fe_sqr_pairs`
- CT masks (Phase 7): `fe_cmp_mask`, `fe_subp_rhs`,
  `fe_add_carry_mask`
- mul_8x8 carry: `poly_carry`

**Naming convention.** The contract SPEC §2 suggests
`<lib_prefix>_<role>` naming. c64-x25519's slot names use shorter
historical prefixes (`fe25519_`, `fe_`, `mul_`, `x25_`, `poly_`,
`zp_*`) that predate the contract. Renaming them now would break
consumer ABI for any code that already references them; the names
are kept stable. SPEC §2 uses the word "convention" rather than
"MUST" for naming.

**Consumer usage** (compose with sibling crypto library):

```ca65
.importzp fe25519_src1, fe25519_src2, fe25519_dst
```

No need to `.include "constants.s"` (which would also pull in
KERNAL / VIC / SID / CIA / REU hardware equates).

**Host override** (relocate `fe25519_src1` to `$40`):

```sh
ca65 -D fe25519_src1=$40 -o build/zp_config.o src/zp_config.s
# ...rebuild every library .o with the same -D, then re-archive.
```

---

## §3 — REU layout contract

New file: **`src/reu_config.s`**, compiled to its own `.o`. Owns
two equates governing the library's REU bank allocation:

| Symbol | Default | Purpose |
|---|---|---|
| `X25519_REU_BANK` | `0` | Base bank for all six mul-table banks |
| `X25519_REU_OFFSET` | `$0000` | Within-bank base offset |

Both are `.ifndef`-guarded for `ca65 -D` override and `.export`-ed
as absolute 16-bit symbols (same `:abs` pattern as the version
equates).

**Bank allocation, relative to `X25519_REU_BANK`:**

```
  bank + 0   : 8x8->16 mul tables, lo+hi, for a =   0..127  (full bank)
  bank + 1   : 8x8->16 mul tables, lo+hi, for a = 128..255  (full bank)
  bank + 2   : 64-byte zero block (legacy reu_clear_wide stash)
  bank + 3   : 17th-bit carry bytes for doubled tables (256 B/row)
  bank + 4   : pre-doubled mul tables, lo+hi, a =   0..127  (full bank)
  bank + 5   : pre-doubled mul tables, lo+hi, a = 128..255  (full bank)
```

The library also transiently touches `bank + 7` during `reu_probe`,
restoring it before the probe returns.

**Source change.** 13 bank-immediate sites in `src/x25519_init.s`
were rewritten from hard-coded bank numbers (0/1/2/3/4/5/7) to
`+ X25519_REU_BANK` expressions:

- `reu_mul_init`: 6 sites (lo+hi for first 128 rows; doubled lo+hi
  for second 128 rows; 17th-bit carry table; 64-byte zero block)
- `reu_fetch_mul_row` and `reu_fetch_doubled_row`: 3 sites
- `reu_probe`: 4 sites (read sentinel + write sentinel + round-trip
  read + restore)

Every changed instruction is an `lda #immediate` with the same
cycle count as before. The bank number is derived from a public
loop counter + a public assemble-time constant, so the timing
surface is unchanged. **Zero CT impact.**

**Aggregate bitmask** (also required by §3): exported as part of
the §5 manifest below.

**Host override** (relocate the six-bank claim from banks 0-5 to
banks 3-8 to free banks 0-2 for a sibling REU consumer):

```sh
ca65 -D X25519_REU_BANK=3 -o build/x25519_init.o src/x25519_init.s
# ...rebuild every library .o with the same -D, then re-archive.
```

The library's standalone `make` / `make lib` build always uses the
default; consumer projects rebuild from source with their preferred
bank base. `X25519_REU_OFFSET` is exported as a contract-compliance
equate but currently has no effect (tables span full banks); reserved
for a future release.

**Naming note.** The contract SPEC §3 example uses `--asm-define`
on the ca65 command line; that's the `cl65` driver form, while
`ca65` itself uses `-D` directly. Functionally equivalent.

---

## §5 — Aggregate manifest equates

Four integer equates added to `src/lib_version.s`, exported as
absolute 16-bit symbols. They let a consumer cfg do assemble-time
fit / collision checks against the library before kicking off a
30-minute compile + VICE test cycle.

| Symbol | Value | What it reports |
|---|---|---|
| `LIB_X25519_ZP_USAGE_BYTES` | `85` | Sum of `.exportzp`-ed slots in `zp_config.s` + pinned `fe_wide` |
| `LIB_X25519_REU_BANKS_USED` | `$3F << X25519_REU_BANK` | Bitmask of claimed REU banks; default `$3F` at base 0 |
| `LIB_X25519_RESIDENT_BYTES` | `9275` | CODE+DATA+SQTAB CPU-resident footprint |
| `LIB_X25519_COLD_BYTES` | `0` | Overlay-pageable footprint (none today) |

`LIB_X25519_REU_BANKS_USED` is computed at **link time** via ca65's
shift operator, with `X25519_REU_BANK` imported as an external
symbol. A `-D X25519_REU_BANK=3` override shifts the mask
automatically without requiring a manual edit.

**Resident footprint breakdown** (from `od65 --dump-segsize` on the
v0.5.0 library `.o` files):

| Module | CODE | DATA |
|---|---|---|
| x25519.o | 698 | 0 |
| x25519_init.o | 849 | 0 |
| fe25519.o | 2711 | 0 |
| mul_8x8.o | 251 | 0 |
| util.o | 158 | 0 |
| data.o | 0 | 3584 |
| lib_version.o | 0 | 0 (equates only) |
| zp_config.o | 0 | 0 (equates only) |
| reu_config.o | 0 | 0 (equates only) |
| **total** | **4667** | **3584** |
| **+ SQTAB** | | **1024** (runtime-built at fixed `$7800-$7BFF`) |
| **= RESIDENT_BYTES** | | **9275** |

The three config `.o` files contain only equate declarations and
`.export` directives; they emit no CODE/DATA bytes and don't shift
the resident total.

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

**Refresh policy** (per SPEC §5): values are approximate ("within
5% is fine") and refreshed when a release substantively changes any
one of them. v0.5.0 is the first release to declare them; v0.4.0's
numbers were not exported as equates.

---

## Performance

Unchanged from v0.4.0:

| Operation | Cost |
|---|---|
| `x25519_scalarmult` (basepoint 9) | 15,350 jiffies (~256.4 s NTSC) |
| `fe25519_mul` | 5.98 jiffies/call (CT spread 0.000) |
| `fe25519_sqr` | 6.44 jiffies/call (CT spread 0.005) |
| `fe25519_mul_a24` | 0.475-0.480 jiffies/call (CT spread 0.005) |

Every v0.5.0 source change is either an additive equate declaration
(zero code emitted), an `.export` directive (zero code emitted), or
a single-operand rewrite of an `lda #immediate` in
`src/x25519_init.s` (same instruction encoding, same cycle count).
**No CT cycle-count guard has changed.** `make test-vice` is the
canonical regression gate; it passes at v0.5.0 with the same
spread numbers reported for v0.4.0.

---

## CT posture

**No CT changes.** The full L1-L29 CT closure shipped in v0.4.0 is
intact; see [`docs/CT_ANALYSIS.md`](CT_ANALYSIS.md) for the leak
catalogue. The 13 bank-immediate rewrites in `src/x25519_init.s`
are immediate-mode loads of an assemble-time constant `+ X25519_REU_BANK`;
no branch added, no instruction count change, bank number derives
only from public loop indices + a public constant. CT-irrelevant.

---

## File set changes from v0.4.0

**New files** (all in `src/`):

- `src/lib_version.s` — `LIB_VERSION_*` and `LIB_X25519_*` equates
- `src/zp_config.s` — ZP slot inventory + `.exportzp` block
- `src/reu_config.s` — `X25519_REU_BANK`/`X25519_REU_OFFSET`

**Modified files:**

- `src/constants.s` — delegates ZP block to `zp_config.s` and REU
  base to `reu_config.s` via `.include` with `*_NO_EXPORTS` flags
- `src/main.s` — dropped duplicate `.exportzp` of slots now owned by
  `zp_config.o`
- `src/x25519_init.s` — 13 bank-immediate sites rewritten to use
  `+ X25519_REU_BANK`
- `src/x25519.inc` — VERSION CONSTANTS / REU layout import blocks
  added to the public header's import list
- `tests/lib_linkage/lib_linkage_stub.s` — `.word` and `.byte`
  reference blocks for the new exports so `ld65`'s archive-member
  resolution pulls `lib_version.o`, `zp_config.o`, `reu_config.o`
  out of `libx25519.a`
- `Makefile` — three new objects added to `LIB_OBJS` and
  `CA65_SRCS`; `.o` pattern rule extended to depend on the new
  config sources; `lib-verify` symbol-presence assertion extended
  to cover all new exports
- `docs/LIBRARY.md` — new §4.3 Version constants, §4.4 Aggregate
  manifest equates, §4.5 Overriding the REU bank base; §1
  Requirements clarified to "85 bytes" (true count; v0.4.0
  documentation claimed "87 bytes" via a stale double-count)
- `README.md` — Status / Integrating sections updated; new
  paragraphs cross-link to `c64-lib-contract`

**Migration from v0.4.0 (downstream callers):** none required.
Every v0.4.0 public symbol still exists with the same value and
semantics. Vendoring this tarball over a v0.4.0 vendor directory
is a drop-in replacement. New symbols (`LIB_VERSION_*`, ZP slot
exports, REU-layout exports, manifest equates) are additive
opt-ins.

---

## Commits since v0.4.0

- `4d1c752` docs: fix stale "87 bytes" ZP claim — actual count is 85 (#51)
- `e9de878` feat(lib): LIB_X25519_* aggregate manifest equates (closes #46) (#50)
- `4d402d7` feat(lib): make REU bank base configurable via X25519_REU_BANK (#43) (#49)
- `ab92e88` feat(lib): publish .exportzp ZP config for consumer .importzp (#44) (#48)
- `7c0a90d` feat(lib): export LIB_VERSION_* and LIB_ABI_VERSION for consumer pinning (#45) (#47)

Plus the v0.5.0 release prep commit (this file, version bump,
tarball-manifest update).

---

## Tarball

**c64-x25519-v0.5.0.tar.gz** — source distribution (ca65/ld65-compatible
assembly + docs + linker config example + LICENSE +
ORIGIN.txt.template). Adds three config files over the v0.4.0
manifest (`lib_version.s`, `zp_config.s`, `reu_config.s`).

- Size: **81,213 bytes**
- SHA256: `d79fe1a508c6f8612e2290e396c2ce3928a6c3b0c3d672e755418b83b0182a91`
- Download: https://github.com/JC-000/c64-x25519/releases/download/v0.5.0/c64-x25519-v0.5.0.tar.gz

Built reproducibly from the v0.5.0 tag. Recipe is checked in at
`tools/build_release.sh`; invoke with
`tools/build_release.sh v0.5.0` (or `make dist VERSION=v0.5.0`).
The file list is the v0.5.0+ vendoring set documented in
"File set changes from v0.4.0" above. Determinism: `git archive` is
byte-deterministic for a given commit, and `gzip -n` drops the gzip
header timestamp, so the same tag always reproduces this SHA256.

Note: v0.4.0's tarball used a smaller file list (no contract
files); `make dist VERSION=v0.4.0` no longer reproduces the v0.4.0
recorded SHA. The v0.4.0 download link remains valid for callers
that pinned to the prior tag.

---

## Re-quotable disclosure language

For consumers documenting their c64-x25519 adoption, the
following language summarises v0.5.0 and is safe to quote:

> c64-x25519 v0.5.0 adopts c64-lib-contract sections §1 (version
> identification), §2 (`.exportzp` ZP slot inventory in
> `src/zp_config.s`), §3 (REU bank configurability via
> `X25519_REU_BANK` in `src/reu_config.s`), and §5 (aggregate
> manifest equates `LIB_X25519_*`). No CT, correctness, or
> performance change from v0.4.0; all changes are additive
> exports and `.ifndef`-guarded equates. Public symbol set is
> a strict superset of v0.4.0.

---

## Acknowledgements

c64-lib-contract was bootstrapped by `c64-https` and
`c64-wireguard` on 2026-05-20. Their cross-consumer tracking
issues (filed against c64-x25519 as
[#43](https://github.com/JC-000/c64-x25519/issues/43) /
[#44](https://github.com/JC-000/c64-x25519/issues/44) /
[#45](https://github.com/JC-000/c64-x25519/issues/45) /
[#46](https://github.com/JC-000/c64-x25519/issues/46)) drove this
release.
