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
;   1. Pass `-D fe25519_src1=0x30` on the ca65 command line. This
;      defines the symbol globally for the translation unit, and the
;      .ifndef guard below then skips the default. ALL library translation
;      units must be assembled with the same -D values, since
;      each .o bakes in the equate value at assemble time.
;
;   2. Inside a wrapper .s file:
;
;          fe25519_src1 = $30
;          .include "zp_config.s"
;
; The library's own standalone PRG (`make`) and library archive (`make
; lib`) assemble with the defaults. Consumer projects rebuild the library
; from source with -D to pin slots to their preferred layout.
;
; The roster
; ----------
;
; Every slot is ONE line in `x25519_zp_roster` below: name, default
; address, size in bytes. That line is the only place a slot is
; declared. The roster is expanded twice:
;
;   1. x25519_zp_define: the `.ifndef`-guarded default, the `.exportzp`,
;      asserts that the span lies in $02-$FF (zero page, clear of the
;      6510 port -- a bare `-D slot` defines 0), and a per-slot size marker
;      (`x25519_zp_size_<slot>`) that tools/check_zp_roster.py reads.
;      The running total `x25519_zp_bytes` is what src/lib_manifest.s
;      publishes as LIB_X25519_ZP_USAGE_BYTES.
;   2. x25519_zp_check_pair: every unordered pair of slots is asserted
;      disjoint over its full byte span, on the (possibly -D-overridden)
;      addresses. A failure names both slots and both spans.
;
; A slot declared outside the roster is invisible to both, so
; `make lib-verify` runs tools/check_zp_roster.py, which fails on any
; symbol THIS FILE defines that is not in the roster, and on any
; zp_config.o export the roster does not list. It does not see a slot
; defined in another file (constants.s or any other TU): declare every
; slot here.
;
; Not in the roster
; -----------------
;
; - `SQR_DMA_K`: a build-time numeric tunable, not an address.
; - Hardware-address equates (chrout, vic_*, cia*, sid_*, proc_port, REU
;   registers, kbd_buf_count, jiffy_clock): host-overridable for non-C64
;   targets but not claimed ZP slots.
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

; Loud-trip for the renamed override spelling: a consumer still passing
; -D poly_carry=<addr> after the v0.11.0 rename to mul_carry would
; otherwise be silently ignored.
.ifdef poly_carry
.error "poly_carry was renamed to mul_carry at v0.11.0 (SPEC v0.9.0 §2 ZP prefix registry) — override mul_carry instead"
.endif

; --- The roster: one line per claimed slot (name, default, bytes) ---
; `m` is the macro applied to each line; `p1`/`p2` are passed through
; unchanged so the pairwise check can carry the outer slot along.
.macro x25519_zp_roster m, p1, p2
  ; fe25519 field arithmetic working variables
  m p1, p2, fe25519_src1,      $1e,  2   ; pointer to operand 1
  m p1, p2, fe25519_src2,      $20,  2   ; pointer to operand 2
  m p1, p2, fe25519_dst,       $22,  2   ; pointer to destination
  m p1, p2, mul_pending,       $24,  1   ; 0/1 carry chain bit
  m p1, p2, mul_bound,         $25,  1   ; 63 - fe_mul_i, public phantom guard
  m p1, p2, fe_carry,          $26,  1   ; carry/borrow byte
  m p1, p2, fe_loop,           $27,  1   ; loop counter
  m p1, p2, fe_mul_i,          $28,  1   ; multiply outer index
  m p1, p2, fe_mul_j,          $29,  1   ; multiply inner index
  m p1, p2, mul_ripple_start,  $2f,  1   ; fe25519_mul end-of-inner ripple start
  ; X25519 ladder working variables
  m p1, p2, x25_prev_bit,      $2a,  1   ; previous k_t for swap
  m p1, p2, x25_byte_idx,      $2c,  1   ; byte index in scalar
  m p1, p2, x25_bit_mask,      $2d,  1   ; current bit mask
  m p1, p2, fe_sqr_pairs,      $2e,  1   ; fe25519_sqr unrolled cross-loop counter
  ; CT field-op masks
  m p1, p2, fe_cmp_mask,       $14,  1   ; $00/$FF "result >= p" mask
  m p1, p2, fe_subp_rhs,       $15,  1   ; per-iter (p_byte AND mask) scratch
  m p1, p2, fe_add_carry_mask, $16,  1   ; $00/$FF carry-out mask from fe25519_add
  ; mul_8x8 / fe25519 reuse
  m p1, p2, mul_carry,         $1c,  1   ; carry byte
  ; 64-byte product accumulator (see the fe_wide assert below)
  m p1, p2, fe_wide,           $40, 64
.endmacro

; Pass 1: define (.ifndef-guarded), export, size-mark, and total.
x25519_zp_bytes .set 0
.macro x25519_zp_define p1, p2, name, addr, size
  .ifndef name
    name = addr
  .endif
  .ident(.sprintf("x25519_zp_size_%s", .string(name))) = size
  x25519_zp_bytes .set x25519_zp_bytes + size
  .ifndef ZP_CONFIG_NO_EXPORTS
    .exportzp name
  .endif
  .if .const(name)
    .assert name + size <= $100, error, .sprintf("ZP slot %s [$%02X-$%02X] does not fit in zero page", .string(name), name, name + size - 1)
    .assert name >= 2, error, .sprintf("ZP slot %s [$%02X-$%02X] overlaps the 6510 processor port $00-$01", .string(name), name, name + size - 1)
  .else
    .assert name + size <= $100, lderror, .sprintf("ZP slot %s does not fit in zero page", .string(name))
    .assert name >= 2, lderror, .sprintf("ZP slot %s overlaps the 6510 processor port $00-$01", .string(name))
  .endif
.endmacro
x25519_zp_roster x25519_zp_define, 0, 0
.delmacro x25519_zp_define

; Pass 2: pairwise disjointness over every unordered pair of slots.
.macro x25519_zp_check_pair an, as, bn, baddr, bs
  x25519_zp_j .set x25519_zp_j + 1
  .if x25519_zp_j > x25519_zp_i
    .if .const(an) .and .const(bn)
      .assert (an + as <= bn) .or (bn + bs <= an), error, .sprintf("ZP slots %s [$%02X-$%02X] and %s [$%02X-$%02X] overlap", .string(an), an, an + as - 1, .string(bn), bn, bn + bs - 1)
    .else
      .assert (an + as <= bn) .or (bn + bs <= an), lderror, .sprintf("ZP slots %s and %s overlap", .string(an), .string(bn))
    .endif
  .endif
.endmacro
.macro x25519_zp_check_outer p1, p2, name, addr, size
  x25519_zp_i .set x25519_zp_i + 1
  x25519_zp_j .set 0
  x25519_zp_roster x25519_zp_check_pair, name, size
.endmacro
x25519_zp_i .set 0
x25519_zp_roster x25519_zp_check_outer, 0, 0
.delmacro x25519_zp_check_outer
.delmacro x25519_zp_check_pair

; fe_wide: fe25519_mul/sqr self-modify only the one-byte operand of
; their `fe_wide+1,x` zero-page sites (base = <fe_wide + i + 1>, i <= 31),
; and the fixed sites address up to fe_wide+36. All of that is correct
; only while the whole 64-byte span assembles as zero-page operands and
; <fe_wide + i + 1> never carries out of the low byte.
.if .const(fe_wide)
.assert fe_wide + 64 <= $100, error, .sprintf("fe_wide [$%02X-$%02X] must lie wholly in zero page: fe25519_mul/sqr patch only the zero-page operand byte of fe_wide,X", fe_wide, fe_wide + 63)
.else
.assert fe_wide + 64 <= $100, lderror, "fe_wide must lie wholly in zero page: fe25519_mul/sqr patch only the zero-page operand byte of fe_wide,X"
.endif

.endif ; ZP_CONFIG_S_INCLUDED
