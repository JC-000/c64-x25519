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
;   $1C            mul_carry
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

; --- issue #72: on-chip multiply build profile ---
; Defined FIRST: reu_config.s (included just below) and everything
; after it gate on this symbol. Full description at the SQR_DMA_K
; block further down.
.ifndef X25519_ONCHIP_MUL
  X25519_ONCHIP_MUL = 0
.endif

; Public REU layout configuration (X25519_REU_BANK / X25519_REU_OFFSET).
; The library uses six contiguous REU banks starting at X25519_REU_BANK
; (default 0). See src/reu_config.s and c64-lib-contract SPEC §3.
; REU_CONFIG_NO_EXPORTS suppresses the .export emission here so only
; reu_config.o (assembled standalone) emits the public symbols and ld65
; doesn't error on "Duplicate external identifier".
.ifndef REU_CONFIG_NO_EXPORTS
REU_CONFIG_NO_EXPORTS = 1
.endif
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
;   - pass -D <slot>=$<addr> on the ca65 command line (every
;     library translation unit must see the same value), OR
;   - pre-define the symbol in a wrapper .s file before .include'ing
;     zp_config.s directly.
.ifndef ZP_CONFIG_NO_EXPORTS
; .ifndef-guarded (issue #99): a consumer suppressing the .exportzp
; block build-wide (-D ZP_CONFIG_NO_EXPORTS=1, e.g. wireguard's
; supplies-own-slots model) must be able to set this on the command
; line; unguarded, every TU including constants.s died on "Symbol
; already defined". Same guard on REU_CONFIG_NO_EXPORTS above.
ZP_CONFIG_NO_EXPORTS = 1
.endif
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

; --- issue #72: on-chip multiply build profile ---
; X25519_ONCHIP_MUL=1 replaces fe25519_mul's per-row REU DMA fetch with
; a constant-time on-chip row generator (products via the §8.3
; ct_mul_8x8 body) and forces SQR_DMA_K=0 so fe25519_sqr runs the
; REU-free mult66 path. The resulting build issues NO REU traffic at
; all: no banks claimed, no reu_mul_init required, runs on a stock
; expansion-less C64. Slower at stock 1 MHz (the DMA tables exist
; because they win there); the profile exists for turbo hosts, where
; REU DMA is pinned to ~1 MHz bus rate and becomes a wall-clock floor
; (see docs/design/issue_72_onchip_mul.md and issue #72).
; (Symbol itself is defined at the top of this file, before the
;  reu_config.s include, so every gated region sees it.)

; --- fe25519_sqr hybrid DMA threshold (8f+8g) ---
; Under X25519_ONCHIP_MUL the profile forces K=0: the pre-doubled DMA
; tables cannot exist without an REU. A caller-supplied nonzero K is a
; configuration error, hard-failed below rather than silently ignored.
.ifndef SQR_DMA_K
  .if ::X25519_ONCHIP_MUL
    SQR_DMA_K      = 0           ; forced: no REU, no doubled tables
  .else
    SQR_DMA_K      = 22          ; outer i < K uses pre-doubled DMA tables
  .endif
.endif
.if ::X25519_ONCHIP_MUL
.assert SQR_DMA_K = 0, error, "X25519_ONCHIP_MUL requires SQR_DMA_K=0 (no REU, no pre-doubled tables)"
.endif

; --- c64-lib-contract §8.1: shared 8x8 quarter-square multiply table ---
; LIB_SHARED_SQTAB_BASE is the page-aligned base of the 1024-byte
; quarter-square lookup table. sqtab_lo lives at base+$0000,
; sqtab_hi at base+$0200 (512 B each). Default is $7800 to match
; the v0.5.0 / pre-§8 layout; a multi-lib consumer overrides via
; `ca65 -D LIB_SHARED_SQTAB_BASE=0x<addr>` (passed to every
; translation unit so every module agrees on the canonical address).
;
; Page-alignment + page-delta are hard-asserted below — a
; misconfigured override fails at assemble time, not at runtime with
; a silent table corruption (the failure mode that motivated the
; SPEC §8 work; see c64-nist-curves' 2026-05-17 incident).
;
; Why this lives in constants.s rather than being .export'd: every
; lib in a multi-lib link defines the equate via `.ifndef`, so
; duplicate `.export sqtab_lo` across libs would collide at link
; time. The equate-in-shared-header pattern lets each TU compute
; the address locally; every TU gets the same answer because every
; TU sees the same `-D LIB_SHARED_SQTAB_BASE` value.
.ifndef LIB_SHARED_SQTAB_BASE
  LIB_SHARED_SQTAB_BASE = $7800
.endif
sqtab_lo = LIB_SHARED_SQTAB_BASE
sqtab_hi = LIB_SHARED_SQTAB_BASE + $0200
.assert (sqtab_lo & $00ff) = 0, error, "LIB_SHARED_SQTAB_BASE must be page-aligned"
.assert sqtab_hi = sqtab_lo + $0200, error, "sqtab_hi must equal sqtab_lo + $0200 (SMC dispatch contract; see c64-lib-contract SPEC §8.1)"

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

; --- REU post-execute settle (c64-lib-contract SPEC v0.13.0 §8.2, c771935) --
;
; Every REU execute (`sta reu_command` with bit 7 set) MUST be followed,
; before the next access to any REU register, by (a) a read of
; reu_status ($DF00) confirming bit 6 (END OF BLOCK) is set, spinning
; bounded if not, and (b) a post-execute settle meeting the bracketed
; floor (>= 49 cycles at 48 MHz on Ultimate 64 Elite fw 3.15; the
; 64 MHz turbo is UNBRACKETED — c64-x25519 claims conformance at
; <= 48 MHz only). One `lda reu_status` is an I/O-mapped read, which is
; what costs ~49 cycles at turbo on the U64E, so a single read that
; finds bit 6 set already meets floor (b). Tracked at c64-x25519 #115;
; contract#144 / contract#146.
;
; X25519_REU_SETTLE_ITER is the spin bound — a §6.2 knob (`-D`
; overridable; the Makefile's CONTRACT_STAMP reads ALL_DEFINES so a
; changed value invalidates the archive). Reporter's hardware reference
; found bit 6 set on the FIRST read in all 19,416 calls, so 8 is
; generous headroom, not a tuned figure.
;
; REU_SETTLE — the settle itself, as a macro (not a proc) because two of
; the twelve execute sites are on the fe25519_mul / fe25519_sqr hot
; path and a jsr/rts pair per 512-byte row fetch is measurable.
;
;   Reads reu_status ONCE per spin iteration into A and tests there:
;   reading $DF00 clears bits 5-7, so a second read would see them
;   gone. Bit 6 = END OF BLOCK (transfer complete), bit 5 = VERIFY
;   ERROR (only ever set by a VERIFY command, which this library never
;   issues, so its appearance is a hardware fault, not a mismatch).
;
;   Fault channel: the primitive has no error return. On bound expiry
;   the macro ORs $01 into the sticky byte x25519_reu_fault; if bit 5
;   was observed it ORs $02. The byte is cleared at reu_mul_init and
;   reu_probe entry and never cleared by the library otherwise, so a
;   host can inspect it after any call (see src/x25519.inc). The
;   contract's SHOULD is that a bounded-spin failure surfaces the way a
;   missing REU does at init — reu_probe folds it into its C=0 return.
;
;   Autoload-latch invariant (see reu_fetch_doubled_row's banner in
;   src/x25519_init.s): reading $DF00 does NOT disturb the latched
;   address / length / control registers. Per the REC datasheet the
;   status register is read-only and its read side-effect is confined
;   to clearing its own bits 5-7 (INTERRUPT PENDING / END OF BLOCK /
;   VERIFY ERROR); the autoload reload of $DF02-$DF08 happens at
;   execute completion, keyed on the command register's bit 5, and is
;   independent of whether or when status is read. So a settle between
;   two 3-register-touch fetches leaves the latch exactly as the
;   previous execute's autoload left it.
;
;   Registers: clobbers A and X; preserves Y and ALL flags-of-interest
;   downstream — specifically C is never written (lda/and/ora/dex/bne
;   /beq/jmp do not touch C), which reu_fetch_doubled_row's DMA #2 and
;   fe25519_mul's inline fetch do not rely on anyway (both `clc`/`lda`
;   before their next carry use). Every site's X was measured dead at
;   the point of expansion (analysis in docs/CT_ANALYSIS.md L31).
;
;   CT: the spin count depends only on REU completion timing for a
;   fixed-length (256- or 512-byte) transfer — never on a secret
;   operand — and the fault branches are on hardware state. Catalogued
;   as L31 in docs/CT_ANALYSIS.md.
;
;   Fast path (bit 6 set on the first read, the only path ever observed
;   on hardware): ldx / lda abs / and / bne / and / beq = 16 cycles.
.ifndef X25519_REU_SETTLE_ITER
  X25519_REU_SETTLE_ITER = 8
.endif
.assert X25519_REU_SETTLE_ITER >= 1 .and X25519_REU_SETTLE_ITER <= 255, error, "X25519_REU_SETTLE_ITER must be 1..255 (8-bit spin counter)"

.macro REU_SETTLE
        ; Unnamed `:` labels only: a named (even `.local`) label inside
        ; the expansion would open a new cheap-local scope and orphan
        ; the enclosing proc's `@labels` across the site.
        ldx #X25519_REU_SETTLE_ITER
:       lda reu_status         ; single read: clears bits 5-7
        and #$60               ; bit 6 END OF BLOCK, bit 5 VERIFY ERROR
        bne :+                 ; -> seen
        dex
        bne :-                 ; -> spin
        lda #$01               ; bound expired: transfer not confirmed
        ora x25519_reu_fault
        sta x25519_reu_fault
        jmp :++                ; -> done
:       and #$20               ; seen
        beq :+                 ; bit 6 alone — the normal case -> done
        lda #$02               ; bit 5 seen: verify fault
        ora x25519_reu_fault
        sta x25519_reu_fault
:                              ; done
.endmacro

.endif ; CONSTANTS_S_INCLUDED
