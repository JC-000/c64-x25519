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
; aggregates and the §8.x masks; the §8.4 precalc-table enumeration is in
; src/precalc_manifest.s, and src/lib_version.s carries the §1 version
; equates and nothing else.
;
; These integer equates let a consumer cfg do assemble-time fit /
; collision checks before kicking off a 30-min compile + test cycle.
; SPEC §5 allows the numbers to be approximate ("within 5% is fine");
; the library author refreshes them when a release substantively
; changes any one of them.
;
; LIB_X25519_ZP_USAGE_BYTES
;   Total bytes of ZP slots c64-x25519 claims while running: the sum of
;   the sizes in src/zp_config.s's roster (x25519_zp_bytes), which is
;   also the set of `.exportzp`-ed slots. Derived, not restated; 85 B
;   with the current roster:
;     $14-$16 fe_cmp_mask/fe_subp_rhs/fe_add_carry_mask  = 3 B
;     $1C     mul_carry                                  = 1 B
;     $1E-$2A fe25519_src1..x25_prev_bit (contiguous)     = 13 B
;     $2C-$2F x25_byte_idx..mul_ripple_start              = 4 B
;     $40-$7F fe_wide                                     = 64 B
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
;   in any consumer's address space:
;
;       RESIDENT = sum(LIB_X25519_CODE) + sum(LIB_X25519_DATA)
;                  + the 1024 B sqtab window
;       COLD     = sum(LIB_X25519_INIT_CODE)
;
;   summed over the shipped archive's members. No per-member breakdown
;   is kept here, because a hand-written one drifts: `make
;   lib-verify-footprint` (run inside every lib-verify, all seven
;   profiles) derives both from `od65 --dump-segsize` and fails if the
;   _BASE_* / _D_* equates below disagree, printing the per-member
;   figures when it does. SQR_DMA_K = 0 (lib-x25519-1764) is smaller
;   because reu_fetch_doubled_row, fe25519_sqr's DMA dispatch and
;   reu_mul_init's doubled-table generation are gated out.
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
;   split this is real: the LIB_X25519_INIT_CODE segment holds every
;   init-only proc the profile builds (the boot-time table builds and
;   reu_probe), placed last in MAIN by the shipped cfgs so a consumer
;   can reuse the RAM as a contiguous tail after its boot sequence has
;   made every init call its configuration needs (src/x25519.inc,
;   "Order"). ld65 exports __LIB_X25519_INIT_CODE_LOAD__/_SIZE__
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

LIB_X25519_ZP_USAGE_BYTES = x25519_zp_bytes
.if ::X25519_ONCHIP_MUL
; Onchip profile (issue #72): zero REU banks — this zero IS the SPEC §5
; "no REU" declaration ("Zero if no REU", SPEC.md §5; polyval
; precedent). COLD holds sqtab_init only — reu_mul_init/reu_probe are
; gated out. The _BASE_* values below are checked against od65 by
; `make lib-verify-footprint` in every profile, so no derivation of
; them is restated here.
LIB_X25519_REU_BANKS_USED = 0
_BASE_RESIDENT = 8234
_BASE_COLD     = 160
.elseif SQR_DMA_K
LIB_X25519_REU_BANKS_USED = $3B << X25519_REU_BANK
.assert X25519_REU_BANK <= 26, error, "X25519_REU_BANK > 26 shifts the top of the 5-bank $3B window past bit 31 and the exported LIB_X25519_REU_BANKS_USED silently drops it (SPEC §5: banks 0-31)"
_BASE_RESIDENT = 8547
_BASE_COLD     = 947
.else
LIB_X25519_REU_BANKS_USED = $03 << X25519_REU_BANK
.assert X25519_REU_BANK <= 30, error, "X25519_REU_BANK > 30 shifts the hi-half bank of the $03 window past bit 31 and the exported LIB_X25519_REU_BANKS_USED silently drops it (SPEC §5: banks 0-31)"
_BASE_RESIDENT = 8381
_BASE_COLD     = 733
.endif

; --- Why the two bounds above, and why they differ from §8.2's -------------
;
; §5 defines LIB_<X>_REU_BANKS_USED as a 32-bit mask, "bit n = bank n,
; banks 0-31". The mask is the ONLY thing a consumer composes:
;
;   .assert (LIB_NISTCURVES_REU_BANKS_USED & LIB_X25519_REU_BANKS_USED) = 0, error, ...
;
; so a bank this library really claims but whose bit falls off the top of
; the mask is a bank the consumer's collision assert cannot see. Measured
; (ca65 V2.18, `od65 --dump-exports` on the emitted symbol):
;
;   X25519_REU_BANK=26  ->  0xEC000000   banks 26,27,29,30,31   correct
;   X25519_REU_BANK=27  ->  0xD8000000   banks 27,28,30,31      bank 32 GONE
;
; ca65 computes the shift in wider-than-32-bit arithmetic and only narrows
; when it writes the export, so nothing in the assemble reports the loss.
; The only diagnostics ca65 gives — "Symbol is far/long but exported
; absolute" — appear while the mask is still correct and say nothing
; about truncation; they are noise here, not the guard.
;
; SPEC §8.2's own `LIB_SHARED_REU_MUL_BANK < 31` (src/reu_config.s) is the
; same defect one level down and does NOT subsume these: it bounds the
; shared two-bank pair, while this library's default window is the five
; banks of `$3B` (base+0,1,3,4,5), so the binding constraint is base+5 <= 31.
; The 1764 profile claims only `$03` (base+0,1) and takes the looser bound;
; the onchip profile claims none and needs no bound at all.

; §6.4 half-2 (SPEC v0.9.0): the SHARED_* deferral switches gate real
; code out of the archive, so the footprint equates must react to them
; — the pre-migration constants over-claimed COLD by up to +164% in
; deferral builds (the measured shape §6.4 was written against, and
; the per-profile lib-verify value locks certified the fiction).
; Deltas are od65-measured per combo (2026-08-15, post import-never-
; stub migration): sqtab_init body + sq_* temps = 160 B COLD, uniform
; across profiles; reu_mul_init = 427 B COLD at SQR_DMA_K > 0 (doubled
; -table generation included) or 213 B at SQR_DMA_K = 0; the deferred
; §8.3 ct_mul_8x8 body + scratch = 63 B RESIDENT; the §8.2 fetch pair
; (SPEC v0.9.1-C: INIT and FETCH move together) additionally drops the
; resident reu_fetch_mul_row body = 58 B RESIDENT. (Re-measured
; 2026-08-28 for v0.12.0: the §8.2 v0.13.0 REU_SETTLE expansion adds
; 12 B per execute site plus one shared x25519_reu_settle_slow proc
; (RESIDENT, not deferrable — it also serves reu_probe and the
; doubled-row DMA #2), so reu_mul_init grew 364 -> 427 / 186 -> 213
; and reu_fetch_mul_row 20 -> 32; 32 -> 58 when the fetch began
; writing every FETCH register (#164). Measured by assembling x25519_init.s
; under `-D SHARED_REU_MUL_INIT -D SHARED_REU_MUL_FETCH` and diffing
; od65 --dump-segsize against the owner object.)
.ifdef SHARED_SQTAB_INIT
_D_COLD_SQ = 160
.else
_D_COLD_SQ = 0
.endif
.if .defined(SHARED_REU_MUL_INIT) .and (::X25519_ONCHIP_MUL = 0)
.if ::SQR_DMA_K
; 427 B reu_mul_init leaves; 315 B x25519_sqr_tables_init (the private
; doubled/carry-bank build a deferring K>0 archive still owes) arrives.
_D_COLD_REU = 427 - 315
.else
_D_COLD_REU = 213
.endif
_D_RES_REU = 58
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
