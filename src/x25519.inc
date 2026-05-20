; =============================================================================
; x25519.inc - Public interface for the C64 X25519 library
;
; Assembler:  ca65/ld65 (cc65 suite)
; Target:     Commodore 64 + REU (Ram Expansion Unit, >= 512 KB required)
;
; This file declares the public symbols that downstream projects need
; in order to call into the X25519 library. The library is built from
; separate .s source files, each compiled to its own .o and linked
; with ld65. Use .import in your source to pull in the symbols you need.
;
; To use from a downstream project:
;
;     .include "x25519.inc"       ; optional: brings in all .import decls
;
;     ; Or selectively import what you need:
;     .import sqtab_init, reu_mul_init
;     .import x25519_base, x25519_scalarmult
;     .import x25_scalar, x25_u, x25_result
;
;     ; Link your .o files with the library .o files via ld65.
;
; See docs/LIBRARY.md for the full integration guide.
;
; ----------------------------------------------------------------------------
; INITIALIZATION (must be called once before any X25519 / fe25519 op)
; ----------------------------------------------------------------------------
;
;   sqtab_init      Build 1024-byte quarter-square table at $7800-$7BFF
;                   used by mul_8x8. No inputs. Clobbers: A, X, Y.
;
;   reu_mul_init    Build full 8x8->16 multiplication tables in REU banks 0-5
;                   (256 lo + 256 hi bytes per a, plus pre-doubled tables for
;                   fe25519_sqr, plus a 64-byte zero block in bank 2 for
;                   reu_clear_wide). REQUIRES sqtab_init to have been called
;                   first. Takes ~1-2 seconds. No inputs. Clobbers: A, X, Y.
;
;   Order:          jsr sqtab_init
;                   jsr reu_mul_init
;
; ----------------------------------------------------------------------------
; PUBLIC ENTRY POINTS (x25519)
; ----------------------------------------------------------------------------
;
;   x25519_clamp
;       Clamp scalar in-place per RFC 7748 Section 5:
;         x25_scalar[0]  &= 0xF8
;         x25_scalar[31] &= 0x7F
;         x25_scalar[31] |= 0x40
;       Input/output: x25_scalar (32 bytes, in/out).
;       Clobbers: A.
;
;   x25519_scalarmult
;       Compute x25_result = x25_scalar * x25_u on Curve25519 (Montgomery
;       ladder, RFC 7748). Caller is responsible for clamping x25_scalar
;       and for masking the high bit of x25_u (the routine also masks the
;       high bit of x25_u[31] internally per RFC 7748 decodeUCoordinate).
;       Input:   x25_scalar (32 bytes, little-endian, clamped)
;                x25_u      (32 bytes, little-endian u-coordinate)
;       Output:  x25_result (32 bytes, little-endian, fully reduced mod p)
;       Clobbers: A, X, Y, all fe_* / x25_* zero-page scratch ($14-$2E),
;                 fe_wide ($40-$7F), all fe25519_tmp1..4 and x25 scratch buffers,
;                 mul_dma_lo / mul_dma_hi / mul_dma_carry buffers,
;                 REU registers (autoload state preserved for next call).
;       Timing:  ~9,520 jiffies per call on stock C64 with VIC-II
;                blanked (jsr vic_blank) on the basepoint input.
;                ~158.7 s NTSC / ~190.4 s PAL. VIC-II unblanked
;                adds ~25%. Dense u-coordinates (non-basepoint ECDH)
;                run ~10% slower. See docs/LIBRARY.md.
;
;   x25519_base
;       Convenience: x25_result = x25_scalar * basepoint(9). Copies the
;       built-in basepoint into x25_u, calls x25519_clamp, then
;       x25519_scalarmult. Use this for public-key generation.
;       Input:   x25_scalar (32 bytes; will be clamped in-place)
;       Output:  x25_result (32 bytes)
;                x25_u      will be overwritten with the basepoint.
;       Clobbers: as x25519_scalarmult.
;
; ----------------------------------------------------------------------------
; PUBLIC ENTRY POINTS (fe25519 - field arithmetic mod p = 2^255 - 19)
; ----------------------------------------------------------------------------
;
; All fe25519_* routines take operand pointers via the zero-page slots
; fe25519_src1, fe25519_src2, fe25519_dst (each 2 bytes, little-endian). Operands are
; 32-byte little-endian field elements. The destination buffer MUST be
; page-aligned to one of the offsets {$00,$20,$40,$60,$80,$A0,$C0,$E0}
; within its page (so that 32-byte indexed access never crosses a page
; boundary). See "Buffer alignment" in docs/LIBRARY.md.
;
;   fe25519_copy        (fe25519_dst) <- (fe25519_src1)            32-byte copy.
;   fe25519_zero        (fe25519_dst) <- 0
;   fe25519_one         (fe25519_dst) <- 1
;   fe25519_add         (fe25519_dst) <- (fe25519_src1) + (fe25519_src2) mod p
;   fe25519_sub         (fe25519_dst) <- (fe25519_src1) - (fe25519_src2) mod p
;   fe25519_mul         (fe25519_dst) <- (fe25519_src1) * (fe25519_src2) mod p   (REU tables)
;   fe25519_sqr         (fe25519_dst) <- (fe25519_src1)^2 mod p             (REU tables)
;   fe25519_mul_a24     (fe25519_dst) <- 121665 * (fe25519_src1) mod p
;   fe25519_inv         (fe25519_dst) <- (fe25519_src1)^(p-2) mod p   (modular inverse)
;   fe25519_cswap       Conditional swap of (fe25519_src1) and (fe25519_src2) using mask
;                  in fe_carry (A on entry; $00 = no swap, $FF = swap).
;   fe25519_reduce_final  Final canonicalization: ensure (fe25519_dst) < p.
;                    Caller must run this on any value that will be sent
;                    on the wire or compared.
;
;   All clobber: A, X, Y and the fe_* scratch ZP slots.
;
; ----------------------------------------------------------------------------
; OPTIONAL HELPERS
; ----------------------------------------------------------------------------
;
;   vic_blank             Disable VIC-II display (DEN=0). ~25% CPU speedup.
;   vic_unblank           Re-enable VIC-II display.
;   bench_start           Reset jiffy clock for timing. Requires IRQs to
;                         remain enabled across the benched region (the
;                         jiffy clock at $A0-$A2 only advances on each
;                         kernal IRQ). Do NOT use to time a region that
;                         runs under sei (e.g. x25519_scalarmult, which
;                         sei's internally as a CT defence) — the clock
;                         will not tick. Use bench_cycles_start in that
;                         case.
;   bench_stop            Snapshot jiffy clock into bench_ticks (3 bytes).
;   bench_cycles_start    Start CIA1 timer-A/B 32-bit cycle counter.
;                         Survives sei. Counts CPU cycles directly.
;                         Range: 2^32 cycles (~4.2 s of C64 time / ~70 min
;                         wall-clock at 60 Hz). After bench_cycles_stop
;                         the kernal jiffy IRQ rate is no longer correct
;                         until kernal re-init — fine for one-shot bench
;                         harnesses, NOT for long-running host programs.
;   bench_cycles_stop     Stop counter, snapshot into bench_cycles
;                         (4 bytes, little-endian u32 cycle count).
;
; ----------------------------------------------------------------------------
; PUBLIC DATA BUFFERS (caller I/O)
; ----------------------------------------------------------------------------
;
;   x25_scalar      32 bytes  - X25519 scalar input  (32-byte aligned)
;   x25_u           32 bytes  - X25519 u-coord input (32-byte aligned)
;   x25_result      32 bytes  - X25519 output        (32-byte aligned)
;   x25_basepoint   32 bytes  - read-only; constant 9 in little-endian
;
; ----------------------------------------------------------------------------
; ZERO-PAGE USAGE (the library OWNS these slots while running)
; ----------------------------------------------------------------------------
;
; Live ZP surface (post-Phase-7, L1-L29 CT-clean): 87 bytes at
;   $14-$16, $1C, $1E-$2A, $24-$25, $2C-$2F, $40-$7F.
;
;   $14      fe_cmp_mask          (Phase 7: fe_cmp_p_ct $00/$FF mask)
;   $15      fe_subp_rhs          (Phase 7: per-iter (p_byte AND mask) scratch)
;   $16      fe_add_carry_mask    (Phase 7: fe25519_add carry-out mask)
;   $1C      poly_carry           (mul_8x8 / fe25519 reuse)
;   $1E-$1F  fe25519_src1         (caller-set pointer to operand 1)
;   $20-$21  fe25519_src2         (caller-set pointer to operand 2)
;   $22-$23  fe25519_dst          (caller-set pointer to destination)
;   $24      mul_pending          (Phase 7: Option F 1-bit carry chain)
;   $25      mul_bound            (Phase 7: public phantom guard, = 63 - fe_mul_i)
;   $26      fe_carry             (cswap mask / carry byte)
;   $27      fe_loop              (internal loop counter)
;   $28-$29  fe_mul_i, fe_mul_j   (multiply indices)
;   $2A      x25_prev_bit         (mask form, $00/$FF)
;   $2C-$2D  x25_byte_idx, x25_bit_mask
;   $2E      fe_sqr_pairs         (fe25519_sqr unrolled cross-loop counter)
;   $2F      mul_ripple_start     (Phase 7: public end-of-inner ripple start)
;   $40-$7F  fe_wide              (64-byte product accumulator; ZP-pinned by .assert)
;
;   $FB-$FE  zp_ptr1/zp_ptr2 — TEST HARNESS ONLY (used by main.s helpers,
;                              NOT part of the library's claimed ZP surface).
;
; The library does NOT preserve any of these across calls. If your host
; program uses any of the listed slots, save it before calling and
; restore after, OR pre-define the equate before .include'ing
; constants.s (see docs/LIBRARY.md §4.2 for the host override protocol).
;
; CT certification: with Phase 7 landed, every catalogued
; secret-data-dependent branch and (zp),y page-cross leak
; (L1 through L29) in the X25519 library is fixed. The library is
; CT-clean across the entire fe25519_* / mul_8x8 / x25519_scalarmult
; surface for network-facing use. See docs/CT_ANALYSIS.md for the
; full leak catalogue and Phase 7 closure mechanism.
;
; ----------------------------------------------------------------------------
; STATIC MEMORY OWNED BY THE LIBRARY
; ----------------------------------------------------------------------------
;
;   $7800-$7BFF  sqtab_lo / sqtab_hi    (1024-byte quarter-square table,
;                                        built by sqtab_init)
;   Page-aligned 32-byte field buffers (see data.s). Two consecutive
;   256-byte pages hold:
;     fe25519_tmp1..4, x25_x2, x25_z2, x25_x3, x25_z3,
;     x25_a, x25_b, x25_da, x25_cb, x25_e, x25_scalar, x25_u, x25_result
;   plus a third page-aligned page holding x25_basepoint and fe_p.
;   Each buffer's low byte is one of $00,$20,$40,$60,$80,$A0,$C0,$E0
;   (32-byte stride within a page) so 32-byte loops never page-cross.
;
;   mul_dma_lo, mul_dma_hi, mul_dma_carry  (256 bytes each, page-aligned)
;     REU DMA staging buffers for fe25519_mul / fe25519_sqr.
;
;   sqtab2_lo, sqtab2_hi, mul38_lo_tab, mul38_hi_tab,
;   sqr_lo, sqr_hi, a24_b0..a24_b3       (lookup tables)
;
; ----------------------------------------------------------------------------
; REU USAGE
; ----------------------------------------------------------------------------
;
;   Bank 0-1: 256 rows x 512 bytes each = full a*b lo+hi tables (a=0..255)
;   Bank 2:   first 64 bytes used as a zero-block for reu_clear_wide.
;             Rest unused by the library.
;   Bank 3:   17th-bit carry tables for pre-doubled fe25519_sqr products.
;   Bank 4-5: 256 rows x 512 bytes each = pre-doubled (2*a*b) lo+hi tables.
;
;   Total REU footprint: 6 banks (384 KB used of a 512 KB minimum REU).
;   The library REQUIRES at least a 512 KB REU. Larger REUs are fine —
;   only the first 6 banks are touched.
;
;   The library uses the REU's autoload feature and leaves the REU
;   command/length/address registers in a state ready for the next
;   reu_fetch_mul_row. If your application also uses the REU, save and
;   restore the REU register set ($DF00-$DF0A) around X25519 calls.
;
; ----------------------------------------------------------------------------
; INTERRUPTS / TIMING
; ----------------------------------------------------------------------------
;
;   The library does not touch the IRQ vector. It does not disable IRQs
;   except briefly inside bench_start / bench_stop, AND for the full
;   duration of x25519_scalarmult itself (which wraps its body in
;   php / sei … plp as a CT defence — see commit 35351c9). One
;   consequence: the kernal jiffy clock at $A0-$A2 does NOT advance
;   during a scalarmult call, so bench_start / bench_stop will report
;   ~0 jif around it. Time scalarmult with bench_cycles_start /
;   bench_cycles_stop (CIA1-driven, survives sei) instead.
;
;   For best (and most consistent) timing, callers should:
;     sei                ; mask IRQ for the duration of the op
;     jsr vic_blank      ; ~25% speedup
;     jsr x25519_scalarmult
;     jsr vic_unblank
;     cli
;   The library does NOT mask NMIs and assumes RESTORE is not pressed.
;
; =============================================================================

; Imports for downstream use — .include this file to get all public symbols.
.import sqtab_init, reu_mul_init
.import x25519_clamp, x25519_scalarmult, x25519_base
.import fe25519_add, fe25519_sub, fe25519_mul, fe25519_sqr
.import fe25519_copy, fe25519_zero, fe25519_one, fe25519_cswap
.import fe25519_inv, fe25519_reduce_final, fe25519_mul_a24
.import x25_scalar, x25_u, x25_result, x25_basepoint
.import vic_blank, vic_unblank, bench_start, bench_stop, bench_ticks
.import bench_cycles_start, bench_cycles_stop, bench_cycles

; REU layout equates (c64-lib-contract §3). Default 0; override via
; ca65 -D X25519_REU_BANK=$N when rebuilding the library from source.
.import X25519_REU_BANK, X25519_REU_OFFSET
