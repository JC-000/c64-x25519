; =============================================================================
; util.s - Library-public utility routines (benchmark timing + VIC-II control)
;
; This file is part of the c64-x25519 library archive. It provides helpers
; that downstream consumers can link against without pulling in the test
; harness (BASIC stub, idle loop, print helpers) from main.s.
;
; Exports:
;   bench_start    Reset jiffy clock and start timing
;   bench_stop     Snapshot jiffy clock into bench_ticks (3 bytes)
;   bench_ticks    3-byte result buffer filled by bench_stop
;   vic_blank      Disable VIC-II display (~25% CPU speedup)
;   vic_unblank    Re-enable VIC-II display
;
; See src/x25519.inc for full calling conventions.
; =============================================================================

.setcpu "6502"

.include "constants.s"

.export bench_start, bench_stop, bench_ticks
.export vic_blank, vic_unblank

.segment "CODE"

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
