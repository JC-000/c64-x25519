; =============================================================================
; x25519_init.s - Library initialization and REU helper routines
; =============================================================================

.setcpu "6502"

.include "constants.s"

.export reu_mul_init
.export reu_fetch_mul_row, reu_fetch_doubled_row, reu_clear_wide

; --- Imports from mul_8x8.s ---
.import mul_8x8, poly_prod_lo, poly_prod_hi

; --- Imports from data.s ---
.import mul_dma_lo, mul_dma_hi, mul_dma_carry, mul_cached_a

.segment "CODE"

; =============================================================================
; REU multiplication table routines
; =============================================================================

; =============================================================================
; reu_mul_init - Generate 256 full multiplication rows and stash in REU
;
; For each a = 0..255, computes a*b for b = 0..255 and stashes:
;   256 lo bytes at REU offset a*512
;   256 hi bytes at REU offset a*512+256
;
; Uses mul_dma_lo/mul_dma_hi as staging buffers.
; Uses mul_8x8 (requires sqtab to be initialized first).
; Clobbers: A, X, Y
; =============================================================================
.proc reu_mul_init
        lda #0
        sta reu_init_a         ; outer counter (multiplier a)

@outer:
        ; For current a, compute a*b for all b=0..255
        lda #0
        sta reu_init_b         ; inner counter (multiplicand b)

@inner:
        lda reu_init_a
        ldx reu_init_b
        jsr mul_8x8            ; poly_prod_lo/hi = a * b

        ldx reu_init_b
        lda poly_prod_lo
        sta mul_dma_lo,x
        lda poly_prod_hi
        sta mul_dma_hi,x

        inc reu_init_b
        bne @inner             ; loop b = 0..255

        ; Stash lo table (256 bytes) to REU at offset a*512
        lda #<(mul_dma_lo)
        sta reu_c64_lo
        lda #>(mul_dma_lo)
        sta reu_c64_hi
        lda #0
        sta reu_reu_lo         ; REU offset low = 0
        lda reu_init_a
        asl                    ; A = a * 2 (high byte of offset)
        sta reu_reu_hi
        lda #0
        adc #0                 ; carry into bank if a >= 128
        sta reu_reu_bank
        lda #0
        sta reu_len_lo
        lda #1
        sta reu_len_hi         ; length = 256
        lda #0
        sta reu_addr_ctrl      ; both addresses increment
        lda #%10110000         ; execute + autoload + STASH (C64->REU)
        sta reu_command

        ; Stash hi table (256 bytes) to REU at offset a*512+256
        lda #<(mul_dma_hi)
        sta reu_c64_lo
        lda #>(mul_dma_hi)
        sta reu_c64_hi
        lda #0
        sta reu_reu_lo
        lda reu_init_a
        asl                    ; a*2 (carry = bit 7 of a)
        lda #0
        adc #0                 ; bank = a >> 7
        sta reu_reu_bank
        lda reu_init_a
        asl                    ; a*2
        ora #1                 ; +1 for hi page (a*2 is even, so OR works)
        sta reu_reu_hi
        lda #0
        sta reu_len_lo
        lda #1
        sta reu_len_hi         ; length = 256
        lda #0
        sta reu_addr_ctrl
        lda #%10110000         ; execute + autoload + STASH
        sta reu_command

        ; --- Generate pre-doubled tables for fe25519_sqr (8f+8g) ---
        ; Overwrite mul_dma_lo/hi with 2*a*b (17-bit), and fill mul_dma_carry
        ; with the 17th bit. Regular tables were already stashed above.
        ldx #0
@dbl_gen:
        lda mul_dma_hi,x
        asl                    ; carry = bit7 of original hi = bit16 of 2*a*b
        lda #0
        rol                    ; A = 0/1 carry bit
        sta mul_dma_carry,x
        lda mul_dma_lo,x
        asl                    ; shift lo, carry out = bit7
        sta mul_dma_lo,x
        lda mul_dma_hi,x
        rol                    ; shift hi with carry in
        sta mul_dma_hi,x
        inx
        bne @dbl_gen

        ; Stash doubled lo table to bank (4 + a>>7), offset a*512 mod 65536
        lda #<(mul_dma_lo)
        sta reu_c64_lo
        lda #>(mul_dma_lo)
        sta reu_c64_hi
        lda #0
        sta reu_reu_lo
        lda reu_init_a
        asl                    ; A = a*2, carry = bit7
        sta reu_reu_hi
        lda #4
        adc #0                 ; bank = 4 + carry
        sta reu_reu_bank
        lda #0
        sta reu_len_lo
        lda #1
        sta reu_len_hi
        sta reu_addr_ctrl
        lda #0
        sta reu_addr_ctrl
        lda #%10110000
        sta reu_command

        ; Stash doubled hi table to banks 4-5, offset a*512+256
        lda #<(mul_dma_hi)
        sta reu_c64_lo
        lda #>(mul_dma_hi)
        sta reu_c64_hi
        lda #0
        sta reu_reu_lo
        lda reu_init_a
        asl                    ; a*2
        lda #4
        adc #0                 ; bank = 4 + (a>>7)
        sta reu_reu_bank
        lda reu_init_a
        asl
        ora #1
        sta reu_reu_hi
        lda #0
        sta reu_len_lo
        lda #1
        sta reu_len_hi
        sta reu_addr_ctrl
        lda #%10110000
        sta reu_command

        ; Stash carry table (256 bytes) to bank 3, offset a*256
        lda #<(mul_dma_carry)
        sta reu_c64_lo
        lda #>(mul_dma_carry)
        sta reu_c64_hi
        lda #0
        sta reu_reu_lo
        lda reu_init_a
        sta reu_reu_hi
        lda #3
        sta reu_reu_bank
        lda #0
        sta reu_len_lo
        lda #1
        sta reu_len_hi
        sta reu_addr_ctrl
        lda #%10110000
        sta reu_command

        inc reu_init_a
        beq @init_done         ; if wrapped to 0, done
        jmp @outer
@init_done:
        ; Stash 64 zero bytes to REU bank 2 offset 0 (for fe_wide zeroing via DMA).
        ; Build zero buffer by overwriting mul_dma_lo[0..63] (will be overwritten
        ; by next fetch_mul_row, so safe to corrupt now).
        ldx #63
        lda #0
@zbuf:  sta mul_dma_lo,x
        dex
        bpl @zbuf
        ; STASH 64 bytes from mul_dma_lo to REU bank=2, offset=$0000
        lda #<(mul_dma_lo)
        sta reu_c64_lo
        lda #>(mul_dma_lo)
        sta reu_c64_hi
        lda #0
        sta reu_reu_lo
        sta reu_reu_hi
        lda #2
        sta reu_reu_bank
        lda #64
        sta reu_len_lo
        lda #0
        sta reu_len_hi
        sta reu_addr_ctrl
        lda #%10110000         ; execute + autoload + STASH (C64->REU)
        sta reu_command

        ; Pre-configure constant REU registers for fetch routine
        lda #<(mul_dma_lo)
        sta reu_c64_lo
        lda #>(mul_dma_lo)
        sta reu_c64_hi
        lda #0
        sta reu_reu_lo
        sta reu_len_lo
        sta reu_addr_ctrl
        lda #2
        sta reu_len_hi         ; length high = 2 (512 bytes)
        rts

reu_init_a:     .byte 0
reu_init_b:     .byte 0
.endproc

; =============================================================================
; reu_fetch_mul_row - DMA a multiplication table row from REU to C64
;
; Input: A = multiplier value (0-255) in mul_cached_a
; Fetches 512 bytes: 256 lo bytes to mul_dma_lo, 256 hi bytes to mul_dma_hi
; Clobbers: A
; =============================================================================
.proc reu_fetch_mul_row
        lda mul_cached_a
        asl                    ; A = multiplier * 2, carry = bit 7
        sta reu_reu_hi
        lda #0
        adc #0                 ; bank = carry from shift
        sta reu_reu_bank
        lda #%10110001         ; execute + autoload + FETCH (REU->C64)
        sta reu_command
        rts
.endproc

; =============================================================================
; reu_fetch_doubled_row - DMA pre-doubled multiplication row for fe25519_sqr
;
; Input: A = multiplier value in mul_cached_a
; Fetches 512 bytes from banks 4-5 to mul_dma_lo/hi (doubled lo+hi),
; then 256 bytes from bank 3 to mul_dma_carry (17th-bit carry flags).
; Clobbers: A
; NOTE: Leaves REU registers in a non-default state; caller must restore
; if the regular mul-row FETCH config is needed afterward.
; =============================================================================
.proc reu_fetch_doubled_row
        ; First DMA: 512 bytes to mul_dma_lo from banks 4-5, offset a*512
        lda #<(mul_dma_lo)
        sta reu_c64_lo
        lda #>(mul_dma_lo)
        sta reu_c64_hi
        lda #0
        sta reu_reu_lo
        sta reu_len_lo
        sta reu_addr_ctrl
        lda #2
        sta reu_len_hi         ; 512 bytes
        lda mul_cached_a
        asl                    ; A = a*2, carry = bit7
        sta reu_reu_hi
        lda #4
        adc #0                 ; bank = 4 + (a>>7)
        sta reu_reu_bank
        lda #%10110001
        sta reu_command

        ; Second DMA: 256 bytes to mul_dma_carry from bank 3, offset a*256
        lda #<(mul_dma_carry)
        sta reu_c64_lo
        lda #>(mul_dma_carry)
        sta reu_c64_hi
        lda #0
        sta reu_reu_lo
        sta reu_len_lo
        sta reu_addr_ctrl
        lda #1
        sta reu_len_hi         ; 256 bytes
        lda mul_cached_a
        sta reu_reu_hi
        lda #3
        sta reu_reu_bank
        lda #%10110001
        sta reu_command
        rts
.endproc

; =============================================================================
; reu_clear_wide - DMA-zero fe_wide[0..63] ($40..$7F) via REU FETCH from bank 2
;
; Fetches 64 pre-stashed zero bytes from REU bank=2, offset=0 to C64 $0040.
; Then restores REU registers to mul-row FETCH config (c64=mul_dma_lo, len=512).
; Clobbers: A
; =============================================================================
.proc reu_clear_wide
        ; Configure DMA: 64 bytes from REU bank 2 / $0000 to C64 $0040
        lda #$40
        sta reu_c64_lo
        lda #0
        sta reu_c64_hi
        sta reu_reu_hi         ; (also 0 — autoload may have changed it)
        sta reu_len_hi
        lda #2
        sta reu_reu_bank
        lda #64
        sta reu_len_lo
        lda #%10110001         ; execute + autoload + FETCH (REU->C64)
        sta reu_command
        ; Restore mul-row FETCH config (reu_reu_lo / addr_ctrl are still 0 via autoload)
        lda #<(mul_dma_lo)
        sta reu_c64_lo
        lda #>(mul_dma_lo)
        sta reu_c64_hi
        lda #0
        sta reu_len_lo
        lda #2
        sta reu_len_hi
        rts

.endproc
