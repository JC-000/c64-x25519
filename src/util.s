; =============================================================================
; util.s - Library-public utility routines (benchmark timing + VIC-II control)
;
; This file is part of the c64-x25519 library archive. It provides helpers
; that downstream consumers can link against without pulling in the test
; harness (BASIC stub, idle loop, print helpers) from main.s.
;
; Exports:
;   bench_start          Reset jiffy clock and start timing
;   bench_stop           Snapshot jiffy clock into bench_ticks (3 bytes)
;   bench_ticks          3-byte result buffer filled by bench_stop
;   bench_cycles_start   Start CIA1 TA+TB 32-bit cycle counter (sei-safe)
;   bench_cycles_stop    Stop counter, snapshot into bench_cycles (4 bytes)
;   bench_cycles         4-byte cycle count (LE 32-bit) from bench_cycles_stop
;   vic_blank            Disable VIC-II display (~25% CPU speedup)
;   vic_unblank          Re-enable VIC-II display
;
; See src/x25519.inc for full calling conventions.
; =============================================================================

.setcpu "6502"

.include "constants.s"

.export bench_start, bench_stop, bench_ticks
.export bench_cycles_start, bench_cycles_stop, bench_cycles
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
; CIA1-based 32-bit cycle counter (sei-safe)
;
; The jiffy-clock timer (bench_start / bench_stop above) is driven by the
; kernal IRQ handler. Callers that run with IRQs disabled — notably
; x25519_scalarmult, which sei's for its entire body as a CT defence —
; will see the jiffy clock frozen for the whole call, so bench_ticks
; reports ~0 jif regardless of wall time.
;
; The CIA1 hardware timers tick from the phi2 system clock directly and
; keep counting under sei. We chain CIA1 timer A and timer B as a 32-bit
; cycle counter:
;
;   - Timer A: continuous mode, phi2 clock source, latch = $FFFF.
;             One decrement per CPU cycle. Underflow every 65,536 cycles.
;   - Timer B: continuous mode, *count timer A underflows*, latch = $FFFF.
;             One decrement per timer A underflow. Together with TA this
;             gives a 32-bit down-counter spanning 2^32 cycles (~4.2 s
;             of real C64 time, ~70 min of C64 work at 60Hz wall clock).
;
; Sufficient for x25519_scalarmult (~280M cycles ~= 14.4k jif), with
; ~15x headroom before TB underflows.
;
; Both timers are *stopped* and then snapshotted at bench_cycles_stop
; (no read-while-running atomicity hazard). The CIA1 interrupt sources
; for TA/TB underflow are masked at bench_cycles_start so a transient
; CLI in the timed code path can't raise an IRQ off our reconfigured
; timers.
;
; CAVEAT: bench_cycles_start replaces the kernal's CIA1 TA setup
; (which normally fires the 1/60s jiffy IRQ). After bench_cycles_stop
; runs, the kernal jiffy IRQ rate is no longer correct until kernal
; re-initialisation. This is fine for bench harnesses that run once
; and exit, but bench_cycles_* is NOT a drop-in for bench_start/stop
; in long-running host programs that expect the jiffy clock to keep
; working afterwards.
;
; Result layout (4 bytes, little-endian 32-bit cycle count):
;   bench_cycles+0..1  = (initial TA $FFFF) - (final TA)  = low 16 bits
;   bench_cycles+2..3  = (initial TB $FFFF) - (final TB)  = high 16 bits
; bench_cycles_stop computes the subtraction so callers just read four
; bytes and treat them as a little-endian u32 cycle count.
;
; Like bench_start/stop, this pair preserves the caller's I-flag via
; bench_cycles_saved_p. Single-shot (not nestable).
; =============================================================================

; bench_cycles_start - Configure CIA1 TA+TB as a free-running 32-bit
;                      down-counter starting at $FFFFFFFF. Saves caller's
;                      P (incl. I flag); leaves IRQs masked while the
;                      counter runs (matched by bench_cycles_stop's plp).
.proc bench_cycles_start
        php                         ; save caller's P (incl. I flag)
        pla
        sta bench_cycles_saved_p
        sei                         ; mask IRQs while we reconfigure CIA1

        ; --- Stop both timers so writes to TA/TB hi load the latch
        ;     without triggering a force-load race ---
        lda #$00
        sta cia1_cra                ; CRA = 0  -> TA stopped
        sta cia1_crb                ; CRB = 0  -> TB stopped

        ; --- Mask CIA1 TA/TB underflow IRQ sources ---
        ; ICR write: bit 7 = 0 -> "clear the masked sources"
        ;            bits 0,1 = 1 -> clear TA-underflow + TB-underflow IRQs.
        lda #$7f                    ; %0111_1111 = clear all CIA1 IRQ sources
        sta cia1_icr
        lda cia1_icr                ; read clears latched IRQs

        ; --- Load TA latch = $FFFF (writing hi to a stopped timer also
        ;     loads the counter from the latch) ---
        lda #$ff
        sta cia1_ta_lo
        sta cia1_ta_hi

        ; --- Load TB latch = $FFFF ---
        sta cia1_tb_lo
        sta cia1_tb_hi

        ; --- Start timer B first (input mode = count TA underflows).
        ;     CRB = %01010001:
        ;       bit 0   = 1  -> start
        ;       bit 3   = 0  -> continuous (auto-reload on underflow)
        ;       bit 4   = 1  -> force load from latch
        ;       bits 5-6= 10 -> count TA underflows
        lda #$51
        sta cia1_crb

        ; --- Start timer A (count phi2, continuous, force load).
        ;     CRA = %00010001:
        ;       bit 0   = 1  -> start
        ;       bit 3   = 0  -> continuous
        ;       bit 4   = 1  -> force load from latch
        ;       bits 5-6= 00 -> count phi2 (system clock)
        lda #$11
        sta cia1_cra
        rts
.endproc

; bench_cycles_stop - Stop CIA1 TA+TB, compute 32-bit cycle count
;                     into bench_cycles (little-endian), restore caller's P.
.proc bench_cycles_stop
        ; --- Stop both timers (atomic snapshot) ---
        lda #$00
        sta cia1_cra                ; stop TA
        sta cia1_crb                ; stop TB

        ; --- Compute low 16 bits: $FFFF - TA  (carry propagates) ---
        sec
        lda #$ff
        sbc cia1_ta_lo
        sta bench_cycles+0
        lda #$ff
        sbc cia1_ta_hi
        sta bench_cycles+1

        ; --- Compute high 16 bits: $FFFF - TB ---
        ; Note: TB decrements on TA *underflow*. Each TA underflow takes
        ; one extra cycle for the latch reload, so TB tick = 65,536 cycles
        ; of TA. The low/high pair below is therefore a clean 32-bit
        ; cycle count for the period TA+TB were both running together.
        sec
        lda #$ff
        sbc cia1_tb_lo
        sta bench_cycles+2
        lda #$ff
        sbc cia1_tb_hi
        sta bench_cycles+3

        lda bench_cycles_saved_p
        pha
        plp                         ; restore caller's I flag (and full P)
        rts
.endproc

bench_cycles:           .res 4, 0
bench_cycles_saved_p:   .byte 0     ; caller's P across start/stop. Single-shot.

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
