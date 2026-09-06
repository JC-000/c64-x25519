.setcpu "6502"

; =============================================================================
; c64-x25519 §8.4 precalc-table enumeration — ISOLATED TRANSLATION UNIT
; =============================================================================
;
; This file exists ONLY to hold the LIB_PRECALC_TABLE invocations, and it
; must stay that way. It is not a stylistic split.
;
; c64-lib-contract SPEC v1.2.2 §6.1 "Member isolation" (quote the TAG you
; conform to -- §6.1 was corrected twice on 2026-09-06 and the v1.2.0
; wording, which lacked the prefixed-counterparts exception, would have made
; this very file non-conformant):
;
;   ld65 links whole archive members. A symbol a consumer may displace --
;   suppress under LIB_NO_BARE_EXPORTS, or define itself under APP_OWNED
;   (SS8.0) -- MUST live in a translation unit that exports nothing else a
;   consumer may import -- other displaceable names included, THEIR OWN
;   PREFIXED COUNTERPARTS EXCEPTED -- and defines nothing else the
;   library's own code references. Otherwise the member arrives uninvited
;   and its displaceable names collide -- with the consumer's own
;   definitions, or with the identical bare name a sibling library exports
;   -- and the consumer can repair neither: member surgery is banned above.
;
; The macro emits the deprecated BARE triple LIB_PRECALC_<name>_{SIZE,
; REGION,SHARED} unless LIB_NO_BARE_EXPORTS is defined. Those names are
; identical in every §8.4 adopter, so they are exactly the displaceable
; class the rule governs. Until v0.14.0 they lived in src/lib_manifest.s
; beside the six LIB_X25519_* §5 aggregates that §5 REQUIRES a composing
; consumer to import — so importing a footprint equate pulled this member
; in and collided on names the consumer never referenced. Measured before
; the split (ca65 2.19 / ld65 V2.18), with a consumer importing only two
; prefixed §5 equates from two libraries and referencing no bare name:
;
;   ld65: Error: Duplicate external identifier: 'LIB_PRECALC_sqtab_SHARED'
;
; Raised as c64-lib-contract#177, settled at SPEC v1.2.0 and corrected to
; its final wording at v1.2.2. The rule is stated once, in §6.1, with §1
; and §8.4 citing it rather than restating it.
;
; DO NOT add anything else to this file — no §5 equates, no §1 version
; equates, no code, no data. c64-nist-curves keeps the same shape in its
; own src/precalc_manifest.s.
;
; §8.4's separate requirement — "The macro MUST be included from a single
; translation unit" — is NOT this rule and is not discharged by it. That
; one governs how many TUs may emit the triple; this file is that one TU.
;
; Discovery moved with the block: the audit command is now
;   od65 --dump-exports build/lib/precalc_manifest.o | grep _PRECALC_
; (the pattern is `_PRECALC_`, not `LIB_PRECALC_` — the latter silently
; misses every prefixed export; SPEC v0.7.0.)
; =============================================================================

; SQR_DMA_K and X25519_ONCHIP_MUL gate which tables this build ships.
; constants.s already sets ZP_CONFIG_NO_EXPORTS / REU_CONFIG_NO_EXPORTS,
; so this transitive include does not double-emit consumer-facing
; exports — which is also what keeps this TU isolated.
.include "constants.s"

; =============================================================================
; Enumeration (c64-lib-contract §8.4)
; =============================================================================
;
; Per §8.4 every adopter enumerates each precalculated table it ships of
; 256 bytes or more that is REU-resident, read in a per-byte or per-row
; inner loop, or page-aligned for fetch alignment, in two forms:
;
;   1. Doc-level — docs/precalc-tables.md (name, size, region, source,
;      classification, rationale). The rationale field is load-bearing
;      for the cross-adopter audit (e.g. "could c448 / Ed448 ever land
;      with the same pre-doubling trick?").
;   2. Assembler-level — the LIB_PRECALC_TABLE invocations below, each
;      emitting LIB_X25519_PRECALC_<name>_{SIZE,REGION,SHARED} plus,
;      unless LIB_NO_BARE_EXPORTS is defined, the deprecated bare triple.
;
; Both forms MUST stay in lock-step. Asymmetry between them blocks
; adopter PRs per the intake-reviewer rule in c64-lib-contract
; adopters.md step 6.
;
; The canonical macro source `precalc_table.inc` is copied verbatim from
; c64-lib-contract's repo root; do not edit the local copy.
;
; Canonical names "sqtab" (§8.1) and "reu_mul" (§8.2) are NORMATIVE — do
; not prefix them with library/curve names. The fifth macro argument is
; the library prefix (§8.4): it identifies the DECLARING library, never
; the table, so a consumer linking two adopters can cross-check that they
; agree on a shared table's shape:
;   .assert LIB_X25519_PRECALC_sqtab_SIZE = LIB_<other>_PRECALC_sqtab_SIZE
; =============================================================================

.include "precalc_table.inc"

LIB_PRECALC_TABLE "sqtab",           1024,   PRECALC_REGION_RAM, PRECALC_SHARED_YES, "X25519"
.if ::X25519_ONCHIP_MUL = 0
; reu_mul claim dropped under the onchip profile (issue #72): the
; profile builds no REU table. Per the §8.4 symmetry rule the matching
; docs/precalc-tables.md row carries a per-profile annotation (see that
; file). sqtab stays — the onchip generator reads it on every product.
LIB_PRECALC_TABLE "reu_mul",         131072, PRECALC_REGION_REU, PRECALC_SHARED_YES, "X25519"
.endif
.if SQR_DMA_K
; The pre-doubled tables (banks +3..+5) only exist in the default
; SQR_DMA_K > 0 build; gated out in the lib-x25519-1764 variant so this
; macro invocation does not emit LIB_PRECALC_reu_mul_doubled_* exports
; in that build (matches the LIB_X25519_REU_BANKS_USED mask flip).
;
; Size = 3 × 65,536 B (one full REU bank each):
;   bank LIB_SHARED_REU_MUL_BANK + 3: 17th-bit carry table, 256 B × 256 rows = 64 KB
;   bank LIB_SHARED_REU_MUL_BANK + 4: doubled lo+hi, a = 0..127             = 64 KB
;   bank LIB_SHARED_REU_MUL_BANK + 5: doubled lo+hi, a = 128..255           = 64 KB
;                                                                  total: 196608 B
LIB_PRECALC_TABLE "reu_mul_doubled", 196608, PRECALC_REGION_REU, PRECALC_SHARED_NO, "X25519"
.endif
