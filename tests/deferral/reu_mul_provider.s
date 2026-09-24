; =============================================================================
; reu_mul_provider.s - Functional stand-in §8.2 provider for the deferral
;                      runtime test (tools/test_shared_reu_deferral.py)
;
; Linked into build-defer/x25519.prg beside x25519 objects assembled with
; -D SHARED_REU_MUL_INIT -D SHARED_REU_MUL_FETCH. Modelled on
; c64-nist-curves' src/reu_mul_init.s: same row layout (row a at bank
; base + (a >> 7), offset (a*512) & $FFFF, lo page then hi page), its OWN
; build buffer, and it leaves the autoload latch pointing at that buffer.
; Products come from repeated addition, not from x25519's ct_mul_8x8 or
; sqtab, so a wrong x25519 table cannot be masked by a shared bug.
;
; It builds banks base and base+1 only, as SPEC v1.2.2 §8.2 has a
; provider do. Test scaffolding: never ships in an archive.
; =============================================================================

.setcpu "6502"

.export reu_mul_tables_init, reu_fetch_mul_row
.import LIB_X25519_SHARED_REU_MUL_BANK
.import LIB_X25519_SHARED_REU_MUL_STAGE_LO

.ifdef LIB_SHARED_REU_MUL_BANK
PROV_BANK = LIB_SHARED_REU_MUL_BANK
.else
PROV_BANK = 0
.endif
.assert PROV_BANK = LIB_X25519_SHARED_REU_MUL_BANK, lderror, "test provider and x25519 disagree on the reu_mul base bank"

prov_status    = $DF00
prov_command   = $DF01
prov_c64_lo    = $DF02
prov_c64_hi    = $DF03
prov_reu_lo    = $DF04
prov_reu_hi    = $DF05
prov_reu_bank  = $DF06
prov_len_lo    = $DF07
prov_len_hi    = $DF08
prov_addr_ctrl = $DF0A

.segment "CODE"

.proc reu_mul_tables_init
        lda #0
        sta row
@outer:
        lda #0
        sta plo
        sta phi
        tax
@inner:                        ; buf[b] = a*b by running sum
        lda plo
        sta buf_lo,x
        lda phi
        sta buf_hi,x
        clc
        lda plo
        adc row
        sta plo
        lda phi
        adc #0
        sta phi
        inx
        bne @inner

        lda #<buf_lo           ; one 512 B stash: buf_hi follows buf_lo
        sta prov_c64_lo
        lda #>buf_lo
        sta prov_c64_hi
        lda #0
        sta prov_reu_lo
        sta prov_len_lo
        sta prov_addr_ctrl
        lda #2
        sta prov_len_hi
        lda row
        asl                    ; offset hi = a*2, C = a >> 7
        sta prov_reu_hi
        lda #PROV_BANK
        adc #0
        sta prov_reu_bank
        lda #%10110000         ; execute + autoload + STASH
        sta prov_command
@wait:  lda prov_status
        and #$40
        beq @wait

        inc row
        bne @outer
        rts                    ; latch left at buf_lo / 512 (autoload)
.endproc

.proc reu_fetch_mul_row        ; §8.2: A = a; row a -> STAGE_LO / STAGE_HI
        asl
        sta prov_reu_hi
        lda #PROV_BANK
        adc #0
        sta prov_reu_bank
        lda #<LIB_X25519_SHARED_REU_MUL_STAGE_LO
        sta prov_c64_lo
        lda #>LIB_X25519_SHARED_REU_MUL_STAGE_LO
        sta prov_c64_hi
        lda #0
        sta prov_reu_lo
        sta prov_len_lo
        sta prov_addr_ctrl
        lda #2
        sta prov_len_hi
        lda #%10110001         ; execute + autoload + FETCH
        sta prov_command
@wait:  lda prov_status
        and #$40
        beq @wait
        rts
.endproc

row:    .byte 0
plo:    .byte 0
phi:    .byte 0

.segment "BSS"
buf_lo: .res 256
buf_hi: .res 256
