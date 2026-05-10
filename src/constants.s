; =============================================================================
; constants.s - System equates, zero page, hardware addresses
; Stripped for standalone X25519 performance tuning
;
; This file is .include'd by every compilation unit. It defines only
; assembly-time equates (= expressions), which are invisible to the linker.
; Symbols that need to appear in the VICE label file are exported once
; from main.s.
;
; Live ZP surface owned by the library while running (post-Phase-7 +
; W3 ZP audit, 87 bytes total):
;   $14-$16        fe_cmp_mask / fe_subp_rhs / fe_add_carry_mask
;   $1C            poly_carry
;   $1E-$2A        fe25519_src1/src2/dst, mul_pending/mul_bound,
;                  fe_carry, fe_loop, fe_mul_i/j, x25_prev_bit
;   $2C-$2F        x25_byte_idx, x25_bit_mask, fe_sqr_pairs,
;                  mul_ripple_start
;   $40-$7F        fe_wide (64-byte product accumulator, ZP-pinned)
;
; Hosts can override most equates via `.ifndef` (see docs/LIBRARY.md §4.2).
; fe_wide is intentionally NOT host-overridable: it must stay in ZP for
; the SMC patch sites in fe25519_mul/sqr to work correctly.
; =============================================================================

.ifndef CONSTANTS_S_INCLUDED
CONSTANTS_S_INCLUDED = 1

; --- Kernal routines ---
; All KERNAL / hardware-register / system-address equates are wrapped in
; `.ifndef` so non-C64 hosts (e.g. C128, embedded, simulators) can redirect
; them by pre-defining the symbol before .include'ing constants.s.
.ifndef chrout
  chrout          = $ffd2         ; output character
.endif
.ifndef getin
  getin           = $ffe4         ; get character from keyboard
.endif

; --- Hardware registers ---
.ifndef vic_ctrl1
  vic_ctrl1       = $d011         ; VIC-II control register 1 (DEN=bit4)
.endif
.ifndef vic_border
  vic_border      = $d020         ; border color
.endif
.ifndef vic_bg
  vic_bg          = $d021         ; background color
.endif
.ifndef cia1_ta_lo
  cia1_ta_lo      = $dc04         ; CIA #1 timer A low byte
.endif
.ifndef cia1_ta_hi
  cia1_ta_hi      = $dc05         ; CIA #1 timer A high byte
.endif
.ifndef cia1_cra
  cia1_cra        = $dc0e         ; CIA #1 control register A
.endif
.ifndef sid_v3_freq_lo
  sid_v3_freq_lo  = $d40e         ; SID voice 3 frequency low
.endif
.ifndef sid_v3_freq_hi
  sid_v3_freq_hi  = $d40f         ; SID voice 3 frequency high
.endif
.ifndef sid_v3_ctrl
  sid_v3_ctrl     = $d412         ; SID voice 3 control
.endif
.ifndef sid_osc3
  sid_osc3        = $d41b         ; SID oscillator 3 readout
.endif
.ifndef proc_port
  proc_port       = $01           ; processor port (ROM banking)
.endif

; --- System addresses ---
screen_ram      = $0400         ; screen memory (40x25)
color_ram       = $d800         ; color memory
kbd_buffer      = $0277         ; keyboard buffer
.ifndef kbd_buf_count
  kbd_buf_count   = $00c6         ; keyboard buffer count
.endif
cassette_buf    = $0334         ; cassette buffer (safe scratch area)
.ifndef jiffy_clock
  jiffy_clock     = $00a0         ; 3-byte jiffy clock (MSB)
.endif

; --- Zero page variables ---
; General purpose pointers
.ifndef zp_ptr1
  zp_ptr1         = $fb           ; 2-byte pointer
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
; fe25519_mul Phase-6-style CT carry-chain scratch (L25/L26 closure).
; Mirrors fe25519_sqr's sqr_pending/sqr_bound/sqr_ripple_start, but in ZP
; for shorter encodings (zp store = 3 cyc, abs = 4 cyc). Lifetime is
; per-call: written before every read, dead after fe25519_mul returns.
;     mul_pending     - 0/1 overflow bit threaded between body chain steps
;                       within a single outer-i. Reset at @mul_outer entry.
;     mul_bound       - public phantom guard: 63 - fe_mul_i. Body D's
;                       chain step does `cpx mul_bound / bcs skip` so that
;                       only i=31 last iteration drops its (always-zero)
;                       phantom carry. Public-derived; cpx is CT-safe.
;     mul_ripple_start - public start position of end-of-inner ripple,
;                       computed from fe_mul_i + final X. Read once.
.ifndef mul_pending
  mul_pending     = $24           ; 0/1 carry chain bit (was: fe_misc)
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

; X25519 working variables
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
  fe_sqr_pairs    = $2e           ; fe25519_sqr unrolled cross-loop pair counter
.endif
.ifndef mul_ripple_start
  mul_ripple_start = $2f          ; fe25519_mul end-of-inner ripple start (public)
.endif

; (lmul0/lmul1 removed after Phase 2 CT rewrite: fe25519_sqr no longer
;  uses indirect-indexed sqtab pointers. $14-$16 reclaimed by L29 CT
;  field-op masks below; $17 remains free.)

; fe_cmp_p_ct / fe25519_add / fe25519_sub / fe25519_reduce_final scratch
; (L29 closure). These are the constant-time-replacement equivalents of
; the prior branchful fe_cmp_p / add-then-cond-sub / sub-then-cond-add /
; reduce_final loop. The mask-and-rhs scratch slots are written before
; every use, so their post-call state is undefined per the library's
; ZP contract.
.ifndef fe_cmp_mask
  fe_cmp_mask     = $14           ; $00/$FF "result >= p" mask from fe_cmp_p_ct
.endif
.ifndef fe_subp_rhs
  fe_subp_rhs     = $15           ; per-iter (p_byte AND mask) scratch
.endif
.ifndef fe_add_carry_mask
  fe_add_carry_mask = $16         ; $00/$FF carry-out mask from fe25519_add
.endif

; mul_8x8 / fe25519 reuse: only poly_carry remains live after the W3 ZP audit.
; (poly_i $1A / poly_j $1B / poly_tmp $1D were declared but never read in any
;  src/*.s — removed in v0.4.0 to narrow the library's claimed ZP surface.)
.ifndef poly_carry
  poly_carry      = $1c           ; carry byte
.endif

; fe_wide product buffer pinned to zero page ($40..$7F)
;
; This enables zp,X addressing (2 bytes, 4 cycles) vs abs,X (3 bytes, 5
; cycles) and — more importantly — is a CT/SMC invariant. The library's
; SMC inner loops (fe25519_mul, fe25519_sqr) patch ONLY the low byte of
; `fe_wide,X` operands at runtime, which silently assumes the high byte
; of every fe_wide store/load address is $00. Letting a host override
; fe_wide outside ZP would corrupt SMC patch sites with no link error.
;
; Therefore fe_wide is intentionally NOT wrapped in `.ifndef`, and the
; .assert below makes any out-of-ZP placement a hard link error.
fe_wide         = $40
.assert (fe_wide & $FF00) = 0, lderror, "fe_wide must be in zero page (CT/SMC invariant)"

; --- fe25519_sqr hybrid DMA threshold (8f+8g) ---
.ifndef SQR_DMA_K
  SQR_DMA_K        = 22          ; outer i < K uses pre-doubled DMA tables
.endif

; --- REU (Ram Expansion Unit) registers ---
.ifndef reu_status
  reu_status      = $df00         ; status register
.endif
.ifndef reu_command
  reu_command     = $df01         ; command register
.endif
.ifndef reu_c64_lo
  reu_c64_lo      = $df02         ; C64 base address low
.endif
.ifndef reu_c64_hi
  reu_c64_hi      = $df03         ; C64 base address high
.endif
.ifndef reu_reu_lo
  reu_reu_lo      = $df04         ; REU base address low
.endif
.ifndef reu_reu_hi
  reu_reu_hi      = $df05         ; REU base address high
.endif
.ifndef reu_reu_bank
  reu_reu_bank    = $df06         ; REU bank
.endif
.ifndef reu_len_lo
  reu_len_lo      = $df07         ; transfer length low
.endif
.ifndef reu_len_hi
  reu_len_hi      = $df08         ; transfer length high
.endif
.ifndef reu_addr_ctrl
  reu_addr_ctrl   = $df0a         ; address control
.endif

.endif ; CONSTANTS_S_INCLUDED
