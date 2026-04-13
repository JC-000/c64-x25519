; =============================================================================
; x25519.s - X25519 Diffie-Hellman (RFC 7748)
;
; Montgomery ladder scalar multiplication on Curve25519.
; Uses fe25519.s field arithmetic.
;
; API:
;   x25519_clamp       - Clamp 32-byte scalar per RFC 7748
;   x25519_scalarmult  - Montgomery ladder: result = scalar * u-point
;   x25519_base        - Convenience: result = scalar * basepoint(9)
;
; Input:  x25_scalar (32 bytes), x25_u (32 bytes)
; Output: x25_result (32 bytes)
;
; Performance: ~2550 field multiplies + ~264 for inversion ≈ ~2 min per op
; =============================================================================

.setcpu "6502"

.include "constants.s"

.export x25519_clamp, x25519_scalarmult, x25519_base

; DEBUG-ONLY export — NOT part of the stable v0.1.0 public API.
; x25519_ladder_step is exposed so differential-testing harnesses can drive
; the ladder one step at a time and compare intermediate field elements
; against a Python reference (see tools/diff_ladder_bug.py ancestors).
; Downstream consumers of this library MUST NOT depend on this symbol; it
; may be renamed, reshaped, or removed in any release without notice.
.export x25519_ladder_step

; --- Imports from fe25519.s ---
.import fe25519_add, fe25519_sub, fe25519_mul, fe25519_sqr
.import fe25519_one, fe25519_zero, fe25519_copy, fe25519_cswap
.import fe25519_inv, fe25519_reduce_final, fe25519_mul_a24

; --- Imports from data.s ---
.import fe25519_tmp1, fe25519_tmp2, fe25519_tmp3, fe_tmp4
.import x25_x2, x25_z2, x25_x3, x25_z3
.import x25_a, x25_b, x25_da, x25_cb, x25_e
.import x25_scalar, x25_u, x25_result, x25_basepoint

.segment "CODE"

; =============================================================================
; x25519_clamp - Clamp scalar per RFC 7748 §5
;
; Clear bits 0, 1, 2 of byte 0
; Clear bit 7 of byte 31
; Set bit 6 of byte 31
;
; Input/Output: x25_scalar (32 bytes, modified in place)
; Clobbers: A
; =============================================================================
.proc x25519_clamp
        lda x25_scalar
        and #$f8               ; clear bits 0,1,2
        sta x25_scalar
        lda x25_scalar+31
        and #$7f               ; clear bit 7
        ora #$40               ; set bit 6
        sta x25_scalar+31
        rts
.endproc

; =============================================================================
; x25519_scalarmult - Montgomery ladder: x25_result = x25_scalar * x25_u
;
; RFC 7748 Montgomery ladder:
;   x_2 = 1, z_2 = 0, x_3 = u, z_3 = 1
;   For each bit of scalar (from bit 254 down to 0):
;     swap = k_t XOR prev_bit
;     cswap(x_2, x_3, swap)
;     cswap(z_2, z_3, swap)
;     prev_bit = k_t
;     ... ladder step ...
;   cswap(x_2, x_3, prev_bit)
;   cswap(z_2, z_3, prev_bit)
;   result = x_2 * z_2^(-1)
;
; Clobbers: A, X, Y, all fe_* and x25_* ZP vars
; =============================================================================
.proc x25519_scalarmult
        ; Initialize ladder state
        ; x_2 = 1
        lda #<(x25_x2)
        sta fe25519_dst
        lda #>(x25_x2)
        sta fe25519_dst+1
        jsr fe25519_one

        ; z_2 = 0
        lda #<(x25_z2)
        sta fe25519_dst
        lda #>(x25_z2)
        sta fe25519_dst+1
        jsr fe25519_zero

        ; x_3 = u (mask high bit per RFC 7748 decodeUCoordinate)
        lda x25_u+31
        and #$7f
        sta x25_u+31
        lda #<(x25_u)
        sta fe25519_src1
        lda #>(x25_u)
        sta fe25519_src1+1
        lda #<(x25_x3)
        sta fe25519_dst
        lda #>(x25_x3)
        sta fe25519_dst+1
        jsr fe25519_copy

        ; z_3 = 1
        lda #<(x25_z3)
        sta fe25519_dst
        lda #>(x25_z3)
        sta fe25519_dst+1
        jsr fe25519_one

        ; prev_bit = 0
        lda #0
        sta x25_prev_bit

        ; Start from bit 254 (byte 31, bit 6) down to bit 0
        ; bit_number = byte_idx * 8 + bit_position
        ; 254 = 31*8 + 6
        lda #31
        sta x25_byte_idx
        lda #$40               ; bit 6 mask
        sta x25_bit_mask

@bit_loop:
        ; Get current bit k_t (single extraction)
        ldx x25_byte_idx
        lda x25_scalar,x
        and x25_bit_mask
        beq @bit_zero
        lda #1
@bit_zero:
        ; A = k_t (0 or 1)
        tax                    ; X = k_t (save for prev_bit update)
        eor x25_prev_bit       ; A = swap = k_t XOR old prev_bit
        stx x25_prev_bit       ; update prev_bit = k_t

        ; Convert to mask: 0 → $00, 1 → $FF
        beq @no_swap_mask
        lda #$ff
@no_swap_mask:

        ; cswap(x_2, x_3, swap)
        pha                    ; save mask
        sta fe_carry           ; fe25519_cswap reads mask from A
        lda #<(x25_x2)
        sta fe25519_src1
        lda #>(x25_x2)
        sta fe25519_src1+1
        lda #<(x25_x3)
        sta fe25519_src2
        lda #>(x25_x3)
        sta fe25519_src2+1
        lda fe_carry           ; restore mask
        jsr fe25519_cswap

        ; cswap(z_2, z_3, swap)
        pla                    ; restore mask
        sta fe_carry
        lda #<(x25_z2)
        sta fe25519_src1
        lda #>(x25_z2)
        sta fe25519_src1+1
        lda #<(x25_z3)
        sta fe25519_src2
        lda #>(x25_z3)
        sta fe25519_src2+1
        lda fe_carry
        jsr fe25519_cswap

        ; --- Montgomery ladder step ---
        jsr x25519_ladder_step

        ; Advance to next bit
        lsr x25_bit_mask       ; shift mask right
        bne @bit_loop          ; if mask nonzero, same byte

        ; Move to next byte (lower index)
        lda #$80               ; reset to bit 7
        sta x25_bit_mask
        dec x25_byte_idx
        bpl @bit_loop          ; continue until byte_idx < 0

        ; Final cswap with prev_bit
        lda x25_prev_bit
        beq @skip_final_mask
        lda #$ff
@skip_final_mask:
        pha
        sta fe_carry
        lda #<(x25_x2)
        sta fe25519_src1
        lda #>(x25_x2)
        sta fe25519_src1+1
        lda #<(x25_x3)
        sta fe25519_src2
        lda #>(x25_x3)
        sta fe25519_src2+1
        lda fe_carry
        jsr fe25519_cswap

        pla
        sta fe_carry
        lda #<(x25_z2)
        sta fe25519_src1
        lda #>(x25_z2)
        sta fe25519_src1+1
        lda #<(x25_z3)
        sta fe25519_src2
        lda #>(x25_z3)
        sta fe25519_src2+1
        lda fe_carry
        jsr fe25519_cswap

        ; result = x_2 * z_2^(-1)
        ; First compute z_2_inv = fe25519_inv(z_2)
        lda #<(x25_z2)
        sta fe25519_src1
        lda #>(x25_z2)
        sta fe25519_src1+1
        lda #<(x25_result)
        sta fe25519_dst
        lda #>(x25_result)
        sta fe25519_dst+1
        jsr fe25519_inv             ; x25_result = z_2^(-1)

        ; result = x_2 * z_2_inv
        lda #<(x25_x2)
        sta fe25519_src1
        lda #>(x25_x2)
        sta fe25519_src1+1
        lda #<(x25_result)
        sta fe25519_src2
        lda #>(x25_result)
        sta fe25519_src2+1
        lda #<(x25_result)
        sta fe25519_dst
        lda #>(x25_result)
        sta fe25519_dst+1
        jsr fe25519_mul             ; x25_result = x_2 * z_2^(-1) mod p
        jsr fe25519_reduce_final    ; Final output must be canonical

        rts
.endproc

; =============================================================================
; x25519_ladder_step - One step of the Montgomery ladder
;
; Computes the differential addition and doubling:
;   A  = x_2 + z_2       B  = x_2 - z_2
;   AA = A^2              BB = B^2
;   E  = AA - BB
;   C  = x_3 + z_3       D  = x_3 - z_3
;   DA = D * A            CB = C * B
;   x_3 = (DA + CB)^2
;   z_3 = x_1 * (DA - CB)^2
;   x_2 = AA * BB
;   z_2 = E * (AA + a24*E)
;
; Uses x25_a, x25_b, x25_da, x25_cb, x25_e as temporaries.
;
; Clobbers: A, X, Y, all fe_* ZP vars
; =============================================================================
.proc x25519_ladder_step
        ; A = x_2 + z_2 → x25_a
        lda #<(x25_x2)
        sta fe25519_src1
        lda #>(x25_x2)
        sta fe25519_src1+1
        lda #<(x25_z2)
        sta fe25519_src2
        lda #>(x25_z2)
        sta fe25519_src2+1
        lda #<(x25_a)
        sta fe25519_dst
        lda #>(x25_a)
        sta fe25519_dst+1
        jsr fe25519_add

        ; B = x_2 - z_2 → x25_b
        ; fe25519_src1=x25_x2, fe25519_src2=x25_z2 still set from fe25519_add above
        lda #<(x25_b)
        sta fe25519_dst
        lda #>(x25_b)
        sta fe25519_dst+1
        jsr fe25519_sub

        ; AA = A^2 → fe25519_tmp3
        lda #<(x25_a)
        sta fe25519_src1
        lda #>(x25_a)
        sta fe25519_src1+1
        lda #<(fe25519_tmp3)
        sta fe25519_dst
        lda #>(fe25519_tmp3)
        sta fe25519_dst+1
        jsr fe25519_sqr             ; fe25519_tmp3 = AA
        jsr fe25519_reduce_final    ; AA feeds into fe25519_sub/fe25519_add

        ; BB = B^2 → fe_tmp4
        lda #<(x25_b)
        sta fe25519_src1
        lda #>(x25_b)
        sta fe25519_src1+1
        lda #<(fe_tmp4)
        sta fe25519_dst
        lda #>(fe_tmp4)
        sta fe25519_dst+1
        jsr fe25519_sqr             ; fe_tmp4 = BB
        jsr fe25519_reduce_final    ; BB feeds into fe25519_sub

        ; E = AA - BB → x25_e
        lda #<(fe25519_tmp3)
        sta fe25519_src1
        lda #>(fe25519_tmp3)
        sta fe25519_src1+1
        lda #<(fe_tmp4)
        sta fe25519_src2
        lda #>(fe_tmp4)
        sta fe25519_src2+1
        lda #<(x25_e)
        sta fe25519_dst
        lda #>(x25_e)
        sta fe25519_dst+1
        jsr fe25519_sub             ; x25_e = E = AA - BB

        ; C = x_3 + z_3 → fe25519_tmp1 (temp)
        lda #<(x25_x3)
        sta fe25519_src1
        lda #>(x25_x3)
        sta fe25519_src1+1
        lda #<(x25_z3)
        sta fe25519_src2
        lda #>(x25_z3)
        sta fe25519_src2+1
        lda #<(fe25519_tmp1)
        sta fe25519_dst
        lda #>(fe25519_tmp1)
        sta fe25519_dst+1
        jsr fe25519_add             ; fe25519_tmp1 = C

        ; D = x_3 - z_3 → fe25519_tmp2 (temp)
        ; fe25519_src1=x25_x3, fe25519_src2=x25_z3 still set from fe25519_add above
        lda #<(fe25519_tmp2)
        sta fe25519_dst
        lda #>(fe25519_tmp2)
        sta fe25519_dst+1
        jsr fe25519_sub             ; fe25519_tmp2 = D

        ; DA = D * A → x25_da
        lda #<(fe25519_tmp2)
        sta fe25519_src1
        lda #>(fe25519_tmp2)
        sta fe25519_src1+1
        lda #<(x25_a)
        sta fe25519_src2
        lda #>(x25_a)
        sta fe25519_src2+1
        lda #<(x25_da)
        sta fe25519_dst
        lda #>(x25_da)
        sta fe25519_dst+1
        jsr fe25519_mul             ; x25_da = D * A
        jsr fe25519_reduce_final    ; DA feeds into fe25519_add/fe25519_sub

        ; CB = C * B → x25_cb
        lda #<(fe25519_tmp1)
        sta fe25519_src1
        lda #>(fe25519_tmp1)
        sta fe25519_src1+1
        lda #<(x25_b)
        sta fe25519_src2
        lda #>(x25_b)
        sta fe25519_src2+1
        lda #<(x25_cb)
        sta fe25519_dst
        lda #>(x25_cb)
        sta fe25519_dst+1
        jsr fe25519_mul             ; x25_cb = C * B
        jsr fe25519_reduce_final    ; CB feeds into fe25519_add/fe25519_sub

        ; x_3 = (DA + CB)^2
        lda #<(x25_da)
        sta fe25519_src1
        lda #>(x25_da)
        sta fe25519_src1+1
        lda #<(x25_cb)
        sta fe25519_src2
        lda #>(x25_cb)
        sta fe25519_src2+1
        lda #<(x25_x3)
        sta fe25519_dst
        lda #>(x25_x3)
        sta fe25519_dst+1
        jsr fe25519_add             ; x25_x3 = DA + CB
        ; fe25519_dst=x25_x3 still set; copy to fe25519_src1 for squaring
        lda #<(x25_x3)
        sta fe25519_src1
        lda #>(x25_x3)
        sta fe25519_src1+1
        jsr fe25519_sqr             ; x25_x3 = (DA + CB)^2
        jsr fe25519_reduce_final    ; x_3 is output, feeds into add in next iteration

        ; z_3 = x_1 * (DA - CB)^2
        ; x_1 is the original u-coordinate (x25_u)
        lda #<(x25_da)
        sta fe25519_src1
        lda #>(x25_da)
        sta fe25519_src1+1
        lda #<(x25_cb)
        sta fe25519_src2
        lda #>(x25_cb)
        sta fe25519_src2+1
        lda #<(x25_z3)
        sta fe25519_dst
        lda #>(x25_z3)
        sta fe25519_dst+1
        jsr fe25519_sub             ; x25_z3 = DA - CB
        ; fe25519_dst=x25_z3 still set; copy to fe25519_src1 for squaring
        lda #<(x25_z3)
        sta fe25519_src1
        lda #>(x25_z3)
        sta fe25519_src1+1
        jsr fe25519_sqr             ; x25_z3 = (DA - CB)^2
        ; Now z_3 = x_1 * (DA-CB)^2
        ; fe25519_dst=x25_z3 still set from fe25519_sqr above
        lda #<(x25_u)
        sta fe25519_src1
        lda #>(x25_u)
        sta fe25519_src1+1
        lda #<(x25_z3)
        sta fe25519_src2
        lda #>(x25_z3)
        sta fe25519_src2+1
        jsr fe25519_mul             ; x25_z3 = x_1 * (DA - CB)^2
        jsr fe25519_reduce_final    ; z_3 is output, feeds into add/sub in next iteration

        ; x_2 = AA * BB
        lda #<(fe25519_tmp3)
        sta fe25519_src1
        lda #>(fe25519_tmp3)
        sta fe25519_src1+1
        lda #<(fe_tmp4)
        sta fe25519_src2
        lda #>(fe_tmp4)
        sta fe25519_src2+1
        lda #<(x25_x2)
        sta fe25519_dst
        lda #>(x25_x2)
        sta fe25519_dst+1
        jsr fe25519_mul             ; x25_x2 = AA * BB
        jsr fe25519_reduce_final    ; x_2 is output, feeds into add/sub in next iteration

        ; z_2 = E * (AA + a24*E)
        ; First: a24*E → fe25519_tmp1
        lda #<(x25_e)
        sta fe25519_src1
        lda #>(x25_e)
        sta fe25519_src1+1
        lda #<(fe25519_tmp1)
        sta fe25519_dst
        lda #>(fe25519_tmp1)
        sta fe25519_dst+1
        jsr fe25519_mul_a24         ; fe25519_tmp1 = a24 * E

        ; AA + a24*E → fe25519_tmp1
        ; fe25519_dst=fe25519_tmp1 still set from fe25519_mul_a24 above
        lda #<(fe25519_tmp3)
        sta fe25519_src1
        lda #>(fe25519_tmp3)
        sta fe25519_src1+1
        lda #<(fe25519_tmp1)
        sta fe25519_src2
        lda #>(fe25519_tmp1)
        sta fe25519_src2+1
        jsr fe25519_add             ; fe25519_tmp1 = AA + a24*E

        ; z_2 = E * (AA + a24*E)
        ; fe25519_src2=fe25519_tmp1 still set from fe25519_add above
        lda #<(x25_e)
        sta fe25519_src1
        lda #>(x25_e)
        sta fe25519_src1+1
        lda #<(x25_z2)
        sta fe25519_dst
        lda #>(x25_z2)
        sta fe25519_dst+1
        jsr fe25519_mul             ; x25_z2 = E * (AA + a24*E)
        jsr fe25519_reduce_final    ; z_2 is output, feeds into add/sub in next iteration

        rts
.endproc

; =============================================================================
; x25519_base - Compute x25_result = x25_scalar * basepoint(9)
;
; Convenience wrapper. Copies basepoint to x25_u and calls scalarmult.
;
; Input: x25_scalar (32 bytes, will be clamped)
; Output: x25_result (32 bytes)
; Clobbers: A, X, Y
; =============================================================================
.proc x25519_base
        ; Copy basepoint (9) to x25_u
        lda #<(x25_basepoint)
        sta fe25519_src1
        lda #>(x25_basepoint)
        sta fe25519_src1+1
        lda #<(x25_u)
        sta fe25519_dst
        lda #>(x25_u)
        sta fe25519_dst+1
        jsr fe25519_copy

        ; Clamp scalar
        jsr x25519_clamp

        ; Compute
        jsr x25519_scalarmult
        rts
.endproc
