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
; `ca65 --asm-define LIB_SHARED_SQTAB_BASE=$N`. Page-alignment +
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

.setcpu "6502"
.include "constants.s"

.export sqtab_init, mul_tables_init
.ifndef SHARED_CT_MUL_8X8
.export mul_8x8, ct_mul_8x8, poly_prod_lo, poly_prod_hi
; SMC operand-bake sites — patched by the caller (reu_mul_init) once per
; outer-a iteration. Exported for the cross-TU bake from x25519_init.s.
.export smc_sum_a_imm, smc_diff_a_imm
.endif

; sqtab_lo / sqtab_hi / LIB_SHARED_SQTAB_BASE are now defined in
; constants.s as `.ifndef`-guarded equates (c64-lib-contract §8.1
; shared-primitive adoption). Every translation unit that `.include`s
; constants.s sees the same values, so no `.import` or `.export`
; needed across TUs — each module derives the addresses locally. A
; multi-lib consumer passes `-D LIB_SHARED_SQTAB_BASE=$N` to every
; ca65 invocation; every lib agrees on the canonical base.

.segment "CODE"

; =============================================================================
; sqtab_init / mul_tables_init - Build quarter-square lookup table
;
; Two names for the same entry point. `sqtab_init` is the historical
; library name; `mul_tables_init` is the c64-lib-contract §8.1
; canonical name for the shared primitive. Both point at the same
; body. Callers can use whichever fits their integration shape:
;
;   jsr sqtab_init        ; legacy / standalone-build path
;   jsr mul_tables_init   ; multi-lib / contract-§8 path
;
; When the consumer defines `SHARED_SQTAB_INIT` at build time, the
; body below is gated out — c64-x25519 trusts that some other library
; in the link will provide a `mul_tables_init` that populates the
; canonical `LIB_SHARED_SQTAB_BASE` region before any field op runs.
; The local `sqtab_init` / `mul_tables_init` symbols still resolve
; (returning immediately), so existing callers don't break.
;
; Idempotency: the body is a deterministic table build over the same
; `LIB_SHARED_SQTAB_BASE` region; calling it twice from different
; library initializers in a multi-lib PRG is wasteful but not
; incorrect. The contract §8.1 expectation is that the host calls
; the canonical init exactly once.
; =============================================================================
mul_tables_init = sqtab_init    ; canonical contract-§8.1 alias

.proc sqtab_init
.ifdef SHARED_SQTAB_INIT
        ; Consumer signaled that another translation unit provides the
        ; canonical `mul_tables_init`. Skip our table build to avoid
        ; clobbering the shared region with a second copy of the same
        ; values (correctness-preserving but wasteful).
        rts
.else
        lda #0
        sta sq_acc              ; accumulator = 0
        sta sq_acc+1
        sta sq_acc+2
        sta sq_i                ; index = 0
        sta sq_i+1

@loop:
        ; Compute f(i) = sq_acc >> 2 (divide by 4)
        lda sq_acc+2
        lsr
        sta sq_sh+2
        lda sq_acc+1
        ror
        sta sq_sh+1
        lda sq_acc
        ror
        sta sq_sh
        lsr sq_sh+2
        ror sq_sh+1
        ror sq_sh

        ; Store in table at index sq_i (0..511)
        ldx sq_i                ; low byte of index
        lda sq_i+1
        beq @pg0
        ; Page 1 (256..511)
        lda sq_sh
        sta sqtab_lo+256,x
        lda sq_sh+1
        sta sqtab_hi+256,x
        jmp @advance
@pg0:
        lda sq_sh
        sta sqtab_lo,x
        lda sq_sh+1
        sta sqtab_hi,x

@advance:
        ; sq_acc += 2*i + 1 (recurrence: (i+1)^2 = i^2 + 2i + 1)
        lda sq_i
        asl
        sta sq_ad
        lda sq_i+1
        rol
        sta sq_ad+1
        inc sq_ad
        bne :+
        inc sq_ad+1
:
        clc
        lda sq_acc
        adc sq_ad
        sta sq_acc
        lda sq_acc+1
        adc sq_ad+1
        sta sq_acc+1
        lda sq_acc+2
        adc #0
        sta sq_acc+2

        inc sq_i
        bne :+
        inc sq_i+1
:       lda sq_i+1
        cmp #2                  ; check if i reached 512 (0x200)
        beq @done
        jmp @loop
@done:  rts
.endif  ; SHARED_SQTAB_INIT
.endproc

; Temporaries for sqtab_init
sq_acc: .res 3, 0              ; 24-bit accumulator for i^2
sq_sh:  .res 3, 0              ; 24-bit shifted result (i^2 / 4)
sq_ad:  .res 2, 0              ; 16-bit addition term (2i+1)
sq_i:   .res 2, 0              ; 16-bit index counter (0..511)

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
