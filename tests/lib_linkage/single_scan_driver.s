; =============================================================================
; single_scan_driver.s - consumer side of the #132 single-scan extraction leg
;
; Stands in for a real two-sibling consumer (c64-wireguard's shape): it
; references x25519's public API AND a sibling library that defers §8.1 to
; us. The whole point of the harness is the LINK ORDER used by
; `make lib-verify-single-scan`:
;
;     ld65 ... single_scan_driver.o x25519.a sibling.a
;
; x25519.a is listed FIRST, which is the order every consumer writes and the
; order that worked before v0.16.0. ld65 scans each archive once, in link
; order, so if nothing inside x25519.a references the §8.1 group then
; sqtab_init.o is never extracted and the sibling's import (scanned later,
; with no archive left behind it) is unresolvable. That is #132.
;
; This TU deliberately references only PUBLIC API and never mul_tables_init
; itself -- a driver-side import would satisfy the sibling by itself and the
; leg would pass with the defect present.
; =============================================================================

.setcpu "6502"

; ld65's LOADADDR segment needs this import to land the 2-byte load header.
.export __LOADADDR__: absolute = 1

.import x25519_clamp, x25_scalar
.import sibling_entry

.segment "LOADADDR"
        .addr $0801

.segment "BASICSTUB"
        .word @basic_end
        .word 10
        .byte $9e
        .byte "2064"
        .byte 0
@basic_end:
        .word 0

.segment "CODE"
        .res 3, $00
start:
        jsr sibling_entry
        jsr x25519_clamp
        rts

; A referenced symbol is what forces an archive-member pull; a bare .import
; emits no import record at all (measured -- the same fact Option B rests on).
        .addr x25_scalar
