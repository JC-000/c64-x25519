; =============================================================================
; fe25519.asm - Field arithmetic mod p = 2^255 - 19
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
; =============================================================================
fe_cswap:
        sta fe_carry           ; save mask
        ldy #31
@loop:
        lda (fe_src1),y
        eor (fe_src2),y        ; diff = a ^ b
        and fe_carry           ; mask it
        sta fe_loop            ; temp
        lda (fe_src1),y
        eor fe_loop
        sta (fe_src1),y
        lda (fe_src2),y
        eor fe_loop
        sta (fe_src2),y
        dey
        bpl @loop
        rts

; =============================================================================
; fe_mul - (fe_dst) = (fe_src1) * (fe_src2) mod p
;
; Optimized schoolbook 32x32->64-byte multiply with inlined quarter-square
; multiplication. Copies src2 to an absolute buffer to avoid repeated
; indirect-indexed loads, caches src1[i] per outer iteration, and inlines
; the mul_8x8 logic to avoid JSR/RTS overhead (~12 cycles saved per multiply).
;
; Clobbers: A, X, Y
; =============================================================================
fe_mul:
        ; 1. Zero the 64-byte product buffer
        ldx #63
        lda #0
@zero_wide:
        sta fe_wide,x
        dex
        bpl @zero_wide

        ; 2. Copy src2 to absolute buffer (saves 1-2 cycles per inner access)
        ldy #31
@copy_src2:
        lda (fe_src2),y
        sta mul_src2_buf,y
        dey
        bpl @copy_src2

        ; 3. Schoolbook multiply with inlined mul_8x8
        lda #0
        sta fe_mul_i
@mul_outer:
        ldy fe_mul_i
        lda (fe_src1),y
        bne @nonzero_i         ; branch if src1[i] != 0
        jmp @skip_zero
@nonzero_i:
        sta mul_cached_a       ; cache src1[i] for entire inner loop

        lda #0
        sta fe_mul_j
@mul_inner:
        ldx fe_mul_j
        lda mul_src2_buf,x     ; A = src2[j] (absolute indexed = 4 cycles)
        beq @next_j            ; skip if zero

        ; --- INLINED mul_8x8: mul_cached_a * A -> poly_prod_lo/hi ---
        sta mul_b              ; save src2[j]
        tax                    ; X = src2[j] (kept for later)

        ; Compute sum = a + b
        lda mul_cached_a
        clc
        adc mul_b              ; A = a + b (low byte)
        tay                    ; Y = sum low byte
        lda #0
        adc #0                 ; carry -> sum page (0 or 1)
        sta mul_s_pg

        ; Compute |a - b|
        lda mul_cached_a
        sec
        sbc mul_b
        bcs @no_neg
        eor #$ff
        adc #1                 ; negate (carry was clear, so ADC adds 1)
@no_neg:
        tax                    ; X = |a-b| (always <= 255)

        ; sqtab[sum] - sqtab[|diff|]
        lda mul_s_pg
        beq @sum_pg0

        ; sum is in page 1 (256..510)
        lda sqtab_lo+256,y
        sec
        sbc sqtab_lo,x
        sta poly_prod_lo
        lda sqtab_hi+256,y
        sbc sqtab_hi,x
        sta poly_prod_hi
        jmp @accum

@sum_pg0:
        ; sum is in page 0 (0..255)
        lda sqtab_lo,y
        sec
        sbc sqtab_lo,x
        sta poly_prod_lo
        lda sqtab_hi,y
        sbc sqtab_hi,x
        sta poly_prod_hi
        ; --- END INLINED mul_8x8 ---

@accum:
        ; Add 16-bit product to fe_wide[i+j]
        lda fe_mul_i
        clc
        adc fe_mul_j
        tax                    ; X = i+j

        clc
        lda fe_wide,x
        adc poly_prod_lo
        sta fe_wide,x
        inx
        lda fe_wide,x
        adc poly_prod_hi
        sta fe_wide,x
        bcc @next_j

        ; Propagate carry
@prop_carry:
        inx
        cpx #64
        bcs @next_j
        sec
        lda fe_wide,x
        adc #0
        sta fe_wide,x
        bcs @prop_carry

@next_j:
        inc fe_mul_j
        lda fe_mul_j
        cmp #32
        bcs @skip_zero
        jmp @mul_inner

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

        jsr fe_reduce_final
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
        lda fe_wide+32,x
        beq @reduce1_zero

        stx fe_loop            ; save byte index
        jsr mul_by_38          ; poly_prod_lo/hi = A * 38
        ldx fe_loop            ; restore byte index

        ; Add product + running carry to fe_wide[x]
        clc
        lda poly_prod_lo
        adc fe_carry
        sta fe_carry
        lda poly_prod_hi
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
        jsr mul_by_38

        clc
        lda fe_wide
        adc poly_prod_lo
        sta fe_wide
        lda fe_wide+1
        adc poly_prod_hi
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

mul38_in:  !byte 0
mul38_lo:  !byte 0
mul38_hi:  !byte 0

; =============================================================================
; fe_sqr - (fe_dst) = (fe_src1)^2 mod p
;
; Dedicated squaring: exploits symmetry a[i]*a[j] = a[j]*a[i].
; 1. Cross terms: accumulate a[i]*a[j] for i < j   (496 mul_8x8 calls)
; 2. Double the 64-byte buffer (shift left 1 bit)
; 3. Diagonal: add a[i]*a[i] at position 2*i        (32 mul_8x8 calls)
; 4. Reduce mod p
; Total: 528 byte-multiplies vs 1024 for schoolbook.
;
; Clobbers: A, X, Y
; =============================================================================
fe_sqr:
        ; 1. Zero the 64-byte product buffer
        ldx #63
        lda #0
@zero_wide:
        sta fe_wide,x
        dex
        bpl @zero_wide

        ; 2. Cross terms: accumulate a[i]*a[j] for all i < j
        lda #0
        sta fe_mul_i           ; i = 0
@sqr_outer:
        ldy fe_mul_i
        lda (fe_src1),y
        beq @sqr_skip_i       ; skip if a[i] == 0

        ; j starts at i+1
        lda fe_mul_i
        clc
        adc #1
        sta fe_mul_j

@sqr_inner:
        ; Load a[i]
        ldy fe_mul_i
        lda (fe_src1),y
        pha                    ; save a[i]

        ; Load a[j]
        ldy fe_mul_j
        lda (fe_src1),y
        beq @sqr_skip_j       ; skip if a[j] == 0
        tax                    ; X = a[j]
        pla                    ; A = a[i]
        jsr mul_8x8            ; poly_prod_lo/hi = a[i] * a[j]

        ; Add to fe_wide[i+j]
        lda fe_mul_i
        clc
        adc fe_mul_j
        tax                    ; X = i+j

        clc
        lda fe_wide,x
        adc poly_prod_lo
        sta fe_wide,x
        inx
        lda fe_wide,x
        adc poly_prod_hi
        sta fe_wide,x
        bcc @sqr_next_j

        ; Propagate carry
@sqr_prop:
        inx
        cpx #64
        bcs @sqr_next_j
        sec
        lda fe_wide,x
        adc #0                 ; carry is set via SEC
        sta fe_wide,x
        bcs @sqr_prop
        jmp @sqr_next_j        ; carry propagation done, skip pla

@sqr_skip_j:
        pla                    ; discard a[i]
@sqr_next_j:
        inc fe_mul_j
        lda fe_mul_j
        cmp #32
        bcc @sqr_inner

@sqr_skip_i:
        inc fe_mul_i
        lda fe_mul_i
        cmp #31                ; i goes 0..30 (j needs room for i+1)
        bcs @sqr_cross_done
        jmp @sqr_outer
@sqr_cross_done:

        ; 3. Double the entire 64-byte buffer (left shift by 1 bit)
        ;    Use DEX for loop count (preserves carry) and INY for index.
        clc
        ldx #64                ; count down
        ldy #0                 ; index up
@double_loop:
        lda fe_wide,y
        rol                    ; uses carry from previous byte
        sta fe_wide,y
        iny
        dex                    ; DEX preserves carry!
        bne @double_loop

        ; 4. Add diagonal terms: a[i]^2 at position 2*i
        lda #0
        sta fe_mul_i
@diag_outer:
        ldy fe_mul_i
        lda (fe_src1),y
        beq @diag_skip         ; skip if a[i] == 0
        tax                    ; X = a[i]
        ; A already = a[i]
        jsr mul_8x8            ; poly_prod = a[i]^2

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
        adc #0                 ; carry is set via SEC
        sta fe_wide,x
        bcs @diag_prop

@diag_skip:
        inc fe_mul_i
        lda fe_mul_i
        cmp #32
        bcs @sqr_reduce
        jmp @diag_outer

@sqr_reduce:
        ; 5. Reduce mod p (same as fe_mul)
        jsr fe_reduce_wide

        ; Copy result to (fe_dst)
        ldy #31
@copy_result:
        lda fe_wide,y
        sta (fe_dst),y
        dey
        bpl @copy_result

        jsr fe_reduce_final
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

        ; src1[i] * $41 → add at offset i
        ldx #$41
        jsr mul_8x8
        ldx fe_mul_i
        clc
        lda fe_wide,x
        adc poly_prod_lo
        sta fe_wide,x
        lda fe_wide+1,x
        adc poly_prod_hi
        sta fe_wide+1,x
        bcc +
        inc fe_wide+2,x
        bne +
        inc fe_wide+3,x
+
        ; src1[i] * $DB → add at offset i+1
        ldy fe_mul_i
        lda (fe_src1),y
        ldx #$db
        jsr mul_8x8
        ldx fe_mul_i
        clc
        lda fe_wide+1,x
        adc poly_prod_lo
        sta fe_wide+1,x
        lda fe_wide+2,x
        adc poly_prod_hi
        sta fe_wide+2,x
        bcc +
        inc fe_wide+3,x
        bne +
        inc fe_wide+4,x
+
        ; src1[i] * $01 → add at offset i+2
        ldy fe_mul_i
        lda (fe_src1),y
        ldx fe_mul_i
        clc
        adc fe_wide+2,x
        sta fe_wide+2,x
        bcc +
        inc fe_wide+3,x
        bne +
        inc fe_wide+4,x
+
@skip_zero_a24:
        ldx fe_mul_i
        inx
        cpx #32
        bcc @outer

        ; Reduce: fe_wide[32..34] * 38 → add to fe_wide[0..31]
        lda fe_wide+32
        beq @r_b33
        jsr mul_by_38
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
        lda fe_wide+33
        beq @r_b34
        jsr mul_by_38
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
        lda fe_wide+34
        beq @r_done_a24
        jsr mul_by_38
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
        lda #<fe_tmp1
        sta fe_dst
        lda #>fe_tmp1
        sta fe_dst+1
        jsr fe_copy             ; fe_tmp1 = z

        ; --- z2 = z^2 → fe_tmp2 ---
        lda #<fe_tmp1
        sta fe_src1
        lda #>fe_tmp1
        sta fe_src1+1
        lda #<fe_tmp2
        sta fe_dst
        lda #>fe_tmp2
        sta fe_dst+1
        jsr fe_sqr              ; fe_tmp2 = z^2

        ; --- z4 = z2^2 → fe_tmp3 ---
        lda #<fe_tmp2
        sta fe_src1
        lda #>fe_tmp2
        sta fe_src1+1
        lda #<fe_tmp3
        sta fe_dst
        lda #>fe_tmp3
        sta fe_dst+1
        jsr fe_sqr              ; fe_tmp3 = z^4

        ; --- z8 = z4^2 → fe_tmp3 ---
        lda #<fe_tmp3
        sta fe_src1
        lda #>fe_tmp3
        sta fe_src1+1
        lda #<fe_tmp3
        sta fe_dst
        lda #>fe_tmp3
        sta fe_dst+1
        jsr fe_sqr              ; fe_tmp3 = z^8

        ; --- z9 = z8 * z → fe_tmp3 ---
        lda #<fe_tmp3
        sta fe_src1
        lda #>fe_tmp3
        sta fe_src1+1
        lda #<fe_tmp1
        sta fe_src2
        lda #>fe_tmp1
        sta fe_src2+1
        lda #<fe_tmp3
        sta fe_dst
        lda #>fe_tmp3
        sta fe_dst+1
        jsr fe_mul              ; fe_tmp3 = z^9

        ; --- z11 = z9 * z2 → x25_a (saved for final step) ---
        lda #<fe_tmp3
        sta fe_src1
        lda #>fe_tmp3
        sta fe_src1+1
        lda #<fe_tmp2
        sta fe_src2
        lda #>fe_tmp2
        sta fe_src2+1
        lda #<x25_a
        sta fe_dst
        lda #>x25_a
        sta fe_dst+1
        jsr fe_mul              ; x25_a = z^11

        ; --- z22 = z11^2 → fe_tmp2 ---
        lda #<x25_a
        sta fe_src1
        lda #>x25_a
        sta fe_src1+1
        lda #<fe_tmp2
        sta fe_dst
        lda #>fe_tmp2
        sta fe_dst+1
        jsr fe_sqr              ; fe_tmp2 = z^22

        ; --- z_5_0 = z22 * z9 = z^31 → fe_tmp2 ---
        lda #<fe_tmp2
        sta fe_src1
        lda #>fe_tmp2
        sta fe_src1+1
        lda #<fe_tmp3
        sta fe_src2
        lda #>fe_tmp3
        sta fe_src2+1
        lda #<fe_tmp2
        sta fe_dst
        lda #>fe_tmp2
        sta fe_dst+1
        jsr fe_mul              ; fe_tmp2 = z^(2^5-1)

        ; --- Save z_5_0 to fe_tmp3, square 5x, multiply ---
        lda #<fe_tmp2
        sta fe_src1
        lda #>fe_tmp2
        sta fe_src1+1
        lda #<fe_tmp3
        sta fe_dst
        lda #>fe_tmp3
        sta fe_dst+1
        jsr fe_copy             ; fe_tmp3 = z_5_0

        lda #5
        jsr fe_inv_sqrn_tmp2    ; fe_tmp2 = z_5_0^(2^5)

        ; --- z_10_0 = fe_tmp2 * fe_tmp3 → x25_b (saved) ---
        lda #<fe_tmp2
        sta fe_src1
        lda #>fe_tmp2
        sta fe_src1+1
        lda #<fe_tmp3
        sta fe_src2
        lda #>fe_tmp3
        sta fe_src2+1
        lda #<x25_b
        sta fe_dst
        lda #>x25_b
        sta fe_dst+1
        jsr fe_mul              ; x25_b = z^(2^10-1)

        ; --- z_20_0: copy z_10_0 to tmp2, square 10x, multiply with z_10_0 ---
        lda #<x25_b
        sta fe_src1
        lda #>x25_b
        sta fe_src1+1
        lda #<fe_tmp2
        sta fe_dst
        lda #>fe_tmp2
        sta fe_dst+1
        jsr fe_copy             ; fe_tmp2 = z_10_0

        lda #10
        jsr fe_inv_sqrn_tmp2    ; fe_tmp2 = z_10_0^(2^10)

        lda #<fe_tmp2
        sta fe_src1
        lda #>fe_tmp2
        sta fe_src1+1
        lda #<x25_b
        sta fe_src2
        lda #>x25_b
        sta fe_src2+1
        lda #<fe_tmp2
        sta fe_dst
        lda #>fe_tmp2
        sta fe_dst+1
        jsr fe_mul              ; fe_tmp2 = z^(2^20-1)

        ; --- z_40_0: square 20x, multiply with z_20_0 ---
        lda #<fe_tmp2
        sta fe_src1
        lda #>fe_tmp2
        sta fe_src1+1
        lda #<fe_tmp3
        sta fe_dst
        lda #>fe_tmp3
        sta fe_dst+1
        jsr fe_copy             ; fe_tmp3 = z_20_0

        lda #20
        jsr fe_inv_sqrn_tmp2    ; fe_tmp2 = z_20_0^(2^20)

        lda #<fe_tmp2
        sta fe_src1
        lda #>fe_tmp2
        sta fe_src1+1
        lda #<fe_tmp3
        sta fe_src2
        lda #>fe_tmp3
        sta fe_src2+1
        lda #<fe_tmp2
        sta fe_dst
        lda #>fe_tmp2
        sta fe_dst+1
        jsr fe_mul              ; fe_tmp2 = z^(2^40-1)

        ; --- z_50_0: square 10x, multiply with z_10_0 → x25_da (saved) ---
        lda #10
        jsr fe_inv_sqrn_tmp2    ; fe_tmp2 = z_40_0^(2^10)

        lda #<fe_tmp2
        sta fe_src1
        lda #>fe_tmp2
        sta fe_src1+1
        lda #<x25_b
        sta fe_src2
        lda #>x25_b
        sta fe_src2+1
        lda #<x25_da
        sta fe_dst
        lda #>x25_da
        sta fe_dst+1
        jsr fe_mul              ; x25_da = z^(2^50-1)

        ; --- z_100_0: copy z_50_0 to tmp2, square 50x, multiply → x25_cb (saved) ---
        lda #<x25_da
        sta fe_src1
        lda #>x25_da
        sta fe_src1+1
        lda #<fe_tmp2
        sta fe_dst
        lda #>fe_tmp2
        sta fe_dst+1
        jsr fe_copy

        lda #50
        jsr fe_inv_sqrn_tmp2

        lda #<fe_tmp2
        sta fe_src1
        lda #>fe_tmp2
        sta fe_src1+1
        lda #<x25_da
        sta fe_src2
        lda #>x25_da
        sta fe_src2+1
        lda #<x25_cb
        sta fe_dst
        lda #>x25_cb
        sta fe_dst+1
        jsr fe_mul              ; x25_cb = z^(2^100-1)

        ; --- z_200_0: copy z_100_0 to tmp2, square 100x, multiply ---
        lda #<x25_cb
        sta fe_src1
        lda #>x25_cb
        sta fe_src1+1
        lda #<fe_tmp2
        sta fe_dst
        lda #>fe_tmp2
        sta fe_dst+1
        jsr fe_copy

        lda #100
        jsr fe_inv_sqrn_tmp2

        lda #<fe_tmp2
        sta fe_src1
        lda #>fe_tmp2
        sta fe_src1+1
        lda #<x25_cb
        sta fe_src2
        lda #>x25_cb
        sta fe_src2+1
        lda #<fe_tmp2
        sta fe_dst
        lda #>fe_tmp2
        sta fe_dst+1
        jsr fe_mul              ; fe_tmp2 = z^(2^200-1)

        ; --- z_250_0: square 50x, multiply with z_50_0 ---
        lda #50
        jsr fe_inv_sqrn_tmp2

        lda #<fe_tmp2
        sta fe_src1
        lda #>fe_tmp2
        sta fe_src1+1
        lda #<x25_da
        sta fe_src2
        lda #>x25_da
        sta fe_src2+1
        lda #<fe_tmp2
        sta fe_dst
        lda #>fe_tmp2
        sta fe_dst+1
        jsr fe_mul              ; fe_tmp2 = z^(2^250-1)

        ; --- Final: square 5x, multiply with z11 ---
        lda #5
        jsr fe_inv_sqrn_tmp2    ; fe_tmp2 = z^((2^250-1)*2^5) = z^(2^255-32)

        lda #<fe_tmp2
        sta fe_src1
        lda #>fe_tmp2
        sta fe_src1+1
        lda #<x25_a
        sta fe_src2
        lda #>x25_a
        sta fe_src2+1
        lda fe_inv_dst
        sta fe_dst
        lda fe_inv_dst+1
        sta fe_dst+1
        jsr fe_mul              ; (original fe_dst) = z^(2^255-21) = z^(p-2)

        rts

; Saved destination pointer for fe_inv
fe_inv_dst:     !word 0

; =============================================================================
; fe_inv_sqrn_tmp2 - Square fe_tmp2 in place N times
;
; Input: A = number of squarings
; Clobbers: A, X, Y, fe_src1, fe_src2, fe_dst
; =============================================================================
fe_inv_sqrn_tmp2:
        sta fe_inv_sqr_cnt
@loop:
        lda #<fe_tmp2
        sta fe_src1
        lda #>fe_tmp2
        sta fe_src1+1
        lda #<fe_tmp2
        sta fe_dst
        lda #>fe_tmp2
        sta fe_dst+1
        jsr fe_sqr
        dec fe_inv_sqr_cnt
        bne @loop
        rts

fe_inv_sqr_cnt: !byte 0
