; =============================================================================
; data.asm - Data buffers for fe25519 and X25519
; =============================================================================

; --- fe25519 field arithmetic ---
; fe_wide[0..63] is now in zero page at $40..$7F (see constants.asm)
fe_tmp1:
        !fill 32, 0            ; temporary field element 1
fe_tmp2:
        !fill 32, 0            ; temporary field element 2
fe_tmp3:
        !fill 32, 0            ; temporary field element 3
fe_tmp4:
        !fill 32, 0            ; temporary field element 4

; p = 2^255 - 19 in little-endian
fe_p:
        !byte $ed
        !fill 30, $ff
        !byte $7f

; --- X25519 state ---
x25_scalar:
        !fill 32, 0            ; clamped scalar
x25_u:
        !fill 32, 0            ; input u-coordinate
x25_result:
        !fill 32, 0            ; output u-coordinate
x25_x2:
        !fill 32, 0            ; Montgomery ladder state
x25_z2:
        !fill 32, 0
x25_x3:
        !fill 32, 0
x25_z3:
        !fill 32, 0
x25_a:
        !fill 32, 0            ; ladder temporaries
x25_b:
        !fill 32, 0
x25_da:
        !fill 32, 0
x25_cb:
        !fill 32, 0
x25_e:
        !fill 32, 0
x25_basepoint:
        !byte 9
        !fill 31, 0

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
