; =============================================================================
; fe25519.s - Field arithmetic mod p = 2^255 - 19
;
; 32-byte little-endian field elements.
; Uses ZP pointers fe25519_src1, fe25519_src2, fe25519_dst for operands.
; Reuses mul_8x8 and sqtab from mul_8x8.s for multiplication.
;
; Key design:
;   - Little-endian throughout (matches 6502 carry propagation and X25519 wire)
;   - DEX/DEY for all carry-dependent loops (CPX/CPY clobber carry)
;   - Reduction mod p: 2^256 ≡ 38 mod p, so multiply overflow by 38 and add
; =============================================================================

.setcpu "6502"
.include "constants.s"

; --- Exports ---
.export fe25519_copy, fe25519_zero, fe25519_one
.export fe25519_add, fe25519_sub, fe25519_reduce_final
.export fe25519_cswap, fe25519_mul, fe25519_sqr
.export fe25519_mul_a24, fe25519_inv
.export mul_by_38

; --- Imports from mul_8x8.s ---
.import poly_prod_lo, poly_prod_hi
; sqtab_lo / sqtab_hi are now `.ifndef`-guarded equates in constants.s
; (c64-lib-contract §8.1 shared-primitive adoption) — visible here via
; the `.include "constants.s"` at the top of this file. No .import.

; --- Imports from x25519_init.s ---
.import reu_clear_wide
.if ::SQR_DMA_K
; reu_fetch_doubled_row is only defined (and only invoked) when the
; pre-doubled-table DMA fast-path is compiled in. In the K=0 variant
; (`make lib-x25519-1764`) fe25519_sqr never dispatches to the DMA
; path, the proc body in x25519_init.s is gated out, and importing
; the symbol would leave the linker with an unresolved external.
.import reu_fetch_doubled_row
.endif

; --- Imports from data.s ---
.import fe25519_tmp1, fe25519_tmp2, fe25519_tmp3, fe25519_tmp4
.import x25_a, x25_b, x25_da, x25_cb
.import fe_p, mul_cached_a, mul_src2_buf
.import mul_dma_lo, mul_dma_hi, mul_dma_carry
.import mul38_lo_tab, mul38_hi_tab
.import sqr_lo, sqr_hi
.import a24_b0, a24_b1, a24_b2, a24_b3

.segment "CODE"

; =============================================================================
; fe25519_copy - Copy 32 bytes: (fe25519_dst) = (fe25519_src1)
; Clobbers: A, Y
; =============================================================================
.proc fe25519_copy
        ldy #31
@loop:
        lda (fe25519_src1),y
        sta (fe25519_dst),y
        dey
        bpl @loop
        rts
.endproc


; =============================================================================
; fe25519_zero - Zero 32 bytes at (fe25519_dst)
; Clobbers: A, Y
; =============================================================================
.proc fe25519_zero
        lda #0
        ldy #31
@loop:
        sta (fe25519_dst),y
        dey
        bpl @loop
        rts
.endproc


; =============================================================================
; fe25519_one - Set (fe25519_dst) = 1 (LE: byte 0 = 1, rest 0)
; Clobbers: A, Y
; =============================================================================
.proc fe25519_one
        jsr fe25519_zero
        lda #1
        ldy #0
        sta (fe25519_dst),y
        rts
.endproc


; =============================================================================
; fe25519_add - (fe25519_dst) = (fe25519_src1) + (fe25519_src2) mod p
;
; 32-byte addition, then unconditional masked subtract-p driven by the
; combined "must reduce" mask = (add-carry-out) OR (raw-result >= p).
; Clobbers: A, X, Y, fe_cmp_mask, fe_add_carry_mask, fe_subp_rhs.
;
; L29 closure: constant-time via masked sub-p. The pre-L29 version used
; `bcs @must_reduce` and `bcc @done` after the compare — both branches
; depended on (overflow OR dst-value)-derived data, which is secret in
; the ladder hot path. The new flow performs:
;
;   1) 32-byte adc loop (always 32 bytes, no early exit).
;   2) Convert add carry-out to a $00/$FF mask in fe_add_carry_mask via
;      `lda #0 / sbc #0 / eor #$FF` (relies on dex/iny/bne not touching
;      C between the final adc and the sbc).
;   3) jsr fe_cmp_p_ct → 32-byte compare-with-p that returns its
;      $00/$FF "dst >= p" mask in A and fe_cmp_mask.
;   4) Combine: fe_cmp_mask := fe_cmp_mask OR fe_add_carry_mask, so the
;      mask is $FF iff a sub-p MUST be applied.
;   5) 32-byte unconditional masked sub-p loop. Per-byte:
;        lda fe_p,y / and fe_cmp_mask / sta fe_subp_rhs
;        lda dst,y  / sbc fe_subp_rhs / sta dst,y
;      When mask = $00, fe_subp_rhs = 0 each byte and the loop is a
;      no-op (modulo the carry chain, which sec primes correctly), so
;      the result is unchanged. When mask = $FF, p is subtracted in
;      full. Either way the instruction sequence is identical.
;
; Self-modifying code (mirrors fe25519_cswap): src1/src2/dst patched
; into the abs,Y operands at proc entry. The patches read public ZP
; pointers (fe25519_src1/src2/dst) so they are CT-neutral. The 32-byte
; alignment contract (.assert (X & $1F) = 0 in data.s) guarantees
; abs,Y over Y in [0,31] never crosses a page.
; =============================================================================
.proc fe25519_add
        ; Patch src1/src2/dst into abs,Y operands (both loops).
        lda fe25519_src1
        sta @add_ld_src1+1
        lda fe25519_src1+1
        sta @add_ld_src1+2
        lda fe25519_src2
        sta @add_ld_src2+1
        lda fe25519_src2+1
        sta @add_ld_src2+2
        lda fe25519_dst
        sta @add_st_dst+1
        sta @sub_ld_dst+1
        sta @sub_st_dst+1
        lda fe25519_dst+1
        sta @add_st_dst+2
        sta @sub_ld_dst+2
        sta @sub_st_dst+2

        clc
        ldy #0
        ldx #32
@add_loop:
@add_ld_src1:
        lda $ffff,y            ; PATCHED: src1 base
@add_ld_src2:
        adc $ffff,y            ; PATCHED: src2 base
@add_st_dst:
        sta $ffff,y            ; PATCHED: dst  base
        iny
        dex                    ; DEX/INY do not affect C
        bne @add_loop          ; public counter X

        ; Capture add carry-out into fe_add_carry_mask.
        ; C=1 (overflow) → A=0  → eor $FF → $FF
        ; C=0 (no over)  → A=$FF → eor $FF → $00
        lda #0
        sbc #0
        eor #$FF
        sta fe_add_carry_mask

        ; Compute "raw dst >= p" mask in fe_cmp_mask (and A).
        jsr fe_cmp_p_ct

        ; Combine: must-reduce iff overflow OR (dst >= p).
        ora fe_add_carry_mask
        sta fe_cmp_mask

        ; Unconditional masked sub-p. mask=$00 → subtract 0 (no-op);
        ; mask=$FF → subtract p. Identical instruction stream either way.
        sec
        ldy #0
        ldx #32
@sub_p:
        lda fe_p,y
        and fe_cmp_mask
        sta fe_subp_rhs
@sub_ld_dst:
        lda $ffff,y            ; PATCHED: dst base
        sbc fe_subp_rhs
@sub_st_dst:
        sta $ffff,y            ; PATCHED: dst base
        iny
        dex
        bne @sub_p             ; public counter X
        rts
.endproc


; =============================================================================
; fe25519_sub - (fe25519_dst) = (fe25519_src1) - (fe25519_src2) mod p
;
; 32-byte subtraction, then unconditional masked add-p driven by the
; "borrow occurred" mask.
; Clobbers: A, X, Y, fe_cmp_mask, fe_subp_rhs.
;
; L29 closure: constant-time via masked add-p. The pre-L29 version used
; `bcs @done` after the sub loop; the branch direction encoded sign of
; (src1 - src2), which is secret. The new flow:
;
;   1) 32-byte sbc loop (always 32 bytes, no early exit).
;   2) Convert final-borrow into a $00/$FF mask via `lda #0 / sbc #0`
;      (no `eor #$FF`: SBC of #0 with C=0 yields $FF, with C=1 yields
;      $00, which is exactly the "borrow → add p" polarity we want).
;   3) 32-byte unconditional masked add-p loop. Per-byte:
;        lda fe_p,y / and fe_cmp_mask / sta fe_subp_rhs
;        lda dst,y  / adc fe_subp_rhs / sta dst,y
;      Mask=$00 → adds 0 (no-op given clc); mask=$FF → adds p.
;
; SMC patches mirror fe25519_add (src1/src2/dst patched at entry).
; =============================================================================
.proc fe25519_sub
        ; Patch src1/src2/dst into abs,Y operands (both loops).
        lda fe25519_src1
        sta @sub_ld_src1+1
        lda fe25519_src1+1
        sta @sub_ld_src1+2
        lda fe25519_src2
        sta @sub_ld_src2+1
        lda fe25519_src2+1
        sta @sub_ld_src2+2
        lda fe25519_dst
        sta @sub_st_dst+1
        sta @add_ld_dst+1
        sta @add_st_dst+1
        lda fe25519_dst+1
        sta @sub_st_dst+2
        sta @add_ld_dst+2
        sta @add_st_dst+2

        sec
        ldy #0
        ldx #32
@sub_loop:
@sub_ld_src1:
        lda $ffff,y            ; PATCHED: src1 base
@sub_ld_src2:
        sbc $ffff,y            ; PATCHED: src2 base
@sub_st_dst:
        sta $ffff,y            ; PATCHED: dst  base
        iny
        dex
        bne @sub_loop          ; public counter X

        ; Capture final-borrow directly into fe_cmp_mask.
        ; C=1 (no borrow)   → A = 0 - 0 - 0 = $00 → mask=$00 (skip add)
        ; C=0 (borrow)      → A = 0 - 0 - 1 = $FF → mask=$FF (add p)
        lda #0
        sbc #0
        sta fe_cmp_mask

        ; Unconditional masked add-p. mask=$00 → add 0; mask=$FF → add p.
        clc
        ldy #0
        ldx #32
@add_p:
        lda fe_p,y
        and fe_cmp_mask
        sta fe_subp_rhs
@add_ld_dst:
        lda $ffff,y            ; PATCHED: dst base
        adc fe_subp_rhs
@add_st_dst:
        sta $ffff,y            ; PATCHED: dst base
        iny
        dex
        bne @add_p             ; public counter X
        rts
.endproc


; =============================================================================
; fe_cmp_p_ct - Constant-time compare (fe25519_dst) with p
;
; Output: A = $FF iff (fe25519_dst) >= p, else $00.
;         fe_cmp_mask = same mask as A.
; Clobbers: A, X, Y, fe_cmp_mask.
;
; L29 closure: constant-time replacement for the legacy fe_cmp_p, which
; used a leading-byte-comparison early-exit (`bcc @less / bne @greater`)
; whose loop trip count depended on dst's MSB pattern — a secret-leaky
; control flow. The new variant performs a full 32-byte borrow-tracking
; sub against fe_p (no early exit, public counter X) and converts the
; final carry into a $00/$FF mask.
;
;   sbc dst[i] - p[i] - !C across i in [0..31]:
;     C=1 at end iff dst >= p (no final borrow).
;
; The mask is computed via `lda #0 / sbc #0 / eor #$FF`:
;   C=1 → A=0  → eor $FF → $FF (mask = "dst >= p, must subtract")
;   C=0 → A=$FF → eor $FF → $00 (mask = "dst < p")
;
; Self-modifying code (mirrors fe25519_cswap): patches dst into the
; abs,Y load operand at proc entry from public ZP fe25519_dst.
;
; Internal symbol — not exported. Called by fe25519_add and
; fe25519_reduce_final.
; =============================================================================
.proc fe_cmp_p_ct
        ; Patch dst into the abs,Y load.
        lda fe25519_dst
        sta @cmp_ld_dst+1
        lda fe25519_dst+1
        sta @cmp_ld_dst+2

        sec
        ldy #0
        ldx #32
@cmp_loop:
@cmp_ld_dst:
        lda $ffff,y            ; PATCHED: dst base
        sbc fe_p,y
        iny
        dex                    ; DEX/INY preserve C
        bne @cmp_loop          ; public counter X

        lda #0
        sbc #0
        eor #$FF               ; A = $FF iff dst >= p, else $00
        sta fe_cmp_mask
        rts
.endproc


; =============================================================================
; fe25519_reduce_final - Canonical reduction of (fe25519_dst) to [0, p-1]
;
; Pre: post-fe_reduce_wide invariant guarantees R <= 2*p (Inv3 / W2),
; so two unconditional iterations of (compare-with-p, masked subtract-p)
; suffice to land R in [0, p).
; Clobbers: A, X, Y, fe_cmp_mask, fe_subp_rhs.
;
; L29 closure: constant-time via masked sub-p. The pre-L29 version used
; a `bcc @done` early-exit on the compare result, which leaked the
; canonical-vs-non-canonical state of the input value. The new flow is:
;
;   for i in 0..1:
;       jsr fe_cmp_p_ct              ; mask <- (dst >= p) ? $FF : $00
;       <32-byte unconditional masked sub-p>
;
; Two iterations suffice because after iter 0 R is in [0, p+max(0,p-1)]
; ⊆ [0, 2p); after iter 1 R must be in [0, p). A 3-iteration variant
; was rejected by the maintainer in favor of relying on the R <= 2p
; bound, gated by the regression test in tools/test_fe_reduce_wide_bound.py.
;
; SMC: dst patched into both sub_p loops at proc entry. fe_cmp_p_ct
; performs its own dst patch internally on each call.
; =============================================================================
.proc fe25519_reduce_final
        ; Patch dst into both masked-sub-p loops at entry (4 stores per
        ; address byte × 2 iterations = 8 stores).
        lda fe25519_dst
        sta @sub_ld_dst1+1
        sta @sub_st_dst1+1
        sta @sub_ld_dst2+1
        sta @sub_st_dst2+1
        lda fe25519_dst+1
        sta @sub_ld_dst1+2
        sta @sub_st_dst1+2
        sta @sub_ld_dst2+2
        sta @sub_st_dst2+2

        ; --- Iteration 1 ---
        jsr fe_cmp_p_ct              ; A, fe_cmp_mask = mask
        sec
        ldy #0
        ldx #32
@sub_p1:
        lda fe_p,y
        and fe_cmp_mask
        sta fe_subp_rhs
@sub_ld_dst1:
        lda $ffff,y                  ; PATCHED: dst base
        sbc fe_subp_rhs
@sub_st_dst1:
        sta $ffff,y                  ; PATCHED: dst base
        iny
        dex
        bne @sub_p1                  ; public counter X

        ; --- Iteration 2 ---
        jsr fe_cmp_p_ct
        sec
        ldy #0
        ldx #32
@sub_p2:
        lda fe_p,y
        and fe_cmp_mask
        sta fe_subp_rhs
@sub_ld_dst2:
        lda $ffff,y                  ; PATCHED: dst base
        sbc fe_subp_rhs
@sub_st_dst2:
        sta $ffff,y                  ; PATCHED: dst base
        iny
        dex
        bne @sub_p2                  ; public counter X
        rts
.endproc


; =============================================================================
; fe25519_cswap - Constant-time conditional swap of (fe25519_src1) and (fe25519_src2)
;
; Input: A = swap mask (0x00 = no swap, 0xFF = swap)
; Clobbers: A, X, Y
;
; Self-modifying code: patches absolute,Y addresses into the inner loop
; to replace indirect-indexed (zp),Y loads/stores (4-5 cyc vs 5-6 cyc each).
; Eliminates redundant re-read of src1 by keeping value in X register.
; Unrolled 4x to reduce loop overhead (32 bytes / 4 = 8 iterations).
;
; Per byte: lda abs,Y(4) + tax(2) + eor abs,Y(4) + and zp(3) + sta zp(3)
;           + txa(2) + eor zp(3) + sta abs,Y(5) + lda abs,Y(4) + eor zp(3)
;           + sta abs,Y(5) = 38 cycles/byte
; Old: 49 cycles/byte (indirect-indexed + redundant re-read)
; Savings: ~11 cyc/byte * 32 bytes * 512 calls = ~180k cycles
;
; --- CT audit (closed on branch audit/ladder-cswap-ct) ---
; The swap mask is secret (derived from scalar bits via k_t XOR prev_bit).
; Every op below must therefore be mask-time-invariant:
;   * Entry SMC patches src1/src2 addresses 20 times — src1 and src2 are
;     public link-time pointers (fe25519_src1/src2 ZP, set by the ladder
;     caller to point at x25_x2/x3/z2/z3, all 32-byte-aligned public data
;     addresses). No secret input to the patch sequence.
;   * Inner loop (unrolled 4x) runs 8 iterations of a fixed instruction
;     sequence: lda/tax/eor/and/sta/txa/eor/sta/lda/eor/sta. Every op
;     executes every iteration regardless of mask value. The mask only
;     influences the DATA loaded/stored, not the control flow or timing.
;   * No branch on the mask; the only loop branch is `bpl @loop` on the
;     Y counter (public byte index).
;   * No page-cross in the abs,Y loads: every caller (x25519_scalarmult)
;     passes src1/src2 pointing at 32-byte-aligned buffers (x25_x2/x3/z2/z3
;     at page+$80/$A0/$C0/$E0 respectively — see data.s). With Y in
;     [0..31], the abs+Y access stays within a single page. The 32-byte
;     alignment is a hard link-time assertion in data.s, and is documented
;     as a library contract in LIBRARY.md §6.
; Conclusion: fe25519_cswap is CT-clean with respect to the swap mask.
; =============================================================================
.proc fe25519_cswap
        sta fe_carry           ; save mask

        ; Patch src1 address into lda/sta abs,Y instructions (8 patches)
        lda fe25519_src1
        sta @ld_a1+1
        sta @st_a1+1
        sta @ld_a2+1
        sta @st_a2+1
        sta @ld_a3+1
        sta @st_a3+1
        sta @ld_a4+1
        sta @st_a4+1
        lda fe25519_src1+1
        sta @ld_a1+2
        sta @st_a1+2
        sta @ld_a2+2
        sta @st_a2+2
        sta @ld_a3+2
        sta @st_a3+2
        sta @ld_a4+2
        sta @st_a4+2

        ; Patch src2 address into eor/lda/sta abs,Y instructions (12 patches)
        lda fe25519_src2
        sta @eor_b1+1
        sta @ld_b1+1
        sta @st_b1+1
        sta @eor_b2+1
        sta @ld_b2+1
        sta @st_b2+1
        sta @eor_b3+1
        sta @ld_b3+1
        sta @st_b3+1
        sta @eor_b4+1
        sta @ld_b4+1
        sta @st_b4+1
        lda fe25519_src2+1
        sta @eor_b1+2
        sta @ld_b1+2
        sta @st_b1+2
        sta @eor_b2+2
        sta @ld_b2+2
        sta @st_b2+2
        sta @eor_b3+2
        sta @ld_b3+2
        sta @st_b3+2
        sta @eor_b4+2
        sta @ld_b4+2
        sta @st_b4+2

        ldy #31
@loop:
        ; --- Byte at Y ---
@ld_a1: lda $ffff,y            ; a[y]           (patched)
        tax                    ; X = a[y]
@eor_b1:eor $ffff,y            ; a[y] ^ b[y]    (patched)
        and fe_carry           ; diff
        sta fe_loop            ; save diff
        txa                    ; A = a[y]
        eor fe_loop            ; a[y] ^ diff
@st_a1: sta $ffff,y            ; store new a[y]  (patched)
@ld_b1: lda $ffff,y            ; b[y]           (patched)
        eor fe_loop            ; b[y] ^ diff
@st_b1: sta $ffff,y            ; store new b[y]  (patched)

        dey

        ; --- Byte at Y ---
@ld_a2: lda $ffff,y
        tax
@eor_b2:eor $ffff,y
        and fe_carry
        sta fe_loop
        txa
        eor fe_loop
@st_a2: sta $ffff,y
@ld_b2: lda $ffff,y
        eor fe_loop
@st_b2: sta $ffff,y

        dey

        ; --- Byte at Y ---
@ld_a3: lda $ffff,y
        tax
@eor_b3:eor $ffff,y
        and fe_carry
        sta fe_loop
        txa
        eor fe_loop
@st_a3: sta $ffff,y
@ld_b3: lda $ffff,y
        eor fe_loop
@st_b3: sta $ffff,y

        dey

        ; --- Byte at Y ---
@ld_a4: lda $ffff,y
        tax
@eor_b4:eor $ffff,y
        and fe_carry
        sta fe_loop
        txa
        eor fe_loop
@st_a4: sta $ffff,y
@ld_b4: lda $ffff,y
        eor fe_loop
@st_b4: sta $ffff,y

        dey
        bpl @loop
        rts
.endproc


; =============================================================================
; fe25519_mul - (fe25519_dst) = (fe25519_src1) * (fe25519_src2) mod p
;
; Combined REU DMA table lookup + 2x inner loop unroll.
; Each outer iteration: DMA fetches 512-byte mul row for src1[i],
; then inner loop does direct table lookup (mul_dma_lo/hi,Y) instead of
; mult66 quarter-square. Inner loop unrolled 2x to reduce branch overhead.
;
; Clobbers: A, X, Y
; =============================================================================
.proc fe25519_mul
        ; H2 defensive REU register init (mirrors S2 in x25519_scalarmult).
        ; Direct callers of public field ops must not be exposed to issue #33
        ; (caller-controlled $DF04/$DF0A residue silently corrupting DMA).
        lda #0
        sta reu_reu_lo            ; $DF04
        sta reu_addr_ctrl         ; $DF0A

        ; 1. Zero the 64-byte product buffer via REU DMA FETCH from bank 2
        jsr reu_clear_wide

        ; 2. Self-mod patch the four `ldy src2_buf,x` sites in the inner loop
        ;    and the outer `lda src1_buf,y` site to read directly from src1/2
        ;    (avoids 32-byte copy and zp-indirect-indexed addressing).
        lda fe25519_src2
        sta @ldy_src2_a+1
        sta @ldy_src2_b+1
        sta @ldy_src2_c+1
        sta @ldy_src2_d+1
        lda fe25519_src2+1
        sta @ldy_src2_a+2
        sta @ldy_src2_b+2
        sta @ldy_src2_c+2
        sta @ldy_src2_d+2
        lda fe25519_src1
        sta @load_src1+1
        lda fe25519_src1+1
        sta @load_src1+2

        ; 3. Schoolbook multiply with REU DMA lookup + self-mod accumulation
        lda #0
        sta fe_mul_i
@mul_outer:
        ; --- Phase-6-style CT structure (L25/L26 closure) ---
        ; sqr's sqr_pending/sqr_bound chain pattern, ported to mul. Reset the
        ; pending-carry chain at the start of each outer-i. Compute the
        ; public phantom-guard bound (mul_bound = 63 - i) for body D's
        ; chain step. Both are public (depend only on fe_mul_i, not on
        ; secret data). All four bodies run unconditionally; the L25
        ; zero-skip on src1[i] is replaced by the same DMA-row[0]==0
        ; invariant that closed L12-L15.
        lda #0
        sta mul_pending
        lda #63
        sec
        sbc fe_mul_i
        sta mul_bound

        ldy fe_mul_i
@load_src1:
        lda mul_src2_buf,y     ; PATCHED at proc entry: abs = src1 base
        ; CT: zero-skip `bne @nonzero_i / jmp @skip_zero` removed (L25).
        ; src1[i]==0 is handled by mul_dma_lo[0]==mul_dma_hi[0]==0 from
        ; reu_mul_init (same invariant that closes L12-L15). The DMA
        ; fetch below loads bank-2 row 0 (all zeros), so every body's
        ; `adc mul_dma_*,y` adds 0 with no carry. Body runs as no-op.

        ; DMA the multiplication row for src1[i] from REU (inlined).
        ; A already holds src1[i]; mul_cached_a store removed (dead in fe_mul).
        asl                    ; A = multiplier * 2, carry = bit 7
        sta reu_reu_hi
        lda #0
        adc #0                 ; bank = carry from shift
        sta reu_reu_bank
        lda #%10110001         ; execute + autoload + FETCH (REU->C64)
        sta reu_command

        ; Self-mod: patch accumulation addresses to base = fe_wide + i
        ; fe_wide is in zero page ($40..$7F) so we only patch the ZP operand byte.
        ; Patch ALL FOUR copies of the unrolled inner loop.
        lda #<(fe_wide)
        clc
        adc fe_mul_i           ; A = (fe_wide + i) & $ff  (stays in $40..$5F)
        sta @accum_ld1+1
        sta @accum_st1+1
        sta @accum_ld1_b+1
        sta @accum_st1_b+1
        sta @accum_ld1_c+1
        sta @accum_st1_c+1
        sta @accum_ld1_d+1
        sta @accum_st1_d+1
        ; For +1 accesses (high byte of product) AND chain-step targets,
        ; base = fe_wide + i + 1. Chain ld/st sites address fe_wide[(i+1)+X]
        ; where X is the threaded body cursor (j+1 for body A, j+2 for B,
        ; j+3 for C, j+4 for D - all post-inx values).
        clc
        adc #1
        sta @accum_ld2+1
        sta @accum_st2+1
        sta @accum_ld2_b+1
        sta @accum_st2_b+1
        sta @accum_ld2_c+1
        sta @accum_st2_c+1
        sta @accum_ld2_d+1
        sta @accum_st2_d+1
        sta @chain_a_ld+1
        sta @chain_a_st+1
        sta @chain_b_ld+1
        sta @chain_b_st+1
        sta @chain_c_ld+1
        sta @chain_c_st+1
        sta @chain_d_ld+1
        sta @chain_d_st+1

        ldx #0                 ; X = j, kept in register

        ; ===== UNROLLED 4x INNER LOOP =====
        ; X register holds j throughout, avoiding ZP load/store.
        ; Direct DMA table accumulation (no ZP intermediaries).
        ;
        ; Carry invariant: C=0 on every entry to @mul_inner. The back-branch
        ; `bcc @mul_inner` after `cpx #32` keeps C=0 when the loop continues
        ; (X<32 -> cpx clears C). Initial entry falls through with C=0 from
        ; the `adc #1` patch step (A = fe_wide+i+1 <= $60, never overflows).
        ; Each chain step ends with `lda #0 / adc #0 / sta mul_pending` -
        ; that final `adc #0` always produces C=0 (max 0+0+1=1, no overflow).
        ; So C=0 is preserved across body->body within a single @mul_inner pass.
@mul_inner:
        ; --- Body A: process src2[j] ---
@ldy_src2_a:
        ldy mul_src2_buf,x     ; patched to direct src2 addr
        ; CT: zero-skip `beq @next_j_first` removed (Phase 5 / L12).
        ; y=0 is handled by mul_dma_lo[0]==mul_dma_hi[0]==0 (adds 0, no carry).
@accum_ld1:
        lda fe_wide,x          ; patched to fe_wide+i base
        adc mul_dma_lo,y
@accum_st1:
        sta fe_wide,x
@accum_ld2:
        lda fe_wide+1,x        ; patched to fe_wide+i+1 base
        adc mul_dma_hi,y
@accum_st2:
        sta fe_wide+1,x
        ; --- Phase-6 chain step: body A (L26 closure) ---
        ; Replaces `bcs @do_prop_a / @next_j_first: inx` with an unconditional
        ; chain step that captures body A's carry-out, folds the prior
        ; mul_pending bit, advances cursor X = j+1, and writes the combined
        ; carry into fe_wide[(i+1)+(j+1)] = fe_wide[i+j+2] via SMC. New
        ; mul_pending = overflow bit from that adc. No phantom guard needed
        ; for body A: max chain target at i=31 is (31+1)+(28+1) = 61 < 64.
        lda #0
        adc #0                 ; A = body A's combined carry (0 or 1); C_out=0
        clc                    ; redundant (C=0 from above); kept for clarity
        adc mul_pending        ; A <= 2; C_out = 0 (max 1+1+0 = 2 < 256)
        inx                    ; X = j+1 -> fe_wide+1,X targets [i+j+2]
@chain_a_ld:
        adc fe_wide+1,x        ; SMC: operand = <fe_wide+i+1>
@chain_a_st:
        sta fe_wide+1,x        ; SMC: operand = <fe_wide+i+1>
        lda #0
        adc #0                 ; new pending = overflow from chain adc; C_out=0
        sta mul_pending

        ; --- Body B: process src2[j+1] ---
@ldy_src2_b:
        ldy mul_src2_buf,x
        ; CT: zero-skip `beq @next_j_second` removed (Phase 5 / L13).
@accum_ld1_b:
        lda fe_wide,x
        adc mul_dma_lo,y
@accum_st1_b:
        sta fe_wide,x
@accum_ld2_b:
        lda fe_wide+1,x
        adc mul_dma_hi,y
@accum_st2_b:
        sta fe_wide+1,x
        ; --- Phase-6 chain step: body B (L26 closure) ---
        ; X enters body B at j+1. Post-inx X = j+2 -> target fe_wide[i+j+3].
        ; No phantom: max target at i=31 is 32 + (28+2) = 62 < 64.
        lda #0
        adc #0
        clc
        adc mul_pending
        inx                    ; X = j+2 -> fe_wide+1,X targets [i+j+3]
@chain_b_ld:
        adc fe_wide+1,x
@chain_b_st:
        sta fe_wide+1,x
        lda #0
        adc #0
        sta mul_pending

        ; --- Body C: process src2[j+2] ---
@ldy_src2_c:
        ldy mul_src2_buf,x
        ; CT: zero-skip `beq @next_j_third` removed (Phase 5 / L14).
@accum_ld1_c:
        lda fe_wide,x
        adc mul_dma_lo,y
@accum_st1_c:
        sta fe_wide,x
@accum_ld2_c:
        lda fe_wide+1,x
        adc mul_dma_hi,y
@accum_st2_c:
        sta fe_wide+1,x
        ; --- Phase-6 chain step: body C (L26 closure) ---
        ; X enters body C at j+2. Post-inx X = j+3 -> target fe_wide[i+j+4].
        ; No phantom: max target at i=31 is 32 + (28+3) = 63 < 64.
        lda #0
        adc #0
        clc
        adc mul_pending
        inx                    ; X = j+3 -> fe_wide+1,X targets [i+j+4]
@chain_c_ld:
        adc fe_wide+1,x
@chain_c_st:
        sta fe_wide+1,x
        lda #0
        adc #0
        sta mul_pending

        ; --- Body D: process src2[j+3] ---
@ldy_src2_d:
        ldy mul_src2_buf,x
        ; CT: zero-skip `beq @next_j` removed (Phase 5 / L15).
@accum_ld1_d:
        lda fe_wide,x
        adc mul_dma_lo,y
@accum_st1_d:
        sta fe_wide,x
@accum_ld2_d:
        lda fe_wide+1,x
        adc mul_dma_hi,y
@accum_st2_d:
        sta fe_wide+1,x
        ; --- Phase-6 chain step: body D with phantom guard (L26 closure) ---
        ; X enters body D at j+3. Post-inx X = j+4. Chain target
        ; fe_wide[(i+1)+(j+4)] = fe_wide[i+j+5]. Out of bounds when
        ; i+j+5 >= 64. Last iteration j=28; max target = i+33. Triggers
        ; only at i=31 (target = 64). Phantom guard:
        ;   cpx mul_bound  ; mul_bound = 63 - i
        ;   bcs skip       ; X >= 63-i  iff (i+1)+X >= 64
        ; cpx clobbers C, so we explicitly `clc` after the bcs (fall-through
        ; path). Skip path drops the carry write (mathematically zero -
        ; product of two 32-byte values fits in 64 bytes; fe_wide[64] is
        ; phantom) and resets mul_pending.
        lda #0
        adc #0
        clc
        adc mul_pending
        inx                    ; X = j+4 -> fe_wide+1,X targets [i+j+5]
        cpx mul_bound          ; public guard: X >= 63-i -> out of fe_wide
        bcs @body_d_chain_skip ; only i=31 last iteration (j=28) ever takes this
        clc                    ; restore C=0 after cpx (cpx clobbers C)
@chain_d_ld:
        adc fe_wide+1,x        ; SMC: operand = <fe_wide+i+1>
@chain_d_st:
        sta fe_wide+1,x        ; SMC: operand = <fe_wide+i+1>
        lda #0
        adc #0
        sta mul_pending
        jmp @body_d_chain_done
@body_d_chain_skip:
        ; Phantom slot (i=31, j=28, X=32): drop the (always-zero) carry;
        ; clear mul_pending so end-of-inner ripple has nothing to flush.
        ; End-of-inner computes mul_ripple_start = (i+1) + X = 32+32 = 64
        ; -> count = 64-64 = 0 -> public skip of the ripple loop.
        lda #0
        sta mul_pending
@body_d_chain_done:

        ; Loop control: exit when X (= j+4 post-body-D-chain-inx) reaches 32.
        ; cpx clobbers C; on the loop-continue path (X<32, C=0 from cpx) we
        ; bypass the bcs and jmp back, leaving C=0 on entry to @mul_inner
        ; (preserving the body's `adc mul_dma_lo,y` carry-in invariant).
        ; Branch reversed (bcs @done / jmp @top) because the unrolled loop
        ; body is too large for an 8-bit relative back-branch to reach
        ; @mul_inner directly. The jmp is a 3-byte absolute, no range issue.
        cpx #32
        bcs @mul_inner_done
        jmp @mul_inner
@mul_inner_done:
        ; fall through to end-of-inner ripple

        ; --- Phase-6 end-of-inner ripple (L26 closure) ---
        ; Replaces the four @do_prop_X / @prop_carry_X / @carry_done_X blocks.
        ; Flushes any residual mul_pending bit forward from
        ; mul_ripple_start = (i+1) + X (where X = j_last+4 = 32, post-chain)
        ; through fe_wide[63]. Count = 64 - mul_ripple_start, derived from
        ; public state (fe_mul_i and the public X=32 loop terminator) - no
        ; secret-dependent branch.
        ;
        ; Cascade primitive: `inx / dey / bne` (NOT `cpx / bcc` - cpx
        ; clobbers C and would break the carry chain mid-ripple, which is
        ; the exact v0.1.0 bug pattern at fe_reduce_wide @prop2 that
        ; tools/test_fe_reduce_wide_carry.py is a permanent regression for).
        ;
        ; When mul_pending == 0, every iteration: A=0, C=0, adc fe_wide,x
        ; yields fe_wide[x] (no change), C=0. Loop runs same #iterations as
        ; the mul_pending==1 path -> CT-equivalent. When mul_pending == 1,
        ; the +1 propagates with carry chain until a non-$FF byte stops it.
        txa                    ; X = j_last+4 = 32 (or skip-preserved 32)
        clc
        adc fe_mul_i
        clc
        adc #1                 ; A = (i+1) + X = mul_ripple_start
        sta mul_ripple_start
        tax                    ; X = ripple_start (public-derived)
        lda #64
        sec
        sbc mul_ripple_start   ; A = 64 - start; C=0 if start > 64
        bcc @mul_ripple_done   ; start>64 (defensive; phantom edge): public skip
        tay                    ; Y = count in [0, 63]
        beq @mul_ripple_done   ; count == 0 (i=31 phantom): public skip
        lda mul_pending
        clc
@mul_ripple:
        adc fe_wide,x
        sta fe_wide,x
        lda #0
        inx
        dey
        bne @mul_ripple
@mul_ripple_done:

        inc fe_mul_i
        lda fe_mul_i
        cmp #32
        bcs @mul_done
        jmp @mul_outer
@mul_done:

        ; 4. Reduce mod p
        jsr fe_reduce_wide

        ; Copy result to (fe25519_dst)
        ldy #31
@copy_result:
        lda fe_wide,y
        sta (fe25519_dst),y
        dey
        bpl @copy_result

        ; NOTE: fe25519_reduce_final removed from fe25519_mul - callers that need
        ; canonical [0,p) output must call fe25519_reduce_final explicitly.
        rts
.endproc


; =============================================================================
; fe_reduce_wide - Reduce fe_wide[0..63] mod p into fe_wide[0..31]
;
; fe_wide[32..63] * 38 + fe_wide[0..31], with second pass for overflow.
; Clobbers: A, X, Y
; =============================================================================
.proc fe_reduce_wide
        ; First pass: fe_wide[0..31] += fe_wide[32..63] * 38
        ;
        ; CT closure (P7-D3, L27a-f): the body runs unconditionally for every
        ; byte. The former `beq @reduce1_zero` early-out leaked the Hamming
        ; weight of the upper half (fe_wide[32..63]) through dispatch timing.
        ; Safety relies on the data.s invariant that mul38_lo_tab[0] = 0 and
        ; mul38_hi_tab[0] = 0, so a Y=0 lookup is a true no-op for the
        ; product term (only the running fe_carry is folded in).
        ;
        ; Likewise, the secondary @reduce1_check / @prop2 / @prop3 carry
        ; cascade is replaced with two unconditional public-count cascades
        ; that always execute to completion. The cascade primitive is
        ; `inx / dey / bne` (NOT `cpx / bcc`). cpx clobbers the carry flag,
        ; which is the v0.1.0 carry-bug pattern preserved by
        ; tools/test_fe_reduce_wide_carry.py.
        lda #0
        sta fe_carry
        ldx #0
@reduce1:
        ldy fe_wide+32,x       ; Y = byte value (table index; may be 0)

        ; Add product (Y*38) + running carry to fe_wide[x] — unconditional.
        ; Y=0 path: mul38_lo_tab[0] = mul38_hi_tab[0] = 0 (data.s invariant),
        ; so the product term is zero and only fe_carry is folded in.
        clc
        lda mul38_lo_tab,y
        adc fe_carry
        sta fe_carry
        lda mul38_hi_tab,y
        adc #0
        sta fe_mul_j           ; high = product_hi + carry overflow

        clc
        lda fe_wide,x
        adc fe_carry
        sta fe_wide,x
        lda fe_mul_j
        adc #0
        sta fe_carry

        inx
        cpx #32
        bcc @reduce1
        ; Fall through unconditionally; X and the bound are public.

        ; --- Section B (folded): add fe_carry*38 into fe_wide[0..1] ---
        ; Always executed. fe_carry=0 case: mul38 tables yield 0, so this
        ; degenerates to a no-op on fe_wide[0..1] and produces C=0 to feed
        ; cascade #1 as a no-op. No branch on fe_carry value.
        ldy fe_carry
        clc
        lda fe_wide
        adc mul38_lo_tab,y
        sta fe_wide
        lda fe_wide+1
        adc mul38_hi_tab,y
        sta fe_wide+1

        ; --- Cascade #1 (unconditional): ripple C from section B through
        ; fe_wide[2..31]. 30 iterations, public count. Uses `inx / dey / bne`
        ; primitive — `cpx` would clobber C and break the chain
        ; (v0.1.0 carry-bug pattern; see test_fe_reduce_wide_carry.py). ---
        ldx #2
        ldy #30
@ucasc1:
        lda fe_wide,x
        adc #0
        sta fe_wide,x
        inx
        dey
        bne @ucasc1

        ; --- Section C (folded): capture cascade-1 residual carry (0 or 1)
        ; and fold via the existing mul38 table. Y in {0,1} maps to
        ; mul38_lo_tab[Y] in {0,38}; mul38_hi_tab[Y] = 0 in both cases, so
        ; cascade #2 picks up the ripple from byte 1 onward. ---
        lda #0
        adc #0                 ; A = 0 or 1 (cascade-1 residual)
        tay
        clc
        lda fe_wide
        adc mul38_lo_tab,y
        sta fe_wide

        ; --- Cascade #2 (unconditional): ripple C from section C through
        ; fe_wide[1..31]. 31 iterations, public count. Same `inx / dey / bne`
        ; primitive. ---
        ldx #1
        ldy #31
@ucasc2:
        lda fe_wide,x
        adc #0
        sta fe_wide,x
        inx
        dey
        bne @ucasc2

        rts
.endproc


; =============================================================================
; mul_by_38 - Multiply A by 38, result in poly_prod_hi:poly_prod_lo
;
; Uses shift-and-add: 38 = 32 + 4 + 2
; Input:  A = multiplicand (0-255)
; Output: poly_prod_lo/poly_prod_hi = A * 38 (16-bit, max 9690=$25DA)
; Clobbers: A, Y
; Preserves: X
; =============================================================================
.proc mul_by_38
        sta mul38_in           ; save input
        ; 16-bit shift register starts as A
        lda mul38_in
        sta mul38_lo
        lda #0
        sta mul38_hi

        ; shift left 1 -> A*2, add to prod
        asl mul38_lo
        rol mul38_hi
        lda mul38_lo
        sta poly_prod_lo
        lda mul38_hi
        sta poly_prod_hi       ; prod = A*2

        ; shift left 1 more -> A*4, add to prod
        asl mul38_lo
        rol mul38_hi           ; mul38 = A*4
        clc
        lda poly_prod_lo
        adc mul38_lo
        sta poly_prod_lo
        lda poly_prod_hi
        adc mul38_hi
        sta poly_prod_hi       ; prod = A*2 + A*4 = A*6

        ; shift left 3 more -> A*32, add to prod
        asl mul38_lo
        rol mul38_hi           ; A*8
        asl mul38_lo
        rol mul38_hi           ; A*16
        asl mul38_lo
        rol mul38_hi           ; A*32
        clc
        lda poly_prod_lo
        adc mul38_lo
        sta poly_prod_lo
        lda poly_prod_hi
        adc mul38_hi
        sta poly_prod_hi       ; prod = A*6 + A*32 = A*38
        rts

mul38_in:  .byte 0
mul38_lo:  .byte 0
mul38_hi:  .byte 0
.endproc


; =============================================================================
; fe25519_sqr - (fe25519_dst) = (fe25519_src1)^2 mod p
;
; Dedicated squaring: exploits symmetry a[i]*a[j] = a[j]*a[i].
; Uses mult66 indirect-indexed multiply + self-modifying accumulation
; (same technique as fe25519_mul). Cross terms added twice to fuse doubling.
; 1. Cross terms: accumulate 2*a[i]*a[j] for i < j  (inline mult66, shift-before-accum)
; 2. Diagonal: add a[i]^2 at position 2*i            (inline mult66)
; 3. Reduce mod p
;
; Clobbers: A, X, Y
; =============================================================================
.proc fe25519_sqr
        ; H2 defensive REU register init (mirrors S2 in x25519_scalarmult).
        ; Direct callers of public field ops must not be exposed to issue #33
        ; (caller-controlled $DF04/$DF0A residue silently corrupting DMA).
        lda #0
        sta reu_reu_lo            ; $DF04
        sta reu_addr_ctrl         ; $DF0A

        ; 1. Zero the 64-byte product buffer via REU DMA FETCH from bank 2
        jsr reu_clear_wide

        ; 2. Copy src1 to absolute buffer (src1==src2 for squaring)
        ldy #31
@copy_src:
        lda (fe25519_src1),y
        sta mul_src2_buf,y
        dey
        bpl @copy_src

        ; 3. (lmul0/lmul1 setup removed — branchless CT quarter-square
        ;     path uses abs,X (SMC-patched) + abs,Y, no indirect-indexed
        ;     loads remain.)

        ; 4. Cross terms with mult66 + self-mod, shift-before-accumulate
        lda #0
        sta fe_mul_i
@sqr_outer:
        ; Phase 6 CT: reset the pending-carry chain at the start of each
        ; outer-i. The chain threads a single 1-bit carry between adjacent
        ; bodies (see sqr_pending comment at end of proc). Must be 0 before
        ; the first body of this outer iteration.
        lda #0
        sta sqr_pending
        ldy fe_mul_i
        lda (fe25519_src1),y
        ; Phase 5b CT: no zero-skip on a[i]. Body runs unconditionally.
        ; When a[i]==0 the branchless quarter-square body yields 0 for every
        ; partial product, and the accumulate is a no-op (+0, no carry).
        sta mul_cached_a       ; cache a[i] for inner loop

        ; Hybrid path select: if i < SQR_DMA_K, use DMA path; else mult66 path
.if ::SQR_DMA_K
        ; Whole DMA-path dispatch block gated on SQR_DMA_K > 0. In the
        ; K=0 build (`make lib-x25519-1764`) reu_fetch_doubled_row is
        ; not imported (see top of file) and the proc body is gated
        ; out in x25519_init.s; this block must drop with it so the
        ; assembler doesn't emit a `jsr` to an undefined symbol.
        ; Functionally equivalent to leaving the block in place: for
        ; K=0, `cmp #0 / bcs` is always taken, so the DMA dispatch is
        ; dead at runtime anyway.
        lda fe_mul_i
        cmp #SQR_DMA_K
        bcs @sqr_use_mult66
        ; --- DMA path: fetch pre-doubled row for a = src[i] ---
        jsr reu_fetch_doubled_row
        ; patch trampoline to jump into DMA inner loop (body A)
        lda #<(@sqr_inner_dma)
        sta @sqr_inner_tramp+1
        lda #>(@sqr_inner_dma)
        sta @sqr_inner_tramp+2
        ; patch DMA inner's self-mod ld/st addresses (single-byte ZP patches)
        lda #<(fe_wide)
        clc
        adc fe_mul_i
        sta @sqr_dma_ld1+1
        sta @sqr_dma_st1+1
        sta @sqr_dma_ld1_b+1
        sta @sqr_dma_st1_b+1
        clc
        adc #1
        sta @sqr_dma_ld2+1
        sta @sqr_dma_st2+1
        sta @sqr_dma_ld2_b+1
        sta @sqr_dma_st2_b+1
        jmp @sqr_path_done
.endif  ; SQR_DMA_K
@sqr_use_mult66:
        ; patch trampoline back to mult66 inner loop
        lda #<(@sqr_inner)
        sta @sqr_inner_tramp+1
        lda #>(@sqr_inner)
        sta @sqr_inner_tramp+2
@sqr_path_done:

        ; Self-mod: patch accumulation addresses to base = fe_wide + i
        ; fe_wide in zero page ($40..$7F) — patch only the ZP operand byte.
        ; Patched for body A and body B — both use same base.
        lda #<(fe_wide)
        clc
        adc fe_mul_i           ; A = (fe_wide + i) & $ff
        sta @sqr_accum_ld1+1
        sta @sqr_accum_st1+1
        sta @sqr_accum_ld1_b+1
        sta @sqr_accum_st1_b+1
        ; For +1 accesses (high byte of product) AND chain-step cursor reads/writes.
        ; Phase 3: @sqr_*_chain_ld/st share the same <fe_wide+i+1> base as
        ; @sqr_accum_ld2/st2 — they read/write fe_wide[(i+1)+X] where X is the
        ; threaded body cursor (= j+1 for body A chain, j+2 for body B chain).
        clc
        adc #1
        sta @sqr_accum_ld2+1
        sta @sqr_accum_st2+1
        sta @sqr_accum_ld2_b+1
        sta @sqr_accum_st2_b+1
        sta @sqr_a_chain_ld+1
        sta @sqr_a_chain_st+1
        sta @sqr_b_chain_ld+1
        sta @sqr_b_chain_st+1
        sta @sqr_dma_a_chain_ld+1
        sta @sqr_dma_a_chain_st+1
        sta @sqr_dma_b_chain_ld+1
        sta @sqr_dma_b_chain_st+1

        ; (No per-outer lmul0/lmul1 feed — CT body computes sum/diff inline.)

        ; j starts at i+1
        lda fe_mul_i
        clc
        adc #1
        sta fe_mul_j

        ; Compute pair count = ceil((31-i)/2) = (32-i)/2.
        ; When actual length L is odd, the last "pair" does body B on the
        ; phantom slot j=32; mul_src2_buf[32] is zero-padded so that body B
        ; takes the Y==0 fast-skip path and performs no work.
        ; Pair count is always >= 1 for i in 0..30, so no empty-check needed.
        lda #32
        sec
        sbc fe_mul_i           ; A = 32 - i
        lsr                    ; A = ceil((31-i)/2)
        sta fe_sqr_pairs       ; pair counter (in ZP)

        ; Phase 3 (v0.3.0): precompute public phantom-guard bound for body B
        ; chain step. sqr_bound = 63 - fe_mul_i; when body-B cursor X reaches
        ; this threshold, chain target (i+1)+X ≥ 64, so guard triggers.
        ; Only i=30 actually triggers this path. Public value; public cpx.
        lda #63
        sec
        sbc fe_mul_i           ; A = 63 - i
        sta sqr_bound

        jmp @sqr_inner_tramp   ; dispatch to mult66 or DMA unrolled pair loop

@sqr_inner:
        ; === Body A (branchless CT quarter-square) ===
        ; Unconditional: no zero-skip, no sign branch, no (zp),y loads.
        ; Mirrors src/mul_8x8.s Phase 1 rewrite.
        ; Phase 1 (v0.3.0): diff held in X across EOR/SBC chain (no ZP
        ; round-trip for sqr_diff); sum-page carry stays in the carry flag
        ; and the hi-table patch is derived from the lo-table patch via
        ; +2 (= >sqtab_hi - >sqtab_lo) rather than a second ADC sum_pg.
        ldx fe_mul_j
        lda mul_src2_buf,x     ; A = a[j]  (unconditional load)
        sta sqr_tmp_b          ; stash a[j] for sum computation below

        ; Branchless |a[i] - a[j]| via sign-mask. Diff kept in X, mask in
        ; ZP (eor/sbc require a mem operand; using X for diff avoids the
        ; sqr_diff round-trip entirely).
        sec
        sbc mul_cached_a       ; A = a[j] - a[i]; C = (a[j] >= a[i])
        tax                    ; X = diff (preserved across mask compute)
        lda #0
        sbc #0                 ; sign mask: $00 if C=1 else $ff
        sta sqr_mask
        txa                    ; A = diff
        eor sqr_mask
        sec
        sbc sqr_mask           ; A = |a[i] - a[j]|
        tay                    ; Y = |diff|  (abs,Y always page 0 of sqtab)

        ; Compute sum = a[i] + a[j]; sum-page carry rides the C flag
        ; directly into the patch compute — no sqr_sum_pg round-trip.
        lda mul_cached_a
        clc
        adc sqr_tmp_b          ; A = sum_lo, C = sum-page carry
        tax                    ; X = sum_lo (C preserved)

        ; Patch hi bytes of the two abs,X load sites (sum path).
        ; sqtab_lo/sqtab_hi are 512 bytes page-aligned: hi += page carry
        ; selects between page 0 and page 1 branchlessly. The hi-table
        ; base differs from the lo-table base by exactly 2 pages
        ; ($7800 vs $7A00), so we derive the hi patch from the lo patch
        ; with a constant +2.
        lda #>sqtab_lo
        adc #0                 ; A = >sqtab_lo + sum_pg (folds in C)
        sta @ct_sum_load_lo_a+2
        clc
        adc #2                 ; A = >sqtab_hi + sum_pg  (hi-lo = +2)
        sta @ct_sum_load_hi_a+2

        ; Straight-line sqtab[sum] - sqtab[|diff|]
@ct_sum_load_lo_a:
        lda sqtab_lo,x         ; hi byte PATCHED above
        sec
        sbc sqtab_lo,y
        sta poly_prod_lo
@ct_sum_load_hi_a:
        lda sqtab_hi,x         ; hi byte PATCHED above
        sbc sqtab_hi,y
        sta poly_prod_hi
        ; --- END CT quarter-square body A ---

@sqr_accum:
        ; Double the product (shift-before-accumulate replaces second addition)
        asl poly_prod_lo
        rol poly_prod_hi
        lda #0
        adc #0                 ; A = carry from ROL (0 or 1)
        sta poly_carry         ; save 17th bit

        ; Single addition of doubled product to fe_wide[i+j]
        ldx fe_mul_j

        clc
@sqr_accum_ld1:
        lda fe_wide,x          ; patched to fe_wide+i base
        adc poly_prod_lo
@sqr_accum_st1:
        sta fe_wide,x
@sqr_accum_ld2:
        lda fe_wide+1,x        ; patched to fe_wide+i+1 base
        adc poly_prod_hi
@sqr_accum_st2:
        sta fe_wide+1,x

        ; --- Phase 3 (v0.3.0) chain step: mult66 body A ---
        ; Phase 6 semantics preserved. X enters = j (from @sqr_accum's ldx).
        ; Threaded cursor: inx → X = j+1 so SMC @sqr_a_chain_*{ld,st} (base
        ; <fe_wide+i+1>) addresses fe_wide[(i+1)+(j+1)] = fe_wide[i+j+2],
        ; eliminating the per-body `lda fe_mul_i / adc fe_mul_j / adc #2`
        ; readdress (~13 cycles). sqr_tmp_b stash elided too (A is live).
        ; ripple_start write is dead in body A (body B always overwrites);
        ; dropped here — end-of-inner recomputes from fe_mul_i/fe_mul_j.
        ; Invariants 1–5 preserved; invariant 8 unchanged (no new branches).
        lda #0
        adc poly_carry         ; A = combined_A (uses C from prior adc_hi)
        clc
        adc sqr_pending        ; A ≤ 3, C = 0 (sum ≤ 3 < 256)
        inx                    ; X = j+1 → fe_wide+1,X points to [i+j+2]
@sqr_a_chain_ld:
        adc fe_wide+1,x        ; SMC: operand = <fe_wide+i+1>
@sqr_a_chain_st:
        sta fe_wide+1,x        ; SMC: operand = <fe_wide+i+1>
        lda #0
        adc #0
        sta sqr_pending        ; new overflow bit → chain
        inc fe_mul_j

        ; === Body B (branchless CT quarter-square, second unrolled copy) ===
        ; Same Phase 1 (v0.3.0) refactor as body A: diff in X, sum_pg in C,
        ; hi-patch derived from lo-patch via +2.
        ldx fe_mul_j
        lda mul_src2_buf,x     ; A = a[j]  (unconditional load)
        sta sqr_tmp_b

        sec
        sbc mul_cached_a       ; A = a[j] - a[i]; C = (a[j] >= a[i])
        tax                    ; X = diff (preserved across mask compute)
        lda #0
        sbc #0
        sta sqr_mask
        txa                    ; A = diff
        eor sqr_mask
        sec
        sbc sqr_mask           ; A = |a[i] - a[j]|
        tay                    ; Y = |diff|

        lda mul_cached_a
        clc
        adc sqr_tmp_b          ; A = sum_lo, C = page carry
        tax                    ; X = sum_lo (C preserved)

        lda #>sqtab_lo
        adc #0                 ; A = >sqtab_lo + sum_pg (folds in C)
        sta @ct_sum_load_lo_b+2
        clc
        adc #2                 ; A = >sqtab_hi + sum_pg  (hi-lo = +2)
        sta @ct_sum_load_hi_b+2

@ct_sum_load_lo_b:
        lda sqtab_lo,x
        sec
        sbc sqtab_lo,y
        sta poly_prod_lo
@ct_sum_load_hi_b:
        lda sqtab_hi,x
        sbc sqtab_hi,y
        sta poly_prod_hi
        ; --- END CT quarter-square body B ---

@sqr_accum_b:
        asl poly_prod_lo
        rol poly_prod_hi
        lda #0
        adc #0
        sta poly_carry

        ldx fe_mul_j

        clc
@sqr_accum_ld1_b:
        lda fe_wide,x
        adc poly_prod_lo
@sqr_accum_st1_b:
        sta fe_wide,x
@sqr_accum_ld2_b:
        lda fe_wide+1,x
        adc poly_prod_hi
@sqr_accum_st2_b:
        sta fe_wide+1,x

        ; --- Phase 3 (v0.3.0) chain step: mult66 body B ---
        ; Phase 6 semantics preserved. X enters = j' = j+1 (body B's j, from
        ; @sqr_accum_b's ldx). Threaded cursor: inx → X = j+2 so SMC
        ; @sqr_b_chain_*{ld,st} (base <fe_wide+i+1>) addresses
        ; fe_wide[(i+1)+(j+2)] = fe_wide[i+j+3] = body B's chain target.
        ; Phantom guard (invariant 7): only i=30 triggers body B chain target
        ; = 64 (out of bounds). Guard is `cpx sqr_bound` where
        ; sqr_bound = 63 - fe_mul_i (precomputed at outer-i top, public).
        ; cpx clobbers C, so we explicitly `clc` before the adc. Skip path
        ; forces sqr_pending = 0 (inv 5); end-of-inner recomputes ripple_start
        ; from fe_mul_i/fe_mul_j, yielding the phantom sentinel value 64.
        lda #0
        adc poly_carry         ; A = combined_B (uses C from prior adc_hi)
        clc
        adc sqr_pending        ; A ≤ 3, C = 0
        inx                    ; X = j+2 → fe_wide+1,X points to [i+j+3]
        cpx sqr_bound          ; public guard: X >= 63-i iff (i+1)+X >= 64
        bcs @sqr_b_chain_skip  ; only i=30 (phantom) ever takes this
        clc                    ; restore C=0 after cpx (cpx clobbers C)
@sqr_b_chain_ld:
        adc fe_wide+1,x        ; SMC: operand = <fe_wide+i+1>
@sqr_b_chain_st:
        sta fe_wide+1,x        ; SMC: operand = <fe_wide+i+1>
        lda #0
        adc #0
        sta sqr_pending
        jmp @sqr_b_chain_done
@sqr_b_chain_skip:
        ; Phantom slot (i=30, j=32): drop the carry write; reset pending.
        ; End-of-inner computes ripple_start = i+1+X = 31+33 = 64 → count=0.
        lda #0
        sta sqr_pending
@sqr_b_chain_done:
        inc fe_mul_j
        dec fe_sqr_pairs
        beq @sqr_pair_loop_exit_mul
@sqr_inner_tramp:
        jmp @sqr_inner         ; patched: @sqr_inner OR @sqr_inner_dma
@sqr_pair_loop_exit_mul:
        jmp @sqr_mult66_inner_done   ; Phase 6: end-of-inner ripple of
                                     ; residual pending carry (see below).

; --- Phase 6: mult66 end-of-inner ripple ---
; Runs once per outer-i for the mult66 path, after the last body B. The
; chain's residual `sqr_pending` bit (if any) lives at position
; `sqr_ripple_start` = last-body-overflow-position (= i+j_last+3). Always
; ripples from there forward to fe_wide[63]. The count is deterministic
; from fe_mul_i / fe_mul_j (public loop state) — no secret-dependent
; branch. When `sqr_pending == 0` every add is +0 (functional no-op).
; When `sqr_pending == 1` the ripple is equivalent to a `+1 with carry
; propagation` from the start position through [63].
;
; Phase 3 (v0.3.0): ripple_start is no longer written per body; it is
; recomputed here from X = j_last+2 (body B cursor) and fe_mul_i:
;   ripple_start = (i+1) + X
; For the phantom case (i=30, j_last=31), X = 33, so ripple_start = 64,
; which produces count=0 — matching the prior sentinel behaviour.
@sqr_mult66_inner_done:
        ; X = j_last + 2 (preserved from body B chain step, normal or skip)
        txa
        clc
        adc fe_mul_i
        clc
        adc #1                 ; A = (i+1) + X = i + j_last + 3 = ripple_start
        sta sqr_ripple_start
        tax                    ; X = ripple_start (public-derived)
        lda #64
        sec
        sbc sqr_ripple_start   ; A = 64 - start; C=0 if start > 64
        bcc @sqr_mult66_rip_done   ; start>64 (phantom edge): public skip
        tay                    ; Y = count ∈ [0,63]
        beq @sqr_mult66_rip_done   ; count==0 public skip
        lda sqr_pending
        clc
@sqr_mult66_rip:
        adc fe_wide,x
        sta fe_wide,x
        lda #0
        inx
        dey
        bne @sqr_mult66_rip
@sqr_mult66_rip_done:
        jmp @sqr_skip_i

; --- DMA inner loop (2x unrolled): pre-doubled product tables in mul_dma_lo/hi/carry ---
; X held as j across both bodies; only reloaded from fe_mul_j on entry.
; Back-branch jumps to @sqr_dma_body_a (after the initial ldx) so X is preserved.
@sqr_inner_dma:
        ldx fe_mul_j
@sqr_dma_body_a:
        ; === Body A (DMA) ===
        ; Phase 5b CT: no zero-skip on a[j]. The doubled row is indexed by
        ; a[j], and row[0] = 2*a[i]*0 = 0 (lo=hi=carry=0 — see
        ; reu_mul_init dbl_gen loop in x25519_init.s:108-121). So Y==0 adds
        ; zero into fe_wide and produces no carry; body is a functional no-op.
        ldy mul_src2_buf,x     ; Y = a[j]
        lda mul_dma_carry,y
        sta poly_carry
        clc
@sqr_dma_ld1:
        lda fe_wide,x          ; patched: fe_wide+i, X = j
        adc mul_dma_lo,y
@sqr_dma_st1:
        sta fe_wide,x
@sqr_dma_ld2:
        lda fe_wide+1,x        ; patched: fe_wide+i+1
        adc mul_dma_hi,y
@sqr_dma_st2:
        sta fe_wide+1,x
        lda #0
        adc poly_carry         ; A = combined_A (accum + 17th-bit)
        ; --- Phase 3 (v0.3.0) chain step: DMA body A ---
        ; Phase 6 semantics preserved. X enters = j (from body A accum, still
        ; alive since DMA's CT body doesn't clobber X after the `sta fe_wide+1,x`).
        ; Threaded cursor: inx → X = j+1 so SMC @sqr_dma_a_chain_*{ld,st}
        ; (base <fe_wide+i+1>) addresses fe_wide[(i+1)+(j+1)] = fe_wide[i+j+2].
        ; Eliminates the stx fe_mul_j / ldx fe_mul_j save-restore (X stays
        ; alive as j+1 = body B's j). ripple_start write dropped (dead).
        ; No new branches; invariant 8 preserved.
        clc
        adc sqr_pending        ; A ≤ 3, C = 0
        inx                    ; X = j+1 → fe_wide+1,X points to [i+j+2]
@sqr_dma_a_chain_ld:
        adc fe_wide+1,x        ; SMC: operand = <fe_wide+i+1>
@sqr_dma_a_chain_st:
        sta fe_wide+1,x        ; SMC: operand = <fe_wide+i+1>
        lda #0
        adc #0
        sta sqr_pending        ; new overflow → pending chain
        ; X = j+1 now = body B's j. No inx/save/restore needed.

        ; === Body B (DMA, second unrolled copy) ===
        ; Phase 5b CT: no zero-skip on a[j] (see Body A comment above).
        ldy mul_src2_buf,x     ; Y = a[j]
        lda mul_dma_carry,y
        sta poly_carry
        clc
@sqr_dma_ld1_b:
        lda fe_wide,x
        adc mul_dma_lo,y
@sqr_dma_st1_b:
        sta fe_wide,x
@sqr_dma_ld2_b:
        lda fe_wide+1,x
        adc mul_dma_hi,y
@sqr_dma_st2_b:
        sta fe_wide+1,x
        lda #0
        adc poly_carry         ; A = combined_B
        ; --- Phase 3 (v0.3.0) chain step: DMA body B ---
        ; Phase 6 semantics preserved. X enters = j' = j+1 (body B's j).
        ; Threaded cursor: inx → X = j+2 so SMC @sqr_dma_b_chain_*{ld,st}
        ; (base <fe_wide+i+1>) addresses fe_wide[(i+1)+(j+2)] = fe_wide[i+j+3].
        ; No phantom guard: DMA path runs only for i < SQR_DMA_K (=22), and
        ; body B chain target = i+j+3 ≤ 21 + 33 = 54 < 64 always.
        ; After chain: X = j+2 = next pair iteration's body A j. No reload.
        ; ripple_start write dropped (recomputed at inner_done from X/fe_mul_i).
        clc
        adc sqr_pending        ; A ≤ 3, C = 0
        inx                    ; X = j+2 → fe_wide+1,X points to [i+j+3]
@sqr_dma_b_chain_ld:
        adc fe_wide+1,x        ; SMC: operand = <fe_wide+i+1>
@sqr_dma_b_chain_st:
        sta fe_wide+1,x        ; SMC: operand = <fe_wide+i+1>
        lda #0
        adc #0
        sta sqr_pending
        ; X = j+2 = next pair iteration's body A j.
        dec fe_sqr_pairs
        beq @sqr_dma_inner_done
        jmp @sqr_dma_body_a    ; preserves X across iterations; long jmp
@sqr_dma_inner_done:
        ; --- Phase 6: DMA end-of-inner ripple ---
        ; Same purpose as @sqr_mult66_inner_done: flush any residual
        ; pending-carry bit from this outer-i forward to fe_wide[63].
        ;
        ; Phase 3 (v0.3.0): ripple_start recomputed from X = j_last+2 and
        ; fe_mul_i; no per-body write. Note DMA path only runs for
        ; i < SQR_DMA_K = 22, so phantom (i=30) never reaches here — but
        ; the same formula would yield ripple_start = 64 if it did.
        txa                    ; X = j_last+2 (body B cursor post-chain-step)
        clc
        adc fe_mul_i
        clc
        adc #1                 ; A = (i+1) + X = ripple_start
        sta sqr_ripple_start
        tax
        lda #64
        sec
        sbc sqr_ripple_start
        bcc @sqr_dma_rip_done
        tay
        beq @sqr_dma_rip_done
        lda sqr_pending
        clc
@sqr_dma_rip:
        adc fe_wide,x
        sta fe_wide,x
        lda #0
        inx
        dey
        bne @sqr_dma_rip
@sqr_dma_rip_done:
        jmp @sqr_skip_i        ; fe_mul_j not needed beyond inner loop

@sqr_skip_i:
        inc fe_mul_i
        lda fe_mul_i
        cmp #31                ; i goes 0..30 (j needs room for i+1)
        bcs @sqr_cross_done
        jmp @sqr_outer
@sqr_cross_done:

        ; 5. Add diagonal terms: a[i]^2 at position 2*i (precomputed sqr tables)
        lda #0
        sta fe_mul_i
; ---------------------------------------------------------------------
; CT invariants for the diagonal carry path (post @diag_prop audit,
; 2026-04-19). Previously out of Phase-6 L19–L22 scope; now closed by
; an unconditional structure analogous to the cross-term chain.
;
;   D1.  Runs unconditionally per public outer-i ∈ [0,31]. No
;        zero-skip on secret a[i] (sqr_lo[0] = sqr_hi[0] = 0 by
;        construction, so `a[i]=0` yields a functional no-op add).
;   D2.  The 16-bit diag add writes fe_wide[2*i] / fe_wide[2*i+1]
;        unconditionally. Any overflow bit (∈ {0,1}) is captured
;        into register A via `lda #0 / adc #0` — no branch on C.
;   D3.  The forward ripple is an unconditional `dey/bne` loop whose
;        count is `62 - 2*i` (public), running from fe_wide[2*i+2]
;        through fe_wide[63]. When `2*i+2 = 64` (only i=31), the
;        count is 0 and the loop body runs zero times.
;   D4.  No interaction with Phase 6 sqr_pending: the diagonal
;        section runs AFTER `@sqr_cross_done`, i.e. after the
;        cross-term end-of-inner ripple flushed any residual
;        pending bit out to fe_wide[63]. sqr_pending is dead at
;        this point and is reused only as a per-iteration scratch.
;   D5.  No `(zp),y` with secret Y: the only indirect load is
;        `lda (fe25519_src1),y` with Y = fe_mul_i (public index).
;        Indirect base fe25519_src1 is a public pointer (set by the
;        caller, not secret data).
;
; All branches in the diagonal section now depend only on public
; counters (fe_mul_i, loop count Y derived from 64 - (2*i+2)).
; ---------------------------------------------------------------------
@diag_outer:
        ; Unconditional body: no zero-skip on a[i] (D1).
        ldy fe_mul_i
        lda (fe25519_src1),y   ; Y = fe_mul_i (public); pointer is public
        tay                    ; Y = a[i]
        lda sqr_lo,y           ; sqr_lo[0] = 0 → add-zero no-op when a[i]=0
        sta poly_prod_lo
        lda sqr_hi,y           ; sqr_hi[0] = 0 likewise
        sta poly_prod_hi

        ; Add poly_prod to fe_wide[2*i..2*i+1] unconditionally.
        lda fe_mul_i
        asl                    ; A = 2*i (public)
        tax

        clc
        lda fe_wide,x
        adc poly_prod_lo
        sta fe_wide,x
        inx                    ; X = 2*i+1
        lda fe_wide,x
        adc poly_prod_hi
        sta fe_wide,x

        ; Capture carry-out into register A as a 0/1 byte, no branch (D2).
        lda #0
        adc #0                 ; A = C_in ∈ {0,1}; C now = 0
        sta sqr_pending        ; stash pending (reuse Phase-6 scratch;
                               ; cross-term chain is dead at this point — D4)

        ; Start of ripple window = 2*i+2. Count = 64 - (2*i+2) = 62 - 2*i.
        ; Both derive from the public loop counter fe_mul_i (D3).
        inx                    ; X = 2*i+2 (public)
        lda #64
        stx sqr_ripple_start
        sec
        sbc sqr_ripple_start   ; A = 64 - (2*i+2); C=0 iff start > 64
        bcc @diag_rip_done     ; public guard: i=31 edge (phantom slot)
        beq @diag_rip_done     ; count==0 → no ripple this iter (public)
        tay                    ; Y = count ∈ [1, 62]
        lda sqr_pending        ; A = pending carry (0 or 1)
        clc
@diag_rip:
        adc fe_wide,x          ; pending (+ prior carry) into fe_wide[x]
        sta fe_wide,x
        lda #0                 ; subsequent adds contribute only carry
        inx
        dey
        bne @diag_rip          ; public count-driven exit

@diag_rip_done:
        inc fe_mul_i
        lda fe_mul_i
        cmp #32
        bcs @sqr_reduce
        jmp @diag_outer

@sqr_reduce:
        ; 6. Reduce mod p (same as fe25519_mul)
        jsr fe_reduce_wide

        ; Copy result to (fe25519_dst)
        ldy #31
@copy_result:
        lda fe_wide,y
        sta (fe25519_dst),y
        dey
        bpl @copy_result

        ; NOTE: fe25519_reduce_final removed from fe25519_sqr — callers that need
        ; canonical [0,p) output must call fe25519_reduce_final explicitly.
        rts

; --- CT quarter-square scratch (local to fe25519_sqr) ---
sqr_diff:   .byte 0
sqr_mask:   .byte 0
sqr_sum_pg: .byte 0
sqr_tmp_b:  .byte 0
; --- Phase 3 (v0.3.0) chain-step cursor helpers ---
;     sqr_bound — public: 63 - fe_mul_i. Used by body B's phantom guard
;                 (cpx sqr_bound / bcs @skip). Only i=30 triggers the skip
;                 (body B chain target = 64, out of fe_wide[0..63]).
;                 cpx clobbers C, so the chain step's own `clc` before
;                 the adc site restores C=0 after the guard.
sqr_bound:  .byte 0
; --- Phase 6 CT carry-chain scratch:
;     sqr_pending — 0 or 1, the overflow bit threaded between consecutive
;                   body carry-steps within a single outer-i iteration.
;                   Reset to 0 at top of each outer-i. Body A's pending
;                   is added into body B's combined carry add (target
;                   [i+j+3] == body A's overflow position); similarly
;                   body B's pending flows into the next pair body A's
;                   combined carry add. At end of inner loop, any residual
;                   pending is rippled forward to fe_wide[63].
;     sqr_ripple_start — position at which the end-of-inner ripple begins
;                   (last carry target + 1). Updated by each body's carry
;                   step. Read once at end of inner loop.
; Both are pure public-state bookkeeping (depend only on i,j and the
; carry chain — not on branch decisions).
sqr_pending:       .byte 0
sqr_ripple_start:  .byte 0
.endproc


; =============================================================================
; fe25519_mul_a24 - (fe25519_dst) = (fe25519_src1) * 121665 mod p
;
; 121665 = $01DB41 (3 bytes LE: $41, $DB, $01)
; Clobbers: A, X, Y
; =============================================================================
.proc fe25519_mul_a24
        ; ---------------------------------------------------------------
        ; CT closure for L28a-k (P7-D4):
        ;   Outer-i loop: drop the `beq @skip_zero_a24` (L28a) and the
        ;   `bcc/inc/inc` 2-byte cascade (L28b/L28c). Body runs
        ;   unconditionally; safety relies on a24_b{0,1,2,3}[0] = 0
        ;   (verified in src/data.s — `.repeat 256, i / .byte <(121665*i)`
        ;   has all-zero entries for i=0). The 2-byte cascade is replaced
        ;   with two unconditional `adc #0` absorptions at fe_wide+i+4 and
        ;   fe_wide+i+5. Magnitude argument: at the start of iteration i,
        ;   the partial sum S_{i-1} = sum_{j<i} 121665*src1[j]*256^j is
        ;   bounded by 121665*256^i < 2^(8i+17), so bits 8(i+4)..
        ;   8(i+5)+7 of S_{i-1} are all zero, i.e. fe_wide+i+4 = 0 and
        ;   fe_wide+i+5 = 0 entering iteration i. The 4-byte add adds at
        ;   most 2^25 starting at byte i, with at most 1 carry into
        ;   fe_wide+i+4. With fe_wide+i+4 = 0 entering, that absorption
        ;   leaves fe_wide+i+4 ∈ {0,1} and C=0; subsequent absorption at
        ;   fe_wide+i+5 (also 0) is a no-op. So the unconditional 2-byte
        ;   cascade always fully absorbs the iteration's carry-out without
        ;   loss, deterministically.
        ;
        ;   Reduction stages (L28d-k): three stages execute unconditionally
        ;   (mul38_lo_tab[0] = mul38_hi_tab[0] = 0 invariant makes the
        ;   secret-byte-zero case a no-op without a `beq` dispatch). Each
        ;   stage's main 2-byte add is followed by a `lda #0/adc #0/sta
        ;   fe_carry` to capture the residual carry into fe_carry; before
        ;   the next stage's main add, the prior fe_carry is folded into
        ;   the byte AT THE CORRECT POSITION via `clc/lda/adc fe_carry/sta`,
        ;   then re-captured. After all 3 stages, a final
        ;   `inx/dey/bne` ripple from byte 5 to byte 31 absorbs any
        ;   remaining residual through the high bytes. (`inx/dey/bne` —
        ;   NOT `cpx/bcc`, since cpx clobbers C, breaking the carry chain;
        ;   this is the v0.1.0 carry-bug pattern in fe_reduce_wide.)
        ; ---------------------------------------------------------------

        ; Zero fe_wide[0..36] - widened by 2 vs. the pre-L28 path so the
        ; unconditional 2-byte cascade at iteration i=31 (which writes
        ; fe_wide+35, fe_wide+36 = $63, $64) lands on zero scratch.
        ; fe_wide is the 64-byte ZP buffer at $40-$7F (src/constants.s),
        ; well within range.
        ; H2 defensive REU register init (mirrors S2 in x25519_scalarmult).
        ; Direct callers of public field ops must not be exposed to issue #33
        ; (caller-controlled $DF04/$DF0A residue silently corrupting DMA).
        lda #0
        sta reu_reu_lo            ; $DF04
        sta reu_addr_ctrl         ; $DF0A

        ldx #36
        lda #0
@zero:
        sta fe_wide,x
        dex
        bpl @zero

        ldx #0                 ; i = 0
@outer:
        stx fe_mul_i

        ; --- L28a-c closure: unconditional outer-i body ---
        ldy fe_mul_i
        lda (fe25519_src1),y
        tay                    ; Y = src1[i]; tables[0]=0 if zero (L28a safe)

        ; fe_wide[i..i+3] += 121665 * src1[i]  (4-byte product via table).
        ; Body is unconditional; for src1[i]=0 the four `adc a24_bN,y` add
        ; zero and the 2-byte cascade simply re-stores zero bytes.
        ldx fe_mul_i
        clc
        lda fe_wide,x
        adc a24_b0,y
        sta fe_wide,x
        lda fe_wide+1,x
        adc a24_b1,y
        sta fe_wide+1,x
        lda fe_wide+2,x
        adc a24_b2,y
        sta fe_wide+2,x
        lda fe_wide+3,x
        adc a24_b3,y
        sta fe_wide+3,x
        ; --- L28b/c closure: unconditional 2-byte cascade ---
        lda fe_wide+4,x        ; cascade absorption step 1
        adc #0
        sta fe_wide+4,x
        lda fe_wide+5,x        ; cascade absorption step 2
        adc #0
        sta fe_wide+5,x
        ; (See header magnitude argument: fe_wide+i+4 = fe_wide+i+5 = 0 at
        ;  iteration entry, so the C-out from step 2 is always 0 and
        ;  dropping it is correctness-preserving.)

        ldx fe_mul_i
        inx
        cpx #32                ; CPX on PUBLIC loop index — CT-clean
        bcc @outer

        ; --- L28d-k closure: 3 reduction stages with fe_carry threading ---
        ; Stage K's main carry-out is owed to byte (K+1) (the byte just
        ; above the main add range). Naïve `clc` between stages drops it,
        ; so we save into fe_carry, fold positionally before the next
        ; stage's main, and absorb the final residual via end-of-reduction
        ; ripple. Pattern mirrors fe_reduce_wide's @ucasc1/@ucasc2 closure
        ; (P7-D3 / L27a-f): unconditional bodies, fe_carry-threaded
        ; pending bit, public-count `inx/dey/bne` ripple.

        ; Initialize fe_carry = 0 (no pending into byte 2 yet).
        lda #0
        sta fe_carry

        ; ---- Stage 1: fe_wide[0..1] += 38 * fe_wide+32 ----
        ; mul38_lo_tab[0] = mul38_hi_tab[0] = 0 (data.s invariant), so
        ; fe_wide+32=0 makes this stage a functional no-op without a
        ; `beq` early-exit (closes L28d).
        ldy fe_wide+32
        lda mul38_lo_tab,y
        sta poly_prod_lo
        lda mul38_hi_tab,y
        sta poly_prod_hi
        clc
        lda fe_wide
        adc poly_prod_lo
        sta fe_wide
        lda fe_wide+1
        adc poly_prod_hi
        sta fe_wide+1
        ; Capture stage 1's main carry-out (positionally at byte 2) into
        ; fe_carry. fe_carry was 0 entering, so A = 0 + 0 + C = C ∈ {0,1}.
        lda fe_carry
        adc #0
        sta fe_carry

        ; ---- Bridge before Stage 2: fold fe_carry into fe_wide+2 ----
        ; The prior fe_carry is owed to byte 2 (stage 1 main's C-out).
        ; Add it now so the byte is positionally correct before stage 2's
        ; main add reads fe_wide+2.
        clc
        lda fe_wide+2
        adc fe_carry
        sta fe_wide+2
        ; Capture residual (only set if fe_wide+2 was $FF and fe_carry=1).
        ; This residual is now positionally at byte 3.
        lda #0
        adc #0
        sta fe_carry

        ; ---- Stage 2: fe_wide[1..2] += 38 * fe_wide+33 ----
        ; (closes L28e/f/g — three former branches collapsed into the
        ;  unconditional body.)
        ldy fe_wide+33
        lda mul38_lo_tab,y
        sta poly_prod_lo
        lda mul38_hi_tab,y
        sta poly_prod_hi
        clc
        lda fe_wide+1
        adc poly_prod_lo
        sta fe_wide+1
        lda fe_wide+2
        adc poly_prod_hi
        sta fe_wide+2
        ; Combine stage 2's main carry-out (positionally at byte 3) with
        ; the prior fe_carry residual (also positionally at byte 3).
        ; fe_carry ∈ {0,1}, C ∈ {0,1}; sum ≤ 2.
        lda fe_carry
        adc #0
        sta fe_carry           ; fe_carry now ∈ {0,1,2}, all owed to byte 3

        ; ---- Bridge before Stage 3: fold fe_carry into fe_wide+3 ----
        clc
        lda fe_wide+3
        adc fe_carry
        sta fe_wide+3
        ; Capture residual at byte 4. fe_wide+3 + fe_carry (≤2): max
        ; carry-out is 1 (need fe_wide+3 ≥ $FE).
        lda #0
        adc #0
        sta fe_carry

        ; ---- Stage 3: fe_wide[2..3] += 38 * fe_wide+34 ----
        ; (closes L28h/i/j/k — four former branches collapsed.)
        ; Note fe_wide+34 ∈ {0,1} after the outer loop (P = 121665*X <
        ; 2^273, byte 34 has only bit 0), so 38*fe_wide+34 ≤ 38 (1 byte).
        ; mul38_hi_tab[0] = mul38_hi_tab[1] = 0, so poly_prod_hi = 0.
        ldy fe_wide+34
        lda mul38_lo_tab,y
        sta poly_prod_lo
        lda mul38_hi_tab,y
        sta poly_prod_hi
        clc
        lda fe_wide+2
        adc poly_prod_lo
        sta fe_wide+2
        lda fe_wide+3
        adc poly_prod_hi
        sta fe_wide+3
        ; Combine stage 3's main carry-out (positionally at byte 4) with
        ; prior fe_carry residual (also at byte 4).
        lda fe_carry
        adc #0
        sta fe_carry           ; fe_carry ∈ {0,1,2}, all owed to byte 4

        ; ---- Final ripple: absorb fe_carry through fe_wide[4..31] ----
        ; Add fe_carry to fe_wide+4, then propagate any new carry through
        ; bytes 5..31 via unconditional `inx/dey/bne` ripple.
        ; Magnitude: total reduction adds ≤ 38*255 + 38*255 + 38 ≤ 19,418
        ; ≈ 2^15 across bytes 0..3 of fe_wide, plus the original fe_wide
        ; value < 2^256. So the ripple chain length to escape would
        ; require many consecutive $FF bytes — public-count loop
        ; deterministically absorbs.
        clc
        lda fe_wide+4
        adc fe_carry
        sta fe_wide+4
        ldx #5
        ldy #27
@final_ripple:
        lda fe_wide,x
        adc #0
        sta fe_wide,x
        inx
        dey
        bne @final_ripple

        ; Copy to (fe25519_dst). PUBLIC loop bound (#31) — CT-clean.
        ldy #31
@copy_a24:
        lda fe_wide,y
        sta (fe25519_dst),y
        dey
        bpl @copy_a24

        jsr fe25519_reduce_final
        rts
.endproc


; =============================================================================
; fe25519_inv - (fe25519_dst) = (fe25519_src1)^(p-2) mod p  (Fermat's little theorem)
;
; p-2 = 2^255 - 21
;
; Addition chain from ref10 (djb):
;   ~253 squarings + 11 multiplications
;
; Buffer allocation:
;   fe25519_tmp1 = z (original input, kept throughout)
;   fe25519_tmp2 = t (working accumulator)
;   fe25519_tmp3 = general scratch
;   x25_a   = z11 (saved for final multiply)
;   x25_b   = z_10_0 (saved for z_20_0 and z_50_0)
;   x25_da  = z_50_0 (saved for z_100_0 and z_250_0)
;   x25_cb  = z_100_0 (saved for z_200_0)
;
; Clobbers: A, X, Y, all fe_* ZP vars
; =============================================================================
.proc fe25519_inv
        ; Save original destination pointer
        lda fe25519_dst
        sta fe_inv_dst
        lda fe25519_dst+1
        sta fe_inv_dst+1

        ; Save z to fe25519_tmp1
        lda #<(fe25519_tmp1)
        sta fe25519_dst
        lda #>(fe25519_tmp1)
        sta fe25519_dst+1
        jsr fe25519_copy             ; fe25519_tmp1 = z

        ; --- z2 = z^2 → fe25519_tmp2 ---
        lda #<(fe25519_tmp1)
        sta fe25519_src1
        lda #>(fe25519_tmp1)
        sta fe25519_src1+1
        lda #<(fe25519_tmp2)
        sta fe25519_dst
        lda #>(fe25519_tmp2)
        sta fe25519_dst+1
        jsr fe25519_sqr              ; fe25519_tmp2 = z^2

        ; --- z4 = z2^2 → fe25519_tmp3 ---
        lda #<(fe25519_tmp2)
        sta fe25519_src1
        lda #>(fe25519_tmp2)
        sta fe25519_src1+1
        lda #<(fe25519_tmp3)
        sta fe25519_dst
        lda #>(fe25519_tmp3)
        sta fe25519_dst+1
        jsr fe25519_sqr              ; fe25519_tmp3 = z^4

        ; --- z8 = z4^2 → fe25519_tmp3 ---
        lda #<(fe25519_tmp3)
        sta fe25519_src1
        lda #>(fe25519_tmp3)
        sta fe25519_src1+1
        lda #<(fe25519_tmp3)
        sta fe25519_dst
        lda #>(fe25519_tmp3)
        sta fe25519_dst+1
        jsr fe25519_sqr              ; fe25519_tmp3 = z^8

        ; --- z9 = z8 * z → fe25519_tmp3 ---
        lda #<(fe25519_tmp3)
        sta fe25519_src1
        lda #>(fe25519_tmp3)
        sta fe25519_src1+1
        lda #<(fe25519_tmp1)
        sta fe25519_src2
        lda #>(fe25519_tmp1)
        sta fe25519_src2+1
        lda #<(fe25519_tmp3)
        sta fe25519_dst
        lda #>(fe25519_tmp3)
        sta fe25519_dst+1
        jsr fe25519_mul              ; fe25519_tmp3 = z^9

        ; --- z11 = z9 * z2 → x25_a (saved for final step) ---
        lda #<(fe25519_tmp3)
        sta fe25519_src1
        lda #>(fe25519_tmp3)
        sta fe25519_src1+1
        lda #<(fe25519_tmp2)
        sta fe25519_src2
        lda #>(fe25519_tmp2)
        sta fe25519_src2+1
        lda #<(x25_a)
        sta fe25519_dst
        lda #>(x25_a)
        sta fe25519_dst+1
        jsr fe25519_mul              ; x25_a = z^11

        ; --- z22 = z11^2 → fe25519_tmp2 ---
        lda #<(x25_a)
        sta fe25519_src1
        lda #>(x25_a)
        sta fe25519_src1+1
        lda #<(fe25519_tmp2)
        sta fe25519_dst
        lda #>(fe25519_tmp2)
        sta fe25519_dst+1
        jsr fe25519_sqr              ; fe25519_tmp2 = z^22

        ; --- z_5_0 = z22 * z9 = z^31 → fe25519_tmp2 ---
        lda #<(fe25519_tmp2)
        sta fe25519_src1
        lda #>(fe25519_tmp2)
        sta fe25519_src1+1
        lda #<(fe25519_tmp3)
        sta fe25519_src2
        lda #>(fe25519_tmp3)
        sta fe25519_src2+1
        lda #<(fe25519_tmp2)
        sta fe25519_dst
        lda #>(fe25519_tmp2)
        sta fe25519_dst+1
        jsr fe25519_mul              ; fe25519_tmp2 = z^(2^5-1)

        ; --- Save z_5_0 to fe25519_tmp3, square 5x, multiply ---
        lda #<(fe25519_tmp2)
        sta fe25519_src1
        lda #>(fe25519_tmp2)
        sta fe25519_src1+1
        lda #<(fe25519_tmp3)
        sta fe25519_dst
        lda #>(fe25519_tmp3)
        sta fe25519_dst+1
        jsr fe25519_copy             ; fe25519_tmp3 = z_5_0

        lda #5
        jsr fe_inv_sqrn_tmp2    ; fe25519_tmp2 = z_5_0^(2^5)

        ; --- z_10_0 = fe25519_tmp2 * fe25519_tmp3 → x25_b (saved) ---
        lda #<(fe25519_tmp2)
        sta fe25519_src1
        lda #>(fe25519_tmp2)
        sta fe25519_src1+1
        lda #<(fe25519_tmp3)
        sta fe25519_src2
        lda #>(fe25519_tmp3)
        sta fe25519_src2+1
        lda #<(x25_b)
        sta fe25519_dst
        lda #>(x25_b)
        sta fe25519_dst+1
        jsr fe25519_mul              ; x25_b = z^(2^10-1)

        ; --- z_20_0: copy z_10_0 to tmp2, square 10x, multiply with z_10_0 ---
        lda #<(x25_b)
        sta fe25519_src1
        lda #>(x25_b)
        sta fe25519_src1+1
        lda #<(fe25519_tmp2)
        sta fe25519_dst
        lda #>(fe25519_tmp2)
        sta fe25519_dst+1
        jsr fe25519_copy             ; fe25519_tmp2 = z_10_0

        lda #10
        jsr fe_inv_sqrn_tmp2    ; fe25519_tmp2 = z_10_0^(2^10)

        lda #<(fe25519_tmp2)
        sta fe25519_src1
        lda #>(fe25519_tmp2)
        sta fe25519_src1+1
        lda #<(x25_b)
        sta fe25519_src2
        lda #>(x25_b)
        sta fe25519_src2+1
        lda #<(fe25519_tmp2)
        sta fe25519_dst
        lda #>(fe25519_tmp2)
        sta fe25519_dst+1
        jsr fe25519_mul              ; fe25519_tmp2 = z^(2^20-1)

        ; --- z_40_0: square 20x, multiply with z_20_0 ---
        lda #<(fe25519_tmp2)
        sta fe25519_src1
        lda #>(fe25519_tmp2)
        sta fe25519_src1+1
        lda #<(fe25519_tmp3)
        sta fe25519_dst
        lda #>(fe25519_tmp3)
        sta fe25519_dst+1
        jsr fe25519_copy             ; fe25519_tmp3 = z_20_0

        lda #20
        jsr fe_inv_sqrn_tmp2    ; fe25519_tmp2 = z_20_0^(2^20)

        lda #<(fe25519_tmp2)
        sta fe25519_src1
        lda #>(fe25519_tmp2)
        sta fe25519_src1+1
        lda #<(fe25519_tmp3)
        sta fe25519_src2
        lda #>(fe25519_tmp3)
        sta fe25519_src2+1
        lda #<(fe25519_tmp2)
        sta fe25519_dst
        lda #>(fe25519_tmp2)
        sta fe25519_dst+1
        jsr fe25519_mul              ; fe25519_tmp2 = z^(2^40-1)

        ; --- z_50_0: square 10x, multiply with z_10_0 → x25_da (saved) ---
        lda #10
        jsr fe_inv_sqrn_tmp2    ; fe25519_tmp2 = z_40_0^(2^10)

        lda #<(fe25519_tmp2)
        sta fe25519_src1
        lda #>(fe25519_tmp2)
        sta fe25519_src1+1
        lda #<(x25_b)
        sta fe25519_src2
        lda #>(x25_b)
        sta fe25519_src2+1
        lda #<(x25_da)
        sta fe25519_dst
        lda #>(x25_da)
        sta fe25519_dst+1
        jsr fe25519_mul              ; x25_da = z^(2^50-1)

        ; --- z_100_0: copy z_50_0 to tmp2, square 50x, multiply → x25_cb (saved) ---
        lda #<(x25_da)
        sta fe25519_src1
        lda #>(x25_da)
        sta fe25519_src1+1
        lda #<(fe25519_tmp2)
        sta fe25519_dst
        lda #>(fe25519_tmp2)
        sta fe25519_dst+1
        jsr fe25519_copy

        lda #50
        jsr fe_inv_sqrn_tmp2

        lda #<(fe25519_tmp2)
        sta fe25519_src1
        lda #>(fe25519_tmp2)
        sta fe25519_src1+1
        lda #<(x25_da)
        sta fe25519_src2
        lda #>(x25_da)
        sta fe25519_src2+1
        lda #<(x25_cb)
        sta fe25519_dst
        lda #>(x25_cb)
        sta fe25519_dst+1
        jsr fe25519_mul              ; x25_cb = z^(2^100-1)

        ; --- z_200_0: copy z_100_0 to tmp2, square 100x, multiply ---
        lda #<(x25_cb)
        sta fe25519_src1
        lda #>(x25_cb)
        sta fe25519_src1+1
        lda #<(fe25519_tmp2)
        sta fe25519_dst
        lda #>(fe25519_tmp2)
        sta fe25519_dst+1
        jsr fe25519_copy

        lda #100
        jsr fe_inv_sqrn_tmp2

        lda #<(fe25519_tmp2)
        sta fe25519_src1
        lda #>(fe25519_tmp2)
        sta fe25519_src1+1
        lda #<(x25_cb)
        sta fe25519_src2
        lda #>(x25_cb)
        sta fe25519_src2+1
        lda #<(fe25519_tmp2)
        sta fe25519_dst
        lda #>(fe25519_tmp2)
        sta fe25519_dst+1
        jsr fe25519_mul              ; fe25519_tmp2 = z^(2^200-1)

        ; --- z_250_0: square 50x, multiply with z_50_0 ---
        lda #50
        jsr fe_inv_sqrn_tmp2

        lda #<(fe25519_tmp2)
        sta fe25519_src1
        lda #>(fe25519_tmp2)
        sta fe25519_src1+1
        lda #<(x25_da)
        sta fe25519_src2
        lda #>(x25_da)
        sta fe25519_src2+1
        lda #<(fe25519_tmp2)
        sta fe25519_dst
        lda #>(fe25519_tmp2)
        sta fe25519_dst+1
        jsr fe25519_mul              ; fe25519_tmp2 = z^(2^250-1)

        ; --- Final: square 5x, multiply with z11 ---
        lda #5
        jsr fe_inv_sqrn_tmp2    ; fe25519_tmp2 = z^((2^250-1)*2^5) = z^(2^255-32)

        lda #<(fe25519_tmp2)
        sta fe25519_src1
        lda #>(fe25519_tmp2)
        sta fe25519_src1+1
        lda #<(x25_a)
        sta fe25519_src2
        lda #>(x25_a)
        sta fe25519_src2+1
        lda fe_inv_dst
        sta fe25519_dst
        lda fe_inv_dst+1
        sta fe25519_dst+1
        jsr fe25519_mul              ; (original fe25519_dst) = z^(2^255-21) = z^(p-2)
        jsr fe25519_reduce_final     ; fe25519_inv output must be canonical

        rts

; Saved destination pointer for fe25519_inv
fe_inv_dst:     .word 0
.endproc


; =============================================================================
; fe_inv_sqrn_tmp2 - Square fe25519_tmp2 in place N times
;
; Input: A = number of squarings
; Clobbers: A, X, Y, fe25519_src1, fe25519_src2, fe25519_dst
; =============================================================================
.proc fe_inv_sqrn_tmp2
        sta fe_inv_sqr_cnt
@loop:
        lda #<(fe25519_tmp2)
        sta fe25519_src1
        lda #>(fe25519_tmp2)
        sta fe25519_src1+1
        lda #<(fe25519_tmp2)
        sta fe25519_dst
        lda #>(fe25519_tmp2)
        sta fe25519_dst+1
        jsr fe25519_sqr
        dec fe_inv_sqr_cnt
        bne @loop
        rts

fe_inv_sqr_cnt: .byte 0

.endproc