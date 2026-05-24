# Precalculated tables — c64-x25519

This document enumerates every precalculated table shipped by
`c64-x25519` that meets the c64-lib-contract SPEC §8.0
("Catch loop: enumeration at adopter intake") floor:

- size ≥ 256 B, AND
- one of: REU-resident, hot-loop-read, or page-aligned.

The list below is **authoritative against the `LIB_PRECALC_TABLE` macro
invocations in `src/lib_version.s`**. The two forms (this doc and the
macro invocations) MUST remain in lock-step — an asymmetry between them
blocks adopter PRs per the intake-reviewer rule in c64-lib-contract
`adopters.md` step 6. To re-audit:

```
od65 --dump-exports build/lib_version.o | grep LIB_PRECALC
grep -n LIB_PRECALC_TABLE src/lib_version.s
```

Both forms must enumerate the same set of `(name, size, region, shared)`
tuples. The doc captures the **rationale** field — which the macro
cannot — so a future audit run can mechanically judge whether each
classification still holds.

## Tables

| Name | Size (B) | Region | Source file | Classification | Rationale |
|---|---:|---|---|---|---|
| `sqtab` | 1024 | RAM | `src/x25519_init.s` (sqtab_init), `src/mul_8x8.s`, `src/fe25519.s` | Shareable (§8.1 normative) | Two 512-byte byte tables (`sqtab_lo`, `sqtab_hi`) implementing the quarter-square identity `a*b = floor((a+b)^2/4) - floor((a-b)^2/4)`. Bit-identical to the sibling implementations in `c64-nist-curves` and `c64-ChaCha20-Poly1305`; canonical placement equate is `LIB_SHARED_SQTAB_BASE`. Already adopted per §8.1 (v0.6.0, PR #56). |
| `reu_mul` | 131072 | REU | `src/x25519_init.s` (`reu_mul_init`), `src/x25519_init.s` (`reu_fetch_mul_row`) | Shareable (§8.2 normative) | Two contiguous REU banks (128 KB) of pre-computed `(a, b) -> a*b` rows, 256 rows × 512 bytes each. Bit-identical to `c64-nist-curves`'s mul table at the default `--asm-define` setting (banks `$00`/`$01`); the §8.2 adoption (this PR) lets a consumer linking both libraries supply one base bank via `LIB_SHARED_REU_MUL_BANK` and avoid a wasted 128 KB. |
| `reu_mul_doubled` | 196608 | REU | `src/x25519_init.s` (`reu_mul_init` under `.if ::SQR_DMA_K`), `src/x25519_init.s` (`reu_fetch_doubled_row`) | Curve-specific (Curve25519 8f+8g squaring optimization) | Three REU banks (192 KB) of pre-doubled (`2 * a * b`) lo/hi tables plus a 17th-bit carry table, generated only under the default `SQR_DMA_K > 0` profile. Consumed by `fe25519_sqr`'s outer-i < K hybrid DMA dispatch (the 8f+8g cross-term path) — see `docs/CT_ANALYSIS.md` Phase 6. The pre-doubling trick has no current P-256 / P-384 analogue, so this table is correctly x25519-private today. **Audit re-classification trigger** (SPEC §8.0): if `c448` or `Ed448` ever land in this stack and use the same pre-doubling step, this entry must be re-classified as `Shareable` and a new §8.x clause filed. The `lib-x25519-1764` variant (`SQR_DMA_K = 0`) gates out generation entirely and the `LIB_PRECALC_reu_mul_doubled_*` exports are not emitted in that build. |

## Cross-reference

- `LIB_X25519_SHARED_PRIMITIVES` (`src/lib_version.s`) ORs in the §8.1
  + §8.2 ownership bits (`$0001 | $0002 = $0003`). Consumers cross-check
  this against sibling libraries' equivalent manifests via the §8.0
  double-ownership `.assert`.
- Tables flagged `PRECALC_SHARED_YES` here are the ones whose
  `LIB_PRECALC_<name>_*` exports cross-adopters can audit via
  `od65 --dump-exports build/lib/libx25519.a | grep LIB_PRECALC_<name>`.
  A byte-identical match across two or more adopters is a §8.x promotion
  candidate per the SPEC §8.0 audit triggers.
- The `reu_mul_doubled` entry illustrates the SPEC §8.0 "generalisation
  of a previously curve-/algorithm-specific table" audit trigger — the
  rationale field above is the load-bearing record a future audit reads
  before deciding whether to re-classify.
