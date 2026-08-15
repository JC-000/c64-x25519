# c64-x25519 v0.11.0 — phase-3 wave: contract v0.9.2 alignment, composed-link fixes, ABI generation 3

The coordinated fleet-wave release (c64-lib-contract #76 phase 3;
sibling wave tags: polyval v0.6.0, ChaCha20-Poly1305 v0.8.0). MINOR
bump; **`LIB_X25519_ABI_VERSION` 2 → 3**; **zero runtime change** —
the test-harness PRG is byte-identical to v0.8.0 through v0.10.1
(SHA256 `905bb969…b95acc`), so every carried perf, hardware A/B, and
CT result (catalogue L1–L30) remains authoritative.

Rolls up PRs #92, #93, #94, #95 — the contract #82/#83 collision
fixes and the full SPEC v0.9.0–v0.9.2 §6-chapter migration.

## Why ABI 2 → 3 (what breaks, what to do)

Breaking export-surface changes, per the v0.7.5 generation-counter
rule:

- **Bare `LIB_SHARED_REU_MUL_*` no longer exported** (#92,
  contract#82): they are consumer-*input* knobs. The archive now
  exports `LIB_X25519_SHARED_REU_MUL_{BANK,OFFSET,BANKS_USED,
  STAGE_LO,STAGE_HI,ZP_INIT_A,ZP_INIT_B}` — output, whose values are
  the values the code reads (the old `LIB_SHARED_REU_MUL_BANK` was
  decorative; the override now genuinely relocates the table).
- **`zp_ptr1`/`zp_tmp1`/`zp_tmp2` no longer exported** (#93,
  contract#83): test-harness scratch, never library surface.
- **`poly_carry` → `mul_carry`** (#95, §2 ZP prefix registry —
  `poly_` is chacha-registered): hard rename, no dual-name window
  (contract#88 rationale — the window would have kept the collision
  alive). Same address (`$1C`), same semantics.
- Under `SHARED_SQTAB_INIT` the archive no longer exports
  `sqtab_init`/`mul_tables_init` stubs (import-never-stub, §8.1) —
  deferral-config-only change; standalone consumers unaffected.

Consumer actions: update the ABI pin to `= 3`; if you imported any of
the removed names, switch to the prefixed outputs / `mul_carry`; if
you hand-rolled the app-owned define set, `make lib-app-owned` now
encapsulates it.

## Contract v0.9.0–v0.9.2 adoption (PR #95)

- **§6.2 defines-forwarding**: `CONTRACT_DEFINES` +
  `CONTRACT_ZP_DEFINES` (`CA65FLAGS` stays as a deprecated alias).
  ZP defines reach every slot-defining TU and never `.importzp`
  consumer TUs — the model-independent rule v0.9.1-D adopted from
  this repo's measurement. Variant targets append profile defines;
  the old recursive-make hard-assign silently dropped consumer
  overrides.
- **§8.1 import-never-stub**: deferring builds import the provider's
  `mul_tables_init`; the old `rts` stub (two exported canonical
  inits per composed link — this repo was the clause's measured
  example) is gone.
- **§8.2 fetch deferral**: new `SHARED_REU_MUL_FETCH`, coupled to
  `SHARED_REU_MUL_INIT` by a named assemble-time error (v0.9.1-C);
  `bank_patch` imported conditionally per v0.9.2 (only when
  `SQR_DMA_K > 0` delegates through it).
- **§6.4 truthful per-config manifests**: `RESIDENT`/`COLD` react to
  deferral switches via od65-measured deltas (sqtab −160 COLD, reu
  pair −364/−186 COLD by `SQR_DMA_K` + −20 RESIDENT, ct −63
  RESIDENT). Pre-migration COLD over-claimed up to +164 % in
  deferral builds; the per-profile verify locks now pin the measured
  values.
- **§6.3**: `make lib-app-owned` → `build/lib/x25519-app-owned.a`
  (all §8.x primitives app-owned; masks `$0000`/`$0007`).
- **§6.1**: canonical archive basenames `x25519[-variant].a` ship
  alongside the deprecated `libx25519*` dialect (dropped at next
  MAJOR).

## Composed-link status (the c64-https / wireguard pair)

With this tag and chacha v0.8.0, both halves of the contract #43/#82/
#83 collision family are fixed *at tag-pinned refs*. The remaining
composed-link duplicates measured in the #82 audit are resolved
structurally by the v0.9.x switch family this release implements.

## No perf / CT deltas

No runtime code changed anywhere in v0.10.1 → v0.11.0. PRG
byte-identical to v0.8.0
(`905bb969f027d02b4671ab04436d8c817b2f3fcfe31200af98931f6151b95acc`);
bench rows, hardware A/B results, and CT catalogue L1–L30 carry
forward unchanged.

## Tarball (DRAFT — filled by the post-tag SHA-fill PR)

```
File:     c64-x25519-v0.11.0.tar.gz
Size:     DRAFT
SHA256:   DRAFT
```
