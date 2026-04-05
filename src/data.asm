; =============================================================================
; data.asm - Data buffers for fe25519 and X25519
; =============================================================================

; --- fe25519 field arithmetic ---
; fe_wide[0..63] is now in zero page at $40..$7F (see constants.asm)
;
; Page-aligned 32-byte buffers: each buffer's low byte is one of
; {$00, $20, $40, $60, $80, $A0, $C0, $E0}, so Y ∈ [0..31] never
; crosses a page boundary. This enables self-mod abs,Y without the
; page-crossing penalty in fe_add/fe_sub/fe_cmp_p/fe_reduce_final.
        !align 255, 0
fe_tmp1:
        !fill 32, 0            ; page+$00
fe_tmp2:
        !fill 32, 0            ; page+$20
fe_tmp3:
        !fill 32, 0            ; page+$40
fe_tmp4:
        !fill 32, 0            ; page+$60
x25_x2:
        !fill 32, 0            ; page+$80
x25_z2:
        !fill 32, 0            ; page+$A0
x25_x3:
        !fill 32, 0            ; page+$C0
x25_z3:
        !fill 32, 0            ; page+$E0

        !align 255, 0          ; next page
x25_a:
        !fill 32, 0            ; page+$00
x25_b:
        !fill 32, 0            ; page+$20
x25_da:
        !fill 32, 0            ; page+$40
x25_cb:
        !fill 32, 0            ; page+$60
x25_e:
        !fill 32, 0            ; page+$80
x25_scalar:
        !fill 32, 0            ; page+$A0
x25_u:
        !fill 32, 0            ; page+$C0
x25_result:
        !fill 32, 0            ; page+$E0

        !align 255, 0          ; next page
x25_basepoint:
        !byte 9                ; page+$00
        !fill 31, 0

; p = 2^255 - 19 in little-endian
fe_p:
        !byte $ed
        !fill 30, $ff
        !byte $7f

; --- fe_mul optimization buffers ---
mul_cached_a:
        !byte 0                ; cached src1[i] for inlined multiply
mul_src2_buf:
        !fill 33, 0           ; absolute copy of src2 for fast indexed access
                              ; (33 bytes: byte 32 is zero-pad for fe_sqr unrolled
                              ; cross-term loop phantom iteration safety)

; --- REU DMA target buffers (page-aligned for LDA abs,Y without penalty) ---
        !align 255, 0          ; align to next page boundary
mul_dma_lo:
        !fill 256, 0           ; DMA target: lo bytes of a*b for current a
mul_dma_hi:
        !fill 256, 0           ; DMA target: hi bytes of a*b for current a
mul_dma_carry:
        !fill 256, 0           ; DMA target: 17th-bit carry of 2*a*b (0 or 1)

        !align 255, 0          ; realign sqtab2 to page boundary
; --- mult66 second quarter-square table ---
; sqtab2[0] = 0
; sqtab2[n] = floor((256-n)^2 / 4) - 1  for n=1..255
; The -1 compensates for carry being clear in the negative-difference path
sqtab2_lo:
        !byte 0
        !for i, 1, 255 {
                !byte <(((256-i)*(256-i))/4 - 1)
        }

sqtab2_hi:
        !byte 0
        !for i, 1, 255 {
                !byte >(((256-i)*(256-i))/4 - 1)
        }

; --- mul_by_38 lookup tables ---
; mul38_lo_tab[i] = low byte of (i * 38)
; mul38_hi_tab[i] = high byte of (i * 38)
mul38_lo_tab:
        !byte 0
        !for i, 1, 255 {
                !byte <(i * 38)
        }

mul38_hi_tab:
        !byte 0
        !for i, 1, 255 {
                !byte >(i * 38)
        }

; --- fe_mul_a24 tables: 121665 * b split into 4 bytes (LE) ---
; For b in 0..255: 121665*b up to 31,024,575 = $01D9E9BF (4 bytes)
; a24_b0[b] = (121665*b) & $ff
; a24_b1[b] = (121665*b >> 8) & $ff
; a24_b2[b] = (121665*b >> 16) & $ff
; a24_b3[b] = (121665*b >> 24) & $ff   (always 0 or 1)
; --- fe_sqr diagonal squaring tables ---
; sqr_lo[a] = low byte of a*a (since 255*255 = 65025 fits in 16 bits)
; sqr_hi[a] = high byte of a*a
        !align 255, 0
sqr_lo:
        !for i, 0, 255 {
                !byte <(i * i)
        }
sqr_hi:
        !for i, 0, 255 {
                !byte >(i * i)
        }

        !align 255, 0
a24_b0:
        !for i, 0, 255 {
                !byte <(121665 * i)
        }
a24_b1:
        !for i, 0, 255 {
                !byte <((121665 * i) >> 8)
        }
a24_b2:
        !for i, 0, 255 {
                !byte <((121665 * i) >> 16)
        }
a24_b3:
        !for i, 0, 255 {
                !byte <((121665 * i) >> 24)
        }
