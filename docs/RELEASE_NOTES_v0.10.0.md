# c64-x25519 v0.10.0 — ABI generation bump (v0.9.0 erratum) + v0.7.4 precalc macro

Two small items since v0.9.0, one of them a signal-only correction
(MINOR bump; `LIB_X25519_ABI_VERSION` **1 → 2**; **zero code change**
— the test-harness PRG remains byte-identical to v0.8.0/v0.9.0,
SHA256 `905bb969…b95acc`, so all carried perf and CT results remain
authoritative):

- **`LIB_X25519_ABI_VERSION` 1 → 2** — erratum for v0.9.0 (below).
- **#85/#86 — `precalc_table.inc` re-copied from the contract v0.7.4
  canonical**: the §8.4 macro now exports the byte-valued
  `_REGION`/`_SHARED` equates with `: abs` hints. Measured: a consumer
  importing all six `LIB_X25519_PRECALC_*_{REGION,SHARED}` equates got
  six `ld65: Warning: Address size mismatch` warnings against v0.9.0,
  zero against this release. `_SIZE` stays unhinted upstream by design
  — `reu_mul` (131,072 B) and `reu_mul_doubled` (196,608 B) exceed 16
  bits and export `far` (contract #58; 6502-side `.import ...: far` is
  rejected, the known §8.4 limitation behind the `od65` out-of-band
  pattern for >64 KB tables).

## ⚠ Erratum: v0.9.0 was a breaking export change; its ABI equate did not say so

v0.9.0 removed three exported symbols —
`LIB_SHARED_PRIMITIVES_{SQTAB,REU_MUL,CT_MUL_8X8}` — and kept
`LIB_X25519_ABI_VERSION = 1`, reasoning that the exports were
themselves a contract violation with a header-compatible replacement.
Contract **v0.7.5** (issue contract#66) has since resolved the §1/§7
ABI-semantics contradiction the other way: `LIB_<X>_ABI_VERSION` is a
monotonic generation counter for the exported surface, incremented on
**any** breaking export change, independent of MAJOR — precisely
because pre-1.0 breakage rides MINOR bumps, MAJOR carries no signal,
and the equate is the only load-bearing consumer gate. The measured
cost of under-signaling is the c64-nist-curves case that motivated the
clarification: 17 exports removed on a MINOR bump with the equate
unchanged, and consumer guards written to catch exactly that stayed
silent (fixed by their nist-curves#95 bump — the precedent this
release mirrors).

Practical consumer guidance:

- The **surface** change happened at **v0.9.0**; the **counter**
  catches up at **v0.10.0**. If you pin
  `.if LIB_X25519_ABI_VERSION <> 1`, treat v0.9.0 as the generation-2
  boundary despite its equate.
- What broke, concretely: hand-written
  `.import LIB_SHARED_PRIMITIVES_*` lines (ld65 unresolved external).
  Consumers using `x25519.inc` were and remain unaffected — the header
  supplies the constants as `.ifndef`-guarded equates.
- Nothing else about the exported surface changed between v0.9.0 and
  v0.10.0; a consumer that already links v0.9.0 cleanly needs only to
  update its ABI pin from `1` to `2`.

The versioning-policy banner in `src/lib_version.s` and the
`LIBRARY.md` §4.3 table now state the v0.7.5 generation-counter
semantics (the old "tracks MAJOR" phrasing reproduced the SPEC
contradiction locally).

## No perf / CT deltas

No runtime code changed in v0.9.0 or v0.10.0. The release-commit PRG
is byte-identical to v0.8.0
(`905bb969f027d02b4671ab04436d8c817b2f3fcfe31200af98931f6151b95acc`),
carrying the v0.8.0 `test-slow` pass, bench rows (262,318,045 /
303,852,663 / 449,589,657 cycles), hardware A/B results, and CT
catalogue L1–L30 forward unchanged.

## Tarball

```
File:     c64-x25519-v0.10.0.tar.gz
Size:     120,686 bytes
SHA256:   7c470b9920599d4fccc47d25f27f8cb6097698e71e8a5b58e89a77586e65a398
```

Byte-identical across two independent `make dist` runs; every shipped
source verified to assemble standalone from the extracted tarball.

Built via `make dist VERSION=v0.10.0` (reproducible; `git archive` +
`gzip -n`).
