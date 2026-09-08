; =============================================================================
; app_owned_header_stub.s - the §8.x-OWNING consumer's translation unit
;
; Issue #130. `make lib-verify-shared` covers the consumer that DEFERS a
; §8.x primitive to a sibling library: it references the canonical name
; and something else in the link provides it. It does NOT cover the
; other half of SPEC §8.0's three-state table, APP_OWNED — the consumer
; whose OWN translation unit defines the primitive and includes
; x25519.inc in the same file.
;
; That case fails one step earlier than any link check can see. ca65
; refuses to import a name the current TU exports, so a header that
; `.import`s a canonical §8.x name is un-includable by its owner:
;
;   src/x25519.inc(397): Error: Cannot import exported symbol 'ct_mul_8x8'
;
; and the workaround — do not include x25519.inc — costs the consumer
; every other declaration in it, i.e. the whole public API.
;
; This TU is that consumer. Each group materializes only when its
; deferral switch is defined, so one source serves all four arms of
; `make lib-verify-app-owned-header` (one per ownership group -- the two
; §8.2 switches move together per SPEC v0.9.1 and src/reu_config.s's
; pairing `.error` -- plus all four switches at once, the
; `make lib-app-owned` define set).
;
; ORDERING IS DELIBERATE. The `.export`s are above the `.include` and
; the labels below it, because that is the ordering that produces the
; diagnostic quoted in #130, and it is the ordering that defeats the two
; fixes that do NOT work. All three orderings (define-then-include,
; export-then-include-then-define, include-then-define) were measured to
; fail before the fix. `.ifndef <name>` around the import fixes only the
; first, because ca65 has no "is exported" predicate. Gating on the
; deferral switch fixes all three but breaks the OTHER §8.0 consumer --
; the one that defers to a sibling and only CALLS the name; measured, the
; in-tree lib_linkage_stub died on `Symbol 'mul_tables_init' is
; undefined`. `.global` is what serves both, and this TU is the half of
; that evidence `make lib-verify-shared` cannot see.
;
; ASSEMBLE-ONLY. The bodies below are one-instruction stand-ins, not
; functional primitives, and this TU is never linked or run. The
; property under test is that the header ASSEMBLES against a TU that
; owns the primitive; the linked composed shape is `make lib-app-owned`.
; =============================================================================

.setcpu "6502"

.ifdef SHARED_SQTAB_INIT
.export mul_tables_init              ; §8.1 canonical entry, app-owned
.endif
.ifdef SHARED_REU_MUL_INIT
.export reu_mul_tables_init          ; §8.2 canonical init entry, app-owned
.endif
.ifdef SHARED_REU_MUL_FETCH
.export reu_fetch_mul_row            ; §8.2 fetch half, app-owned
.export reu_fetch_mul_row_bank_patch
.endif
.ifdef SHARED_CT_MUL_8X8
; The whole §8.3 surface src/mul_8x8.s exports under the same switch —
; entry, SMC immediates and product scratch — because a consumer that
; owns the body owns all of it (see shared_provider_stub.s).
.export ct_mul_8x8
.export smc_sum_a_imm, smc_diff_a_imm
.export poly_prod_lo, poly_prod_hi
.endif

.include "x25519.inc"

.segment "CODE"

.ifdef SHARED_SQTAB_INIT
mul_tables_init:
        rts
.endif
.ifdef SHARED_REU_MUL_INIT
reu_mul_tables_init:
        rts
.endif
.ifdef SHARED_REU_MUL_FETCH
reu_fetch_mul_row:
        lda #$00
reu_fetch_mul_row_bank_patch := reu_fetch_mul_row + 1
        rts
.endif
.ifdef SHARED_CT_MUL_8X8
ct_mul_8x8:
smc_sum_a_imm:
        adc #$00
smc_diff_a_imm:
        adc #$00
        rts
poly_prod_lo:
        .res 1
poly_prod_hi:
        .res 1
.endif

; A live reference to the public API, so this TU also witnesses that the
; rest of the header still declares what a consumer calls after the
; §8.x groups are gated out.
app_entry:
        jsr x25519_clamp
        rts
