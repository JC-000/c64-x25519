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
        lda #X25519_REU_BANK
        adc #0                 ; bank = X25519_REU_BANK + (a >> 7)
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
        lda #X25519_REU_BANK
        adc #0                 ; bank = X25519_REU_BANK + (a >> 7)
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
        lda #4+X25519_REU_BANK
        adc #0                 ; bank = X25519_REU_BANK + 4 + (a >> 7)
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
        lda #4+X25519_REU_BANK
        adc #0                 ; bank = X25519_REU_BANK + 4 + (a >> 7)
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
        lda #3+X25519_REU_BANK
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
        lda #2+X25519_REU_BANK
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
        lda #X25519_REU_BANK
        adc #0                 ; bank = X25519_REU_BANK + (a >> 7)
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
        lda #4+X25519_REU_BANK
        adc #0                 ; bank = X25519_REU_BANK + 4 + (a >> 7)
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
        lda #3+X25519_REU_BANK
        sta reu_reu_bank
        lda #%10110001
        sta reu_command
        rts
.endproc

; =============================================================================
; reu_clear_wide - Zero fe_wide[0..63] ($40..$7F) via 64-byte CPU loop
;
; W2 cleanup: previously this routine FETCHed 64 pre-stashed zero bytes
; from REU bank 2. The REU round-trip (~150 cy) was costlier than the
; CPU clear (~640 cy on 6502, but only ~10.7 jif/scalarmult amortized
; over fe25519_mul invocations), and it created a dangerous coupling:
; if a previous fe25519_sqr's reu_fetch_doubled_row had reconfigured
; the REU registers (different bank, different length, autoload off),
; the next reu_clear_wide would silently fetch garbage. The CPU clear
; is bank-state-independent and removes that failure mode.
;
; The autoload-restore tail at the end of this proc is CRITICAL for
; the same reason: fe25519_mul's per-row inline DMA (in fe25519.s)
; relies on the REU registers being pre-configured to fetch from
; mul_dma_lo with len=512 and autoload latched. Without the tail
; below, an immediately following fe25519_mul would inherit whatever
; the previous fe25519_sqr (via reu_fetch_doubled_row) left behind
; and read the 17th-bit carry table by mistake. This was caught by
; the mul(1,1)-after-sqr(1) → 0 regression (W2 root cause analysis).
;
; Clobbers: A, X
; =============================================================================
.proc reu_clear_wide
        ; CPU clear of fe_wide[0..63] in zero page ($40..$7F).
        ; (fe_wide is .assert'd to ZP; see src/constants.s. zp,X
        ;  store is 4 cyc; 64 iters * 4 cyc = ~256 cy plus DEX/BPL.)
        lda #0
        ldx #63
@loop:
        sta fe_wide,x
        dex
        bpl @loop

        ; Restore mul-row autoload state. fe25519_mul's per-row inline
        ; DMA expects:
        ;   reu_c64_lo/hi   = mul_dma_lo
        ;   reu_len_lo/hi   = $0000 / $0002 (i.e. 512-byte transfer)
        ;   reu_reu_lo      = $00 (already 0 from autoload latch)
        ;   reu_addr_ctrl   = $00 (already 0 from autoload latch)
        ; A previous fe25519_sqr's reu_fetch_doubled_row may have left
        ; reu_c64_* pointing at mul_dma_carry and reu_len_hi at $01;
        ; without restoring here the next fe25519_mul reads garbage.
        lda #<mul_dma_lo
        sta reu_c64_lo
        lda #>mul_dma_lo
        sta reu_c64_hi
        lda #0
        sta reu_len_lo
        lda #2
        sta reu_len_hi
        rts
.endproc

; =============================================================================
; reu_probe - Opt-in REU presence check
;
; Writes a sentinel byte ($5A) to REU bank 7 / $0000 via STASH, then
; reads it back via FETCH and compares to the original byte. If the
; round-trip recovers the sentinel, we have a working REU; otherwise
; the call is on a non-REU host (or a broken / under-sized REU).
;
; Bank 7 is chosen because the library only uses banks 0-5 (multiply
; tables) and bank 2 (zero block, no longer needed but still populated
; for legacy callers). Bank 7 is far enough away that we won't trample
; library state even on a misconfigured host.
;
; The original byte at the probed address is restored before returning,
; so reu_probe is safe to call before sqtab_init / reu_mul_init.
;
; Output:
;   C = 1   REU is present and round-trips the sentinel correctly
;   C = 0   no REU detected (or REU is faulty)
;
; This routine saves and restores enough REU state that subsequent
; sqtab_init / reu_mul_init / x25519_scalarmult calls work as if it
; had not run. It does NOT preserve the autoload latch state, so it
; should be called BEFORE the first reu_mul_init, not in the middle
; of a session.
;
; Cost: ~200-250 cycles. Caller-controlled — not invoked by the
; library itself; downstream hosts targeting mixed C64 hardware can
; gate sqtab_init / reu_mul_init on `bcc no_reu`.
;
; Clobbers: A, X, Y. Touches REU bank 7 offset $0000 (restored).
; =============================================================================
.export reu_probe
.proc reu_probe
        ; Save original REU register set we are about to disturb so the
        ; library's own state machine isn't surprised after probing.
        lda reu_c64_lo
        sta @save_c64_lo
        lda reu_c64_hi
        sta @save_c64_hi
        lda reu_reu_lo
        sta @save_reu_lo
        lda reu_reu_hi
        sta @save_reu_hi
        lda reu_reu_bank
        sta @save_reu_bank
        lda reu_len_lo
        sta @save_len_lo
        lda reu_len_hi
        sta @save_len_hi

        ; First: read the existing byte at bank 7 / $0000 into @scratch
        ; via a 1-byte FETCH so we can restore it later.
        lda #<@scratch
        sta reu_c64_lo
        lda #>@scratch
        sta reu_c64_hi
        lda #0
        sta reu_reu_lo
        sta reu_reu_hi
        sta reu_addr_ctrl
        lda #7+X25519_REU_BANK
        sta reu_reu_bank
        lda #1
        sta reu_len_lo
        lda #0
        sta reu_len_hi
        lda #%10010001         ; execute (no autoload) + FETCH
        sta reu_command
        lda @scratch
        sta @orig_byte         ; remember pre-probe byte for restore

        ; Write sentinel $5A to bank 7 / $0000 via 1-byte STASH.
        lda #$5A
        sta @scratch
        lda #<@scratch
        sta reu_c64_lo
        lda #>@scratch
        sta reu_c64_hi
        lda #0
        sta reu_reu_lo
        sta reu_reu_hi
        sta reu_addr_ctrl
        lda #7+X25519_REU_BANK
        sta reu_reu_bank
        lda #1
        sta reu_len_lo
        lda #0
        sta reu_len_hi
        lda #%10010000         ; execute (no autoload) + STASH
        sta reu_command

        ; Round-trip read back to scratch, then capture it in @rt_byte
        ; before any subsequent DMA can stomp scratch.
        lda #0
        sta @scratch           ; clear so a no-op DMA leaves it 0, not $5A
        lda #<@scratch
        sta reu_c64_lo
        lda #>@scratch
        sta reu_c64_hi
        lda #0
        sta reu_reu_lo
        sta reu_reu_hi
        sta reu_addr_ctrl
        lda #7+X25519_REU_BANK
        sta reu_reu_bank
        lda #1
        sta reu_len_lo
        lda #0
        sta reu_len_hi
        lda #%10010001         ; execute (no autoload) + FETCH
        sta reu_command
        lda @scratch           ; latch fetched byte to a private slot
        sta @rt_byte

        ; Restore the original byte at bank 7 / $0000 BEFORE we examine
        ; the result, so the caller's REU is undisturbed even if the
        ; check fails.
        lda @orig_byte
        sta @scratch
        lda #<@scratch
        sta reu_c64_lo
        lda #>@scratch
        sta reu_c64_hi
        lda #0
        sta reu_reu_lo
        sta reu_reu_hi
        sta reu_addr_ctrl
        lda #7+X25519_REU_BANK
        sta reu_reu_bank
        lda #1
        sta reu_len_lo
        lda #0
        sta reu_len_hi
        lda #%10010000         ; execute (no autoload) + STASH (restore)
        sta reu_command

        ; Now restore the saved REU register set the caller may rely on.
        lda @save_c64_lo
        sta reu_c64_lo
        lda @save_c64_hi
        sta reu_c64_hi
        lda @save_reu_lo
        sta reu_reu_lo
        lda @save_reu_hi
        sta reu_reu_hi
        lda @save_reu_bank
        sta reu_reu_bank
        lda @save_len_lo
        sta reu_len_lo
        lda @save_len_hi
        sta reu_len_hi
        lda #0
        sta reu_addr_ctrl

        ; Compare the latched round-trip byte (captured to @rt_byte
        ; immediately after the FETCH step, before any restore-DMA
        ; could overwrite @scratch). $5A means the REU returned the
        ; sentinel we wrote: REU present.
        lda @rt_byte
        cmp #$5A
        beq @ok
        clc                    ; C = 0: REU not present / not working
        rts
@ok:
        sec                    ; C = 1: REU OK
        rts

@scratch:       .byte 0        ; 1-byte DMA scratch buffer
@orig_byte:     .byte 0        ; saved pre-probe byte at bank7/$0000
@rt_byte:       .byte 0        ; round-trip readback latched before restore
@save_c64_lo:   .byte 0
@save_c64_hi:   .byte 0
@save_reu_lo:   .byte 0
@save_reu_hi:   .byte 0
@save_reu_bank: .byte 0
@save_len_lo:   .byte 0
@save_len_hi:   .byte 0
.endproc
