.setcpu "6502"

; =============================================================================
; zp_config.s - public zero-page slot inventory for c64-x25519.
;
; Per c64-lib-contract SPEC.md §2 (zero-page contract), every ZP slot the
; library claims is declared here as an `.ifndef`-guarded equate and is
; `.exportzp`-ed so consumer modules can `.importzp` it instead of
; `.include`-ing constants.s (which would also pull in BASIC / KERNAL /
; VIC / SID / CIA / REU hardware equates the consumer doesn't need).
;
; Host overrides
; --------------
;
; A host program can override any slot's address by pre-defining the symbol
; before `.include`-ing zp_config.s. The two recommended ways:
;
;   1. Pass `--asm-define fe25519_src1=$40` on the ca65 command line. This
;      defines the symbol globally for the translation unit, and the
;      .ifndef guard below then skips the default. ALL library translation
;      units must be assembled with the same --asm-define values, since
;      each .o bakes in the equate value at assemble time.
;
;   2. Inside a wrapper .s file:
;
;          fe25519_src1 = $40
;          .include "zp_config.s"
;
; The library's own standalone PRG (`make`) and library archive (`make
; lib`) assemble with the defaults. Consumer projects rebuild the library
; from source with --asm-define to pin slots to their preferred layout.
;
; Notes on what is NOT included here
; ----------------------------------
;
; - `fe_wide` ($40-$7F): intentionally pinned. It is a CT/SMC invariant
;   (the library's SMC inner loops patch only the low byte of `fe_wide,X`
;   operands), so it cannot move outside zero page. Declared in
;   constants.s with a hard `.assert` link check, not here.
;
; - `SQR_DMA_K`: a build-time numeric tunable for fe25519_sqr's hybrid
;   DMA threshold, not an address. Stays in constants.s.
;
; - Hardware-address equates (chrout, vic_*, cia*, sid_*, proc_port, REU
;   registers, kbd_buf_count, jiffy_clock): host-overridable for non-C64
;   targets but not consumer-importable as ZP slots.
;
; Suppressing the .exportzp block
; -------------------------------
;
; When zp_config.s is transitively `.include`'d via constants.s, the
; including translation unit must NOT re-emit the `.exportzp` directives
; (ld65 errors on the same symbol being exported from multiple .o files).
; constants.s sets `ZP_CONFIG_NO_EXPORTS = 1` before the include for this
; reason. zp_config.s itself, compiled as its own .o (the only place the
; exports actually need to land), does NOT set the flag and DOES emit
; them.
; =============================================================================

.ifndef ZP_CONFIG_S_INCLUDED
ZP_CONFIG_S_INCLUDED = 1

; --- General-purpose pointers / temps ---
.ifndef zp_ptr1
  zp_ptr1         = $fb           ; 2-byte pointer
.endif
.ifndef zp_tmp1
  zp_tmp1         = $02           ; temp byte
.endif
.ifndef zp_tmp2
  zp_tmp2         = $03           ; temp byte
.endif

; --- fe25519 field arithmetic working variables ---
.ifndef fe25519_src1
  fe25519_src1         = $1e           ; 2-byte pointer to operand 1
.endif
.ifndef fe25519_src2
  fe25519_src2         = $20           ; 2-byte pointer to operand 2
.endif
.ifndef fe25519_dst
  fe25519_dst          = $22           ; 2-byte pointer to destination
.endif
.ifndef mul_pending
  mul_pending     = $24           ; 0/1 carry chain bit (Phase-7 / L25-L26)
.endif
.ifndef mul_bound
  mul_bound       = $25           ; 63 - fe_mul_i, public phantom guard
.endif
.ifndef fe_carry
  fe_carry        = $26           ; carry/borrow byte
.endif
.ifndef fe_loop
  fe_loop         = $27           ; loop counter
.endif
.ifndef fe_mul_i
  fe_mul_i        = $28           ; multiply outer index
.endif
.ifndef fe_mul_j
  fe_mul_j        = $29           ; multiply inner index
.endif
.ifndef mul_ripple_start
  mul_ripple_start = $2f          ; fe25519_mul end-of-inner ripple start
.endif

; --- X25519 ladder working variables ---
.ifndef x25_prev_bit
  x25_prev_bit    = $2a           ; previous k_t for swap
.endif
.ifndef x25_byte_idx
  x25_byte_idx    = $2c           ; byte index in scalar
.endif
.ifndef x25_bit_mask
  x25_bit_mask    = $2d           ; current bit mask
.endif
.ifndef fe_sqr_pairs
  fe_sqr_pairs    = $2e           ; fe25519_sqr unrolled cross-loop counter
.endif

; --- CT field-op masks (L29 closure) ---
.ifndef fe_cmp_mask
  fe_cmp_mask     = $14           ; $00/$FF "result >= p" mask from fe_cmp_p_ct
.endif
.ifndef fe_subp_rhs
  fe_subp_rhs     = $15           ; per-iter (p_byte AND mask) scratch
.endif
.ifndef fe_add_carry_mask
  fe_add_carry_mask = $16         ; $00/$FF carry-out mask from fe25519_add
.endif

; --- mul_8x8 / fe25519 reuse ---
.ifndef poly_carry
  poly_carry      = $1c           ; carry byte
.endif

; --- Exports (suppressed when transitively .include'd via constants.s) ---
.ifndef ZP_CONFIG_NO_EXPORTS

; General-purpose pointers/temps
.exportzp zp_ptr1, zp_tmp1, zp_tmp2

; fe25519 field arithmetic working ZP
.exportzp fe25519_src1, fe25519_src2, fe25519_dst
.exportzp mul_pending, mul_bound
.exportzp fe_carry, fe_loop, fe_mul_i, fe_mul_j
.exportzp mul_ripple_start

; X25519 ladder working ZP
.exportzp x25_prev_bit, x25_byte_idx, x25_bit_mask
.exportzp fe_sqr_pairs

; CT field-op masks (L29 closure)
.exportzp fe_cmp_mask, fe_subp_rhs, fe_add_carry_mask

; mul_8x8 carry
.exportzp poly_carry

.endif ; ZP_CONFIG_NO_EXPORTS

.endif ; ZP_CONFIG_S_INCLUDED
