; main.s — ca65 stub for the dual-build scaffold (Phase B)
;
; This is NOT the real port.  It exists solely to prove the ca65/ld65
; toolchain produces a valid C64 PRG with the correct load address,
; BASIC stub, and VICE-format label file.  The real port replaces this
; file in Phase C.

; ld65 needs this symbol to place the LOADADDR segment in the output file.
.export __LOADADDR__: absolute = 1

; ---------------------------------------------------------------------------
; LOADADDR segment: 2-byte PRG header (little-endian start address $0801)
; ---------------------------------------------------------------------------
.segment "LOADADDR"
    .addr $0801

; ---------------------------------------------------------------------------
; BASIC stub: 12 bytes starting at $0801
;   $0801: $0B $08        next-line pointer ($080B)
;   $0803: $0A $00        line number 10
;   $0805: $9E            BASIC token for SYS
;   $0806: $32 $30 $36 $34  "2064" (ASCII)
;   $080A: $00            end of line
;   $080B: $00 $00        end of program (null next-line pointer)
; ---------------------------------------------------------------------------
.segment "BASICSTUB"
    .byte $0B, $08          ; pointer to next BASIC line
    .byte $0A, $00          ; line number 10
    .byte $9E               ; SYS token
    .byte $32, $30, $36, $34 ; "2064"
    .byte $00               ; end of line
    .byte $00, $00          ; end of BASIC program

; ---------------------------------------------------------------------------
; CODE — minimal entry point
; ---------------------------------------------------------------------------
.segment "CODE"

; Pad to $0810 to match the ACME build entry point.
; BASIC stub is 12 bytes ($0801-$080C), so CODE starts at $080D.
; We need 3 fill bytes to reach $0810.
.res 3, $00

.export start
start:
    lda #$00
    sta $d020           ; set border to black
    jmp start           ; infinite loop — proves PRG is runnable

; ---------------------------------------------------------------------------
; Dummy exports so the label file gets populated with key symbols.
; Phase C replaces these with real code.
; ---------------------------------------------------------------------------
.export x25519_scalarmult
x25519_scalarmult:
    rts

.export fe_mul
fe_mul:
    rts
