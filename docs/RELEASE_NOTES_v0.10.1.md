# c64-x25519 v0.10.1 — contract alignment sweep: working version-guard snippets, cfg failure modes, verify hardening

PATCH release (no ABI change, `LIB_X25519_ABI_VERSION` stays 2;
**zero code change** — PRG byte-identical to v0.8.0 through v0.10.0,
SHA256 `905bb969…b95acc`). Rolls up the team-audited alignment sweep
(PR #89) against contract issues #62/#63 and SPEC v0.8.0/v0.8.1.

## Why a consumer should take this tag

**The version-guard snippets you copy from `x25519.inc` /
`LIBRARY.md` now work.** Every previously shipped `.if`-based guard
was broken as written — ca65 rejects `.if` on an `.import`ed symbol
with `Constant expression expected`, so the guard never assembled at
all. The snippets are now the SPEC v0.8.1 `.assert ..., lderror` form
(single-line — ca65 also rejects `\` continuation without
`.linecont +`), measured both directions against the real archive,
and the previously-absent ABI-generation gate ships alongside:

```ca65
.import LIB_X25519_VERSION_MAJOR, LIB_X25519_VERSION_MINOR
.assert (LIB_X25519_VERSION_MAJOR > 0) .or (LIB_X25519_VERSION_MINOR >= 10), lderror, "this consumer needs c64-x25519 v0.10 or later"

.import LIB_X25519_ABI_VERSION
.assert LIB_X25519_ABI_VERSION = 2, lderror, "c64-x25519 exported-surface generation changed; re-check the integration"
```

The §8 mask-assert snippets in LIBRARY.md received the same
treatment (single-line, `lderror` on imported operands).

## Cfg attributes: declared failure modes (SPEC v0.8.0 §4)

New per-segment table in LIBRARY.md §2 + warnings in both cfgs, each
with its measured consequence (ld65 V2.18):

- `LIB_X25519_DATA` `align = 256`: **hard link error** if violated —
  the library's own CT asserts defend it (exceeds §4's bar).
- `LIB_X25519_DATA` `type = rw`: `bss` links with only a warning and
  silently drops 3,720 B of initialized tables from the PRG.
- `LIB_X25519_INIT_CODE` ordering before bss (R5): zero-diagnostic
  load shift; ordering discipline only.
- `SQTAB` region vs `LIB_SHARED_SQTAB_BASE`: **fully silent**
  divergence — clean link, 1 KB overwrite at init. Keep the MEMORY
  block and the `-D` value in lockstep.

## Doc + verify corrections

- LIBRARY.md's onchip footprint figures corrected to the measured
  `8207`/`160` (the `8300`/`260` "provisional" values were never in
  the source; every shipped archive's manifest was and is byte-exact).
- `make lib-verify` hardened: dedicated `1764` profile, doubled-table
  surface asserted absent where gated out, per-profile value locks on
  `REU_BANKS_USED`/`RESIDENT_BYTES`/`COLD_BYTES` (a seeded wrong
  value fails loudly).
- Stale `$1E00-$1FFF sqtab2` memory-map row dropped (removed in
  Phase 2).

## No perf / CT deltas

PRG byte-identical to v0.8.0
(`905bb969f027d02b4671ab04436d8c817b2f3fcfe31200af98931f6151b95acc`);
all v0.8.0 bench, hardware A/B, and CT catalogue L1–L30 results carry
forward unchanged.

## Tarball (DRAFT — filled by the post-tag SHA-fill PR)

```
File:     c64-x25519-v0.10.1.tar.gz
Size:     DRAFT
SHA256:   DRAFT
```
