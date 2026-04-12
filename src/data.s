; =============================================================================
; data.s - Data buffers for fe25519 and X25519
; =============================================================================

; --- fe25519 field arithmetic ---
; fe_wide[0..63] is now in zero page at $40..$7F (see constants.s)
;
; Page-aligned 32-byte buffers: each buffer's low byte is one of
; {$00, $20, $40, $60, $80, $A0, $C0, $E0}, so Y ∈ [0..31] never
; crosses a page boundary. This enables self-mod abs,Y without the
; page-crossing penalty in fe25519_add/fe25519_sub/fe_cmp_p/fe25519_reduce_final.
        .align 256
fe25519_tmp1:
        .res 32, 0            ; page+$00
fe25519_tmp2:
        .res 32, 0            ; page+$20
fe25519_tmp3:
        .res 32, 0            ; page+$40
fe_tmp4:
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

        .align 256             ; realign sqtab2 to page boundary
; --- mult66 second quarter-square table ---
; sqtab2[0] = 0
; sqtab2[n] = floor((256-n)^2 / 4) - 1  for n=1..255
; The -1 compensates for carry being clear in the negative-difference path
sqtab2_lo:
        .byte 0
        .repeat 255, i
                .byte <(((256-(i+1))*(256-(i+1)))/4 - 1)
        .endrepeat

sqtab2_hi:
        .byte 0
        .repeat 255, i
                .byte >(((256-(i+1))*(256-(i+1)))/4 - 1)
        .endrepeat

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
