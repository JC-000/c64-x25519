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
; VERSION CONSTANTS (link-time .assert guards for consumer pinning)
; ----------------------------------------------------------------------------
;
;   LIB_X25519_VERSION_MAJOR   semver major (currently 0)
;   LIB_X25519_VERSION_MINOR   semver minor (currently 13)
;   LIB_X25519_VERSION_PATCH   semver patch (currently 0)
;   LIB_X25519_ABI_VERSION     exported-surface generation counter
;                              (currently 3; contract v0.7.5 — bumped
;                              on any breaking export change, does NOT
;                              track MAJOR; 3 covers the phase-3-wave
;                              export removals + poly_carry ->
;                              mul_carry rename, see
;                              RELEASE_NOTES_v0.11.0.md)
;
; Per c64-lib-contract §1 (v0.8.1), consumers guard against an
; unsupported library version with .assert/lderror — NOT .if/.error,
; which ca65 rejects with "Constant expression expected" because an
; .import'ed symbol has no value until link time. The guard fires at
; link rather than assemble time; still before anything runs:
;
;     .import LIB_X25519_VERSION_MAJOR, LIB_X25519_VERSION_MINOR
;     .assert (LIB_X25519_VERSION_MAJOR > 0) .or (LIB_X25519_VERSION_MINOR >= 11), lderror, "this consumer needs c64-x25519 v0.11 or later"
;
;     (one line — ca65 rejects backslash continuation unless you
;     enable `.linecont +`)
;
; And the load-bearing breakage gate, the exported-surface generation
; (see LIB_X25519_ABI_VERSION above):
;
;     .import LIB_X25519_ABI_VERSION
;     .assert LIB_X25519_ABI_VERSION = 3, lderror, "c64-x25519 exported-surface generation changed; re-check the integration"
;
; The unprefixed LIB_VERSION_* / LIB_ABI_VERSION forms still exist but
; are deprecated (identical across every contract library, so they
; collide when two libraries share a link; removed at contract v1.0).
; A consumer composing two or more contract libraries builds them all
; with `ca65 -D LIB_NO_BARE_EXPORTS=1` and imports prefixed forms only.
;
; ----------------------------------------------------------------------------
; INITIALIZATION (must be called once before any X25519 / fe25519 op)
; ----------------------------------------------------------------------------
;
;   sqtab_init      Build 1024-byte quarter-square table at
;                   LIB_SHARED_SQTAB_BASE (default $7800-$7BFF) used by
;                   mul_8x8. No inputs. Clobbers: A, X, Y. When
;                   c64-lib-contract §8.1 SHARED_SQTAB_INIT is defined
;                   at build time, this routine is a no-op stub —
;                   another library in the link is expected to provide
;                   the canonical mul_tables_init.
;
;   mul_tables_init Contract-§8.1 canonical alias for sqtab_init. Same
;                   address; either name resolves to the same proc.
;                   Multi-lib hosts should prefer this name.
;
;   reu_mul_init    Build full 8x8->16 multiplication tables in REU banks 0-5
;                   (256 lo + 256 hi bytes per a, plus pre-doubled tables for
;                   fe25519_sqr, plus a 64-byte zero block in bank 2 for
;                   reu_clear_wide). REQUIRES sqtab_init to have been called
;                   first. Takes ~1-2 seconds. No inputs. Clobbers: A, X, Y.
;                   Clears x25519_reu_fault at entry (see below).
;
;   x25519_reu_fault  (v0.12.0, c64-lib-contract SPEC v0.13.0 §8.2)
;                   One sticky byte in LIB_X25519_DATA. After every REU
;                   execute the library reads $DF00 and confirms bit 6
;                   (END OF BLOCK) before touching another REU register,
;                   spinning at most X25519_REU_SETTLE_ITER times
;                   (on bit 6 alone; bit 5 is recorded separately).
;                   The clock the settle is claimed for is
;                   X25519_MAX_CLOCK_MHZ (default 48, asserted <= 48
;                   until a 64 MHz bracket exists). x25519_reu_settle_slow
;                   / _smp / _cnt are cross-TU internals, NOT API.
;                   (default 8; `-D` overridable, a §6.2 knob). The spin
;                   has no error return, so it reports here instead:
;                     bit 0 ($01)  a spin bound expired without END OF
;                                  BLOCK — a transfer was not confirmed
;                     bit 1 ($02)  $DF00 bit 5 (VERIFY ERROR) was seen
;                   Cleared to 0 at reu_mul_init and reu_probe entry;
;                   never cleared otherwise, so a host reads it after a
;                   scalarmult to learn whether every DMA since the last
;                   init/probe completed. reu_probe folds a non-zero
;                   value into its C=0 return (the contract's SHOULD:
;                   surface it the way a missing REU is surfaced).
;                   Always 0 under lib-x25519-onchip (no REU access).
;                   Conformance is claimed at <= 48 MHz (U64E fw 3.15
;                   bracket); 64 MHz is unbracketed by the contract.
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
;       and for masking the high bit of x25_u. The routine also applies
;       the RFC 7748 decodeUCoordinate bit-255 mask internally, but only
;       to its own working copy -- x25_u is NOT modified and is left
;       exactly as the caller supplied it (src/x25519.s:146-150), so the
;       same buffer may be reused across calls.
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
;                adds ~6.7% on a plain 25-row text screen (NTSC;
;                ~5.8% PAL) -- sprites/bitmap modes cost more, see
;                docs/LIBRARY.md. Dense u-coordinates (non-basepoint
;                ECDH) run ~10% slower.
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
; DEPRECATED — scheduled for removal in v1.0
; ----------------------------------------------------------------------------
;
; The following public symbols are retained at v0.x for ABI compatibility
; but have no live callers in the library and will be removed in v1.0.
; Consumer code that uses them should migrate as noted:
;
;   mul_by_38           Shift-and-add (A * 38) -> poly_prod_hi:poly_prod_lo.
;                       Replaced everywhere internally by direct table
;                       lookup via mul38_lo_tab[A] / mul38_hi_tab[A].
;                       Migration: `ldy A / lda mul38_lo_tab,y` etc.
;
;   reu_fetch_mul_row   REU DMA helper for a single 512-byte mul row.
;                       Replaced by the inline DMA setup at the top of
;                       fe25519_mul. No external migration needed if you
;                       call fe25519_mul; otherwise inline the bank
;                       computation + reu_command write yourself — AND
;                       the §8.2 v0.13.0 settle after it (v0.12.0; the
;                       settle adds no register cost — REU_SETTLE keeps
;                       its spin counter in memory. The helper itself
;                       clobbers A and C, preserving X and Y: its
;                       asl / adc #0 bank computation destroys the
;                       entry carry and then overwrites it).
;
;   x25_basepoint       32-byte read-only buffer holding the Curve25519
;                       basepoint {9, 0, ..., 0}. Used only by
;                       x25519_base. Migration: call x25519_base, or
;                       initialise x25_u in your own code with the
;                       basepoint constant (one `lda #9 / sta x25_u`
;                       and 31 zeros).
;
; A v1.0 release will drop the .export of these symbols and (for
; mul_by_38 / x25_basepoint) the underlying CODE / DATA bytes. Pin to
; v0.x if you depend on any of them.
;
; ----------------------------------------------------------------------------
; OPTIONAL HELPERS
; ----------------------------------------------------------------------------
;
;   vic_blank             Disable VIC-II display (DEN=0). ~6% CPU speedup
;                         on a text screen; scales with what the VIC
;                         fetches (sprites/bitmap raise it).
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
; Live ZP surface (post-Phase-7, L1-L30 CT-clean; L30a-d are
; X25519_ONCHIP_MUL-profile entries): 85 bytes at
;   $14-$16, $1C, $1E-$2A, $2C-$2F, $40-$7F.
;
;   $14      fe_cmp_mask          (Phase 7: fe_cmp_p_ct $00/$FF mask)
;   $15      fe_subp_rhs          (Phase 7: per-iter (p_byte AND mask) scratch)
;   $16      fe_add_carry_mask    (Phase 7: fe25519_add carry-out mask)
;   $1C      mul_carry           (mul_8x8 / fe25519 reuse)
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
;   $FB-$FC  zp_ptr1 — TEST HARNESS ONLY (defined locally in main.s
;                       since contract #83; not exported, not shipped,
;                       NOT part of the library's claimed ZP surface).
;
; The library does NOT preserve any of these across calls. If your host
; program uses any of the listed slots, save it before calling and
; restore after, OR pre-define the equate before .include'ing
; constants.s (see docs/LIBRARY.md §4.2 for the host override protocol).
;
; CT certification: with Phase 7 landed, every catalogued
; secret-data-dependent branch and (zp),y page-cross leak
; (L1 through L29, plus the L30a-d onchip-profile entries added by
; issue #72) in the X25519 library is fixed. The library is
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
;   Bank 2:   NOT claimed. (Pre-v0.6 the library stashed a 64-byte zero
;             block here for the old reu_clear_wide; that routine was
;             rewritten to a CPU clear in v0.4.0 prep and the stash was
;             removed in v0.6 prep. Bank 2 is free for sibling consumers.)
;   Bank 3:   17th-bit carry tables for pre-doubled fe25519_sqr products.
;   Bank 4-5: 256 rows x 512 bytes each = pre-doubled (2*a*b) lo+hi tables.
;
;   Total REU footprint: 5 banks (320 KB used of a 512 KB minimum REU);
;   the claimed banks are 0, 1, 3, 4, 5. The library REQUIRES at least
;   a 512 KB REU. Larger REUs are fine — only those 5 banks are touched.
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
;     jsr vic_blank      ; ~6% speedup on a text screen
;     jsr x25519_scalarmult
;     jsr vic_unblank
;     cli
;   The library does NOT mask NMIs and assumes RESTORE is not pressed.
;
; =============================================================================

; Imports for downstream use — .include this file to get all public symbols.

; Onchip-profile guard (issue #72). When linking the lib-x25519-onchip
; archive, define X25519_ONCHIP_MUL=1 (ca65 -D) before .include'ing
; this header: the REU-side surface below does not exist in that
; archive (no REU traffic at all; boot obligation is sqtab_init only).
; Default (0) leaves the header identical to the pre-#72 surface.
.ifndef X25519_ONCHIP_MUL
  X25519_ONCHIP_MUL = 0
.endif

.import mul_tables_init              ; §8.1 canonical entry — always
                                     ; resolves (owner build: x25519's
                                     ; body; deferral: the provider's)
.ifndef SHARED_SQTAB_INIT
.import sqtab_init                   ; historical x25519-own alias;
                                     ; absent from a §8.1 deferral
                                     ; build (import-never-stub, SPEC
                                     ; v0.9.0) — use mul_tables_init
.endif
.if ::X25519_ONCHIP_MUL = 0
.ifndef SHARED_REU_MUL_INIT
.import reu_mul_init                 ; x25519-private init name; gated out of
                                     ; a SHARED_REU_MUL_INIT deferral build —
                                     ; only the canonical §8.2 name below is
                                     ; part of the composed-link surface
.endif
.import reu_mul_tables_init          ; c64-lib-contract §8.2 canonical entry
                                     ; (alias of reu_mul_init standalone;
                                     ; provider-owned under SHARED_REU_MUL_INIT)
.endif
.import ct_mul_8x8                   ; c64-lib-contract §8.3 canonical CT
                                     ; multiply body
.ifndef SHARED_CT_MUL_8X8
.import mul_8x8                      ; back-compat alias (same address) —
                                     ; x25519-own name, absent when the body
                                     ; is deferred to the §8.3 canonical owner
.endif
.if ::X25519_ONCHIP_MUL = 0
.import reu_fetch_mul_row_bank_patch ; §8.2 SMC bank-patch hook (byte
                                     ; address of reu_fetch_mul_row's
                                     ; bank-LDA immediate)
.endif
.import x25519_clamp, x25519_scalarmult, x25519_base
.import fe25519_add, fe25519_sub, fe25519_mul, fe25519_sqr
.import fe25519_copy, fe25519_zero, fe25519_one, fe25519_cswap
.import fe25519_inv, fe25519_reduce_final, fe25519_mul_a24
.import x25_scalar, x25_u, x25_result, x25_basepoint
.import x25519_reu_fault             ; §8.2 v0.13.0 sticky settle-fault byte
                                     ; (v0.12.0; always 0 under onchip)
.import vic_blank, vic_unblank, bench_start, bench_stop, bench_ticks
.import bench_cycles_start, bench_cycles_stop, bench_cycles

; Library version constants (c64-lib-contract §1, v0.7.0 prefixed
; forms). The deprecated bare aliases are only present in the archive
; when it was built without LIB_NO_BARE_EXPORTS; the same define gates
; the consumer-side imports so the two sides stay in step.
.import LIB_X25519_VERSION_MAJOR, LIB_X25519_VERSION_MINOR
.import LIB_X25519_VERSION_PATCH, LIB_X25519_ABI_VERSION
.ifndef LIB_NO_BARE_EXPORTS
.import LIB_VERSION_MAJOR, LIB_VERSION_MINOR, LIB_VERSION_PATCH
.import LIB_ABI_VERSION
.endif

.if ::X25519_ONCHIP_MUL = 0
; REU layout equates (c64-lib-contract §3). Default 0; override via
; ca65 -D X25519_REU_BANK=0x<bank> when rebuilding the library from source.
; Guarding rule (contract#164): guard a header .import iff the defining
; TU guards the definition with .ifndef, and pair every such guard with
; an .else branch asserting the override against the library's exported
; value; if the defining TU assigns unconditionally the equate is
; derived, so leave the import bare and let the -D collide loudly.
;
; §3 documents the consumer override `ca65 -D X25519_REU_BANK=0x<bank>`,
; but a -D that reaches a TU which also .imports the name is "Symbol
; already defined" -- the same -D-versus-.import collision §2 hit and
; solved at v0.9.1. Unguarded, §3's own worked example failed to
; assemble against this header (measured on the pre-guard header, at
; what was then its bare `.import X25519_REU_BANK` line). So
; X25519_REU_BANK / X25519_REU_OFFSET are guarded (reu_config.s:61,74
; define them under .ifndef). A bare guard alone would be worse than
; the collision it removes: it converts a compile error into SILENT
; divergence (measured: a consumer at bank 8 links clean against a
; bank-0 archive). Hence the .else legs, which assert the override
; against the library OUTPUT equates the archive actually baked in.
;
; X25519_REU_BANK_DOUBLED / _CARRY get NO guard: reu_config.s:90-91
; assign them unconditionally as derived values (BANK+4 / BANK+3), so a
; -D on them is not a supported override and MUST collide loudly. A
; guard there would mask a deliberate parse-time rejection.
.ifndef X25519_REU_BANK
.import X25519_REU_BANK
.else
.import LIB_X25519_SHARED_REU_MUL_BANK
.assert X25519_REU_BANK = LIB_X25519_SHARED_REU_MUL_BANK, lderror, "X25519_REU_BANK override disagrees with the archive this header ships against"
.endif
.ifndef X25519_REU_OFFSET
.import X25519_REU_OFFSET
.else
.import LIB_X25519_SHARED_REU_MUL_OFFSET
.assert X25519_REU_OFFSET = LIB_X25519_SHARED_REU_MUL_OFFSET, lderror, "X25519_REU_OFFSET override disagrees with the archive this header ships against"
.endif

; §8.2 shared reu_mul placement equates, LIBRARY-PREFIXED (contract
; #82; see LIBRARY.md §4.8). These are library OUTPUT — what this
; build baked in. Consumers compose/collision-check against these
; instead of hardcoding bank offsets:
;   .assert LIB_X25519_SHARED_REU_MUL_BANK = LIB_<other>_SHARED_REU_MUL_BANK, lderror, "shared mul table placement disagreement"
; The unprefixed LIB_SHARED_REU_MUL_* names are consumer-INPUT knobs
; (assemble-time equates, set via `ca65 -D` across every TU when
; rebuilding; NOT link symbols — exporting them collides between §8.2
; adopters). Overriding LIB_SHARED_REU_MUL_BANK now genuinely
; relocates the table: it drives X25519_REU_BANK (the two must agree,
; assemble-time-asserted in reu_config.s).
.import LIB_X25519_SHARED_REU_MUL_BANK, LIB_X25519_SHARED_REU_MUL_OFFSET
.import LIB_X25519_SHARED_REU_MUL_BANKS_USED
.import X25519_REU_BANK_DOUBLED
.import X25519_REU_BANK_CARRY

; REU presence probe. Completes the x25519_reu_fault contract: the fault
; byte is the READER, reu_probe is the entry that opens a fresh fault
; window and tests for a working REU. Both halves are public API and are
; documented above (§ x25519_reu_fault) and in LIBRARY.md §4.12, but the
; .import was missing here until v0.12.0-post, so a consumer following
; that documentation had to hand-write the import. Call it BEFORE the
; first reu_mul_init -- it does not preserve the autoload latch.
; Returns C=1 when an REU responded, C=0 when absent or faulted.
; Gated with the rest of the REU surface: absent from the onchip archive.
.import reu_probe
.endif ; X25519_ONCHIP_MUL = 0 (issue #72 — no REU surface in onchip archive)

; §5 aggregate manifest equates — assemble-time fit / collision checks
; (ZP footprint, REU bank claim, resident bytes; see LIBRARY.md §4.5).
.import LIB_X25519_ZP_USAGE_BYTES, LIB_X25519_REU_BANKS_USED
.import LIB_X25519_RESIDENT_BYTES, LIB_X25519_COLD_BYTES

; Shared-primitives manifest (c64-lib-contract §5 / §8.0-§8.3).
; LIB_X25519_SHARED_PRIMITIVES: bitmask of the §8.x primitives this
; build of c64-x25519 OWNS — per SPEC v0.4.0 §8.0 a bit is set iff the
; build did NOT define that primitive's deferral switch
; (SHARED_SQTAB_INIT / SHARED_REU_MUL_INIT / SHARED_CT_MUL_8X8). Use
; for assemble-time double-ownership detection when composing
; c64-x25519 with another lib that consumes the same primitives.
; LIB_X25519_SHARED_CONSUMES (SPEC v0.5.0): bit set iff this build
; config consumes the primitive at all — deferral switches do NOT
; clear it, profile gates (X25519_ONCHIP_MUL) do. Every consumed bit
; must have exactly one owner in the composed link:
;   .assert ((LIB_X25519_SHARED_CONSUMES | LIB_<other>_SHARED_CONSUMES) \
;            & ~(LIB_X25519_SHARED_PRIMITIVES | \
;                LIB_<other>_SHARED_PRIMITIVES)) = 0, error, \
;           "consumed shared primitive with no owner in the link"
; See LIBRARY.md §4.7.
.import LIB_X25519_SHARED_PRIMITIVES, LIB_X25519_SHARED_CONSUMES

; §8.x per-primitive bit constants (c64-lib-contract §8.0). Plain
; assemble-time equates, deliberately NOT link symbols: every §8
; adopter carries the same names/values, and only exported symbols can
; collide at link time (issues #77/#78). .ifndef-guarded so a consumer
; that already defines them (e.g. via another adopter's header or -D)
; does not get a redefinition error.
.ifndef LIB_SHARED_PRIMITIVES_SQTAB
LIB_SHARED_PRIMITIVES_SQTAB      = $0001   ; SPEC §8.1 quarter-square table
.endif
.ifndef LIB_SHARED_PRIMITIVES_REU_MUL
LIB_SHARED_PRIMITIVES_REU_MUL    = $0002   ; SPEC §8.2 REU mul table
.endif
.ifndef LIB_SHARED_PRIMITIVES_CT_MUL_8X8
LIB_SHARED_PRIMITIVES_CT_MUL_8X8 = $0004   ; SPEC §8.3 CT multiply body
.endif
