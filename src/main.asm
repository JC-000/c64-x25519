; =============================================================================
; main.asm - Standalone X25519 performance tuning harness
;
; Memory layout:
;   $0801-$08FF: BASIC stub + boot
;   $0900+:      code (mul_8x8, fe25519, x25519, benchmark)
;   $7800-$7BFF: sqtab (quarter-square multiply tables)
; =============================================================================

!cpu 6502
!source "constants.asm"

; --- Program origin ---
* = $0801

; BASIC stub: 10 SYS 2064
basic_stub:
        !word basic_end         ; pointer to next BASIC line
        !word 10                ; line number 10
        !byte $9e               ; SYS token
        !text "2064"            ; decimal address (must match start label)
        !byte 0                 ; end of line
basic_end:
        !word 0                 ; end of BASIC program

; =============================================================================
; Program entry point
; =============================================================================
start:
        ; bank out BASIC ROM to use $A000-$BFFF as RAM
        lda proc_port
        and #$fe                ; clear bit 0 (LORAM) — bank out BASIC ROM
        sta proc_port

        ; clear screen
        jsr clrscr

        ; display title
        lda #<title_msg
        ldy #>title_msg
        jsr print_string

        ; Initialize quarter-square table
        jsr sqtab_init

        ; Initialize REU multiplication tables
        jsr reu_mul_init

        ; display ready message
        lda #<ready_msg
        ldy #>ready_msg
        jsr print_string

        ; Main idle loop - wait for test harness commands
main_loop:
        jmp main_loop

; =============================================================================
; clrscr - Clear screen
; =============================================================================
clrscr:
        lda #$20               ; space character
        ldx #0
@loop:
        sta screen_ram,x
        sta screen_ram+$100,x
        sta screen_ram+$200,x
        sta screen_ram+$2e8,x
        inx
        bne @loop
        rts

; =============================================================================
; print_string - Print null-terminated string
; Input: A=low byte, Y=high byte of string address
; =============================================================================
print_string:
        sta zp_ptr1
        sty zp_ptr1+1
        ldy #0
@loop:
        lda (zp_ptr1),y
        beq @done
        jsr chrout
        iny
        bne @loop
@done:
        rts

; =============================================================================
; Benchmark timer routines
; =============================================================================

; bench_start - Reset jiffy clock and start timing
bench_start:
        sei
        lda #0
        sta jiffy_clock
        sta jiffy_clock+1
        sta jiffy_clock+2
        cli
        rts

; bench_stop - Read jiffy clock into bench_ticks (3 bytes)
bench_stop:
        sei
        lda jiffy_clock
        sta bench_ticks
        lda jiffy_clock+1
        sta bench_ticks+1
        lda jiffy_clock+2
        sta bench_ticks+2
        cli
        rts

bench_ticks:    !fill 3, 0

; =============================================================================
; VIC-II screen blanking for maximum CPU throughput
; Blanking eliminates ~40 stolen cycles/rasterline from VIC-II DMA
; =============================================================================

; vic_blank - Disable VIC-II display (DEN=0) for ~20-25% CPU speedup
vic_blank:
        lda vic_ctrl1
        and #$ef               ; clear bit 4 (DEN - Display Enable)
        sta vic_ctrl1
        rts

; vic_unblank - Re-enable VIC-II display (DEN=1)
vic_unblank:
        lda vic_ctrl1
        ora #$10               ; set bit 4
        sta vic_ctrl1
        rts

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
reu_mul_init:
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
        lda #<mul_dma_lo
        sta reu_c64_lo
        lda #>mul_dma_lo
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
        lda #<mul_dma_hi
        sta reu_c64_lo
        lda #>mul_dma_hi
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

        ; --- Generate pre-doubled tables for fe_sqr (8f+8g) ---
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
        lda #<mul_dma_lo
        sta reu_c64_lo
        lda #>mul_dma_lo
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
        lda #<mul_dma_hi
        sta reu_c64_lo
        lda #>mul_dma_hi
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
        lda #<mul_dma_carry
        sta reu_c64_lo
        lda #>mul_dma_carry
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
        lda #<mul_dma_lo
        sta reu_c64_lo
        lda #>mul_dma_lo
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
        lda #<mul_dma_lo
        sta reu_c64_lo
        lda #>mul_dma_lo
        sta reu_c64_hi
        lda #0
        sta reu_reu_lo
        sta reu_len_lo
        sta reu_addr_ctrl
        lda #2
        sta reu_len_hi         ; length high = 2 (512 bytes)
        rts

reu_init_a:     !byte 0
reu_init_b:     !byte 0

; =============================================================================
; reu_fetch_mul_row - DMA a multiplication table row from REU to C64
;
; Input: A = multiplier value (0-255) in mul_cached_a
; Fetches 512 bytes: 256 lo bytes to mul_dma_lo, 256 hi bytes to mul_dma_hi
; Clobbers: A
; =============================================================================
reu_fetch_mul_row:
        lda mul_cached_a
        asl                    ; A = multiplier * 2, carry = bit 7
        sta reu_reu_hi
        lda #0
        adc #0                 ; bank = carry from shift
        sta reu_reu_bank
        lda #%10110001         ; execute + autoload + FETCH (REU->C64)
        sta reu_command
        rts

; =============================================================================
; reu_fetch_doubled_row - DMA pre-doubled multiplication row for fe_sqr
;
; Input: A = multiplier value in mul_cached_a
; Fetches 512 bytes from banks 4-5 to mul_dma_lo/hi (doubled lo+hi),
; then 256 bytes from bank 3 to mul_dma_carry (17th-bit carry flags).
; Clobbers: A
; NOTE: Leaves REU registers in a non-default state; caller must restore
; if the regular mul-row FETCH config is needed afterward.
; =============================================================================
reu_fetch_doubled_row:
        ; First DMA: 512 bytes to mul_dma_lo from banks 4-5, offset a*512
        lda #<mul_dma_lo
        sta reu_c64_lo
        lda #>mul_dma_lo
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
        lda #<mul_dma_carry
        sta reu_c64_lo
        lda #>mul_dma_carry
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

; =============================================================================
; reu_clear_wide - DMA-zero fe_wide[0..63] ($40..$7F) via REU FETCH from bank 2
;
; Fetches 64 pre-stashed zero bytes from REU bank=2, offset=0 to C64 $0040.
; Then restores REU registers to mul-row FETCH config (c64=mul_dma_lo, len=512).
; Clobbers: A
; =============================================================================
reu_clear_wide:
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
        lda #<mul_dma_lo
        sta reu_c64_lo
        lda #>mul_dma_lo
        sta reu_c64_hi
        lda #0
        sta reu_len_lo
        lda #2
        sta reu_len_hi
        rts

; =============================================================================
; Assembly modules
; =============================================================================
!source "mul_8x8.asm"
!source "fe25519.asm"
!source "x25519.asm"

; =============================================================================
; Data section
; =============================================================================
!source "data.asm"

; =============================================================================
; Strings
; =============================================================================
title_msg:
        !byte 147              ; clear screen (PETSCII)
        !text "X25519 PERF TUNING"
        !byte 13, 0

ready_msg:
        !text "READY. Q=QUIT"
        !byte 13, 0

; Input buffer for test harness trampoline
input_buffer:
        !fill 64, 0
