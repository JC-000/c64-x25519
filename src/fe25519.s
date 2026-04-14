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
.import sqtab_lo, sqtab_hi

; --- Imports from x25519_init.s ---
.import reu_clear_wide, reu_fetch_doubled_row

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
; 32-byte addition with carry, then conditional subtract p if >= p.
; Clobbers: A, X, Y
; =============================================================================
.proc fe25519_add
        clc
        ldy #0
        ldx #32
@add_loop:
        lda (fe25519_src1),y
        adc (fe25519_src2),y
        sta (fe25519_dst),y
        iny
        dex                    ; DEX doesn't affect carry
        bne @add_loop
        bcs @must_reduce       ; carry out → result >= 2^256 > p

        ; Check if result >= p
        jsr fe_cmp_p
        bcc @done

@must_reduce:
        sec
        ldy #0
        ldx #32
@sub_p:
        lda (fe25519_dst),y
        sbc fe_p,y
        sta (fe25519_dst),y
        iny
        dex
        bne @sub_p

@done:
        rts
.endproc


; =============================================================================
; fe25519_sub - (fe25519_dst) = (fe25519_src1) - (fe25519_src2) mod p
;
; 32-byte subtraction. If borrow, add p.
; Clobbers: A, X, Y
; =============================================================================
.proc fe25519_sub
        sec
        ldy #0
        ldx #32
@sub_loop:
        lda (fe25519_src1),y
        sbc (fe25519_src2),y
        sta (fe25519_dst),y
        iny
        dex
        bne @sub_loop
        bcs @done              ; no borrow → done

        ; Borrow: add p
        clc
        ldy #0
        ldx #32
@add_p:
        lda (fe25519_dst),y
        adc fe_p,y
        sta (fe25519_dst),y
        iny
        dex
        bne @add_p

@done:
        rts
.endproc


; =============================================================================
; fe_cmp_p - Compare (fe25519_dst) with p
;
; C=1 if (fe25519_dst) >= p, C=0 if < p
; Clobbers: A, Y
; =============================================================================
.proc fe_cmp_p
        ldy #31
@cmp_loop:
        lda (fe25519_dst),y
        cmp fe_p,y
        bcc @less
        bne @greater
        dey
        bpl @cmp_loop
        sec                    ; equal → >= p
        rts
@less:
        clc
        rts
@greater:
        sec
        rts
.endproc


; =============================================================================
; fe25519_reduce_final - Canonical reduction of (fe25519_dst) to [0, p-1]
; Clobbers: A, X, Y
; =============================================================================
.proc fe25519_reduce_final
@check:
        jsr fe_cmp_p
        bcc @done

        sec
        ldy #0
        ldx #32
@sub_p:
        lda (fe25519_dst),y
        sbc fe_p,y
        sta (fe25519_dst),y
        iny
        dex
        bne @sub_p
        jmp @check

@done:
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
        ldy fe_mul_i
@load_src1:
        lda mul_src2_buf,y     ; PATCHED at proc entry: abs = src1 base
        bne @nonzero_i
        jmp @skip_zero
@nonzero_i:
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
        ; For +1 accesses (high byte of product), base is fe_wide + i + 1
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

        ldx #0                 ; X = j, kept in register

        ; ===== UNROLLED 4x INNER LOOP =====
        ; X register holds j throughout, avoiding ZP load/store
        ; Direct DMA table accumulation (no ZP intermediaries)

        ; Carry invariant: C=0 on every entry to @mul_inner. The back-branch
        ; `bcc @mul_inner` keeps C=0; the initial entry falls through from
        ; `adc #1` which does not overflow (A = fe_wide+i+1 <= $60); and the
        ; rare carry_done_{a,b,c,d} tails each `clc` before jmp'ing to a
        ; mid-loop `@next_j_X` label. That lets us drop the per-body clc.
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
        bcs @do_prop_a
@next_j_first:
        inx                    ; advance j

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
        bcs @do_prop_b
@next_j_second:
        inx

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
        bcs @do_prop_c
@next_j_third:
        inx

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
        bcs @do_prop_d
@next_j:
        inx
        cpx #32
        bcc @mul_inner
        ; fall through to @skip_zero
        jmp @skip_zero

        ; --- Carry propagation blocks (rare path ~2%) ---
        ; Placed outside the tight inner loop so the back-branch remains
        ; within bcc range. Each block restores X to j and jumps back to
        ; its corresponding @next_j_X label.
@do_prop_a:
        stx fe_mul_j
        lda fe_mul_i
        clc
        adc fe_mul_j
        clc
        adc #2
        tax
        ; NOTE: `sec` below is load-bearing. cpx clobbers C, so we
        ; re-establish C=1 each iteration to make `adc #0` = +1.
        ; See feedback_6502_cpx_clobbers_carry. Do NOT remove.
@prop_carry_a:
        cpx #64
        bcs @carry_done_a
        sec
        lda fe_wide,x
        adc #0
        sta fe_wide,x
        inx
        bcs @prop_carry_a
@carry_done_a:
        ldx fe_mul_j
        clc                    ; restore C=0 invariant for clc-less bodies
        jmp @next_j_first

@do_prop_b:
        stx fe_mul_j
        lda fe_mul_i
        clc
        adc fe_mul_j
        clc
        adc #2
        tax
        ; Load-bearing sec — see @prop_carry_a comment above.
@prop_carry_b:
        cpx #64
        bcs @carry_done_b
        sec
        lda fe_wide,x
        adc #0
        sta fe_wide,x
        inx
        bcs @prop_carry_b
@carry_done_b:
        ldx fe_mul_j
        clc                    ; restore C=0 invariant for clc-less bodies
        jmp @next_j_second

@do_prop_c:
        stx fe_mul_j
        lda fe_mul_i
        clc
        adc fe_mul_j
        clc
        adc #2
        tax
        ; Load-bearing sec — see @prop_carry_a comment above.
@prop_carry_c:
        cpx #64
        bcs @carry_done_c
        sec
        lda fe_wide,x
        adc #0
        sta fe_wide,x
        inx
        bcs @prop_carry_c
@carry_done_c:
        ldx fe_mul_j
        clc                    ; restore C=0 invariant for clc-less bodies
        jmp @next_j_third

@do_prop_d:
        stx fe_mul_j
        lda fe_mul_i
        clc
        adc fe_mul_j
        clc
        adc #2
        tax
        ; Load-bearing sec — see @prop_carry_a comment above.
@prop_carry_d:
        cpx #64
        bcs @carry_done_d
        sec
        lda fe_wide,x
        adc #0
        sta fe_wide,x
        inx
        bcs @prop_carry_d
@carry_done_d:
        ldx fe_mul_j
        clc                    ; restore C=0 invariant for clc-less bodies
        jmp @next_j

@skip_zero:
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

        ; NOTE: fe25519_reduce_final removed from fe25519_mul — callers that need
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
        lda #0
        sta fe_carry
        ldx #0
@reduce1:
        ldy fe_wide+32,x       ; Y = byte value (table index)
        beq @reduce1_zero

        ; Add product (Y*38) + running carry to fe_wide[x]
        ; Table lookups chained directly to adds (Y preserved across)
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
        jmp @reduce1_check

@reduce1_zero:
        ; byte is 0; just add running carry
        clc
        lda fe_wide,x
        adc fe_carry
        sta fe_wide,x
        lda #0
        adc #0
        sta fe_carry
        inx
        cpx #32
        bcc @reduce1

@reduce1_check:
        ; If carry remains, multiply by 38 and add to bottom
        lda fe_carry
        beq @done
        tay                    ; Y = carry value
        clc
        lda fe_wide
        adc mul38_lo_tab,y
        sta fe_wide
        lda fe_wide+1
        adc mul38_hi_tab,y
        sta fe_wide+1
        bcc @done
        ldx #2
@prop2:
        ; Propagate a single +1 using inc/bne so the carry from adc need
        ; not survive the cpx #32 loop bound check. Prior `adc #0` version
        ; lost the carry through cpx on the second-and-later bytes, which
        ; produced off-by-one results on specific inputs (byte k == $FF
        ; followed by byte k+1 != $FF mid-propagation).
        inc fe_wide,x
        bne @done
        inx
        cpx #32
        bcc @prop2

        ; Extremely rare: yet another overflow
        clc
        lda fe_wide
        adc #38
        sta fe_wide
        bcc @done
        ldx #1
@prop3:
        inc fe_wide,x
        bne @done
        inx
        cpx #32
        bcc @prop3

@done:
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
        ; For +1 accesses (high byte of product)
        clc
        adc #1
        sta @sqr_accum_ld2+1
        sta @sqr_accum_st2+1
        sta @sqr_accum_ld2_b+1
        sta @sqr_accum_st2_b+1

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

        jmp @sqr_inner_tramp   ; dispatch to mult66 or DMA unrolled pair loop

@sqr_inner:
        ; === Body A (branchless CT quarter-square) ===
        ; Unconditional: no zero-skip, no sign branch, no (zp),y loads.
        ; Mirrors src/mul_8x8.s Phase 1 rewrite.
        ldx fe_mul_j
        lda mul_src2_buf,x     ; A = a[j]  (unconditional load)
        sta sqr_tmp_b          ; stash a[j] for sum computation below

        ; Branchless |a[i] - a[j]| via sign-mask.
        sec
        sbc mul_cached_a       ; A = a[j] - a[i]; C = (a[j] >= a[i])
        sta sqr_diff
        lda #0
        sbc #0                 ; sign mask: $00 if C=1 else $ff
        sta sqr_mask
        lda sqr_diff
        eor sqr_mask
        sec
        sbc sqr_mask           ; A = |a[i] - a[j]|
        tay                    ; Y = |diff|  (abs,Y always page 0 of sqtab)

        ; Compute sum = a[i] + a[j] and sum-page carry.
        lda mul_cached_a
        clc
        adc sqr_tmp_b          ; A = sum_lo, C = sum-page carry
        tax                    ; X = sum_lo
        lda #0
        adc #0                 ; A = sum-page carry (0 or 1)
        sta sqr_sum_pg

        ; Patch hi bytes of the two abs,X load sites (sum path).
        ; sqtab_lo/sqtab_hi are 512 bytes page-aligned: hi += page carry
        ; selects between page 0 and page 1 branchlessly.
        lda #>sqtab_lo
        clc
        adc sqr_sum_pg
        sta @ct_sum_load_lo_a+2
        lda #>sqtab_hi
        clc
        adc sqr_sum_pg
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

        ; --- Phase 6 CT carry-chain step for mult66 body A ---
        ; Compose combined carry (shift+accum, ∈ {0,1,2}) with the pending
        ; carry from the prior body in this outer-i (∈ {0,1}). Sum ≤ 3.
        ; Always add to fe_wide[i+j+2] and always capture the new overflow
        ; bit into sqr_pending — no secret-dependent branch. The next body's
        ; carry target is [i+j+3], which is body A's overflow position, so
        ; the chain stays consistent. See proc-tail comment on sqr_pending.
        lda #0
        adc poly_carry         ; A = combined_A (uses C from prior adc_hi)
        clc
        adc sqr_pending        ; A ≤ 3
        sta sqr_tmp_b          ; stash value-to-add (reusing existing scratch)
        lda fe_mul_i
        clc
        adc fe_mul_j
        clc
        adc #2                 ; A = i+j+2
        tax
        lda sqr_tmp_b
        clc
        adc fe_wide,x
        sta fe_wide,x
        lda #0
        adc #0
        sta sqr_pending        ; new overflow bit → chain
        inx
        stx sqr_ripple_start   ; record [i+j+3] as end-of-inner ripple start
                               ; (overwritten by every subsequent body; at
                               ; end of inner, holds last body's overflow
                               ; position)
        inc fe_mul_j

        ; === Body B (branchless CT quarter-square, second unrolled copy) ===
        ldx fe_mul_j
        lda mul_src2_buf,x     ; A = a[j]  (unconditional load)
        sta sqr_tmp_b

        sec
        sbc mul_cached_a       ; A = a[j] - a[i]; C = (a[j] >= a[i])
        sta sqr_diff
        lda #0
        sbc #0
        sta sqr_mask
        lda sqr_diff
        eor sqr_mask
        sec
        sbc sqr_mask           ; A = |a[i] - a[j]|
        tay                    ; Y = |diff|

        lda mul_cached_a
        clc
        adc sqr_tmp_b          ; A = sum_lo, C = page carry
        tax
        lda #0
        adc #0
        sta sqr_sum_pg

        lda #>sqtab_lo
        clc
        adc sqr_sum_pg
        sta @ct_sum_load_lo_b+2
        lda #>sqtab_hi
        clc
        adc sqr_sum_pg
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

        lda #0
        adc poly_carry         ; A = combined_B
        ; --- Phase 6 CT carry-chain step for mult66 body B (see body A) ---
        ; NOTE: body B for the phantom slot (i=30, j=32, even-i final pair)
        ; has carry target [i+j+2] = [64] — out of fe_wide bounds. In that
        ; case combined_B is guaranteed 0 (zero-padded mul_src2_buf[32]),
        ; but sqr_pending from body A may be nonzero. We guard the write
        ; with a public `cmp #64 / bcs` on the carry-target address. When
        ; skipped, the pending is also forced to 0 via the sentinel path —
        ; mirroring the old code's silent carry-drop past fe_wide[63].
        ; The branch is on public data (fe_mul_i, fe_mul_j) only.
        clc
        adc sqr_pending
        sta sqr_tmp_b
        lda fe_mul_i
        clc
        adc fe_mul_j
        clc
        adc #2                 ; A = i+j+2 (for body B, j = prior j+1)
        cmp #64
        bcs @sqr_b_chain_skip  ; public guard: out-of-bounds phantom case
        tax
        lda sqr_tmp_b
        clc
        adc fe_wide,x
        sta fe_wide,x
        lda #0
        adc #0
        sta sqr_pending
        inx
        stx sqr_ripple_start
        jmp @sqr_b_chain_done
@sqr_b_chain_skip:
        ; Out-of-bounds (i=30, j=32 phantom): drop the carry write.
        ; Clear pending so end-of-inner ripple doesn't try to flush past [63].
        lda #0
        sta sqr_pending
        lda #64
        sta sqr_ripple_start   ; sentinel: end-of-inner ripple count = 0
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
@sqr_mult66_inner_done:
        ldx sqr_ripple_start
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
        ; --- Phase 6 CT carry-chain step for DMA body A ---
        ; Thread combined_A with sqr_pending (bit carried from prior body);
        ; add the sum to fe_wide[i+j+2]; capture new overflow into
        ; sqr_pending. Preserves X (= j) across the ripple-start math via
        ; fe_mul_j. No secret-dependent branch.
        clc
        adc sqr_pending        ; A ≤ 3
        sta sqr_tmp_b          ; value-to-add (scratch is dead here)
        stx fe_mul_j           ; save j; X about to be clobbered
        txa
        clc
        adc fe_mul_i
        clc
        adc #2                 ; A = i+j+2
        tax
        lda sqr_tmp_b
        clc
        adc fe_wide,x
        sta fe_wide,x
        lda #0
        adc #0
        sta sqr_pending        ; new overflow → pending chain
        inx                    ; X = i+j+3
        stx sqr_ripple_start
        ldx fe_mul_j           ; restore j
        inx                    ; advance j (X-register)

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
        ; --- Phase 6 CT carry-chain step for DMA body B (mirrors body A) ---
        clc
        adc sqr_pending
        sta sqr_tmp_b
        stx fe_mul_j
        txa
        clc
        adc fe_mul_i
        clc
        adc #2                 ; A = i+j+2
        tax
        lda sqr_tmp_b
        clc
        adc fe_wide,x
        sta fe_wide,x
        lda #0
        adc #0
        sta sqr_pending
        inx
        stx sqr_ripple_start
        ldx fe_mul_j           ; restore j
        inx                    ; advance j
        dec fe_sqr_pairs
        beq @sqr_dma_inner_done
        jmp @sqr_dma_body_a    ; preserves X across iterations; long jmp
                               ; (Phase 6 body size exceeds bne range)
@sqr_dma_inner_done:
        ; --- Phase 6: DMA end-of-inner ripple ---
        ; Same purpose as @sqr_mult66_inner_done: flush any residual
        ; pending-carry bit from this outer-i forward to fe_wide[63].
        ; Loop count is public (derived from fe_mul_i / fe_mul_j state).
        ldx sqr_ripple_start
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
@diag_outer:
        ldy fe_mul_i
        lda (fe25519_src1),y
        beq @diag_skip         ; skip if a[i] == 0

        tay                    ; Y = a[i]
        lda sqr_lo,y
        sta poly_prod_lo
        lda sqr_hi,y
        sta poly_prod_hi

        ; Add to fe_wide[2*i]
        lda fe_mul_i
        asl                    ; A = 2*i
        tax

        clc
        lda fe_wide,x
        adc poly_prod_lo
        sta fe_wide,x
        inx
        lda fe_wide,x
        adc poly_prod_hi
        sta fe_wide,x
        bcc @diag_skip

        ; Propagate carry.
        ; Load-bearing sec — cpx clobbers C, so sec restores C=1 each
        ; iteration. See feedback_6502_cpx_clobbers_carry. NOTE: this diag
        ; ripple still has secret-dependent branches (bcc/beq). Not in Phase 6
        ; L19-L22 scope (diagonal path wasn't flagged in CT_ANALYSIS.md).
@diag_prop:
        inx
        cpx #64
        bcs @diag_skip
        sec
        lda fe_wide,x
        adc #0
        sta fe_wide,x
        bcs @diag_prop

@diag_skip:
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
        ; Zero fe_wide[0..34]
        ldx #34
        lda #0
@zero:
        sta fe_wide,x
        dex
        bpl @zero

        ldx #0                 ; i = 0
@outer:
        stx fe_mul_i

        ldy fe_mul_i
        lda (fe25519_src1),y
        beq @skip_zero_a24
        tay                    ; Y = src1[i] (nonzero)

        ; fe_wide[i..i+3] += 121665 * src1[i]  (4-byte product via table)
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
        bcc @skip_zero_a24
        inc fe_wide+4,x
        bne @skip_zero_a24
        inc fe_wide+5,x
@skip_zero_a24:
        ldx fe_mul_i
        inx
        cpx #32
        bcc @outer

        ; Reduce: fe_wide[32..34] * 38 → add to fe_wide[0..31]
        ldy fe_wide+32
        beq @r_b33
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
        bcc @r_b33
        ldx #2
@prop_b32:
        inc fe_wide,x
        bne @r_b33
        inx
        cpx #32
        bcc @prop_b32

@r_b33:
        ldy fe_wide+33
        beq @r_b34
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
        bcc @r_b34
        ldx #3
@prop_b33:
        inc fe_wide,x
        bne @r_b34
        inx
        cpx #32
        bcc @prop_b33

@r_b34:
        ldy fe_wide+34
        beq @r_done_a24
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
        bcc @r_done_a24
        ldx #4
@prop_b34:
        inc fe_wide,x
        bne @r_done_a24
        inx
        cpx #32
        bcc @prop_b34

@r_done_a24:
        ; Copy to (fe25519_dst)
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