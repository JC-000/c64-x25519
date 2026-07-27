# c64-x25519 v0.8.0 — cold-segment split, §4 segment prefixes, X25519_ONCHIP_MUL no-REU profile

> **DRAFT until tagged** — tarball SHA256 + size are placeholders until
> the SHA-fill PR after `make dist`.

Rolls up three arcs since v0.7.0, all additive (MINOR bump; `LIB_ABI_VERSION`
unchanged at 1; no CT posture regression — the catalogue extends L1–L29 →
L1–L30 with the new profile-scoped entries):

- **#68/#69 — cold-segment split**: init-only code moved to the
  reclaimable `LIB_X25519_INIT_CODE` segment.
- **#70/#71 — SPEC §4 segment prefixes**: `CODE`/`DATA` →
  `LIB_X25519_CODE`/`LIB_X25519_DATA` (pure rename, proven by
  byte-identical PRG).
- **#72/#73 — `X25519_ONCHIP_MUL` build profile**: constant-time on-chip
  multiply, the library's **first configuration that needs no REU at
  all**, aimed at turbo hosts where REU DMA is a wall-clock floor.

## ⚠ Consumer-cfg migration callout (the one action item)

Downstream linker cfgs need **three new segment declarations**, bundled
deliberately into one release so consumers migrate once:

```
LIB_X25519_CODE:      load = MAIN, type = ro;
LIB_X25519_DATA:      load = MAIN, type = rw;
LIB_X25519_INIT_CODE: load = MAIN, type = ro;   # last FILE-EMITTING entry
                                                # before bss-type segments!
```

Ordering is load-bearing: `LIB_X25519_INIT_CODE` (and every
file-emitting segment) MUST be declared before bss-type segments in a
file-backed memory area — reversed order links without error but loads
the code `__BSS_SIZE__` bytes low (design-doc R5). See
`docs/LIBRARY.md` §4.10 and constraint 5 in `cfg/x25519-example.cfg`.
After init returns, a consumer MAY reclaim `LIB_X25519_INIT_CODE` as
contiguous RAM (826 B default / 648 B 1764 / 160 B onchip).

## X25519_ONCHIP_MUL — the no-REU profile (#72, PR #73)

`make lib-x25519-onchip` builds a profile in which `fe25519_mul`
generates its product rows on-chip through the canonical §8.3
`ct_mul_8x8` body (fixed 32 products/row, no secret-dependent branch
anywhere — CT catalogue entries L30a–d), `SQR_DMA_K` is forced to 0,
and the archive contains **no REU code or claims**:
`LIB_X25519_REU_BANKS_USED = 0`, `LIB_X25519_SHARED_PRIMITIVES = $0005`
(§8.2 omitted-not-deferred), boot obligation `sqtab_init` only. Runs on
a stock, expansion-less C64 — proven at link level, in REU-less VICE,
and on both Ultimate devices with the REU disabled in firmware.

Ported from c64-nist-curves' `FP_ONCHIP_MUL` concept (#69/#71 there),
**redesigned for constant time**: x25519 has no public-input operation,
so every non-CT shortcut in their generator was replaced or deleted.
`ct_mul_8x8` becomes hot-path with secret operands under this profile —
`docs/CT_ANALYSIS.md`'s threat-model section was rewritten accordingly
(L1/L2 are now load-bearing there, not "retained canonical shape").

Consumers assemble against the canonical `x25519.inc` with
`-D X25519_ONCHIP_MUL=1`. **ca65 gotcha: a bare `-D X25519_ONCHIP_MUL`
defines the symbol as 0 and silently selects the default profile —
always write `=1`.**

### Measured — stock clock (VICE, cycle-exact; hardware-anchored)

| Build | scalarmult cycles | NTSC | vs default |
|---|---|---|---|
| default | 262,318,045 | ~4.3 min | 1.000× |
| 1764 (`SQR_DMA_K=0`) | 304,060,643 | ~5.0 min | 1.162× |
| onchip | 449,589,657 | ~7.3 min | 1.718× |

Stock users keep the default build — the REU tables exist because they
win at 1 MHz. Hardware CIA-tick totals at 1 MHz match VICE to
**+0.013% (U64E) / +0.006% (C64U)**.

### Measured — turbo hardware (same-boot A/B, oracle-gated)

| MHz | U64E A/B | C64U A/B (CIA ticks) |
|---|---|---|
| 16 | 0.99× | 0.90× |
| 24 | 1.20× | 1.10× |
| 32 | 1.42× | 1.31× |
| 40 | 1.64× | 1.51× |
| 48 | **1.85×** | 1.69× |
| 64 | (no such step) | **2.00×** |

Device-dependent stall values (per 512 B row): real-1750 model / VICE
532 cy (crossover ~7.7 MHz, projection); U64E fw 3.14 ~189 wall-ticks
(crossover ~17 MHz); C64U fw 1.1.0 ~160 wall-ticks (crossover ~20 MHz).
Neither Ultimate generation reproduces real-1750 1 cy/byte DMA under
turbo. Full derivations: `docs/design/issue_72_onchip_mul.md`.

New tooling: `tools/bench_x25519_u64.py` (same-boot Ultimate A/B,
DeviceLock-serialized, oracle-gated, refuses unknown device
generations) and the `C64_NO_REU=1` launch mode across the VICE suite.

## SPEC §6 build-target variants — adopted

Variant archives now land at the SPEC §6 canonical paths:

```
make lib                  -> build/lib/libx25519.a          (default)
make lib-x25519-1764      -> build/lib/libx25519-1764.a     (256 KB REU)
make lib-x25519-onchip    -> build/lib/libx25519-onchip.a   (no REU)
```

`lib-verify` is now profile-aware: for the onchip surface it asserts
the REU symbols are **absent**, not just that the expected ones are
present.

## Cold-segment split + §4 rename recap (#68–#71)

Shipped on master since v0.7.0: `RESIDENT_BYTES` 8383/8247/8207
(default/1764/onchip), `COLD_BYTES` 826/648/160. Default-build bench
**262,318,045 cy, −0.48% vs v0.7.0** (layout win from tighter packing).
The §4 rename was proven pure by byte-identical PRG (SHA `905bb969…`),
a proof re-run and re-confirmed at every #72-arc commit.

## Manifest equates at v0.8.0

| Equate | default | 1764 | onchip |
|---|---|---|---|
| `LIB_X25519_REU_BANKS_USED` | `$3B` | `$03` | `0` |
| `LIB_X25519_RESIDENT_BYTES` | 8383 | 8247 | 8207 |
| `LIB_X25519_COLD_BYTES` | 826 | 648 | 160 |
| `LIB_X25519_SHARED_PRIMITIVES` | `$0007` | `$0007` | `$0005` |
| `LIB_VERSION_*` | 0.8.0 | 0.8.0 | 0.8.0 |

## Verification

- Default PRG byte-identical to v0.7.0-lineage master at every step of
  the #72 arc (SHA `905bb969…`) — profile gating is invisible to the
  default build.
- Full `make test-slow` suite green at the release commit (see PR).
- Onchip: full differential suite green in VICE with REU attached AND
  detached (`C64_NO_REU=1`), scalarmult cycle count bit-identical
  either way; CT cycle gates hold 0.005 jif spread; `ct_mul_brute_check`
  65,536/65,536; RFC 7748 oracle-gated on U64E and C64U hardware.

## Erratum for v0.7.0 tarballs

`tools/build_release.sh` omitted `src/precalc_table.inc` from the
archive list, so the v0.7.0 tarball cannot assemble `lib_version.s`
as shipped (the git tree was always complete — only the tarball was
affected). Fixed in this release; v0.8.0 tarballs include the file.
Vendors of the v0.7.0 tarball should copy `src/precalc_table.inc`
from the tag or move to v0.8.0.

## Tarball

```
File:     c64-x25519-v0.8.0.tar.gz
Size:     TBD bytes
SHA256:   TBD
```

```
shasum -a 256 c64-x25519-v0.8.0.tar.gz
# expect: TBD
```
