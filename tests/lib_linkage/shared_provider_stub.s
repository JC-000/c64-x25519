; =============================================================================
; shared_provider_stub.s - Stand-in canonical providers for lib-verify-shared
;
; When libx25519.a is built with a c64-lib-contract SHARED_* deferral
; switch defined, the library defers that primitive to "some other
; library in the link" (SPEC §8.0): the gated exports drop out of the
; archive and the retained modules import the canonical surface
; cross-TU instead. In a real consumer that provider is a sibling
; adopter (c64-ChaCha20-Poly1305 for §8.3, c64-nist-curves or another
; §8.2 owner for reu_mul). In the single-library `make lib-verify`
; link nothing would satisfy those imports, so this TU plays the
; provider role with minimal stand-ins.
;
; Assembled with the same $(CA65FLAGS) as the library, so each block
; below materializes exactly when its deferral switch is defined. In a
; default / 1764 / onchip build this TU contributes nothing at all.
;
; SHARED_SQTAB_INIT needs a mul_tables_init stand-in since the SPEC
; v0.9.0 import-never-stub migration: a deferring build imports the
; provider's canonical entry instead of exporting a no-op stub
; (src/mul_8x8.s; the old stub shape put two exported canonical inits
; in every composed link and was the clause's measured example).
;
; This is linkage smoke-test scaffolding only — the stand-ins are NOT
; functional bodies and must never ship in an archive.
; =============================================================================

.setcpu "6502"

.ifdef SHARED_SQTAB_INIT
; §8.1: the canonical table-build entry the provider owns. x25519's
; own sqtab_init / mul_tables_init exports are gated out
; (src/mul_8x8.s); its retained TUs alias sqtab_init := the imported
; canonical entry.
.export mul_tables_init
.segment "CODE"
mul_tables_init:
        rts
.endif

.ifdef SHARED_REU_MUL_INIT
; §8.2: the canonical init entry the provider owns. x25519's own
; reu_mul_init / reu_mul_tables_init exports are gated out
; (src/x25519_init.s), as are the reu_init_a/b-backed ZP_INIT_A/B
; alias equates (src/reu_config.s). The per-row fetch surface
; (reu_fetch_mul_row / _bank_patch) stays x25519-own.
.export reu_mul_tables_init
.segment "CODE"
reu_mul_tables_init:
        rts
.endif

.ifdef SHARED_REU_MUL_FETCH
; §8.2 fetch half (SPEC v0.9.1): canonical per-row fetch + the
; promoted SMC bank-patch label (contract #15). Stand-in only.
.export reu_fetch_mul_row
.export reu_fetch_mul_row_bank_patch
.segment "CODE"
reu_fetch_mul_row:
        rts
reu_fetch_mul_row_bank_patch := reu_fetch_mul_row
.endif

.ifdef SHARED_CT_MUL_8X8
; §8.3: the canonical CT multiply body surface. x25519's retained
; modules import all of this cross-TU (src/x25519_init.s's
; reu_mul_init caller; src/fe25519.s under the onchip profile), so
; the provider must export the SMC immediate sites and the product
; scratch, not just the entry label. Shape mirrors the real operand
; contract: Y = b, multiplier `a` baked at smc_*_a_imm+1.
.export ct_mul_8x8
.export smc_sum_a_imm, smc_diff_a_imm
.export poly_prod_lo, poly_prod_hi
.segment "CODE"
ct_mul_8x8:
smc_sum_a_imm:
        adc #$00
smc_diff_a_imm:
        adc #$00
        rts
poly_prod_lo:   .byte 0
poly_prod_hi:   .byte 0
.endif
