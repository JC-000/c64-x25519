; =============================================================================
; mul_8x8.s - Quarter-square 8x8→16 multiply + table init
;
; Extracted from poly1305 for standalone X25519.
; Quarter-square table: sqtab_lo/hi at $7800-$7BFF (1024 bytes)
; Identity: a*b = floor((a+b)^2/4) - floor((a-b)^2/4)
; =============================================================================

.setcpu "6502"
.include "constants.s"

.export sqtab_init, mul_8x8, poly_prod_lo, poly_prod_hi

; Quarter-square table addresses (page-aligned for speed). Defined as
; linker-level SYMBOLS in cfg/x25519.cfg (and cfg/x25519-example.cfg)
; so that downstream hosts can relocate the SQTAB region without
; touching this source file. Hosts that move the tables MUST update
; both the SYMBOLS block and the SQTAB MEMORY entry in their cfg.
.import sqtab_lo, sqtab_hi

.segment "CODE"

; =============================================================================
; sqtab_init - Build quarter-square lookup table at $7800-$7BFF
; =============================================================================
.proc sqtab_init
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
.endproc

; Temporaries for sqtab_init
sq_acc: .res 3, 0              ; 24-bit accumulator for i^2
sq_sh:  .res 3, 0              ; 24-bit shifted result (i^2 / 4)
sq_ad:  .res 2, 0              ; 16-bit addition term (2i+1)
sq_i:   .res 2, 0              ; 16-bit index counter (0..511)

; =============================================================================
; mul_8x8 - 8-bit x 8-bit → 16-bit multiply using quarter-square table
;
; Input: A = multiplicand, X = multiplier
; Output: poly_prod_lo/hi = A * X (16-bit result)
;
; Uses identity: a*b = sqtab[a+b] - sqtab[|a-b|]
; Clobbers: A, X, Y
; =============================================================================
poly_prod_lo:   .byte 0
poly_prod_hi:   .byte 0

.proc mul_8x8
        sta mul_a               ; save A (multiplicand)
        stx mul_b               ; save X (multiplier)

        ; ---- Branchless |a - b| via sign-mask XOR ----
        ; Compute raw diff = a - b, and mask = 0 (if a>=b) or $ff (if a<b).
        ; Then |a-b| = (raw XOR mask) - mask, using the identity that
        ; subtracting $ff with C=1 equals adding 1 in two's complement.
        lda mul_a
        sec
        sbc mul_b               ; A = a - b (raw), C=1 if a>=b, C=0 if a<b
        sta mul_diff            ; stash raw diff
        lda #0
        sbc #0                  ; A = $00 if C=1, $ff if C=0 (sign mask)
        sta mul_mask
        eor mul_diff            ; A = raw XOR mask
        sec
        sbc mul_mask            ; A = (raw XOR mask) - mask = |a-b|
        tay                     ; Y = |a-b|

        ; ---- Compute sum and sum-page carry ----
        lda mul_a
        clc
        adc mul_b               ; A = (a+b) & $ff
        tax                     ; X = sum low byte
        lda #0
        adc #0                  ; A = sum-page carry (0 or 1)
        sta mul_sum_pg

        ; ---- Patch hi bytes of the two abs,X load sites (SMC) ----
        ; Because sqtab_lo/sqtab_hi are each 512 bytes starting on a page
        ; boundary ($7800 and $7a00), adding the sum-page carry (0 or 1)
        ; to the page hi byte selects between page 0 and page 1 of each
        ; table without any data-dependent branch.
        lda #>sqtab_lo
        clc
        adc mul_sum_pg
        sta @ct_load_lo+2       ; patch hi byte of `lda sqtab_lo,x`
        lda #>sqtab_hi
        clc
        adc mul_sum_pg
        sta @ct_load_hi+2       ; patch hi byte of `lda sqtab_hi,x`

        ; ---- Straight-line sqtab[sum] - sqtab[|diff|] ----
@ct_load_lo:
        lda sqtab_lo,x          ; hi byte PATCHED above
        sec
        sbc sqtab_lo,y
        sta poly_prod_lo
@ct_load_hi:
        lda sqtab_hi,x          ; hi byte PATCHED above
        sbc sqtab_hi,y
        sta poly_prod_hi
        rts
.endproc

mul_a:          .byte 0
mul_b:          .byte 0
mul_diff:       .byte 0
mul_mask:       .byte 0
mul_sum_pg:     .byte 0
