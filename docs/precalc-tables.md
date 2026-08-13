# Precalculated tables — c64-x25519

This document enumerates every precalculated table shipped by
`c64-x25519` that meets the c64-lib-contract SPEC §8.0
("Catch loop: enumeration at adopter intake") floor:

- size ≥ 256 B, AND
- one of: REU-resident, hot-loop-read, or page-aligned.

The list below is **authoritative against the `LIB_PRECALC_TABLE` macro
invocations in `src/lib_manifest.s`** (moved out of `src/lib_version.s`
by the SPEC v0.7.0 §1 TU split, issues #78–#80). The two forms (this
doc and the macro invocations) MUST remain in lock-step — an asymmetry
between them blocks adopter PRs per the intake-reviewer rule in
c64-lib-contract `adopters.md` step 6. To re-audit (pattern is
`_PRECALC_`, which matches the v0.7.0 prefixed `LIB_X25519_PRECALC_*`
triples and the deprecated bare `LIB_PRECALC_*` ones; `od65` reads
objects, not archives — never point it at a `.a`):

```
od65 --dump-exports build/lib_manifest.o | grep _PRECALC_
grep -n LIB_PRECALC_TABLE src/lib_manifest.s

# variant archives export a smaller set — audit each against its own row
od65 --dump-exports build-1764/lib_manifest.o   | grep _PRECALC_
od65 --dump-exports build-onchip/lib_manifest.o | grep _PRECALC_
```

Both forms must enumerate the same set of `(name, size, region, shared)`
tuples. The doc captures the **rationale** field — which the macro
cannot — so a future audit run can mechanically judge whether each
classification still holds.

**Per-profile scope.** The set is not the same in every build profile,
so the symmetry rule is evaluated *per profile* — each row below
carries a **Profiles** column naming the builds in which the macro
invocation actually fires. The gates live next to the
`LIB_PRECALC_TABLE` calls in `src/lib_manifest.s`
(`.if ::X25519_ONCHIP_MUL = 0` for `reu_mul`, `.if SQR_DMA_K` for
`reu_mul_doubled`), so `od65 --dump-exports` against a variant archive
sees a correspondingly smaller set. The three profiles are the default
build (`make lib`), `lib-x25519-1764` (`SQR_DMA_K=0`), and
`lib-x25519-onchip` (`X25519_ONCHIP_MUL=1`, no REU at all) — see
`docs/LIBRARY.md` §4.7 and §4.11.

## Tables

| Name | Size (B) | Region | Profiles | Source file | Classification | Rationale |
|---|---:|---|---|---|---|---|
| `sqtab` | 1024 | RAM | **all profiles** | `src/x25519_init.s` (sqtab_init), `src/mul_8x8.s`, `src/fe25519.s` | Shareable (§8.1 normative) | Two 512-byte byte tables (`sqtab_lo`, `sqtab_hi`) implementing the quarter-square identity `a*b = floor((a+b)^2/4) - floor((a-b)^2/4)`. Bit-identical to the sibling implementations in `c64-nist-curves` and `c64-ChaCha20-Poly1305`; canonical placement equate is `LIB_SHARED_SQTAB_BASE`. Already adopted per §8.1 (v0.6.0, PR #56). The one table present in every profile — and under `lib-x25519-onchip` it is read on *every* product by the on-chip row generator, so it moves from warm to firmly hot there. |
| `reu_mul` | 131072 | REU | default, `lib-x25519-1764` — **absent under `lib-x25519-onchip`** | `src/x25519_init.s` (`reu_mul_init`), `src/x25519_init.s` (`reu_fetch_mul_row`) | Shareable (§8.2 normative) | Two contiguous REU banks (128 KB) of pre-computed `(a, b) -> a*b` rows, 256 rows × 512 bytes each. Bit-identical to `c64-nist-curves`'s mul table at the default `-D` setting (banks `$00`/`$01`); the §8.2 adoption (this PR) lets a consumer linking both libraries supply one base bank via `LIB_SHARED_REU_MUL_BANK` and avoid a wasted 128 KB. Gated out entirely under `lib-x25519-onchip` (issue #72), which computes product rows on-chip and builds no REU table — the `LIB_PRECALC_reu_mul_*` exports are not emitted in that build, and the matching §8.2 bit is omitted from `LIB_X25519_SHARED_PRIMITIVES` (`$0005`, not `$0007`). Omission, not deferral: that profile does not define `SHARED_REU_MUL_INIT`, because there is no provider to defer to. |
| `reu_mul_doubled` | 196608 | REU | default build only — absent under both `lib-x25519-1764` and `lib-x25519-onchip` | `src/x25519_init.s` (`reu_mul_init` under `.if ::SQR_DMA_K`), `src/x25519_init.s` (`reu_fetch_doubled_row`) | Curve-specific (Curve25519 8f+8g squaring optimization) | Three REU banks (192 KB) of pre-doubled (`2 * a * b`) lo/hi tables plus a 17th-bit carry table, generated only under the default `SQR_DMA_K > 0` profile. Consumed by `fe25519_sqr`'s outer-i < K hybrid DMA dispatch (the 8f+8g cross-term path) — see `docs/CT_ANALYSIS.md` Phase 6. The pre-doubling trick has no current P-256 / P-384 analogue, so this table is correctly x25519-private today. **Audit re-classification trigger** (SPEC §8.0): if `c448` or `Ed448` ever land in this stack and use the same pre-doubling step, this entry must be re-classified as `Shareable` and a new §8.x clause filed. The `lib-x25519-1764` variant (`SQR_DMA_K = 0`) gates out generation entirely and the `LIB_PRECALC_reu_mul_doubled_*` exports are not emitted in that build. `lib-x25519-onchip` reaches the same state by a different route: it forces `SQR_DMA_K = 0` as part of the profile (there is no REU to DMA from), so the doubled tables are absent there too. |

## Cross-reference

- `LIB_X25519_SHARED_PRIMITIVES` (`src/lib_manifest.s`) ORs in the
  ownership bits for §8.1 (`$0001`), §8.2 (`$0002`), and §8.3
  (`$0004`) — `$0007` for a standalone default build, `$0005` for a
  standalone `lib-x25519-onchip` build, which owns no §8.2 table.
  Consumers cross-check this against sibling libraries' equivalent
  manifests via the §8.0 double-ownership `.assert`, and check
  provider coverage via the SPEC v0.5.0 `LIB_X25519_SHARED_CONSUMES`
  companion mask (issues #78/#81).
- Tables flagged `PRECALC_SHARED_YES` here are the ones whose
  `LIB_X25519_PRECALC_<name>_*` exports cross-adopters can audit via
  `od65 --dump-exports build/lib/lib_manifest.o | grep _PRECALC_<name>`
  (per-object dump — `od65` cannot read `.a` archives, SPEC v0.7.2).
  A byte-identical match across two or more adopters is a §8.x promotion
  candidate per the SPEC §8.0 audit triggers.
- The `reu_mul_doubled` entry illustrates the SPEC §8.0 "generalisation
  of a previously curve-/algorithm-specific table" audit trigger — the
  rationale field above is the load-bearing record a future audit reads
  before deciding whether to re-classify.
