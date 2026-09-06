; =============================================================================
; mul_8x8.s - Quarter-square 8x8→16 multiply + table init
;
; Extracted from poly1305 for standalone X25519.
; Quarter-square table: sqtab_lo/hi at LIB_SHARED_SQTAB_BASE +$0000/$0200
; (default base $7800; 1024 bytes total).
; Identity: a*b = floor((a+b)^2/4) - floor((a-b)^2/4)
;
; c64-lib-contract §8.1 shared-primitive adoption (v0.6):
; ---------------------------------------------------------------------------
; The sqtab base address is published as the source-level equate
; LIB_SHARED_SQTAB_BASE (default $7800), `.ifndef`-guarded so a
; multi-lib consumer can override it via
; `ca65 -D LIB_SHARED_SQTAB_BASE=0x<addr>`. Page-alignment +
; page-delta are hard `.assert`-checked at link time.
;
; Why source equate rather than linker-export: ct_mul_8x8 (and the
; mult66 path inside fe25519_sqr) self-modifies the hi byte of
; `lda sqtab_lo,x` opcodes at runtime (`smc_lo_addr` / `smc_hi_addr`
; below). ld65 can't rewrite opcode bytes at link time, so the base
; address must be known at assemble time. The equate form lets a
; consumer pin it; the linker no longer needs to know about
; sqtab_lo / sqtab_hi.
;
; Idempotent shared init: a consumer that defines `SHARED_SQTAB_INIT`
; at build time signals that some other library in the link will
; provide the canonical `mul_tables_init` entry, and `sqtab_init`'s
; body in this file becomes a no-op stub. Without the gate (the
; standalone-build default), `sqtab_init` builds its own table as
; before. Either way, `mul_tables_init` is exported as a contract-
; canonical alias for `sqtab_init`.
; =============================================================================


; --- §6.1 member isolation (SPEC v1.2.2), #128 -------------------------------
; The §8.1 group (sqtab_init / mul_tables_init) moved to src/sqtab_init.s at
; v0.16.0. This file now holds the §8.3 group ONLY. They are dropped by
; different switches, so sharing a member made "own §8.3, defer §8.1"
; unsatisfiable from the shipped archive -- measured as
; `ld65: Error: Duplicate external identifier: 'smc_diff_a_imm'`. See the
; header of src/sqtab_init.s for the full reasoning and the grouping rule.
; Do not move either group back.

.setcpu "6502"
.include "constants.s"

.ifndef SHARED_CT_MUL_8X8
.export mul_8x8, ct_mul_8x8, poly_prod_lo, poly_prod_hi
; SMC operand-bake sites — patched by the caller (reu_mul_init) once per
; outer-a iteration. Exported for the cross-TU bake from x25519_init.s.
.export smc_sum_a_imm, smc_diff_a_imm
.endif

; Back to resident LIB_X25519_CODE (issue #68 cold-split boundary). ct_mul_8x8 is
; boot-only in x25519 (sole caller reu_mul_init) but stays RESIDENT
; deliberately: (1) it is the §8.3 shared-primitive body — an
; owner-mode composed build takes runtime calls from deferring
; siblings; (2) tools/ct_mul_brute_check.py JSRs it from the live
; image post-boot; (3) poly_prod_lo/hi just below are runtime-hot
; fe25519 scratch and must never land in a reclaimable segment.
.segment "LIB_X25519_CODE"

; =============================================================================
; ct_mul_8x8 - constant-time 8x8 -> 16-bit multiply (quarter-square)
;
; c64-lib-contract §8.3 candidate (issue #14). This body is byte-identical
; to the canonical owner c64-ChaCha20-Poly1305 `ct_mul_8x8`
; (src/lib/poly1305_lib.s). `tools/ct_mul_brute_check.py` (and the
; cross-adopter copy in c64-lib-contract) asserts opcode-for-opcode
; equality across chacha / nist-curves / x25519 — do NOT alter the
; instruction sequence without re-running it and updating all adopters.
;
; Calling convention (SMC-baked; matches chacha):
;   Entry: Y = b (multiplier). a (multiplicand) is SMC-baked into the two
;          immediate operand sites smc_sum_a_imm+1 / smc_diff_a_imm+1 by
;          the caller, once per outer-a iteration (see reu_mul_init).
;   Exit:  poly_prod_lo / poly_prod_hi = a * b (16-bit, little-endian).
;   Clobbers: A, X, Y, ct_diff_raw, ct_sign_mask, and the four SMC patch
;             sites (smc_sum_a_imm, smc_diff_a_imm, smc_lo_addr, smc_hi_addr).
;
; Identity: a*b = sqtab[a+b] - sqtab[|a-b|].
;
; CT discipline (sum-first canonical ordering; L1/L2 closure preserved —
; see docs/CT_ANALYSIS.md):
;   - |a-b| via branchless sign-mask flip-and-negate, no `bcc`.        [L1]
;   - sum-page bit folded into the SMC hi-byte patch of the two `abs,x`
;     loads, so timing is independent of whether a+b >= 256.           [L2]
;   - `abs,x` / `abs,y` over the page-aligned sqtab never page-cross.
; The reorder to sum-first vs the historical diff-first body is location-
; agnostic for both L1 and L2 (neither fix depends on block order).
;
; NOTE: x25519's mul_8x8 is boot-only — its sole caller is reu_mul_init's
; public (a, b) table enumeration; no secret inputs reach it. The CT
; discipline is retained as the canonical shared-primitive shape, not
; because this call site has secret-timing exposure (see docs/CT_ANALYSIS.md,
; "mul_8x8 boot-only since Phase 1").
;
; `mul_8x8` is retained as a back-compat alias label at the same address.
;
; Migration gate: when a multi-lib consumer defines SHARED_CT_MUL_8X8, the
; canonical body is provided by another translation unit and imported here
; (mirrors the §8.1 SHARED_SQTAB_INIT pattern). Standalone builds (the
; default) define the body locally. The exact shared-link symbol ownership
; (poly_prod buffers, mul_8x8 alias) is pinned by the forthcoming §8.3
; clause; this gate is the adoption hook.
; =============================================================================

.ifndef SHARED_CT_MUL_8X8

poly_prod_lo:   .byte 0
poly_prod_hi:   .byte 0

ct_mul_8x8:
mul_8x8:                            ; back-compat alias (same address)
        ; ---- sum = a + b; SMC-patch the two abs,x hi bytes (page select) ----
        tya                         ; A = b
        clc
smc_sum_a_imm:
        adc #$00                    ; SMC imm = a; A = (a+b).lo, C = page bit
        tax                         ; X = (a+b) & $FF
        lda #>sqtab_lo
        adc #0                      ; page hi += carry  ($78 or $79)
        sta smc_lo_addr+2           ; patch `lda sqtab_lo,x` hi byte
        adc #(>sqtab_hi - >sqtab_lo); C=0 after adc #0, so += 2
        sta smc_hi_addr+2           ; patch `lda sqtab_hi,x` hi byte

        ; ---- |a - b| -> Y via branchless sign-mask flip-and-negate ----
        tya                         ; A = b
        sec
smc_diff_a_imm:
        sbc #$00                    ; SMC imm = a; A = b - a, C=1 iff b>=a
        sta ct_diff_raw
        lda #$00
        sbc #$00                    ; C=1: $00; C=0: $FF (sign mask)
        sta ct_sign_mask
        eor ct_diff_raw             ; raw XOR mask
        sec
        sbc ct_sign_mask            ; + (-mask): +0 if b>=a, +1 if b<a
        tay                         ; Y = |a - b|  (in [0,255])

        ; ---- sqtab[a+b] - sqtab[|a-b|]  (hi bytes SMC-patched above) ----
smc_lo_addr:
        lda sqtab_lo,x              ; hi byte PATCHED above
        sec
        sbc sqtab_lo,y
        sta poly_prod_lo
smc_hi_addr:
        lda sqtab_hi,x              ; hi byte PATCHED above
        sbc sqtab_hi,y
        sta poly_prod_hi
        rts

; ct_diff_raw / ct_sign_mask — straight-line scratch (no secret-dependent
; branch reads them, so placement is CT-neutral). Kept as static data
; bytes; the §8.3 gate compares opcode shape, not their address.
ct_diff_raw:    .byte 0
ct_sign_mask:   .byte 0

.else
        ; Shared §8.3 primitive provided by another translation unit.
        .import ct_mul_8x8, mul_8x8, poly_prod_lo, poly_prod_hi
        .import smc_sum_a_imm, smc_diff_a_imm
.endif
