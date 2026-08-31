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
;   - pass -D <slot>=0x<addr> on the ca65 command line (every
;     library translation unit must see the same value). Use the
;     0x form, never $-hex: this define rides CONTRACT_ZP_DEFINES
;     through make, where `$40` and `$$40` reach ca65 as 0 (and
;     `$$$$40` as the shell's PID). Nothing here asserts a slot is
;     non-zero, so a $-spelled override silently lands the slot at
;     $00 -- the 6510 data-direction register -- with no diagnostic
;     from make, ca65 or ld65. See c64-lib-contract SPEC §2's
;     $-hex quoting note and the v0.14.2 §8.1 parenthetical, OR
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
; before the next access to any REU register, by two SEPARATE
; obligations: (a) a read of reu_status ($DF00) confirming bit 6 (END
; OF BLOCK) is set, spinning bounded if it is not, and (b) a
; post-execute settle meeting the empirically bracketed floor. Tracked
; at c64-x25519 #115; contract#144 / contract#146.
;
; Obligation (b) and the clock claim. The floor is bracketed at
; >= 49 cycles at 48 MHz on an Ultimate 64 Elite, fw 3.15 -- the
; contract#144 reporter's measurement, on U64E unique_id 601A96,
; which is the same physical device as our 10.43.23.81. The core at
; the time of that bracket is recorded nowhere: SPEC v0.13.0 §8.2
; records a core for the observation but firmware only for the floor,
; and core cannot be inferred from a firmware commit. Our own runs on
; 601A96 read core 1.4E on 2026-08-28; the device read 1.4F on
; 2026-08-30 (upstream 59594060 is the 1.4E->1.4F REU change). So the
; bracket is fw-3.15-as-reported on 601A96 (/v1/info cannot distinguish
; stock 3.15 from the locally patched build this device has carried),
; core unknown; our confirming
; observation is 1.4E. The hazard is NOT observable on 1.4F: an
; unmitigated control passed 22/22 cells, ~2100 fetches, 0 wrong
; bytes at 48 and 16 MHz (contract#144 device row, 2026-08-30).
; That is one device and does NOT
; license removing the settle -- 1.4E and earlier devices, real
; 17xx REUs and other REU implementations are all out of scope of
; it, and the obligation stands. What it does mean is that 601A96
; can no longer re-confirm any 1.4E-era claim, this bracket
; included: a green re-run today measures a different core.
; §13.6 is the model that names device, firmware and core together.
; On the U64E one I/O-mapped `lda reu_status`
; costs ~49 cycles at turbo, so the confirm read in (a) is what
; currently satisfies (b) — the contract itself calls that meeting the
; floor "by accident". This library does not let the accident be
; silent: X25519_MAX_CLOCK_MHZ (below) states the clock the settle is
; claimed for, and the .assert makes a build that claims more than the
; bracketed 48 MHz FAIL rather than quietly ship a settle nobody
; measured. Raising the assert bound is only legitimate together with a
; measured bracket at the new clock (and, if that bracket exceeds one
; status read, an explicit delay added to x25519_reu_settle_slow's
; caller path). Until then (b) is satisfied BECAUSE of this asserted
; bound, not by the read as such.
;
; X25519_REU_SETTLE_ITER is the spin bound for (a) — a §6.2 knob (`-D`
; overridable; the Makefile's CONTRACT_STAMP reads ALL_DEFINES so a
; changed value invalidates the archive). Reporter's hardware reference
; found bit 6 set on the FIRST read in all 19,416 calls, so 8 is
; generous headroom, not a tuned figure. Total status reads before a
; fault is recorded = X25519_REU_SETTLE_ITER (one in the macro,
; ITER-1 in the slow path).
;
; REU_SETTLE — the settle, as a macro (not a proc) because three of the
; twelve execute sites are on the fe25519_mul / fe25519_sqr hot path.
;
;   Fast path (the only path ever observed on hardware, and the only
;   path under VICE): lda abs / and / eor / beq = 11 cycles, 9 bytes,
;   taken iff the single read shows bit 6 SET and bit 5 CLEAR. Reading
;   $DF00 clears bits 5-7, so the byte is read ONCE into A and every
;   decision is made on that sample.
;
;   Anything else — bit 6 clear (transfer not confirmed), or bit 5
;   (VERIFY ERROR) set with or without bit 6 — takes
;   `jsr x25519_reu_settle_slow` (src/x25519_init.s), which keeps
;   spinning on bit 6 ALONE until it is set or the bound expires, and
;   records bit 5 separately: $02 into the sticky x25519_reu_fault if
;   bit 5 was ever observed, $01 if the bound expired without bit 6.
;   The clause says confirm bit 6; a verify-fault sample never ends the
;   spin early. (This library issues no VERIFY command, so bit 5 is a
;   hardware fault, not a mismatch.) The byte is cleared at
;   reu_mul_init / reu_probe entry and never otherwise, so a host can
;   inspect it after any call (src/x25519.inc); reu_probe folds a
;   non-zero value into its C=0 return — the contract's SHOULD that a
;   bounded-spin failure surfaces the way a missing REU does at init.
;
;   Autoload-latch invariant (see reu_fetch_doubled_row's banner in
;   src/x25519_init.s): reading $DF00 does NOT disturb the latched
;   address / length / control registers. Per the REC datasheet the
;   status register is read-only and its read side-effect is confined
;   to clearing its own bits 5-7; the autoload reload of $DF02-$DF08
;   happens at execute completion, keyed on the command register's
;   bit 5, and is independent of whether or when status is read.
;
;   Registers: clobbers A ONLY, on both paths. X, Y and C are preserved
;   (lda/and/eor/beq/jsr and the slow proc's lda/and/ora/dec/branches
;   never write C), so the settle adds no register cost to any site it
;   expands at. This does NOT make reu_fetch_mul_row carry-safe: that
;   routine's own asl / adc #0 clobbers C, so its contract is "A and C,
;   X/Y preserved" (x25519_init.s:357-362) both before and after
;   v0.12.0. The slow path keeps
;   its sample and counter in two cross-TU internal bytes in
;   src/data.s (x25519_reu_settle_smp / _cnt — exported for linkage,
;   not API).
;
;   CT: the sampled bits are hardware completion state for a transfer
;   whose length (256 or 512 B), direction and target are fixed; only
;   the REU address varies with the secret row index and REU DMA cost
;   is address-independent. Catalogued as L31 in docs/CT_ANALYSIS.md.
.ifndef X25519_REU_SETTLE_ITER
  X25519_REU_SETTLE_ITER = 8
.endif
.assert X25519_REU_SETTLE_ITER >= 2 .and X25519_REU_SETTLE_ITER <= 255, error, "X25519_REU_SETTLE_ITER must be 2..255 (8-bit spin counter; first read is unconditional)"

.ifndef X25519_MAX_CLOCK_MHZ
  X25519_MAX_CLOCK_MHZ = 48
.endif
.assert X25519_MAX_CLOCK_MHZ <= 48, error, "SPEC v0.13.0 §8.2: the REU post-execute settle is bracketed only to 48 MHz (U64E fw 3.15; core at bracket time unrecorded — see src/constants.s); claiming X25519_MAX_CLOCK_MHZ > 48 needs a measured settle bracket at that clock, with device/fw/core read off the device at measurement time (contract#144)"

.macro REU_SETTLE
        ; Unnamed `:` label only: a named (even `.local`) label inside
        ; the expansion would open a new cheap-local scope and orphan
        ; the enclosing proc's `@labels` across the site.
        lda reu_status         ; single read: clears bits 5-7
        and #$60               ; bit 6 END OF BLOCK, bit 5 VERIFY ERROR
        eor #$40               ; zero iff bit 6 set AND bit 5 clear
        beq :+                 ; -> done (11 cycles)
        jsr x25519_reu_settle_slow   ; A = sample ^ $40; spins on bit 6
:
.endmacro

.endif ; CONSTANTS_S_INCLUDED
