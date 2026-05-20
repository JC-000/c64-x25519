; =============================================================================
; mul_8x8.s - Quarter-square 8x8→16 multiply + table init
;
; Extracted from poly1305 for standalone X25519.
; Quarter-square table: sqtab_lo/hi at LIB_SHARED_SQTAB_BASE +$0000/$0200
; (default base $7800; 1024 bytes total).
; Identity: a*b = floor((a+b)^2/4) - floor((a-b)^2/4)
;
; c64-lib-contract §8.1 shared-primitive adoption (v0.6):
; ---------------------------------------------------------------------------
; The sqtab base address is published as the source-level equate
; LIB_SHARED_SQTAB_BASE (default $7800), `.ifndef`-guarded so a
; multi-lib consumer can override it via
; `ca65 --asm-define LIB_SHARED_SQTAB_BASE=$N`. Page-alignment +
; page-delta are hard `.assert`-checked at link time.
;
; Why source equate rather than linker-export: mul_8x8 (and the
; mult66 path inside fe25519_sqr) self-modifies the hi byte of
; `lda sqtab_lo,x` opcodes at runtime (`@ct_load_lo` / `@ct_load_hi`
; below). ld65 can't rewrite opcode bytes at link time, so the base
; address must be known at assemble time. The equate form lets a
; consumer pin it; the linker no longer needs to know about
; sqtab_lo / sqtab_hi.
;
; Idempotent shared init: a consumer that defines `SHARED_SQTAB_INIT`
; at build time signals that some other library in the link will
; provide the canonical `mul_tables_init` entry, and `sqtab_init`'s
; body in this file becomes a no-op stub. Without the gate (the
; standalone-build default), `sqtab_init` builds its own table as
; before. Either way, `mul_tables_init` is exported as a contract-
; canonical alias for `sqtab_init`.
; =============================================================================

.setcpu "6502"
.include "constants.s"

.export sqtab_init, mul_tables_init, mul_8x8, poly_prod_lo, poly_prod_hi

; sqtab_lo / sqtab_hi / LIB_SHARED_SQTAB_BASE are now defined in
; constants.s as `.ifndef`-guarded equates (c64-lib-contract §8.1
; shared-primitive adoption). Every translation unit that `.include`s
; constants.s sees the same values, so no `.import` or `.export`
; needed across TUs — each module derives the addresses locally. A
; multi-lib consumer passes `-D LIB_SHARED_SQTAB_BASE=$N` to every
; ca65 invocation; every lib agrees on the canonical base.

.segment "CODE"

; =============================================================================
; sqtab_init / mul_tables_init - Build quarter-square lookup table
;
; Two names for the same entry point. `sqtab_init` is the historical
; library name; `mul_tables_init` is the c64-lib-contract §8.1
; canonical name for the shared primitive. Both point at the same
; body. Callers can use whichever fits their integration shape:
;
;   jsr sqtab_init        ; legacy / standalone-build path
;   jsr mul_tables_init   ; multi-lib / contract-§8 path
;
; When the consumer defines `SHARED_SQTAB_INIT` at build time, the
; body below is gated out — c64-x25519 trusts that some other library
; in the link will provide a `mul_tables_init` that populates the
; canonical `LIB_SHARED_SQTAB_BASE` region before any field op runs.
; The local `sqtab_init` / `mul_tables_init` symbols still resolve
; (returning immediately), so existing callers don't break.
;
; Idempotency: the body is a deterministic table build over the same
; `LIB_SHARED_SQTAB_BASE` region; calling it twice from different
; library initializers in a multi-lib PRG is wasteful but not
; incorrect. The contract §8.1 expectation is that the host calls
; the canonical init exactly once.
; =============================================================================
mul_tables_init = sqtab_init    ; canonical contract-§8.1 alias

.proc sqtab_init
.ifdef SHARED_SQTAB_INIT
        ; Consumer signaled that another translation unit provides the
        ; canonical `mul_tables_init`. Skip our table build to avoid
        ; clobbering the shared region with a second copy of the same
        ; values (correctness-preserving but wasteful).
        rts
.else
        lda #0
        sta sq_acc              ; accumulator = 0
        sta sq_acc+1
        sta sq_acc+2
        sta sq_i                ; index = 0
        sta sq_i+1

@loop:
        ; Compute f(i) = sq_acc >> 2 (divide by 4)
        lda sq_acc+2
        lsr
        sta sq_sh+2
        lda sq_acc+1
        ror
        sta sq_sh+1
        lda sq_acc
        ror
        sta sq_sh
        lsr sq_sh+2
        ror sq_sh+1
        ror sq_sh

        ; Store in table at index sq_i (0..511)
        ldx sq_i                ; low byte of index
        lda sq_i+1
        beq @pg0
        ; Page 1 (256..511)
        lda sq_sh
        sta sqtab_lo+256,x
        lda sq_sh+1
        sta sqtab_hi+256,x
        jmp @advance
@pg0:
        lda sq_sh
        sta sqtab_lo,x
        lda sq_sh+1
        sta sqtab_hi,x

@advance:
        ; sq_acc += 2*i + 1 (recurrence: (i+1)^2 = i^2 + 2i + 1)
        lda sq_i
        asl
        sta sq_ad
        lda sq_i+1
        rol
        sta sq_ad+1
        inc sq_ad
        bne :+
        inc sq_ad+1
:
        clc
        lda sq_acc
        adc sq_ad
        sta sq_acc
        lda sq_acc+1
        adc sq_ad+1
        sta sq_acc+1
        lda sq_acc+2
        adc #0
        sta sq_acc+2

        inc sq_i
        bne :+
        inc sq_i+1
:       lda sq_i+1
        cmp #2                  ; check if i reached 512 (0x200)
        beq @done
        jmp @loop
@done:  rts
.endif  ; SHARED_SQTAB_INIT
.endproc

; Temporaries for sqtab_init
sq_acc: .res 3, 0              ; 24-bit accumulator for i^2
sq_sh:  .res 3, 0              ; 24-bit shifted result (i^2 / 4)
sq_ad:  .res 2, 0              ; 16-bit addition term (2i+1)
sq_i:   .res 2, 0              ; 16-bit index counter (0..511)

; =============================================================================
; mul_8x8 - 8-bit x 8-bit → 16-bit multiply using quarter-square table
;
; Input: A = multiplicand, X = multiplier
; Output: poly_prod_lo/hi = A * X (16-bit result)
;
; Uses identity: a*b = sqtab[a+b] - sqtab[|a-b|]
; Clobbers: A, X, Y
; =============================================================================
poly_prod_lo:   .byte 0
poly_prod_hi:   .byte 0

.proc mul_8x8
        sta mul_a               ; save A (multiplicand)
        stx mul_b               ; save X (multiplier)

        ; ---- Branchless |a - b| via sign-mask XOR ----
        ; Compute raw diff = a - b, and mask = 0 (if a>=b) or $ff (if a<b).
        ; Then |a-b| = (raw XOR mask) - mask, using the identity that
        ; subtracting $ff with C=1 equals adding 1 in two's complement.
        lda mul_a
        sec
        sbc mul_b               ; A = a - b (raw), C=1 if a>=b, C=0 if a<b
        sta mul_diff            ; stash raw diff
        lda #0
        sbc #0                  ; A = $00 if C=1, $ff if C=0 (sign mask)
        sta mul_mask
        eor mul_diff            ; A = raw XOR mask
        sec
        sbc mul_mask            ; A = (raw XOR mask) - mask = |a-b|
        tay                     ; Y = |a-b|

        ; ---- Compute sum and sum-page carry ----
        lda mul_a
        clc
        adc mul_b               ; A = (a+b) & $ff
        tax                     ; X = sum low byte
        lda #0
        adc #0                  ; A = sum-page carry (0 or 1)
        sta mul_sum_pg

        ; ---- Patch hi bytes of the two abs,X load sites (SMC) ----
        ; Because sqtab_lo/sqtab_hi are each 512 bytes starting on a page
        ; boundary ($7800 and $7a00), adding the sum-page carry (0 or 1)
        ; to the page hi byte selects between page 0 and page 1 of each
        ; table without any data-dependent branch.
        lda #>sqtab_lo
        clc
        adc mul_sum_pg
        sta @ct_load_lo+2       ; patch hi byte of `lda sqtab_lo,x`
        lda #>sqtab_hi
        clc
        adc mul_sum_pg
        sta @ct_load_hi+2       ; patch hi byte of `lda sqtab_hi,x`

        ; ---- Straight-line sqtab[sum] - sqtab[|diff|] ----
@ct_load_lo:
        lda sqtab_lo,x          ; hi byte PATCHED above
        sec
        sbc sqtab_lo,y
        sta poly_prod_lo
@ct_load_hi:
        lda sqtab_hi,x          ; hi byte PATCHED above
        sbc sqtab_hi,y
        sta poly_prod_hi
        rts
.endproc

mul_a:          .byte 0
mul_b:          .byte 0
mul_diff:       .byte 0
mul_mask:       .byte 0
mul_sum_pg:     .byte 0
