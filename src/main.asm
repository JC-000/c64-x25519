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
