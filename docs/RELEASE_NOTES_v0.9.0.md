# c64-x25519 v0.9.0 — contract v0.7.0/v0.5.0 manifest migration (two-library composition)

Single arc since v0.8.0 (MINOR bump; `LIB_ABI_VERSION` unchanged at 1;
**zero code change** — the test-harness PRG at this release commit is
byte-identical to v0.8.0's, SHA256 `905bb969…b95acc`, so every v0.8.0
performance number and the entire CT posture carry over verbatim):

- **#77–#81 / PR #82 — c64-lib-contract SPEC v0.7.0 + v0.5.0
  adoption**: library-prefixed manifest exports, §1 TU isolation,
  `LIB_X25519_SHARED_CONSUMES`, and un-exported §8.x bit constants.
  This is the x25519 half of the fix for the two-library link
  collision (`c64-lib-contract#43`) filed from `c64-wireguard`, which
  links c64-x25519 and c64-ChaCha20-Poly1305 into one PRG.

## What a composing consumer gets

Build every library in the link — and assemble your own imports —
with `ca65 -D LIB_NO_BARE_EXPORTS=1`, then import prefixed forms only:

```ca65
.import LIB_X25519_VERSION_MAJOR, LIB_X25519_VERSION_MINOR
.import LIB_X25519_SHARED_PRIMITIVES, LIB_X25519_SHARED_CONSUMES
.import LIB_X25519_PRECALC_sqtab_SIZE
```

Measured at this release: the minimal two-manifest consumer from
issue #78 dies against v0.8.0 with
`ld65: Error: Duplicate external identifier: 'LIB_PRECALC_sqtab_SHARED'`
and **links clean** against this release built under the gate — even
against an *unmigrated* c64-ChaCha20-Poly1305 v0.6.0 archive, since
every symbol in the measured duplicate set was exported from the
x25519 side. The cross-library agreement check the bare forms could
not express now works:

```ca65
.assert LIB_X25519_PRECALC_sqtab_SIZE = LIB_CHACHA20_POLY1305_PRECALC_sqtab_SIZE, \
        error, "libraries disagree on shared sqtab size"
```

Single-library consumers change **nothing**: the bare `LIB_VERSION_*`
/ `LIB_PRECALC_*` names stay exported by default (deprecated,
scheduled for removal at contract v1.0).

## ⚠ The one potentially breaking edge

The §8.x bit constants `LIB_SHARED_PRIMITIVES_{SQTAB,REU_MUL,
CT_MUL_8X8}` are **no longer exported** (issue #77). Exporting them
was itself the contract violation that broke the two-library link —
they are identical unprefixed names in every §8 adopter, and SPEC
§8.0 defines them as assemble-time equates each side carries locally.

- Consumers that get them via `.include "x25519.inc"` are
  **unaffected**: the header now defines them as `.ifndef`-guarded
  local equates with the same values.
- Only a hand-written `.import LIB_SHARED_PRIMITIVES_*` line breaks
  (ld65 unresolved external). Migration: delete the import; include
  the header or copy the three-line equate block from SPEC §8.0.

Rationale for MINOR rather than MAJOR despite the removed exports:
the exports were a SPEC-violation bug with exactly one known importer
(this repo's own linkage stub), the header-level surface is fully
compatible, and the library's semver lock covers the `fe25519_*` /
`x25519_*` API, which is untouched. `LIB_ABI_VERSION` stays 1.

## Manifest surface after this release

| Export | Where | Notes |
|---|---|---|
| `LIB_X25519_VERSION_{MAJOR,MINOR,PATCH}`, `LIB_X25519_ABI_VERSION` | `lib_version.o` | §1 prefixed; the only exports in that member (TU isolation) |
| `LIB_VERSION_*`, `LIB_ABI_VERSION` (bare) | `lib_version.o` | deprecated aliases; suppressed by `-D LIB_NO_BARE_EXPORTS=1` |
| `LIB_X25519_{ZP_USAGE,REU_BANKS_USED,RESIDENT,COLD}*` | `lib_manifest.o` (new TU) | §5 aggregates, values unchanged from v0.8.0 |
| `LIB_X25519_SHARED_PRIMITIVES` | `lib_manifest.o` | ownership mask, construction unchanged |
| `LIB_X25519_SHARED_CONSUMES` | `lib_manifest.o` | **new** (SPEC v0.5.0); subset invariant asserted at assemble time |
| `LIB_X25519_PRECALC_<name>_{SIZE,REGION,SHARED}` | `lib_manifest.o` | **new** §8.4 prefixed triples; bare triples remain, gated |

`SHARED_CONSUMES` finally distinguishes the two builds that both
report ownership `$0005`: a `SHARED_REU_MUL_INIT` deferral consumes
`$0007` (needs exactly one §8.2 provider in the link + boot init),
while `X25519_ONCHIP_MUL` consumes `$0005` (no REU table exists, no
provider obligation). Full matrix, verified per-profile by
`make lib-verify` / `lib-verify-shared`:

| Build | `SHARED_PRIMITIVES` | `SHARED_CONSUMES` |
|---|---|---|
| default / 1764 | `$0007` | `$0007` |
| shared-sqtab / -reu / -ct / -all | `$0006` / `$0005` / `$0003` / `$0000` | `$0007` |
| onchip | `$0005` | `$0005` |

## Doc corrections riding along

- Every consumer-facing snippet now uses ca65's real define flag
  `-D name[=value]` (SPEC v0.7.1); `--asm-define` is `cl65`-only and
  never worked when pasted into a direct `ca65` invocation.
- Mask-assert snippets in `LIBRARY.md` moved from boolean `.and`/`.or`
  to bitwise `&`/`|`/`~` (c64-lib-contract#41 defect class — the
  boolean forms collapse multi-bit masks to 0/1 and pass/fail on the
  wrong condition).
- Cross-adopter audit pattern is `_PRECALC_` (matches prefixed + bare
  forms); `od65` reads objects, not archives (SPEC v0.7.2).

## No perf / CT deltas

No runtime code changed. The release-commit PRG is byte-identical to
v0.8.0 (`905bb969f027d02b4671ab04436d8c817b2f3fcfe31200af98931f6151b95acc`),
which per the repo's byte-identity standard carries the v0.8.0
`test-slow` pass, bench rows (262,318,045 / 303,852,663 / 449,589,657
cycles), hardware A/B results, and CT catalogue L1–L30 forward
unchanged.

## Tarball (DRAFT — filled by the post-tag SHA-fill PR)

```
File:     c64-x25519-v0.9.0.tar.gz
Size:     DRAFT
SHA256:   DRAFT
```

Built via `make dist VERSION=v0.9.0` (reproducible; `git archive` +
`gzip -n`). The file list now includes `src/lib_manifest.s`.
