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
; W3 ZP audit, 85 bytes total):
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

; Public REU layout configuration (X25519_REU_BANK / X25519_REU_OFFSET).
; The library uses six contiguous REU banks starting at X25519_REU_BANK
; (default 0). See src/reu_config.s and c64-lib-contract SPEC §3.
; REU_CONFIG_NO_EXPORTS suppresses the .export emission here so only
; reu_config.o (assembled standalone) emits the public symbols and ld65
; doesn't error on "Duplicate external identifier".
REU_CONFIG_NO_EXPORTS = 1
.include "reu_config.s"

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
.ifndef cia1_tb_lo
  cia1_tb_lo      = $dc06         ; CIA #1 timer B low byte
.endif
.ifndef cia1_tb_hi
  cia1_tb_hi      = $dc07         ; CIA #1 timer B high byte
.endif
.ifndef cia1_icr
  cia1_icr        = $dc0d         ; CIA #1 interrupt control register
.endif
.ifndef cia1_crb
  cia1_crb        = $dc0f         ; CIA #1 control register B
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
; Public ZP slot inventory lives in src/zp_config.s (per c64-lib-contract
; SPEC §2). We .include it here so every translation unit that includes
; constants.s transparently gets the equates, but we suppress the .exportzp
; emission via ZP_CONFIG_NO_EXPORTS so that only zp_config.s's own .o
; emits the public symbols (avoids ld65 "exported from multiple files").
;
; A host that wants to override a slot can either:
;   - pass --asm-define <slot>=$<addr> on the ca65 command line (every
;     library translation unit must see the same value), OR
;   - pre-define the symbol in a wrapper .s file before .include'ing
;     zp_config.s directly.
ZP_CONFIG_NO_EXPORTS = 1
.include "zp_config.s"

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
