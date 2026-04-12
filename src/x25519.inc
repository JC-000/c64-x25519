; =============================================================================
; x25519.inc - Public interface for the C64 X25519 library
;
; Assembler:  ACME (!cpu 6502, !source style)
; Target:     Commodore 64 + REU (Ram Expansion Unit, >= 512 KB required)
;
; This file declares the public symbols that downstream projects need
; in order to call into the X25519 library. The library itself is built
; from src/main.asm by linking the modules referenced in this header.
; This .inc file does NOT itself emit code or data — it only documents
; and (where ACME requires) re-states equates.
;
; To use from a downstream project (current single-binary integration):
;
;     !source "x25519.inc"          ; brings in equates / documentation
;     !source "constants.asm"       ; ZP / hardware equates
;     ; ... your code ...
;     ; assemble main.asm-style file that includes
;     ;   mul_8x8.asm, fe25519.asm, x25519.asm, data.asm
;
; A future "rename + scope" pass will turn this into a true header
; (only equates + commented prototypes) once the library is split into
; a self-contained .o produced by ca65/ld65 or relocatable ACME object.
; See TODO-LIBRARY.md at repo root.
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
;       Timing:  ~9,818 jiffies (~163 s) per call on stock C64 PAL with
;                VIC-II blanked (jsr vic_blank). VIC-II unblanked adds
;                ~25%. See docs/LIBRARY.md.
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
; All fe_* routines take operand pointers via the zero-page slots
; fe25519_src1, fe25519_src2, fe25519_dst (each 2 bytes, little-endian). Operands are
; 32-byte little-endian field elements. The destination buffer MUST be
; page-aligned to one of the offsets {$00,$20,$40,$60,$80,$A0,$C0,$E0}
; within its page (so that 32-byte indexed access never crosses a page
; boundary). See "Buffer alignment" below.
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
;   fe_cmp_p       Compare (fe25519_dst) against p. Carry set if >= p.
;
;   All clobber: A, X, Y and the fe_* scratch ZP slots.
;
; ----------------------------------------------------------------------------
; OPTIONAL HELPERS
; ----------------------------------------------------------------------------
;
;   vic_blank      Disable VIC-II display (DEN=0). ~25% CPU speedup.
;   vic_unblank    Re-enable VIC-II display.
;   bench_start    Reset jiffy clock for timing.
;   bench_stop     Snapshot jiffy clock into bench_ticks (3 bytes).
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
;   $14-$15  lmul0          (mul_8x8 sqtab pointer)
;   $16-$17  lmul1          (mul_8x8 sqtab_hi pointer)
;   $1A-$1D  poly_i/j/carry/tmp  (mul_8x8 scratch)
;   $1E-$1F  fe25519_src1        (caller-set pointer to operand 1)
;   $20-$21  fe25519_src2        (caller-set pointer to operand 2)
;   $22-$23  fe25519_dst         (caller-set pointer to destination)
;   $24-$25  fe_misc        (internal pointer)
;   $26      fe_carry       (cswap mask / carry byte)
;   $27      fe_loop        (internal loop counter)
;   $28-$29  fe_mul_i, fe_mul_j  (multiply indices)
;   $2A-$2D  x25_prev_bit, x25_bit_ctr, x25_byte_idx, x25_bit_mask
;   $2E      fe_sqr_pairs   (fe25519_sqr unrolled cross-loop counter)
;   $40-$7F  fe_wide        (64-byte product accumulator; ZP for speed)
;   $FB-$FE  zp_ptr1/zp_ptr2 (general scratch, used by main.asm helpers)
;
; The library does NOT preserve any of these across calls. If your host
; program uses any of $14-$7F or $FB-$FE, save it before calling and
; restore after.
;
; ----------------------------------------------------------------------------
; STATIC MEMORY OWNED BY THE LIBRARY
; ----------------------------------------------------------------------------
;
;   $7800-$7BFF  sqtab_lo / sqtab_hi    (1024-byte quarter-square table,
;                                        built by sqtab_init)
;   Page-aligned 32-byte field buffers (see data.asm). Two consecutive
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
;   except briefly inside bench_start / bench_stop. For best (and most
;   consistent) timing, callers should:
;     sei                ; mask IRQ for the duration of the op
;     jsr vic_blank      ; ~25% speedup
;     jsr x25519_scalarmult
;     jsr vic_unblank
;     cli
;   The library does NOT mask NMIs and assumes RESTORE is not pressed.
;
; =============================================================================
;
; This .inc is documentation-only at present. All public symbols are
; defined as plain global labels in their source files (constants.asm,
; mul_8x8.asm, fe25519.asm, x25519.asm, data.asm, main.asm). ACME has no
; .import / .export distinction, so name collisions with the host program
; must be avoided by the host (or by waiting for the rename pass that
; will prefix every public symbol with x25519_ / fe25519_).
;
; =============================================================================
