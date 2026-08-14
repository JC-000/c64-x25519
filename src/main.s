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

; Test-harness-local ZP scratch (contract #83): moved here from
; zp_config.s — no library TU uses these, and shipping them as bare
; archive exports collided with c64-nist-curves' live slots of the
; same generic names. Harness-only; NOT part of the library's claimed
; ZP surface (see x25519.inc ZP map).
zp_ptr1 = $fb           ; 2-byte pointer
zp_tmp1 = $02           ; temp byte
zp_tmp2 = $03           ; temp byte

; --- Imports from mul_8x8.s ---
.import sqtab_init

; --- Imports from x25519_init.s ---
.if ::X25519_ONCHIP_MUL = 0
.import reu_mul_init
.endif

; --- Exports defined in this file ---
.export input_buffer

; bench_*/vic_* live in util.s (library-public utilities). They are not
; re-exported here but are pulled into the test harness build via the
; Makefile's object list.

; --- Export ZP/constant symbols for VICE label file ---
; fe25519_src1/_src2/_dst (and the other public ZP slots) are now
; exported by src/zp_config.s per c64-lib-contract §2; do NOT re-export
; them here or ld65 errors on "Duplicate external identifier".
; fe_wide stays in constants.s (pinned CT/SMC invariant; not movable),
; so it's still exported here to land in the VICE label file.
.exportzp fe_wide
.export cassette_buf
.export main_loop                 ; needed by tools/test_issue33_adversarial.py
                                  ; for trampoline hijack on U64E hardware

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

.if ::X25519_ONCHIP_MUL = 0
        ; Initialize REU multiplication tables
        jsr reu_mul_init
.endif
        ; (Onchip profile boots with sqtab_init only — no REU init,
        ;  no REU present required. Issue #72.)

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
