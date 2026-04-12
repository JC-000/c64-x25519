; =============================================================================
; fe25519.s - Field arithmetic mod p = 2^255 - 19
;
; 32-byte little-endian field elements.
; Uses ZP pointers fe_src1, fe_src2, fe_dst for operands.
; Reuses mul_8x8 and sqtab from mul_8x8.asm for multiplication.
;
; Key design:
;   - Little-endian throughout (matches 6502 carry propagation and X25519 wire)
;   - DEX/DEY for all carry-dependent loops (CPX/CPY clobber carry)
;   - Reduction mod p: 2^256 ≡ 38 mod p, so multiply overflow by 38 and add
; =============================================================================

; =============================================================================
; fe_copy - Copy 32 bytes: (fe_dst) = (fe_src1)
; Clobbers: A, Y
; =============================================================================
fe_copy:
        ldy #31
@loop:
        lda (fe_src1),y
        sta (fe_dst),y
        dey
        bpl @loop
        rts

; =============================================================================
; fe_zero - Zero 32 bytes at (fe_dst)
; Clobbers: A, Y
; =============================================================================
fe_zero:
        lda #0
        ldy #31
@loop:
        sta (fe_dst),y
        dey
        bpl @loop
        rts

; =============================================================================
; fe_one - Set (fe_dst) = 1 (LE: byte 0 = 1, rest 0)
; Clobbers: A, Y
; =============================================================================
fe_one:
        jsr fe_zero
        lda #1
        ldy #0
        sta (fe_dst),y
        rts

; =============================================================================
; fe_add - (fe_dst) = (fe_src1) + (fe_src2) mod p
;
; 32-byte addition with carry, then conditional subtract p if >= p.
; Clobbers: A, X, Y
; =============================================================================
fe_add:
        clc
        ldy #0
        ldx #32
@add_loop:
        lda (fe_src1),y
        adc (fe_src2),y
        sta (fe_dst),y
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
        lda (fe_dst),y
        sbc fe_p,y
        sta (fe_dst),y
        iny
        dex
        bne @sub_p

@done:
        rts

; =============================================================================
; fe_sub - (fe_dst) = (fe_src1) - (fe_src2) mod p
;
; 32-byte subtraction. If borrow, add p.
; Clobbers: A, X, Y
; =============================================================================
fe_sub:
        sec
        ldy #0
        ldx #32
@sub_loop:
        lda (fe_src1),y
        sbc (fe_src2),y
        sta (fe_dst),y
        iny
        dex
        bne @sub_loop
        bcs @done              ; no borrow → done

        ; Borrow: add p
        clc
        ldy #0
        ldx #32
@add_p:
        lda (fe_dst),y
        adc fe_p,y
        sta (fe_dst),y
        iny
        dex
        bne @add_p

@done:
        rts

; =============================================================================
; fe_cmp_p - Compare (fe_dst) with p
;
; C=1 if (fe_dst) >= p, C=0 if < p
; Clobbers: A, Y
; =============================================================================
fe_cmp_p:
        ldy #31
@cmp_loop:
        lda (fe_dst),y
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

; =============================================================================
; fe_reduce_final - Canonical reduction of (fe_dst) to [0, p-1]
; Clobbers: A, X, Y
; =============================================================================
fe_reduce_final:
        jsr fe_cmp_p
        bcc @done

        sec
        ldy #0
        ldx #32
@sub_p:
        lda (fe_dst),y
        sbc fe_p,y
        sta (fe_dst),y
        iny
        dex
        bne @sub_p

@done:
        rts

; =============================================================================
; fe_cswap - Constant-time conditional swap of (fe_src1) and (fe_src2)
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
fe_cswap:
        sta fe_carry           ; save mask

        ; Patch src1 address into lda/sta abs,Y instructions (8 patches)
        lda fe_src1
        sta @ld_a1+1
        sta @st_a1+1
        sta @ld_a2+1
        sta @st_a2+1
        sta @ld_a3+1
        sta @st_a3+1
        sta @ld_a4+1
        sta @st_a4+1
        lda fe_src1+1
        sta @ld_a1+2
        sta @st_a1+2
        sta @ld_a2+2
        sta @st_a2+2
        sta @ld_a3+2
        sta @st_a3+2
        sta @ld_a4+2
        sta @st_a4+2

        ; Patch src2 address into eor/lda/sta abs,Y instructions (12 patches)
        lda fe_src2
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
        lda fe_src2+1
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

; =============================================================================
; fe_mul - (fe_dst) = (fe_src1) * (fe_src2) mod p
;
; Combined REU DMA table lookup + 2x inner loop unroll.
; Each outer iteration: DMA fetches 512-byte mul row for src1[i],
; then inner loop does direct table lookup (mul_dma_lo/hi,Y) instead of
; mult66 quarter-square. Inner loop unrolled 2x to reduce branch overhead.
;
; Clobbers: A, X, Y
; =============================================================================
fe_mul:
        ; 1. Zero the 64-byte product buffer via REU DMA FETCH from bank 2
        jsr reu_clear_wide

        ; 2. Copy src2 to absolute buffer (needed for indexed access)
        ldy #31
@copy_src2:
        lda (fe_src2),y
        sta mul_src2_buf,y
        dey
        bpl @copy_src2

        ; 3. Schoolbook multiply with REU DMA lookup + self-mod accumulation
        lda #0
        sta fe_mul_i
@mul_outer:
        ldy fe_mul_i
        lda (fe_src1),y
        bne @nonzero_i
        jmp @skip_zero
@nonzero_i:
        sta mul_cached_a       ; cache src1[i] for inner loop

        ; DMA the multiplication row for src1[i] from REU (inlined)
        ; A already contains mul_cached_a from the sta above
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

@mul_inner:
        ; --- Body A: process src2[j] ---
        ldy mul_src2_buf,x     ; Y = src2[j]
        beq @next_j_first      ; skip if zero
        clc
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
        ldy mul_src2_buf,x
        beq @next_j_second
        clc
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
        ldy mul_src2_buf,x
        beq @next_j_third
        clc
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
        ldy mul_src2_buf,x
        beq @next_j
        clc
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
        jmp @next_j_first

@do_prop_b:
        stx fe_mul_j
        lda fe_mul_i
        clc
        adc fe_mul_j
        clc
        adc #2
        tax
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
        jmp @next_j_second

@do_prop_c:
        stx fe_mul_j
        lda fe_mul_i
        clc
        adc fe_mul_j
        clc
        adc #2
        tax
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
        jmp @next_j_third

@do_prop_d:
        stx fe_mul_j
        lda fe_mul_i
        clc
        adc fe_mul_j
        clc
        adc #2
        tax
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

        ; Copy result to (fe_dst)
        ldy #31
@copy_result:
        lda fe_wide,y
        sta (fe_dst),y
        dey
        bpl @copy_result

        ; NOTE: fe_reduce_final removed from fe_mul — callers that need
        ; canonical [0,p) output must call fe_reduce_final explicitly.
        rts

; =============================================================================
; fe_reduce_wide - Reduce fe_wide[0..63] mod p into fe_wide[0..31]
;
; fe_wide[32..63] * 38 + fe_wide[0..31], with second pass for overflow.
; Clobbers: A, X, Y
; =============================================================================
fe_reduce_wide:
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
        lda fe_wide,x
        adc #0
        sta fe_wide,x
        bcc @done
        inx
        cpx #32
        bcc @prop2

        ; Extremely rare: yet another overflow
        clc
        lda fe_wide
        adc #38
        sta fe_wide
        ldx #1
@prop3:
        lda fe_wide,x
        adc #0
        sta fe_wide,x
        bcc @done
        inx
        cpx #32
        bcc @prop3

@done:
        rts

; =============================================================================
; mul_by_38 - Multiply A by 38, result in poly_prod_hi:poly_prod_lo
;
; Uses shift-and-add: 38 = 32 + 4 + 2
; Input:  A = multiplicand (0-255)
; Output: poly_prod_lo/poly_prod_hi = A * 38 (16-bit, max 9690=$25DA)
; Clobbers: A, Y
; Preserves: X
; =============================================================================
mul_by_38:
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

; =============================================================================
; fe_sqr - (fe_dst) = (fe_src1)^2 mod p
;
; Dedicated squaring: exploits symmetry a[i]*a[j] = a[j]*a[i].
; Uses mult66 indirect-indexed multiply + self-modifying accumulation
; (same technique as fe_mul). Cross terms added twice to fuse doubling.
; 1. Cross terms: accumulate 2*a[i]*a[j] for i < j  (inline mult66, shift-before-accum)
; 2. Diagonal: add a[i]^2 at position 2*i            (inline mult66)
; 3. Reduce mod p
;
; Clobbers: A, X, Y
; =============================================================================
fe_sqr:
        ; 1. Zero the 64-byte product buffer via REU DMA FETCH from bank 2
        jsr reu_clear_wide

        ; 2. Copy src1 to absolute buffer (src1==src2 for squaring)
        ldy #31
@copy_src:
        lda (fe_src1),y
        sta mul_src2_buf,y
        dey
        bpl @copy_src

        ; 3. Set up ZP pointers for mult66 indirect-indexed multiply
        lda #>(sqtab_lo)
        sta lmul0+1
        lda #>(sqtab_hi)
        sta lmul1+1

        ; 4. Cross terms with mult66 + self-mod, shift-before-accumulate
        lda #0
        sta fe_mul_i
@sqr_outer:
        ldy fe_mul_i
        lda (fe_src1),y
        bne @sqr_nonzero_i
        jmp @sqr_skip_i
@sqr_nonzero_i:
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

        ; Set up ZP pointer low byte = a[i] once per outer loop
        lda mul_cached_a
        sta lmul0              ; lmul0 = sqtab_lo + a[i]
        sta lmul1              ; lmul1 = sqtab_hi + a[i]

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
        ; === Body A (mult66) ===
        ldx fe_mul_j
        ldy mul_src2_buf,x     ; Y = a[j]
        bne @sqr_nonzero_j     ; skip if zero
        jmp @sqr_next_j
@sqr_nonzero_j:

        ; --- mult66 inline: a[i] * a[j] ---
        tya                    ; A = a[j]
        sec
        sbc mul_cached_a       ; A = a[j] - a[i]
        tax                    ; X = difference (or wrapped)

        ; (lmul0),Y = sqtab_lo[a[i] + a[j]]
        lda (lmul0),y
        bcc @sqr_neg_diff      ; branch if a[j] < a[i]

        ; Positive difference path (carry SET):
        sbc sqtab_lo,x
        sta poly_prod_lo
        lda (lmul1),y
        sbc sqtab_hi,x
        sta poly_prod_hi
        jmp @sqr_accum

@sqr_neg_diff:
        ; Negative difference path (carry CLEAR):
        sbc sqtab2_lo,x
        sta poly_prod_lo
        lda (lmul1),y
        sbc sqtab2_hi,x
        sta poly_prod_hi
        ; --- END mult66 ---

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

        ; Capture accumulation carry and combine with shift carry
        lda #0
        adc poly_carry         ; A = accum_carry + shift_carry (0, 1, or 2)
        beq @sqr_next_j        ; if both zero, skip

        ; Add combined carries to fe_wide[i+j+2]
        ldx fe_mul_i
        tay                    ; Y = combined carry value
        txa
        clc
        adc fe_mul_j
        clc
        adc #2
        tax
        tya                    ; A = combined carry value
        clc
        adc fe_wide,x
        sta fe_wide,x
        bcc @sqr_next_j
        ; Propagate further carries
@sqr_prop1:
        inx
        cpx #64
        bcs @sqr_next_j
        sec
        lda fe_wide,x
        adc #0
        sta fe_wide,x
        bcs @sqr_prop1
@sqr_next_j:
        inc fe_mul_j

        ; === Body B (mult66, second unrolled copy) ===
        ldx fe_mul_j
        ldy mul_src2_buf,x     ; Y = a[j]
        bne @sqr_nonzero_j_b
        jmp @sqr_next_j_b
@sqr_nonzero_j_b:

        tya
        sec
        sbc mul_cached_a
        tax

        lda (lmul0),y
        bcc @sqr_neg_diff_b

        sbc sqtab_lo,x
        sta poly_prod_lo
        lda (lmul1),y
        sbc sqtab_hi,x
        sta poly_prod_hi
        jmp @sqr_accum_b

@sqr_neg_diff_b:
        sbc sqtab2_lo,x
        sta poly_prod_lo
        lda (lmul1),y
        sbc sqtab2_hi,x
        sta poly_prod_hi

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
        adc poly_carry
        beq @sqr_next_j_b

        ldx fe_mul_i
        tay
        txa
        clc
        adc fe_mul_j
        clc
        adc #2
        tax
        tya
        clc
        adc fe_wide,x
        sta fe_wide,x
        bcc @sqr_next_j_b
@sqr_prop1_b:
        inx
        cpx #64
        bcs @sqr_next_j_b
        sec
        lda fe_wide,x
        adc #0
        sta fe_wide,x
        bcs @sqr_prop1_b
@sqr_next_j_b:
        inc fe_mul_j
        dec fe_sqr_pairs
        beq @sqr_pair_loop_exit_mul
@sqr_inner_tramp:
        jmp @sqr_inner         ; patched: @sqr_inner OR @sqr_inner_dma
@sqr_pair_loop_exit_mul:
        jmp @sqr_skip_i

; --- DMA inner loop (2x unrolled): pre-doubled product tables in mul_dma_lo/hi/carry ---
@sqr_inner_dma:
        ; === Body A (DMA) ===
        ldx fe_mul_j
        ldy mul_src2_buf,x     ; Y = a[j]
        bne @sqr_nonzero_j_dma
        jmp @sqr_next_j_dma
@sqr_nonzero_j_dma:
        lda mul_dma_carry,y
        sta poly_carry
        clc
@sqr_dma_ld1:
        lda fe_wide,x          ; patched: fe_wide+i, X = fe_mul_j
        adc mul_dma_lo,y
@sqr_dma_st1:
        sta fe_wide,x
@sqr_dma_ld2:
        lda fe_wide+1,x        ; patched: fe_wide+i+1
        adc mul_dma_hi,y
@sqr_dma_st2:
        sta fe_wide+1,x
        lda #0
        adc poly_carry         ; combined carry = accum_carry + 17th-bit
        beq @sqr_next_j_dma
        ; propagate into fe_wide[i+j+2]
        ldx fe_mul_i
        tay
        txa
        clc
        adc fe_mul_j
        clc
        adc #2
        tax
        tya
        clc
        adc fe_wide,x
        sta fe_wide,x
        bcc @sqr_next_j_dma
@sqr_dma_prop1:
        inx
        cpx #64
        bcs @sqr_next_j_dma
        sec
        lda fe_wide,x
        adc #0
        sta fe_wide,x
        bcs @sqr_dma_prop1
@sqr_next_j_dma:
        inc fe_mul_j

        ; === Body B (DMA, second unrolled copy) ===
        ldx fe_mul_j
        ldy mul_src2_buf,x     ; Y = a[j]
        bne @sqr_nonzero_j_dma_b
        jmp @sqr_next_j_dma_b
@sqr_nonzero_j_dma_b:
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
        adc poly_carry
        beq @sqr_next_j_dma_b
        ldx fe_mul_i
        tay
        txa
        clc
        adc fe_mul_j
        clc
        adc #2
        tax
        tya
        clc
        adc fe_wide,x
        sta fe_wide,x
        bcc @sqr_next_j_dma_b
@sqr_dma_prop1_b:
        inx
        cpx #64
        bcs @sqr_next_j_dma_b
        sec
        lda fe_wide,x
        adc #0
        sta fe_wide,x
        bcs @sqr_dma_prop1_b
@sqr_next_j_dma_b:
        inc fe_mul_j
        dec fe_sqr_pairs
        beq @sqr_pair_loop_exit_dma
        jmp @sqr_inner_dma
@sqr_pair_loop_exit_dma:
        jmp @sqr_skip_i

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
        lda (fe_src1),y
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

        ; Propagate carry
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
        ; 6. Reduce mod p (same as fe_mul)
        jsr fe_reduce_wide

        ; Copy result to (fe_dst)
        ldy #31
@copy_result:
        lda fe_wide,y
        sta (fe_dst),y
        dey
        bpl @copy_result

        ; NOTE: fe_reduce_final removed from fe_sqr — callers that need
        ; canonical [0,p) output must call fe_reduce_final explicitly.
        rts

; =============================================================================
; fe_mul_a24 - (fe_dst) = (fe_src1) * 121665 mod p
;
; 121665 = $01DB41 (3 bytes LE: $41, $DB, $01)
; Clobbers: A, X, Y
; =============================================================================
fe_mul_a24:
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
        lda (fe_src1),y
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
        ; Copy to (fe_dst)
        ldy #31
@copy_a24:
        lda fe_wide,y
        sta (fe_dst),y
        dey
        bpl @copy_a24

        jsr fe_reduce_final
        rts

; =============================================================================
; fe_inv - (fe_dst) = (fe_src1)^(p-2) mod p  (Fermat's little theorem)
;
; p-2 = 2^255 - 21
;
; Addition chain from ref10 (djb):
;   ~253 squarings + 11 multiplications
;
; Buffer allocation:
;   fe_tmp1 = z (original input, kept throughout)
;   fe_tmp2 = t (working accumulator)
;   fe_tmp3 = general scratch
;   x25_a   = z11 (saved for final multiply)
;   x25_b   = z_10_0 (saved for z_20_0 and z_50_0)
;   x25_da  = z_50_0 (saved for z_100_0 and z_250_0)
;   x25_cb  = z_100_0 (saved for z_200_0)
;
; Clobbers: A, X, Y, all fe_* ZP vars
; =============================================================================
fe_inv:
        ; Save original destination pointer
        lda fe_dst
        sta fe_inv_dst
        lda fe_dst+1
        sta fe_inv_dst+1

        ; Save z to fe_tmp1
        lda #<(fe_tmp1)
        sta fe_dst
        lda #>(fe_tmp1)
        sta fe_dst+1
        jsr fe_copy             ; fe_tmp1 = z

        ; --- z2 = z^2 → fe_tmp2 ---
        lda #<(fe_tmp1)
        sta fe_src1
        lda #>(fe_tmp1)
        sta fe_src1+1
        lda #<(fe_tmp2)
        sta fe_dst
        lda #>(fe_tmp2)
        sta fe_dst+1
        jsr fe_sqr              ; fe_tmp2 = z^2

        ; --- z4 = z2^2 → fe_tmp3 ---
        lda #<(fe_tmp2)
        sta fe_src1
        lda #>(fe_tmp2)
        sta fe_src1+1
        lda #<(fe_tmp3)
        sta fe_dst
        lda #>(fe_tmp3)
        sta fe_dst+1
        jsr fe_sqr              ; fe_tmp3 = z^4

        ; --- z8 = z4^2 → fe_tmp3 ---
        lda #<(fe_tmp3)
        sta fe_src1
        lda #>(fe_tmp3)
        sta fe_src1+1
        lda #<(fe_tmp3)
        sta fe_dst
        lda #>(fe_tmp3)
        sta fe_dst+1
        jsr fe_sqr              ; fe_tmp3 = z^8

        ; --- z9 = z8 * z → fe_tmp3 ---
        lda #<(fe_tmp3)
        sta fe_src1
        lda #>(fe_tmp3)
        sta fe_src1+1
        lda #<(fe_tmp1)
        sta fe_src2
        lda #>(fe_tmp1)
        sta fe_src2+1
        lda #<(fe_tmp3)
        sta fe_dst
        lda #>(fe_tmp3)
        sta fe_dst+1
        jsr fe_mul              ; fe_tmp3 = z^9

        ; --- z11 = z9 * z2 → x25_a (saved for final step) ---
        lda #<(fe_tmp3)
        sta fe_src1
        lda #>(fe_tmp3)
        sta fe_src1+1
        lda #<(fe_tmp2)
        sta fe_src2
        lda #>(fe_tmp2)
        sta fe_src2+1
        lda #<(x25_a)
        sta fe_dst
        lda #>(x25_a)
        sta fe_dst+1
        jsr fe_mul              ; x25_a = z^11

        ; --- z22 = z11^2 → fe_tmp2 ---
        lda #<(x25_a)
        sta fe_src1
        lda #>(x25_a)
        sta fe_src1+1
        lda #<(fe_tmp2)
        sta fe_dst
        lda #>(fe_tmp2)
        sta fe_dst+1
        jsr fe_sqr              ; fe_tmp2 = z^22

        ; --- z_5_0 = z22 * z9 = z^31 → fe_tmp2 ---
        lda #<(fe_tmp2)
        sta fe_src1
        lda #>(fe_tmp2)
        sta fe_src1+1
        lda #<(fe_tmp3)
        sta fe_src2
        lda #>(fe_tmp3)
        sta fe_src2+1
        lda #<(fe_tmp2)
        sta fe_dst
        lda #>(fe_tmp2)
        sta fe_dst+1
        jsr fe_mul              ; fe_tmp2 = z^(2^5-1)

        ; --- Save z_5_0 to fe_tmp3, square 5x, multiply ---
        lda #<(fe_tmp2)
        sta fe_src1
        lda #>(fe_tmp2)
        sta fe_src1+1
        lda #<(fe_tmp3)
        sta fe_dst
        lda #>(fe_tmp3)
        sta fe_dst+1
        jsr fe_copy             ; fe_tmp3 = z_5_0

        lda #5
        jsr fe_inv_sqrn_tmp2    ; fe_tmp2 = z_5_0^(2^5)

        ; --- z_10_0 = fe_tmp2 * fe_tmp3 → x25_b (saved) ---
        lda #<(fe_tmp2)
        sta fe_src1
        lda #>(fe_tmp2)
        sta fe_src1+1
        lda #<(fe_tmp3)
        sta fe_src2
        lda #>(fe_tmp3)
        sta fe_src2+1
        lda #<(x25_b)
        sta fe_dst
        lda #>(x25_b)
        sta fe_dst+1
        jsr fe_mul              ; x25_b = z^(2^10-1)

        ; --- z_20_0: copy z_10_0 to tmp2, square 10x, multiply with z_10_0 ---
        lda #<(x25_b)
        sta fe_src1
        lda #>(x25_b)
        sta fe_src1+1
        lda #<(fe_tmp2)
        sta fe_dst
        lda #>(fe_tmp2)
        sta fe_dst+1
        jsr fe_copy             ; fe_tmp2 = z_10_0

        lda #10
        jsr fe_inv_sqrn_tmp2    ; fe_tmp2 = z_10_0^(2^10)

        lda #<(fe_tmp2)
        sta fe_src1
        lda #>(fe_tmp2)
        sta fe_src1+1
        lda #<(x25_b)
        sta fe_src2
        lda #>(x25_b)
        sta fe_src2+1
        lda #<(fe_tmp2)
        sta fe_dst
        lda #>(fe_tmp2)
        sta fe_dst+1
        jsr fe_mul              ; fe_tmp2 = z^(2^20-1)

        ; --- z_40_0: square 20x, multiply with z_20_0 ---
        lda #<(fe_tmp2)
        sta fe_src1
        lda #>(fe_tmp2)
        sta fe_src1+1
        lda #<(fe_tmp3)
        sta fe_dst
        lda #>(fe_tmp3)
        sta fe_dst+1
        jsr fe_copy             ; fe_tmp3 = z_20_0

        lda #20
        jsr fe_inv_sqrn_tmp2    ; fe_tmp2 = z_20_0^(2^20)

        lda #<(fe_tmp2)
        sta fe_src1
        lda #>(fe_tmp2)
        sta fe_src1+1
        lda #<(fe_tmp3)
        sta fe_src2
        lda #>(fe_tmp3)
        sta fe_src2+1
        lda #<(fe_tmp2)
        sta fe_dst
        lda #>(fe_tmp2)
        sta fe_dst+1
        jsr fe_mul              ; fe_tmp2 = z^(2^40-1)

        ; --- z_50_0: square 10x, multiply with z_10_0 → x25_da (saved) ---
        lda #10
        jsr fe_inv_sqrn_tmp2    ; fe_tmp2 = z_40_0^(2^10)

        lda #<(fe_tmp2)
        sta fe_src1
        lda #>(fe_tmp2)
        sta fe_src1+1
        lda #<(x25_b)
        sta fe_src2
        lda #>(x25_b)
        sta fe_src2+1
        lda #<(x25_da)
        sta fe_dst
        lda #>(x25_da)
        sta fe_dst+1
        jsr fe_mul              ; x25_da = z^(2^50-1)

        ; --- z_100_0: copy z_50_0 to tmp2, square 50x, multiply → x25_cb (saved) ---
        lda #<(x25_da)
        sta fe_src1
        lda #>(x25_da)
        sta fe_src1+1
        lda #<(fe_tmp2)
        sta fe_dst
        lda #>(fe_tmp2)
        sta fe_dst+1
        jsr fe_copy

        lda #50
        jsr fe_inv_sqrn_tmp2

        lda #<(fe_tmp2)
        sta fe_src1
        lda #>(fe_tmp2)
        sta fe_src1+1
        lda #<(x25_da)
        sta fe_src2
        lda #>(x25_da)
        sta fe_src2+1
        lda #<(x25_cb)
        sta fe_dst
        lda #>(x25_cb)
        sta fe_dst+1
        jsr fe_mul              ; x25_cb = z^(2^100-1)

        ; --- z_200_0: copy z_100_0 to tmp2, square 100x, multiply ---
        lda #<(x25_cb)
        sta fe_src1
        lda #>(x25_cb)
        sta fe_src1+1
        lda #<(fe_tmp2)
        sta fe_dst
        lda #>(fe_tmp2)
        sta fe_dst+1
        jsr fe_copy

        lda #100
        jsr fe_inv_sqrn_tmp2

        lda #<(fe_tmp2)
        sta fe_src1
        lda #>(fe_tmp2)
        sta fe_src1+1
        lda #<(x25_cb)
        sta fe_src2
        lda #>(x25_cb)
        sta fe_src2+1
        lda #<(fe_tmp2)
        sta fe_dst
        lda #>(fe_tmp2)
        sta fe_dst+1
        jsr fe_mul              ; fe_tmp2 = z^(2^200-1)

        ; --- z_250_0: square 50x, multiply with z_50_0 ---
        lda #50
        jsr fe_inv_sqrn_tmp2

        lda #<(fe_tmp2)
        sta fe_src1
        lda #>(fe_tmp2)
        sta fe_src1+1
        lda #<(x25_da)
        sta fe_src2
        lda #>(x25_da)
        sta fe_src2+1
        lda #<(fe_tmp2)
        sta fe_dst
        lda #>(fe_tmp2)
        sta fe_dst+1
        jsr fe_mul              ; fe_tmp2 = z^(2^250-1)

        ; --- Final: square 5x, multiply with z11 ---
        lda #5
        jsr fe_inv_sqrn_tmp2    ; fe_tmp2 = z^((2^250-1)*2^5) = z^(2^255-32)

        lda #<(fe_tmp2)
        sta fe_src1
        lda #>(fe_tmp2)
        sta fe_src1+1
        lda #<(x25_a)
        sta fe_src2
        lda #>(x25_a)
        sta fe_src2+1
        lda fe_inv_dst
        sta fe_dst
        lda fe_inv_dst+1
        sta fe_dst+1
        jsr fe_mul              ; (original fe_dst) = z^(2^255-21) = z^(p-2)
        jsr fe_reduce_final     ; fe_inv output must be canonical

        rts

; Saved destination pointer for fe_inv
fe_inv_dst:     .word 0

; =============================================================================
; fe_inv_sqrn_tmp2 - Square fe_tmp2 in place N times
;
; Input: A = number of squarings
; Clobbers: A, X, Y, fe_src1, fe_src2, fe_dst
; =============================================================================
fe_inv_sqrn_tmp2:
        sta fe_inv_sqr_cnt
@loop:
        lda #<(fe_tmp2)
        sta fe_src1
        lda #>(fe_tmp2)
        sta fe_src1+1
        lda #<(fe_tmp2)
        sta fe_dst
        lda #>(fe_tmp2)
        sta fe_dst+1
        jsr fe_sqr
        dec fe_inv_sqr_cnt
        bne @loop
        rts

fe_inv_sqr_cnt: .byte 0
