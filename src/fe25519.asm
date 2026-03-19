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
; Schoolbook 32x32→64-byte multiply using mul_8x8 (quarter-square table).
; Then reduce mod p.
; Clobbers: A, X, Y
; =============================================================================
fe_mul:
        ; --- Single-level Karatsuba 32x32 multiply ---
        ; Split a = aH*2^128 + aL, b = bH*2^128 + bL (16 bytes each)
        ; P0 = aL*bL, P2 = aH*bH, P1 = (aL+aH)*(bL+bH) - P0 - P2
        ; result = P0 + P1*2^128 + P2*2^256
        ; Then reduce mod p (2^256 ≡ 38).

        ; Copy src1 and src2 to absolute buffers
        ldy #31
@cpy:   lda (fe_src1),y
        sta kara_a,y
        lda (fe_src2),y
        sta kara_b,y
        dey
        bpl @cpy

        ; Save fe_dst on stack (2 bytes) for later
        lda fe_dst+1
        pha
        lda fe_dst
        pha

        ; --- P0 = aL * bL (16x16 → 32 bytes) ---
        lda #<kara_a
        sta fe_src1
        lda #>kara_a
        sta fe_src1+1
        lda #<kara_b
        sta fe_src2
        lda #>kara_b
        sta fe_src2+1
        ldx #31
        lda #0
@z0:    sta fe_wide,x
        dex
        bpl @z0
        lda #16
        sta kara_mul_len
        jsr schoolbook_16x16
        ldy #31
@cp0:   lda fe_wide,y
        sta kara_p0,y
        dey
        bpl @cp0

        ; --- P2 = aH * bH (16x16 → 32 bytes) ---
        lda #<(kara_a+16)
        sta fe_src1
        lda #>(kara_a+16)
        sta fe_src1+1
        lda #<(kara_b+16)
        sta fe_src2
        lda #>(kara_b+16)
        sta fe_src2+1
        ldx #31
        lda #0
@z2:    sta fe_wide,x
        dex
        bpl @z2
        lda #16
        sta kara_mul_len
        jsr schoolbook_16x16
        ldy #31
@cp2:   lda fe_wide,y
        sta kara_p2,y
        dey
        bpl @cp2

        ; --- sum_a = aL + aH (17 bytes) ---
        clc
        ldy #0
        ldx #16
@adda:  lda kara_a,y
        adc kara_a+16,y
        sta kara_sum_a,y
        iny
        dex                    ; DEX doesn't affect carry
        bne @adda
        lda #0
        adc #0
        sta kara_sum_a+16      ; carry byte

        ; --- sum_b = bL + bH (17 bytes) ---
        clc
        ldy #0
        ldx #16
@addb:  lda kara_b,y
        adc kara_b+16,y
        sta kara_sum_b,y
        iny
        dex                    ; DEX doesn't affect carry
        bne @addb
        lda #0
        adc #0
        sta kara_sum_b+16      ; carry byte

        ; --- P1_raw = sum_a * sum_b (17x17 → 34 bytes) ---
        lda #<kara_sum_a
        sta fe_src1
        lda #>kara_sum_a
        sta fe_src1+1
        lda #<kara_sum_b
        sta fe_src2
        lda #>kara_sum_b
        sta fe_src2+1
        ldx #33
        lda #0
@z1:    sta fe_wide,x
        dex
        bpl @z1
        lda #17
        sta kara_mul_len
        jsr schoolbook_16x16
        ; Copy fe_wide[0..33] to kara_p1
        ldy #33
@cp1:   lda fe_wide,y
        sta kara_p1,y
        dey
        bpl @cp1

        ; --- P1 = P1_raw - P0 (34-byte minus 32-byte, padded) ---
        sec
        ldy #0
        ldx #32
@sub0:  lda kara_p1,y
        sbc kara_p0,y
        sta kara_p1,y
        iny
        dex                    ; DEX doesn't affect carry
        bne @sub0
        ; Propagate borrow through remaining 2 bytes
        lda kara_p1+32
        sbc #0
        sta kara_p1+32
        lda kara_p1+33
        sbc #0
        sta kara_p1+33

        ; --- P1 = P1 - P2 ---
        sec
        ldy #0
        ldx #32
@sub2:  lda kara_p1,y
        sbc kara_p2,y
        sta kara_p1,y
        iny
        dex                    ; DEX doesn't affect carry
        bne @sub2
        lda kara_p1+32
        sbc #0
        sta kara_p1+32
        lda kara_p1+33
        sbc #0
        sta kara_p1+33

        ; --- Combine: result = P0 + P1*2^128 + P2*2^256 ---
        ; Build into fe_wide[0..63]

        ; Start with P0 in [0..31]
        ldy #31
@init:  lda kara_p0,y
        sta fe_wide,y
        dey
        bpl @init
        ; Zero upper half [32..63]
        lda #0
        ldx #32
@zhi:   sta fe_wide,x
        inx
        cpx #64
        bcc @zhi

        ; Add P1 at offset 16 (P1 is 34 bytes → positions 16..49)
        clc
        ldy #0
        ldx #34
@addp1: lda fe_wide+16,y
        adc kara_p1,y
        sta fe_wide+16,y
        iny
        dex                    ; DEX doesn't affect carry
        bne @addp1
        ; Propagate carry through remaining bytes
        bcc @p1done
@prop1: cpy #48                ; y is at 34 after loop; max offset = 16+48=64
        bcs @p1done
        lda fe_wide+16,y
        clc
        adc #1                 ; add the carry we're propagating
        sta fe_wide+16,y
        iny
        bcs @prop1             ; if still overflowed, keep propagating
@p1done:

        ; Add P2 at offset 32 (P2 is 32 bytes → positions 32..63)
        clc
        ldy #0
        ldx #32
@addp2: lda fe_wide+32,y
        adc kara_p2,y
        sta fe_wide+32,y
        iny
        dex                    ; DEX doesn't affect carry
        bne @addp2
        ; Any carry past byte 63 is handled by reduction

        ; --- Reduce mod p ---
        jsr fe_reduce_wide

        ; Restore fe_dst from stack
        pla
        sta fe_dst
        pla
        sta fe_dst+1

        ; Copy result to (fe_dst)
        ldy #31
@cpres: lda fe_wide,y
        sta (fe_dst),y
        dey
        bpl @cpres

        jsr fe_reduce_final
        jsr fe_reduce_final    ; second pass needed when reduce_wide gives >= 2p
        rts

; =============================================================================
; schoolbook_16x16 - Inner schoolbook multiply for Karatsuba
;
; Multiplies (fe_src1)[0..len-1] * (fe_src2)[0..len-1]
; Length in kara_mul_len (16 or 17)
; Result accumulated into fe_wide[] (MUST be pre-zeroed by caller)
; Clobbers: A, X, Y, fe_mul_i, fe_mul_j
; =============================================================================
schoolbook_16x16:
        lda #0
        sta fe_mul_i
@outer:
        ldy fe_mul_i
        lda (fe_src1),y
        beq @skip_i
        lda #0
        sta fe_mul_j
@inner:
        ldy fe_mul_i
        lda (fe_src1),y
        pha
        ldy fe_mul_j
        lda (fe_src2),y
        beq @skip_j_zero
        tax
        pla
        jsr mul_8x8
        ; Accumulate at fe_wide[i+j]
        lda fe_mul_i
        clc
        adc fe_mul_j
        tax
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
@prop:  inx
        cpx #34              ; max product size (17x17)
        bcs @next_j
        sec
        lda fe_wide,x
        adc #0               ; SEC + ADC #0 = add 1
        sta fe_wide,x
        bcs @prop
        jmp @next_j
@skip_j_zero:
        pla
@next_j:
        inc fe_mul_j
        lda fe_mul_j
        cmp kara_mul_len
        bcc @inner
@skip_i:
        inc fe_mul_i
        lda fe_mul_i
        cmp kara_mul_len
        bcs @done
        jmp @outer
@done:
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
        ldx #38
        jsr mul_8x8            ; poly_prod_lo/hi = byte * 38
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
        ldx #38
        jsr mul_8x8

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
; fe_sqr - (fe_dst) = (fe_src1)^2 mod p
; Clobbers: A, X, Y
; =============================================================================
fe_sqr:
        lda fe_src1
        sta fe_src2
        lda fe_src1+1
        sta fe_src2+1
        jmp fe_mul

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
        ldx #38
        jsr mul_8x8
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
        ldx #38
        jsr mul_8x8
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
        ldx #38
        jsr mul_8x8
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
