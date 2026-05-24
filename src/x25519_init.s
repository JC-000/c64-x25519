; =============================================================================
; x25519_init.s - Library initialization and REU helper routines
; =============================================================================

.setcpu "6502"

.include "constants.s"

.export reu_fetch_mul_row, reu_clear_wide
.if ::SQR_DMA_K
; reu_fetch_doubled_row only exists in the SQR_DMA_K > 0 (default)
; build. The K=0 / lib-x25519-1764 variant gates the proc body out
; below (see banner at the proc), and matching call-site / .import
; in src/fe25519.s drops with it. Without gating the .export, ca65
; errors with "Exported symbol 'reu_fetch_doubled_row' was never
; defined" because .export demands a definition in the same TU.
.export reu_fetch_doubled_row
.endif

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
;
; SPEC §8.2 migration gate. When a consumer defines SHARED_REU_MUL_INIT
; (e.g. it links c64-nist-curves alongside c64-x25519 and wants one
; canonical 128 KB build), this whole body is gated out and the
; consumer's `reu_mul_tables_init` from its other adopter takes over.
;
; Caveat for the SQR_DMA_K > 0 (default) build: the pre-doubled rows
; in banks +3..+5 are currently generated INSIDE this proc's per-a
; loop, reusing each iteration's mul_dma_lo/hi staging buffer before
; the next iteration overwrites it. Under SHARED_REU_MUL_INIT, those
; banks are NOT produced by the canonical init (which by SPEC §8.2
; "MUST NOT touch those banks"). A consumer that defines
; SHARED_REU_MUL_INIT with SQR_DMA_K > 0 must therefore either:
;   1. build c64-x25519 as the 1764-variant (`make lib-x25519-1764`,
;      SQR_DMA_K = 0) so the doubled tables are never read, OR
;   2. ship its own library-private doubled-bank init that re-reads
;      banks 0/1 row-by-row and re-runs the doubling step (the
;      structural refactor tracked by c64-lib-contract issue #15).
;
; The standalone build (no SHARED_REU_MUL_INIT) is unchanged: this
; proc runs, both un-doubled and doubled rows are produced, and the
; library is bit-identical to v0.6.0. `reu_mul_tables_init` is
; published as the SPEC §8.2 canonical alias.
;
; "Safe to call twice" per SPEC §8.2: a second call rebuilds the same
; final REU state with the same observable side effects (the full
; ~3 s init runs again). NOT idempotent in the no-op sense.
; =============================================================================
.ifndef SHARED_REU_MUL_INIT
.export reu_mul_init
; SPEC §8.2 canonical entry point. In standalone builds, aliases the
; library's own body (this proc). When SHARED_REU_MUL_INIT is defined,
; this alias is not emitted here; the consumer's shared-primitives
; module provides reu_mul_tables_init from elsewhere.
.export reu_mul_tables_init
reu_mul_tables_init = reu_mul_init
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

.if ::SQR_DMA_K
        ; --- Generate pre-doubled tables for fe25519_sqr (8f+8g) ---
        ; Overwrite mul_dma_lo/hi with 2*a*b (17-bit), and fill mul_dma_carry
        ; with the 17th bit. Regular tables were already stashed above.
        ;
        ; Whole block gated on `SQR_DMA_K > 0`. When SQR_DMA_K = 0
        ; (the v0.6 1764-variant build, see make lib-x25519-1764),
        ; fe25519_sqr never dispatches to the DMA path so banks 3/4/5
        ; are unused at runtime. Skipping the generation here drops
        ; ~600 ms of init wall-clock per cold boot AND truly frees the
        ; banks (otherwise the stash still runs even though the data
        ; is never read back). With this guard:
        ;
        ;   default build (SQR_DMA_K=22) → banks 0,1,3,4,5 written.
        ;   K=0 build                    → banks 0,1 only.
        ;
        ; The corresponding LIB_X25519_REU_BANKS_USED manifest mask
        ; flips from $3B to $03 in src/lib_version.s under the same
        ; guard, so consumer collision checks see the smaller claim.
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
.endif  ; SQR_DMA_K (non-zero)

        inc reu_init_a
        beq @init_done         ; if wrapped to 0, done
        jmp @outer
@init_done:
        ; (W3 / v0.6 prep: the legacy "stash 64 zero bytes to REU bank 2
        ;  offset 0" block that used to live here has been removed.
        ;  reu_clear_wide was rewritten in v0.4.0 prep (W2) to do a CPU
        ;  clear of fe_wide; nothing in the library reads from bank 2.
        ;  Removing the stash frees REU bank 2 for sibling consumers and
        ;  drops the LIB_X25519_REU_BANKS_USED claim from $3F to $3B.)

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

; SPEC §8.2 ZP scratch contract: these two byte slots are exported via
; `.global` so reu_config.s's LIB_SHARED_REU_MUL_ZP_INIT_A / _B equates
; (declared as link-time aliases under their respective .ifndef guards)
; resolve to the same storage. Default consumers see the legacy
; CODE-segment scratch; an override-via-`--asm-define` consumer that
; defines the equates earlier wins via the .ifndef.
.global reu_init_a, reu_init_b
reu_init_a:     .byte 0
reu_init_b:     .byte 0
.endproc
.endif ; SHARED_REU_MUL_INIT

; =============================================================================
; reu_fetch_mul_row - DMA a multiplication table row from REU to C64
;
; Input: A = multiplier value (0-255) in mul_cached_a
; Fetches 512 bytes: 256 lo bytes to mul_dma_lo, 256 hi bytes to mul_dma_hi
; Clobbers: A
;
; The `bank_lda` regular local label (not cheap-`@`-local because we
; address it from outside the proc via `proc::label` syntax, which
; cheap-locals don't support) tags the LDA #X25519_REU_BANK instruction
; so reu_fetch_mul_row_bank_patch (below) can export its immediate-byte
; address as an SMC patch point. This is a no-op for canonical callers;
; it is consumed by reu_fetch_doubled_row's DMA #1 (above the inline
; carry-fetch) to retarget the bank base to X25519_REU_BANK_DOUBLED for
; the duration of one call, then restored. See the
; c64-lib-contract issue #15 design notes at
; docs/design/issue_15_smc_patch_doubled_fetch.md.
;
; Caller contract (autoload-latch trust): this proc does NOT touch
; reu_c64_lo/hi, reu_len_lo/hi, reu_reu_lo, or reu_addr_ctrl. Callers
; MUST have established the canonical autoload-latch state
; (mul_dma_lo / 512 / 0 / 0) before JSR'ing here. The two callers that
; honor this contract are (a) fe25519_mul's per-row inline DMA (which
; runs after reu_clear_wide's autoload-restore tail) and (b)
; reu_fetch_doubled_row's DMA #1 (which explicitly re-writes the four
; registers before the JSR — see banner there).
; =============================================================================
.proc reu_fetch_mul_row
        lda mul_cached_a
        asl                    ; A = multiplier * 2, carry = bit 7
        sta reu_reu_hi
bank_lda:
        lda #X25519_REU_BANK
        adc #0                 ; bank = X25519_REU_BANK + (a >> 7)
        sta reu_reu_bank
        lda #%10110001         ; execute + autoload + FETCH (REU->C64)
        sta reu_command
        rts
.endproc

; SMC patch point export. Address of the immediate-operand byte of the
; `lda #X25519_REU_BANK` instruction inside reu_fetch_mul_row. +1 skips
; the LDA opcode and lands on the immediate byte; an SMC caller can STA
; here to retarget the fetch to a different REU bank base without
; rebuilding the library. No-op for in-tree / canonical callers.
reu_fetch_mul_row_bank_patch := reu_fetch_mul_row::bank_lda + 1
.export reu_fetch_mul_row_bank_patch

; =============================================================================
; reu_fetch_doubled_row - DMA pre-doubled multiplication row for fe25519_sqr
;
; Input: A = multiplier value in mul_cached_a
; Fetches 512 bytes from banks 4-5 to mul_dma_lo/hi (doubled lo+hi),
; then 256 bytes from bank 3 to mul_dma_carry (17th-bit carry flags).
; Clobbers: A
; NOTE: Leaves REU registers in a non-default state; caller must restore
; if the regular mul-row FETCH config is needed afterward (see
; reu_clear_wide's autoload-restore tail, which is what fe25519_sqr
; relies on between its calls and any subsequent fe25519_mul).
;
; -----------------------------------------------------------------------------
; c64-lib-contract issue #15 refactor (v0.7.0 prep):
;
; DMA #1 (the 512-byte doubled-lo/hi fetch) is delegated to the canonical
; 3-register-touch `reu_fetch_mul_row` primitive (only writes
; reu_reu_hi / reu_reu_bank / reu_command), with the bank-base immediate
; byte SMC-patched to X25519_REU_BANK_DOUBLED for the duration of the
; call and restored to X25519_REU_BANK immediately after return. This
; collapses ~16 bytes of duplicated REU-register staging in the library
; image and unlocks SPEC §8.x sharing of the fetch primitive.
;
; Autoload-latch invariant (LOAD-BEARING — do not break):
;   reu_fetch_mul_row trusts the autoload latch for reu_c64_lo/hi,
;   reu_len_lo/hi, reu_reu_lo, and reu_addr_ctrl. Specifically it
;   expects:
;       reu_c64_lo/hi = mul_dma_lo
;       reu_len_lo/hi = $00 / $02 (i.e. 512-byte transfer)
;       reu_reu_lo    = $00
;       reu_addr_ctrl = $00
;   Two callers establish this latched state:
;     (a) the tail of `reu_mul_init` (one-shot init), and
;     (b) the tail of `reu_clear_wide` (re-establishes the latch on
;         every fe25519_sqr / fe25519_mul entry).
;   fe25519_sqr's current call shape is:
;       jsr reu_clear_wide       ; (re-)establishes canonical latch
;       loop:
;         jsr reu_fetch_doubled_row  ; uses canonical latch on entry,
;                                    ; STOMPS it via DMA #2 below.
;   The "stomp" in DMA #2 is harmless WITHIN this proc because:
;     - DMA #2 writes its own reu_c64_lo/hi, reu_len_hi (=$01),
;       reu_addr_ctrl, reu_reu_lo before firing, so it never reads
;       a stale latch value.
;     - The NEXT iteration's DMA #1 re-establishes the canonical
;       latch by re-writing those four registers BEFORE delegating
;       to reu_fetch_mul_row (see explicit `sta reu_c64_lo` / `_hi`
;       / `len_lo` / `addr_ctrl` / `reu_reu_lo` sequence below).
;   Without those explicit re-writes, iterations 2..N would inherit
;   DMA #2's latched mul_dma_carry/256/... and reu_fetch_mul_row
;   would DMA 256 bytes into mul_dma_carry, silently corrupting the
;   doubled-lo/hi tables. This is the same W2-class state-leak class
;   that the v0.4.0 `reu_clear_wide` rewrite closed (see that proc's
;   banner). Regression: `tools/test_fe_sqr_then_mul.py`.
; -----------------------------------------------------------------------------
;
; Gated on `SQR_DMA_K`: when SQR_DMA_K = 0 (the v0.6 1764-variant
; build), `fe25519_sqr` never dispatches to the DMA path so this proc
; is dead code. Gating it out drops dead references to
; reu_fetch_mul_row_bank_patch from the K=0 build image (mirrors the
; existing SQR_DMA_K gate inside reu_mul_init above and
; LIB_X25519_REU_BANKS_USED's $3B↔$03 flip in src/lib_version.s).
; The matching `.export reu_fetch_doubled_row` at the top of this
; file is gated under the same condition, and `src/fe25519.s`'s
; `.import` + DMA-dispatch block are gated too — see the issue #15
; design doc at docs/design/issue_15_smc_patch_doubled_fetch.md.
; =============================================================================
.if ::SQR_DMA_K
.proc reu_fetch_doubled_row
        ; --- DMA #1: 512 bytes to mul_dma_lo from banks 4-5, offset a*512
        ;
        ; Re-establish canonical autoload-latch state (see banner above).
        ; These five writes are NOT redundant: DMA #2 of the previous
        ; iteration stomped reu_c64_lo/hi (=mul_dma_carry) and
        ; reu_len_hi (=$01). They must be canonical BEFORE delegating
        ; to reu_fetch_mul_row, which trusts the latch.
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
        ; SMC: retarget reu_fetch_mul_row at the DOUBLED bank base for
        ; this one call, then restore the canonical X25519_REU_BANK
        ; before RTS. fe25519_mul currently INLINES its per-row DMA
        ; (it does not JSR reu_fetch_mul_row), so a missed restore
        ; would not immediately corrupt fe25519_mul. The restore is
        ; nonetheless unconditional for two reasons:
        ;   (1) R1 hygiene — the proc is R1-safe in isolation, the
        ;       SMC byte's post-call state is always X25519_REU_BANK,
        ;       no caller-side restore obligation.
        ;   (2) Forward-compat — a future c64-lib-contract consumer
        ;       (or a SHARED_REU_MUL_INIT user) that JSRs
        ;       reu_fetch_mul_row directly after fe25519_sqr would
        ;       silently read from bank +4 if the restore were
        ;       skipped, recreating the W2-class corruption class.
        lda #X25519_REU_BANK_DOUBLED
        sta reu_fetch_mul_row_bank_patch
        jsr reu_fetch_mul_row
        lda #X25519_REU_BANK
        sta reu_fetch_mul_row_bank_patch

        ; --- DMA #2: 256 bytes to mul_dma_carry from CARRY bank,
        ;     offset a*256. Stays inline: different length (256 not 512),
        ;     different target buffer, different reu_reu_hi derivation
        ;     (raw `mul_cached_a`, not `mul_cached_a << 1`). Cannot fold
        ;     into reu_fetch_mul_row without changing that primitive's
        ;     contract.
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
        lda #X25519_REU_BANK_CARRY
        sta reu_reu_bank
        lda #%10110001
        sta reu_command
        rts
.endproc
.endif  ; SQR_DMA_K

; =============================================================================
; reu_clear_wide - Zero fe_wide[0..63] ($40..$7F) via 64-byte CPU loop
;
; W2 cleanup: previously this routine FETCHed 64 pre-stashed zero bytes
; from REU bank 2. The REU round-trip (~150 cy) was costlier than the
; CPU clear (~640 cy on 6502, but only ~10.7 jif/scalarmult amortized
; over fe25519_mul invocations), and it created a dangerous coupling:
; if a previous fe25519_sqr's reu_fetch_doubled_row inline carry-fetch
; (DMA #2, see that proc) had reconfigured the REU registers
; (different bank, different length, autoload off), the next
; reu_clear_wide would silently fetch garbage. The CPU clear is
; bank-state-independent and removes that failure mode.
;
; The autoload-restore tail at the end of this proc is CRITICAL for
; the same reason: fe25519_mul's per-row inline DMA (in fe25519.s)
; relies on the REU registers being pre-configured to fetch from
; mul_dma_lo with len=512 and autoload latched. Without the tail
; below, an immediately following fe25519_mul would inherit whatever
; the previous fe25519_sqr left in the autoload latch via
; reu_fetch_doubled_row's inline DMA #2 (256 bytes to mul_dma_carry
; from bank +3) and read the 17th-bit carry table by mistake. This
; was caught by the mul(1,1)-after-sqr(1) → 0 regression (W2 root
; cause analysis). The issue #15 SMC-patch refactor of DMA #1 does
; NOT change this story: DMA #1 now delegates to reu_fetch_mul_row,
; whose autoload-completed state is canonical (mul_dma_lo / 512), so
; the post-fetch_doubled_row latched state is determined entirely by
; the inline DMA #2 — same residue, same restore obligation.
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
        ; A previous fe25519_sqr's reu_fetch_doubled_row inline DMA #2
        ; (256 bytes to mul_dma_carry from bank +3, see that proc) may
        ; have left reu_c64_* pointing at mul_dma_carry and reu_len_hi
        ; at $01; without restoring here the next fe25519_mul reads
        ; garbage.
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
