.setcpu "6502"

; Pull SQR_DMA_K (controls fe25519_sqr's DMA-vs-mult66 path threshold;
; see src/constants.s) and X25519_REU_BANK so the LIB_X25519_* manifest
; equates below can react to the build-time configuration. constants.s
; already sets ZP_CONFIG_NO_EXPORTS / REU_CONFIG_NO_EXPORTS so this
; transitive include doesn't double-emit consumer-facing exports.
.include "constants.s"

; =============================================================================
; c64-x25519 aggregate manifest (c64-lib-contract §5 + §8.x)
;
; Split out of src/lib_version.s per SPEC v0.7.0 §1 TU isolation
; (issues #78/#79): ld65 links whole object members, so the §5
; aggregates a consumer legitimately imports must not share a member
; with the deprecated bare §1 version names. This TU carries the §5
; aggregates, the §8.x masks, and the §8.4 precalc-table enumeration;
; src/lib_version.s carries the §1 version equates and nothing else.
;
; These integer equates let a consumer cfg do assemble-time fit /
; collision checks before kicking off a 30-min compile + test cycle.
; SPEC §5 allows the numbers to be approximate ("within 5% is fine");
; the library author refreshes them when a release substantively
; changes any one of them.
;
; LIB_X25519_ZP_USAGE_BYTES
;   Total bytes of ZP slots c64-x25519 claims while running. Sum of
;   every `.exportzp`-ed slot in src/zp_config.s plus the (unexported)
;   fe_wide region in constants.s:
;     $14-$16 fe_cmp_mask/fe_subp_rhs/fe_add_carry_mask  = 3 B
;     $1C     mul_carry                                  = 1 B
;     $1E-$2A fe25519_src1..x25_prev_bit (contiguous)     = 13 B
;     $2C-$2F x25_byte_idx..mul_ripple_start              = 4 B
;     $40-$7F fe_wide (CT/SMC-pinned)                     = 64 B
;     ------------------------------------------------------------
;                                                          85 B total
;   (Prior in-source comments and README claimed "87 bytes" via a
;   stale double-count of $24-$25 within the $1E-$2A range; PR #51
;   landed the textual cleanup so README / constants.s / x25519.inc
;   / LIBRARY.md now agree with this equate.)
;
; LIB_X25519_REU_BANKS_USED
;   Bitmask of REU banks claimed for the precomputed multiplication
;   tables. Depends on the SQR_DMA_K build constant:
;
;     SQR_DMA_K > 0 (default, =22):
;       Banks 0, 1, 3, 4, 5 used (= base mask $3B). Mul tables + the
;       pre-doubled tables for fe25519_sqr's DMA path. Library needs a
;       512 KB REU (1750) at minimum.
;
;     SQR_DMA_K = 0 (lib-x25519-1764 build variant):
;       Banks 0, 1 only (= base mask $03). fe25519_sqr's DMA dispatch
;       never fires; the inline mult66 path handles every cross-term.
;       Doubled-table generation in reu_mul_init is gated out. Library
;       fits a 256 KB REU (1764). +16.2 % scalarmult cost — see
;       docs/REU_USAGE_ANALYSIS.md.
;
;   Bank 2 is intentionally NOT claimed in either configuration — the
;   v0.4.0 W2 refactor moved reu_clear_wide to a CPU clear and the
;   legacy bank-2 zero stash was removed in v0.6 prep.
;
;   Mask is computed as `<base> << X25519_REU_BANK` so an
;   `-D X25519_REU_BANK=0x<bank>` override of the bank base automatically
;   shifts the claim. (Bank 7 is touched transiently by reu_probe but
;   restored before return; not counted as a claim.)
;
; LIB_X25519_RESIDENT_BYTES
;   Approximate code + data footprint that must remain CPU-resident
;   in any consumer's address space. Depends on the SQR_DMA_K build
;   constant (the 1764 variant drops the @dbl_gen / doubled-stash
;   sections from reu_mul_init):
;
;     SQR_DMA_K > 0 (default, =22):
;       LIB_X25519_CODE total ≈ 3775 B  (x25519 717 + fe25519 2711 +
;                               mul_8x8 63 + x25519_init 132 + util 152)
;       LIB_X25519_DATA total ≈ 3584 B
;       SQTAB         1024 B
;       ---------------------------------------------------------------
;                            ≈ 8383 B RESIDENT
;       LIB_X25519_INIT_CODE ≈ 826 B COLD (x25519_init 666 =
;                               reu_mul_init 364 + reu_probe 302;
;                               mul_8x8 160 = sqtab_init + sq_* temps)
;
;     SQR_DMA_K = 0 (lib-x25519-1764 variant):
;       LIB_X25519_CODE total ≈ 3639 B  (x25519_init.o library code
;                               drops to 50 B — reu_fetch_doubled_row
;                               gated out — and fe25519.o to 2657 B per
;                               the #61 .if ::SQR_DMA_K DMA-dispatch
;                               gating)
;       LIB_X25519_DATA total ≈ 3584 B
;       SQTAB         1024 B
;       ---------------------------------------------------------------
;                            ≈ 8247 B RESIDENT
;       LIB_X25519_INIT_CODE ≈ 648 B COLD (reu_mul_init loses the
;                               doubled-table generation at K=0)
;
;   (Refreshed 2026-07-19 for the issue-#68 cold-segment split: the
;   init-only procs moved to LIB_X25519_INIT_CODE, so RESIDENT and
;   COLD are now the SPEC §5 disjoint partition — RESIDENT dropped by
;   exactly the COLD amount vs the v0.7.0 numbers (9209/8895). The
;   §8.3 ct_mul_8x8 body (59 B + 4 B scratch) deliberately stays
;   RESIDENT — owner-mode composed builds take runtime calls from
;   deferring siblings. See docs/design/issue_68_cold_segment_split.md.
;   The four config .o files ─ lib_version.o, lib_manifest.o,
;   zp_config.o, reu_config.o ─ emit no code or data bytes into any
;   LIB_X25519_* segment and don't shift totals.)
;
; LIB_X25519_COLD_BYTES
;   Approximate code + data footprint that a consumer MAY overlay-page
;   or reclaim (SPEC §5; disjoint from RESIDENT). As of the issue-#68
;   split this is real: the LIB_X25519_INIT_CODE segment holds the
;   init-only procs (sqtab_init, reu_mul_init, reu_probe), placed last
;   in MAIN by the shipped cfgs so a consumer can reuse the RAM as a
;   contiguous tail after its boot sequence has called the init entry
;   points. ld65 exports __LIB_X25519_INIT_CODE_LOAD__/_SIZE__
;   (define = yes) for computing the reclaim window. Init entry points
;   MUST NOT be called again after reclaim.
;
; LIB_X25519_SHARED_PRIMITIVES
;   c64-lib-contract §5 + §8.0-§8.3 append-only bitmask. One bit per
;   contract-§8 shared primitive this build OWNS. Per SPEC v0.4.0
;   §8.0 the mask is CONDITIONAL: a bit is set iff this build does
;   NOT define that primitive's deferral switch (the invariant the
;   .ifdef blocks below implement):
;     bit $0001  LIB_SHARED_PRIMITIVES_SQTAB      — 8x8 quarter-square
;                multiply table (§8.1); dropped under SHARED_SQTAB_INIT
;     bit $0002  LIB_SHARED_PRIMITIVES_REU_MUL    — 128 KB 8x8->16 REU
;                multiplication table (§8.2); dropped under
;                SHARED_REU_MUL_INIT
;     bit $0004  LIB_SHARED_PRIMITIVES_CT_MUL_8X8 — CT 8x8->16 multiply
;                body (§8.3); dropped under SHARED_CT_MUL_8X8
;   c64-x25519 consumes all three:
;     - sqtab: mul_8x8 + the mult66 path inside fe25519_sqr both read
;       sqtab_lo / sqtab_hi at runtime.
;     - reu_mul: reu_mul_init builds 256 rows × 512 B in REU banks
;       LIB_SHARED_REU_MUL_BANK / +1; reu_fetch_mul_row DMAs them
;       row-by-row into mul_dma_lo/hi.
;     - ct_mul_8x8: the canonical §8.3 multiply body in src/mul_8x8.s
;       (byte-identical to the chacha owner; `mul_8x8` is the
;       back-compat alias label).
;   A standalone build (no switches defined) claims all three → $0007.
;   An integrated build drops the bit for each primitive it defers to
;   a canonical provider, so a consumer composing c64-x25519 with
;   another §8 adopter asserts:
;     .import LIB_X25519_SHARED_PRIMITIVES, LIB_<other>_SHARED_PRIMITIVES
;     .assert (LIB_X25519_SHARED_PRIMITIVES & \
;              LIB_<other>_SHARED_PRIMITIVES) = 0, error, \
;              "shared-primitive double-ownership — exactly one \
;               provider must own each shared primitive; the other(s) \
;               must build with that primitive's SHARED_* switch defined"
;   which holds for correctly-composed builds because the deferring
;   side's bits drop out (c64-lib-contract#21 fix, SPEC v0.4.0).
;
; LIB_X25519_SHARED_CONSUMES
;   c64-lib-contract §5 + §8.0 companion mask (required, SPEC v0.5.0;
;   issues #78/#81). Bit set iff this build configuration CONSUMES the
;   primitive at all — a SHARED_* deferral switch does NOT clear it
;   (the deferring build still reads the primitive at runtime and
;   needs exactly one owner in the link plus boot-time init); only a
;   profile gate or permanent non-consumption does. This is what lets
;   a consumer distinguish the two clear-ownership-bit states that
;   export identical LIB_X25519_SHARED_PRIMITIVES = $0005 masks:
;     SHARED_REU_MUL_INIT deferral: CONSUMES = $0007 (provider needed)
;     X25519_ONCHIP_MUL profile:    CONSUMES = $0005 (no §8.2 table
;                                   exists; no provider obligation)
;   Subset invariant pinned below: OWNED ⊆ CONSUMED, always.
; =============================================================================

; X25519_REU_BANK comes in via the `.include "constants.s"` at the top
; of this file (which transitively includes reu_config.s with
; REU_CONFIG_NO_EXPORTS set so we don't re-emit the public export
; here). The shift in LIB_X25519_REU_BANKS_USED below resolves at
; assemble time when SQR_DMA_K is known and at link time for the
; bank-base shift.

LIB_X25519_ZP_USAGE_BYTES = 85
.if ::X25519_ONCHIP_MUL
; Onchip profile (issue #72): zero REU banks — this zero IS the SPEC §5
; "no REU" declaration ("Zero if no REU", SPEC.md §5; polyval
; precedent). RESIDENT = LIB_X25519_CODE (3599) + LIB_X25519_DATA
; (3584) + sqtab (1024); COLD = LIB_X25519_INIT_CODE (sqtab_init only
; — reu_mul_init/reu_probe are gated out). Measured via od65 at
; v0.8.0 (`make lib-x25519-onchip` prints the per-object dump).
LIB_X25519_REU_BANKS_USED = 0
_BASE_RESIDENT = 8207
_BASE_COLD     = 160
.elseif SQR_DMA_K
LIB_X25519_REU_BANKS_USED = $3B << X25519_REU_BANK
_BASE_RESIDENT = 8383
_BASE_COLD     = 826
.else
LIB_X25519_REU_BANKS_USED = $03 << X25519_REU_BANK
_BASE_RESIDENT = 8247
_BASE_COLD     = 648
.endif

; §6.4 half-2 (SPEC v0.9.0): the SHARED_* deferral switches gate real
; code out of the archive, so the footprint equates must react to them
; — the pre-migration constants over-claimed COLD by up to +164% in
; deferral builds (the measured shape §6.4 was written against, and
; the per-profile lib-verify value locks certified the fiction).
; Deltas are od65-measured per combo (2026-08-15, post import-never-
; stub migration): sqtab_init body + sq_* temps = 160 B COLD, uniform
; across profiles; reu_mul_init = 364 B COLD at SQR_DMA_K > 0 (doubled
; -table generation included) or 186 B at SQR_DMA_K = 0; the deferred
; §8.3 ct_mul_8x8 body + scratch = 63 B RESIDENT; the §8.2 fetch pair
; (SPEC v0.9.1-C: INIT and FETCH move together) additionally drops the
; resident reu_fetch_mul_row body = 20 B RESIDENT.
.ifdef SHARED_SQTAB_INIT
_D_COLD_SQ = 160
.else
_D_COLD_SQ = 0
.endif
.if .defined(SHARED_REU_MUL_INIT) .and (::X25519_ONCHIP_MUL = 0)
.if ::SQR_DMA_K
_D_COLD_REU = 364
.else
_D_COLD_REU = 186
.endif
_D_RES_REU = 20
.else
_D_COLD_REU = 0
_D_RES_REU = 0
.endif
.ifdef SHARED_CT_MUL_8X8
_D_RES_CT = 63
.else
_D_RES_CT = 0
.endif

LIB_X25519_RESIDENT_BYTES = _BASE_RESIDENT - _D_RES_CT - _D_RES_REU
LIB_X25519_COLD_BYTES     = _BASE_COLD - _D_COLD_SQ - _D_COLD_REU

; c64-lib-contract §5 / §8.x shared-primitives bit constants. Bit
; allocation is append-only — bits are never reused even if a primitive
; is later deprecated, so old consumer cfg `.assert`s keep parsing.
;
;   bit $0001 (SPEC §8.1): the 8x8 quarter-square multiply table.
;   bit $0002 (SPEC §8.2): the 128 KB 8x8->16 REU multiplication table.
;   bit $0004 (SPEC §8.3): the CT 8x8->16 multiply body (ct_mul_8x8).
;
; Deliberately NOT .export-ed (issues #77/#78 item 3): SPEC §8.0
; presents these as plain assemble-time equates every adopter copies
; verbatim — both sides of a link carry them, and only exported
; symbols can collide at link time (the §13.0 NET_FAMILY_* rationale,
; verbatim). Exporting them is what broke the two-library link with
; c64-ChaCha20-Poly1305. .ifndef-guarded (nist-curves shape) so a
; consumer that defines them globally via -D does not get a
; redefinition error.
.ifndef LIB_SHARED_PRIMITIVES_SQTAB
LIB_SHARED_PRIMITIVES_SQTAB      = $0001
.endif
.ifndef LIB_SHARED_PRIMITIVES_REU_MUL
LIB_SHARED_PRIMITIVES_REU_MUL    = $0002
.endif
.ifndef LIB_SHARED_PRIMITIVES_CT_MUL_8X8
LIB_SHARED_PRIMITIVES_CT_MUL_8X8 = $0004
.endif

; Consumption gates (SPEC v0.5.0 §8.0): profile/config gates drop bits
; from BOTH masks; SHARED_* deferral switches drop bits from the
; ownership mask only.
.if ::X25519_ONCHIP_MUL
; Onchip profile does not CONSUME §8.2 at all (no REU table exists), so
; the bit is omitted from both mask expressions — per SPEC §8.0
; "OR only the primitives this lib uses" (SPEC.md mask-construction
; comment; polyval non-consumer precedent). This is deliberately NOT
; the SHARED_REU_MUL_INIT deferral switch, which would mean "a
; canonical provider owns the table" — under onchip there is no
; provider and no table. Standalone onchip masks: $0005 / $0005.
; (nist-curves' onchip manifest still claims $0002 — a known
;  inconsistency we do not replicate; see issue #72 discussion.)
_USE_REU_MUL = 0
.else
_USE_REU_MUL = LIB_SHARED_PRIMITIVES_REU_MUL
.endif

; Ownership mask construction — SPEC v0.4.0 §8.0 required form. Each
; primitive's bit is included iff this build consumes it AND does NOT
; define that primitive's deferral switch; a build that defers a
; primitive to a canonical provider drops the bit, keeping composed
; masks disjoint so the consumer-side double-ownership .assert is
; satisfiable (c64-lib-contract#21). Standalone build: $0007.
.ifdef SHARED_SQTAB_INIT
_OWN_SQTAB   = 0
.else
_OWN_SQTAB   = LIB_SHARED_PRIMITIVES_SQTAB
.endif
.if _USE_REU_MUL = 0
_OWN_REU_MUL = 0
.elseif .defined(SHARED_REU_MUL_INIT)
_OWN_REU_MUL = 0
.else
_OWN_REU_MUL = LIB_SHARED_PRIMITIVES_REU_MUL
.endif
.ifdef SHARED_CT_MUL_8X8
_OWN_CT_MUL  = 0
.else
_OWN_CT_MUL  = LIB_SHARED_PRIMITIVES_CT_MUL_8X8
.endif

LIB_X25519_SHARED_PRIMITIVES = _OWN_SQTAB | _OWN_REU_MUL | _OWN_CT_MUL

; Consumes mask (SPEC v0.5.0 §8.0 required form). sqtab and ct_mul_8x8
; are consumed in every build config: sqtab is read by mul_8x8 /
; fe25519_sqr's mult66 path (and by the onchip row generator), and the
; §8.3 ct_mul_8x8 canonical body is exported in every non-deferring
; build — which counts as consuming it per §8.0 even where no runtime
; path calls it (a co-linked sibling's deferral may target it).
LIB_X25519_SHARED_CONSUMES = LIB_SHARED_PRIMITIVES_SQTAB | _USE_REU_MUL | LIB_SHARED_PRIMITIVES_CT_MUL_8X8

; Adopter-side subset invariant, pinned at assemble time (SPEC v0.5.0).
.assert (LIB_X25519_SHARED_PRIMITIVES & ~LIB_X25519_SHARED_CONSUMES) = 0, error, "a build cannot own a primitive it does not consume"

.export LIB_X25519_ZP_USAGE_BYTES: abs
.export LIB_X25519_REU_BANKS_USED: abs
.export LIB_X25519_RESIDENT_BYTES: abs
.export LIB_X25519_COLD_BYTES:     abs
.export LIB_X25519_SHARED_PRIMITIVES: abs
.export LIB_X25519_SHARED_CONSUMES:   abs

; =============================================================================
; c64-lib-contract SPEC §8.0 catch-loop: precalc-table enumeration
; =============================================================================
;
; Per SPEC §8.0 step-6, every adopter MUST enumerate its precalculated
; tables (size >= 256 B AND one of: REU-resident / hot-loop-read /
; page-aligned) in two forms:
;
;   1. Doc-level — docs/precalc-tables.md (name, size, region, source,
;      classification, rationale). The rationale field is load-bearing
;      for the cross-adopter audit (e.g. "could c448 / Ed448 ever land
;      with the same pre-doubling trick?").
;   2. Assembler-level — LIB_PRECALC_TABLE macro invocations (below),
;      each emitting the exported equates LIB_X25519_PRECALC_<name>_
;      {SIZE,REGION,SHARED} plus, unless LIB_NO_BARE_EXPORTS is
;      defined, the deprecated bare triple LIB_PRECALC_<name>_*.
;      Build-time discovery via
;      `od65 --dump-exports build/lib_manifest.o | grep _PRECALC_`.
;      (The audit pattern is `_PRECALC_`, not `LIB_PRECALC_` — the
;      latter silently misses every prefixed export; SPEC v0.7.0.)
;
; Both forms MUST stay in lock-step. Asymmetry between them blocks
; adopter PRs per the intake-reviewer rule in c64-lib-contract
; adopters.md step 6.
;
; The canonical macro source `precalc_table.inc` is copied verbatim
; from c64-lib-contract's repo root; do not edit the local copy.
;
; Canonical names "sqtab" (§8.1) and "reu_mul" (§8.2) are NORMATIVE —
; do not prefix them with library/curve names. The fifth macro argument
; is the library prefix (SPEC v0.7.0 §8.4): it identifies the DECLARING
; library, never the table, so a consumer linking two adopters can
; cross-check that they agree on a shared table's shape:
;   .assert LIB_X25519_PRECALC_sqtab_SIZE = LIB_<other>_PRECALC_sqtab_SIZE
; =============================================================================

.include "precalc_table.inc"

LIB_PRECALC_TABLE "sqtab",           1024,   PRECALC_REGION_RAM, PRECALC_SHARED_YES, "X25519"
.if ::X25519_ONCHIP_MUL = 0
; reu_mul claim dropped under the onchip profile (issue #72): the
; profile builds no REU table. Per the SPEC §8.0 symmetry rule the
; matching docs/precalc-tables.md row carries a per-profile
; annotation (see that file). sqtab stays — the onchip generator
; reads it on every product.
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
