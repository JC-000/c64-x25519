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
.import fe25519_tmp1, fe25519_tmp2, fe25519_tmp3, fe25519_tmp4
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
        php              ; save caller's processor status (I flag incl.)
        sei              ; mask IRQs for the full call — defends
                         ; against mid-REU-DMA preemption and against
                         ; consumer ISRs clobbering our 83 ZP bytes
                         ; ($1A-$2E, $40-$7F).  See A2/A5 memos.

        ; --- Defensive REU register init (issue #33) ---
        ; The inlined per-row DMA in fe25519_mul/_sqr/_mul_a24 relies on
        ; reu_reu_lo == 0 and reu_addr_ctrl == 0 being latched by the
        ; tail of reu_mul_init. A caller that touched $DF04 or $DF0A
        ; after init (e.g. a sibling REU consumer) leaves those
        ; registers non-zero, causing the per-row DMA to read from
        ; the wrong REU offset. Result: deterministic-but-wrong
        ; scalarmult output (not a hang). Re-establish them here so
        ; caller REU register state cannot affect us.
        ;
        ; (Post-W2: reu_clear_wide is now a CPU clear that no longer
        ;  uses these registers, but the per-row DMA inside
        ;  fe25519_mul/sqr/mul_a24 still does, and each of those
        ;  routines also has its own defensive H2 init at entry —
        ;  belt-and-braces for callers that bypass scalarmult.)
        lda #0
        sta reu_reu_lo            ; $df04
        sta reu_addr_ctrl         ; $df0a

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
        ;
        ; W4 H1 fix: do NOT write the masked byte back to x25_u+31.
        ; The previous code did `sta x25_u+31` which silently mutated
        ; the caller's u-buffer — a surprising side effect, especially
        ; for hosts that hold the peer's public key in x25_u between
        ; multiple ECDH operations. Apply the mask only on the working
        ; copy (x25_x3) after fe25519_copy.
        lda #<(x25_u)
        sta fe25519_src1
        lda #>(x25_u)
        sta fe25519_src1+1
        lda #<(x25_x3)
        sta fe25519_dst
        lda #>(x25_x3)
        sta fe25519_dst+1
        jsr fe25519_copy
        ; Now mask the high bit on the working copy only — x25_u
        ; remains exactly as the caller provided it.
        lda x25_u+31
        and #$7f
        sta x25_x3+31

        ; z_3 = 1
        lda #<(x25_z3)
        sta fe25519_dst
        lda #>(x25_z3)
        sta fe25519_dst+1
        jsr fe25519_one

        ; prev_bit_mask = $00 (no prior bit, no swap on first iteration)
        ; NOTE: x25_prev_bit is stored in MASK form ($00/$FF), not value form
        ; (0/1), to permit branchless bit-extract + swap-mask compute in the
        ; loop below. See ladder CT audit (audit/ladder-cswap-ct).
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
        ; --- CT-audit: branchless bit extraction + swap-mask compute ---
        ; The prior layout branched on the scalar bit (beq @bit_zero) and
        ; again on the swap value (beq @no_swap_mask). Each branch
        ; contributed ~1 cyc of scalar-bit-dependent timing per iteration
        ; (255 iterations × 2 branches). The rewrite below produces the
        ; swap mask in $00/$FF form without any branch on the scalar.
        ;
        ; Sequence (all ops constant-cycle; no branches on secret state):
        ;   1. load scalar byte (byte_idx is public loop counter)
        ;   2. AND with bit_mask (bit_mask is public loop counter)
        ;   3. cmp #1      → C = (AND result != 0), i.e., C = scalar bit
        ;   4. lda #0      → A = 0
        ;   5. sbc #0      → A = $00 if bit=1 (C=1), $FF if bit=0 (C=0)
        ;   6. eor #$ff    → A = $FF if bit=1, $00 if bit=0 (= k_t_mask)
        ;   7. tax         → X = k_t_mask (save for prev_bit update)
        ;   8. eor prev    → A = swap_mask = k_t_mask XOR prev_bit_mask
        ;   9. stx prev    → prev_bit = k_t_mask (mask form carries forward)
        ldx x25_byte_idx       ; X = byte_idx (public loop counter)
        lda x25_scalar,x       ; A = scalar[byte_idx]
        and x25_bit_mask       ; A = scalar_bit * bit_mask (0 or bit_mask)
        cmp #1                 ; C = (A != 0) = scalar bit
        lda #0
        sbc #0                 ; A = $00 if bit=1, $FF if bit=0
        eor #$ff               ; A = $FF if bit=1, $00 if bit=0 (k_t_mask)
        tax                    ; X = k_t_mask (save for prev_bit update)
        eor x25_prev_bit       ; A = swap_mask = k_t_mask XOR old prev_mask
        stx x25_prev_bit       ; prev_bit_mask = k_t_mask

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

        ; Final cswap with prev_bit. x25_prev_bit is already in mask form
        ; ($00/$FF) from the loop above, so no branch needed here.
        ; CT-audit: no secret-dependent branches in this final-cswap setup.
        ; Note: with a clamped scalar (k_0 = 0), the final prev_bit_mask is
        ; always $00 and the cswap is a no-op — but we call it unconditionally
        ; in constant time to preserve CT behaviour for non-clamped callers
        ; and to match RFC 7748's pseudocode shape.
        lda x25_prev_bit
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
        jsr fe25519_reduce_final    ; KEEP: the wire result MUST be
                                    ; canonical regardless of the
                                    ; pairwise pruning above. Skipping
                                    ; this would expose ≤2p form on the
                                    ; network, which fails interop.

        plp              ; restore caller's processor status (I flag incl.)
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
        ; W4 pairwise-safe pruning: reduce_final dropped here. The very
        ; next consumer of AA (fe25519_sub for E = AA - BB) is paired
        ; with a partner operand (BB) that is canonical: BB's
        ; reduce_final immediately below is retained. Per Inv3, fe25519
        ; output bound ≤ 2p plus one canonical partner is sufficient
        ; for the masked reduce_final inside fe25519_sub to produce a
        ; canonical result without an explicit reduce here.

        ; BB = B^2 → fe25519_tmp4
        lda #<(x25_b)
        sta fe25519_src1
        lda #>(x25_b)
        sta fe25519_src1+1
        lda #<(fe25519_tmp4)
        sta fe25519_dst
        lda #>(fe25519_tmp4)
        sta fe25519_dst+1
        jsr fe25519_sqr             ; fe25519_tmp4 = BB
        jsr fe25519_reduce_final    ; KEEP: BB is the canonical partner of
                                    ; AA in `E = AA - BB` and `x_2 = AA*BB`.
                                    ; AA's reduce was dropped above per the
                                    ; pairwise rule; one canonical partner
                                    ; per pair is sufficient.

        ; E = AA - BB → x25_e
        lda #<(fe25519_tmp3)
        sta fe25519_src1
        lda #>(fe25519_tmp3)
        sta fe25519_src1+1
        lda #<(fe25519_tmp4)
        sta fe25519_src2
        lda #>(fe25519_tmp4)
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
        ; W4 pairwise-safe pruning: reduce_final dropped here. DA is
        ; consumed only as `DA + CB` and `DA - CB`; CB's reduce_final
        ; is retained below as the canonical partner. Per Inv3 bound,
        ; one canonical operand per pair suffices for the next
        ; fe25519_add/sub to produce a correct, canonical result.

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
        jsr fe25519_reduce_final    ; KEEP: CB is the canonical partner
                                    ; of DA in `DA + CB` and `DA - CB`.
                                    ; DA's reduce was dropped above per
                                    ; the pairwise rule.

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
        ; W4 pairwise-safe pruning: reduce_final dropped here. Next
        ; iteration consumes x_3 only as `C = x_3 + z_3` and
        ; `D = x_3 - z_3`; z_3's reduce_final below is retained as
        ; the canonical partner. The final cswap before fe25519_inv
        ; preserves the ≤ 2p bound (cswap is byte-wise).

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
        jsr fe25519_reduce_final    ; KEEP: z_3 is the canonical partner
                                    ; of x_3 in next iteration's
                                    ; `C = x_3 + z_3` / `D = x_3 - z_3`.
                                    ; x_3's reduce was dropped above per
                                    ; the pairwise rule.

        ; x_2 = AA * BB
        lda #<(fe25519_tmp3)
        sta fe25519_src1
        lda #>(fe25519_tmp3)
        sta fe25519_src1+1
        lda #<(fe25519_tmp4)
        sta fe25519_src2
        lda #>(fe25519_tmp4)
        sta fe25519_src2+1
        lda #<(x25_x2)
        sta fe25519_dst
        lda #>(x25_x2)
        sta fe25519_dst+1
        jsr fe25519_mul             ; x25_x2 = AA * BB
        ; W4 pairwise-safe pruning: reduce_final dropped here. Next
        ; iteration consumes x_2 only as `A = x_2 + z_2` and
        ; `B = x_2 - z_2`; z_2's reduce_final below is retained as
        ; the canonical partner. The final scalarmult-tail x_2*z_2^-1
        ; ends with reduce_final on the wire result, so x_2's transient
        ; non-canonical state never escapes the ladder.

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
        jsr fe25519_reduce_final    ; KEEP: z_2 is the canonical partner
                                    ; of x_2 in next iteration's
                                    ; `A = x_2 + z_2` / `B = x_2 - z_2`.
                                    ; x_2's reduce was dropped above per
                                    ; the pairwise rule.

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
