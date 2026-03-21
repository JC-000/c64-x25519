; =============================================================================
; constants.asm - System equates, zero page, hardware addresses
; Stripped for standalone X25519 performance tuning
; =============================================================================

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
zp_ptr1         = $fb           ; 2-byte pointer
zp_ptr2         = $fd           ; 2-byte pointer
zp_tmp1         = $02           ; temp byte
zp_tmp2         = $03           ; temp byte

; fe25519 field arithmetic working variables
fe_src1         = $1e           ; 2-byte pointer to operand 1
fe_src2         = $20           ; 2-byte pointer to operand 2
fe_dst          = $22           ; 2-byte pointer to destination
fe_misc         = $24           ; 2-byte misc pointer
fe_carry        = $26           ; carry/borrow byte
fe_loop         = $27           ; loop counter
fe_mul_i        = $28           ; multiply outer index
fe_mul_j        = $29           ; multiply inner index

; X25519 working variables
x25_prev_bit    = $2a           ; previous k_t for swap
x25_bit_ctr     = $2b           ; bit counter
x25_byte_idx    = $2c           ; byte index in scalar
x25_bit_mask    = $2d           ; current bit mask

; mult65 indirect-indexed pointers for fe_mul
lmul0           = $14           ; 2-byte ZP pointer (low=multiplicand, high=sqtab_lo page)
lmul1           = $16           ; 2-byte ZP pointer (low=multiplicand, high=sqtab_hi page)

; Poly1305 mul_8x8 working variables (reused by fe25519)
poly_i          = $1a           ; inner loop counter
poly_j          = $1b           ; outer loop counter
poly_carry      = $1c           ; carry byte
poly_tmp        = $1d           ; temp
