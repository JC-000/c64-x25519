; =============================================================================
; main.s - Standalone X25519 test harness
;
; Memory layout:
;   $0801-$08FF: BASIC stub + boot
;   $0900+:      code (mul_8x8, fe25519, x25519, benchmark)
;   $7800-$7BFF: sqtab (quarter-square multiply tables)
; =============================================================================

.setcpu "6502"

; ld65 needs this symbol to place the LOADADDR segment in the output file.
.export __LOADADDR__: absolute = 1

.include "constants.s"

; --- Imports from mul_8x8.s ---
.import sqtab_init

; --- Imports from x25519_init.s ---
.import reu_mul_init

; --- Exports defined in this file ---
.export bench_start, bench_stop, bench_ticks, input_buffer
.export vic_blank, vic_unblank

; --- Export ZP/constant symbols for VICE label file ---
; These are equates from constants.s; exporting once here makes them
; appear in ld65 -Ln output for the Python test harness.
.exportzp fe25519_src1, fe25519_src2, fe25519_dst
.exportzp fe_wide
.export cassette_buf

; ---------------------------------------------------------------------------
; LOADADDR segment: 2-byte PRG header (little-endian start address $0801)
; ---------------------------------------------------------------------------
.segment "LOADADDR"
        .addr $0801

; ---------------------------------------------------------------------------
; BASIC stub: 12 bytes starting at $0801
; ---------------------------------------------------------------------------
.segment "BASICSTUB"
basic_stub:
        .word basic_end         ; pointer to next BASIC line
        .word 10                ; line number 10
        .byte $9e               ; SYS token
        .byte "2064"            ; decimal address (must match start label)
        .byte 0                 ; end of line
basic_end:
        .word 0                 ; end of BASIC program

; =============================================================================
; Program entry point
; =============================================================================
.segment "CODE"

; Pad to $0810 so start label lands at $0810 (SYS 2064).
; BASIC stub is 12 bytes ($0801-$080C), so CODE starts at $080D.
; We need 3 fill bytes to reach $0810.
.res 3, $00

start:
        ; bank out BASIC ROM to use $A000-$BFFF as RAM
        lda proc_port
        and #$fe                ; clear bit 0 (LORAM) — bank out BASIC ROM
        sta proc_port

        ; clear screen
        jsr clrscr

        ; display title
        lda #<(title_msg)
        ldy #>(title_msg)
        jsr print_string

        ; Initialize quarter-square table
        jsr sqtab_init

        ; Initialize REU multiplication tables
        jsr reu_mul_init

        ; display ready message
        lda #<(ready_msg)
        ldy #>(ready_msg)
        jsr print_string

        ; Main idle loop - wait for test harness commands
main_loop:
        jmp main_loop

; =============================================================================
; clrscr - Clear screen
; =============================================================================
.proc clrscr
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
.endproc

; =============================================================================
; print_string - Print null-terminated string
; Input: A=low byte, Y=high byte of string address
; =============================================================================
.proc print_string
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
.endproc

; =============================================================================
; Benchmark timer routines
; =============================================================================

; bench_start - Reset jiffy clock and start timing
.proc bench_start
        sei
        lda #0
        sta jiffy_clock
        sta jiffy_clock+1
        sta jiffy_clock+2
        cli
        rts
.endproc

; bench_stop - Read jiffy clock into bench_ticks (3 bytes)
.proc bench_stop
        sei
        lda jiffy_clock
        sta bench_ticks
        lda jiffy_clock+1
        sta bench_ticks+1
        lda jiffy_clock+2
        sta bench_ticks+2
        cli
        rts
.endproc

bench_ticks:    .res 3, 0

; =============================================================================
; VIC-II screen blanking for maximum CPU throughput
; =============================================================================

; vic_blank - Disable VIC-II display (DEN=0) for ~20-25% CPU speedup
.proc vic_blank
        lda vic_ctrl1
        and #$ef               ; clear bit 4 (DEN - Display Enable)
        sta vic_ctrl1
        rts
.endproc

; vic_unblank - Re-enable VIC-II display (DEN=1)
.proc vic_unblank
        lda vic_ctrl1
        ora #$10               ; set bit 4
        sta vic_ctrl1
        rts
.endproc

; =============================================================================
; Strings
; =============================================================================
title_msg:
        .byte 147              ; clear screen (PETSCII)
        .byte "X25519 PERF TUNING"
        .byte 13, 0

ready_msg:
        .byte "READY. Q=QUIT"
        .byte 13, 0

; Input buffer for test harness trampoline
input_buffer:
        .res 64, 0
