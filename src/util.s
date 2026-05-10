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
;
; bench_start / bench_stop preserve the caller's I-flag (interrupt-disable)
; state via a static one-byte slot `bench_saved_p`. The pair previously
; used raw `sei` / `cli`, which silently re-enabled IRQs at bench_stop
; even when the caller had been running with IRQs disabled (e.g. a host
; that wraps the bench in its own `php / sei … plp`). The php/plp pair
; below records the caller's status register at bench_start and restores
; it at bench_stop, leaving the I-flag exactly as the caller had it.
;
; LIMITATION: the slot is one byte, so bench_start / bench_stop pairs
; cannot be nested. This matches the existing `bench_ticks` 3-byte slot,
; which is also a single-shot global.
; =============================================================================

; bench_start - Reset jiffy clock and start timing.
;               Saves caller's processor status (incl. I flag) to
;               bench_saved_p; matched by bench_stop's plp.
.proc bench_start
        php                     ; save caller's P register
        pla                     ; pull P into A
        sta bench_saved_p       ; stash for bench_stop
        sei                     ; mask IRQs while we zero the jiffy clock
        lda #0
        sta jiffy_clock
        sta jiffy_clock+1
        sta jiffy_clock+2
        rts
.endproc

; bench_stop - Read jiffy clock into bench_ticks (3 bytes), then restore
;              the caller's processor status saved by bench_start (bench_saved_p
;              -> P via pha/plp), so the I flag returns to its prior state.
.proc bench_stop
        ; (No SEI/CLI here: bench_start already left IRQs masked, and the
        ; caller's I flag is restored via plp below.)
        lda jiffy_clock
        sta bench_ticks
        lda jiffy_clock+1
        sta bench_ticks+1
        lda jiffy_clock+2
        sta bench_ticks+2
        lda bench_saved_p       ; recover caller's P
        pha
        plp                     ; restore caller's I flag (and full P)
        rts
.endproc

bench_ticks:    .res 3, 0
bench_saved_p:  .byte 0         ; static slot for caller's I-flag across
                                ; bench_start / bench_stop. Single-shot:
                                ; bench_start/stop pairs cannot be nested.

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
