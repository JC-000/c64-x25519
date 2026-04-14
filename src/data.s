; =============================================================================
; data.s - Data buffers for fe25519 and X25519
; =============================================================================

.setcpu "6502"

; --- Exported data labels ---
.export fe25519_tmp1, fe25519_tmp2, fe25519_tmp3, fe25519_tmp4
.export x25_x2, x25_z2, x25_x3, x25_z3
.export x25_a, x25_b, x25_da, x25_cb, x25_e
.export x25_scalar, x25_u, x25_result
.export x25_basepoint, fe_p
.export mul_cached_a, mul_src2_buf
.export mul_dma_lo, mul_dma_hi, mul_dma_carry
.export mul38_lo_tab, mul38_hi_tab
.export sqr_lo, sqr_hi
.export a24_b0, a24_b1, a24_b2, a24_b3

.segment "DATA"

; --- fe25519 field arithmetic ---
; fe_wide[0..63] is now in zero page at $40..$7F (see constants.s)
;
; Page-aligned 32-byte buffers: each buffer's low byte is one of
; {$00, $20, $40, $60, $80, $A0, $C0, $E0}, so Y ∈ [0..31] never
; crosses a page boundary. This enables self-mod abs,Y without the
; page-crossing penalty in fe25519_add/fe25519_sub/fe25519_reduce_final.
        .align 256
fe25519_tmp1:
        .res 32, 0            ; page+$00
fe25519_tmp2:
        .res 32, 0            ; page+$20
fe25519_tmp3:
        .res 32, 0            ; page+$40
fe25519_tmp4:
        .res 32, 0            ; page+$60
x25_x2:
        .res 32, 0            ; page+$80
x25_z2:
        .res 32, 0            ; page+$A0
x25_x3:
        .res 32, 0            ; page+$C0
x25_z3:
        .res 32, 0            ; page+$E0

        .align 256             ; next page
x25_a:
        .res 32, 0            ; page+$00
x25_b:
        .res 32, 0            ; page+$20
x25_da:
        .res 32, 0            ; page+$40
x25_cb:
        .res 32, 0            ; page+$60
x25_e:
        .res 32, 0            ; page+$80
x25_scalar:
        .res 32, 0            ; page+$A0
x25_u:
        .res 32, 0            ; page+$C0
x25_result:
        .res 32, 0            ; page+$E0

        .align 256             ; next page
x25_basepoint:
        .byte 9                ; page+$00
        .res 31, 0

; p = 2^255 - 19 in little-endian
fe_p:
        .byte $ed
        .res 30, $ff
        .byte $7f

; =============================================================================
; Compile-time alignment enforcement for 32-byte field buffers
; =============================================================================
; The optimized fe25519_add / fe25519_sub / fe25519_cmp_p /
; fe25519_reduce_final routines use self-modifying abs,Y addressing with
; Y in [0..31]. Each buffer's address must therefore be 32-byte aligned
; (offset within page is one of $00, $20, $40, $60, $80, $A0, $C0, $E0)
; so Y never crosses a page boundary. Misalignment would produce silent
; corruption — these link-time assertions catch it at build time instead.
; See docs/LIBRARY.md §6 (Buffer alignment contract).

.assert (fe25519_tmp1 & $1F) = 0, lderror, "fe25519_tmp1 must be 32-byte aligned"
.assert (fe25519_tmp2 & $1F) = 0, lderror, "fe25519_tmp2 must be 32-byte aligned"
.assert (fe25519_tmp3 & $1F) = 0, lderror, "fe25519_tmp3 must be 32-byte aligned"
.assert (fe25519_tmp4      & $1F) = 0, lderror, "fe25519_tmp4 must be 32-byte aligned"
.assert (x25_x2       & $1F) = 0, lderror, "x25_x2 must be 32-byte aligned"
.assert (x25_z2       & $1F) = 0, lderror, "x25_z2 must be 32-byte aligned"
.assert (x25_x3       & $1F) = 0, lderror, "x25_x3 must be 32-byte aligned"
.assert (x25_z3       & $1F) = 0, lderror, "x25_z3 must be 32-byte aligned"
.assert (x25_a        & $1F) = 0, lderror, "x25_a must be 32-byte aligned"
.assert (x25_b        & $1F) = 0, lderror, "x25_b must be 32-byte aligned"
.assert (x25_da       & $1F) = 0, lderror, "x25_da must be 32-byte aligned"
.assert (x25_cb       & $1F) = 0, lderror, "x25_cb must be 32-byte aligned"
.assert (x25_e        & $1F) = 0, lderror, "x25_e must be 32-byte aligned"
.assert (x25_scalar   & $1F) = 0, lderror, "x25_scalar must be 32-byte aligned"
.assert (x25_u        & $1F) = 0, lderror, "x25_u must be 32-byte aligned"
.assert (x25_result   & $1F) = 0, lderror, "x25_result must be 32-byte aligned"
.assert (x25_basepoint & $1F) = 0, lderror, "x25_basepoint must be 32-byte aligned"
.assert (fe_p         & $1F) = 0, lderror, "fe_p must be 32-byte aligned"

; --- fe25519_mul optimization buffers ---
mul_cached_a:
        .byte 0                ; cached src1[i] for inlined multiply
mul_src2_buf:
        .res 33, 0           ; absolute copy of src2 for fast indexed access
                              ; (33 bytes: byte 32 is zero-pad for fe25519_sqr unrolled
                              ; cross-term loop phantom iteration safety)

; --- REU DMA target buffers (page-aligned for LDA abs,Y without penalty) ---
        .align 256             ; align to next page boundary
mul_dma_lo:
        .res 256, 0           ; DMA target: lo bytes of a*b for current a
mul_dma_hi:
        .res 256, 0           ; DMA target: hi bytes of a*b for current a
mul_dma_carry:
        .res 256, 0           ; DMA target: 17th-bit carry of 2*a*b (0 or 1)

; (sqtab2_lo / sqtab2_hi removed after Phase 2: the branchless CT
;  quarter-square path in fe25519_sqr no longer needs a second
;  negative-diff table — ~512 bytes of binary reclaimed.)

; --- mul_by_38 lookup tables ---
; mul38_lo_tab[i] = low byte of (i * 38)
; mul38_hi_tab[i] = high byte of (i * 38)
mul38_lo_tab:
        .byte 0
        .repeat 255, i
                .byte <((i+1) * 38)
        .endrepeat

mul38_hi_tab:
        .byte 0
        .repeat 255, i
                .byte >((i+1) * 38)
        .endrepeat

; --- fe25519_mul_a24 tables: 121665 * b split into 4 bytes (LE) ---
; For b in 0..255: 121665*b up to 31,024,575 = $01D9E9BF (4 bytes)
; a24_b0[b] = (121665*b) & $ff
; a24_b1[b] = (121665*b >> 8) & $ff
; a24_b2[b] = (121665*b >> 16) & $ff
; a24_b3[b] = (121665*b >> 24) & $ff   (always 0 or 1)
; --- fe25519_sqr diagonal squaring tables ---
; sqr_lo[a] = low byte of a*a (since 255*255 = 65025 fits in 16 bits)
; sqr_hi[a] = high byte of a*a
        .align 256
sqr_lo:
        .repeat 256, i
                .byte <(i * i)
        .endrepeat
sqr_hi:
        .repeat 256, i
                .byte >(i * i)
        .endrepeat

        .align 256
a24_b0:
        .repeat 256, i
                .byte <(121665 * i)
        .endrepeat
a24_b1:
        .repeat 256, i
                .byte <((121665 * i) >> 8)
        .endrepeat
a24_b2:
        .repeat 256, i
                .byte <((121665 * i) >> 16)
        .endrepeat
a24_b3:
        .repeat 256, i
                .byte <((121665 * i) >> 24)
        .endrepeat
