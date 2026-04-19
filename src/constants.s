; =============================================================================
; constants.s - System equates, zero page, hardware addresses
; Stripped for standalone X25519 performance tuning
;
; This file is .include'd by every compilation unit. It defines only
; assembly-time equates (= expressions), which are invisible to the linker.
; Symbols that need to appear in the VICE label file are exported once
; from main.s.
; =============================================================================

.ifndef CONSTANTS_S_INCLUDED
CONSTANTS_S_INCLUDED = 1

; --- Kernal routines ---
chrout          = $ffd2         ; output character
getin           = $ffe4         ; get character from keyboard

; --- Hardware registers ---
vic_ctrl1       = $d011         ; VIC-II control register 1 (DEN=bit4)
vic_border      = $d020         ; border color
vic_bg          = $d021         ; background color
cia1_ta_lo      = $dc04         ; CIA #1 timer A low byte
cia1_ta_hi      = $dc05         ; CIA #1 timer A high byte
cia1_cra        = $dc0e         ; CIA #1 control register A
sid_v3_freq_lo  = $d40e         ; SID voice 3 frequency low
sid_v3_freq_hi  = $d40f         ; SID voice 3 frequency high
sid_v3_ctrl     = $d412         ; SID voice 3 control
sid_osc3        = $d41b         ; SID oscillator 3 readout
proc_port       = $01           ; processor port (ROM banking)

; --- System addresses ---
screen_ram      = $0400         ; screen memory (40x25)
color_ram       = $d800         ; color memory
kbd_buffer      = $0277         ; keyboard buffer
kbd_buf_count   = $00c6         ; keyboard buffer count
cassette_buf    = $0334         ; cassette buffer (safe scratch area)
jiffy_clock     = $00a0         ; 3-byte jiffy clock (MSB)

; --- Zero page variables ---
; General purpose pointers
.ifndef zp_ptr1
  zp_ptr1         = $fb           ; 2-byte pointer
.endif
.ifndef zp_ptr2
  zp_ptr2         = $fd           ; 2-byte pointer
.endif
.ifndef zp_tmp1
  zp_tmp1         = $02           ; temp byte
.endif
.ifndef zp_tmp2
  zp_tmp2         = $03           ; temp byte
.endif

; fe25519 field arithmetic working variables
.ifndef fe25519_src1
  fe25519_src1         = $1e           ; 2-byte pointer to operand 1
.endif
.ifndef fe25519_src2
  fe25519_src2         = $20           ; 2-byte pointer to operand 2
.endif
.ifndef fe25519_dst
  fe25519_dst          = $22           ; 2-byte pointer to destination
.endif
.ifndef fe_misc
  fe_misc         = $24           ; 2-byte misc pointer
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

; X25519 working variables
.ifndef x25_prev_bit
  x25_prev_bit    = $2a           ; previous k_t for swap
.endif
.ifndef x25_bit_ctr
  x25_bit_ctr     = $2b           ; bit counter
.endif
.ifndef x25_byte_idx
  x25_byte_idx    = $2c           ; byte index in scalar
.endif
.ifndef x25_bit_mask
  x25_bit_mask    = $2d           ; current bit mask
.endif
.ifndef fe_sqr_pairs
  fe_sqr_pairs    = $2e           ; fe25519_sqr unrolled cross-loop pair counter
.endif

; (lmul0/lmul1 removed after Phase 2 CT rewrite: fe25519_sqr no longer
;  uses indirect-indexed sqtab pointers. Former slots $14-$17 are free.)

; Poly1305 mul_8x8 working variables (reused by fe25519)
.ifndef poly_i
  poly_i          = $1a           ; inner loop counter
.endif
.ifndef poly_j
  poly_j          = $1b           ; outer loop counter
.endif
.ifndef poly_carry
  poly_carry      = $1c           ; carry byte
.endif
.ifndef poly_tmp
  poly_tmp        = $1d           ; temp
.endif

; fe_wide product buffer relocated to zero page ($40..$7F)
; This enables zp,X addressing (2 bytes, 4 cycles) vs abs,X (3 bytes, 5 cycles)
.ifndef fe_wide
  fe_wide         = $40
.endif

; --- fe25519_sqr hybrid DMA threshold (8f+8g) ---
SQR_DMA_K        = 14          ; outer i < K uses pre-doubled DMA tables

; --- REU (Ram Expansion Unit) registers ---
reu_status      = $df00         ; status register
reu_command     = $df01         ; command register
reu_c64_lo      = $df02         ; C64 base address low
reu_c64_hi      = $df03         ; C64 base address high
reu_reu_lo      = $df04         ; REU base address low
reu_reu_hi      = $df05         ; REU base address high
reu_reu_bank    = $df06         ; REU bank
reu_len_lo      = $df07         ; transfer length low
reu_len_hi      = $df08         ; transfer length high
reu_addr_ctrl   = $df0a         ; address control

.endif ; CONSTANTS_S_INCLUDED
