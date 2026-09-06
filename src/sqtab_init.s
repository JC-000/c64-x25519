; =============================================================================
; sqtab_init / mul_tables_init — §8.1 shared quarter-square table build
; ISOLATED TRANSLATION UNIT (c64-lib-contract SPEC v1.2.2 §6.1)
; =============================================================================
;
; Split out of src/mul_8x8.s at v0.16.0. This file holds the §8.1 group and
; NOTHING ELSE, and mul_8x8.s holds the §8.3 group. That separation is the
; whole point of the file and must not be undone.
;
; §6.1 member isolation, quoted from the frozen v1.2.2 tag:
;
;   ld65 links whole archive members. A symbol a consumer may displace --
;   suppress under LIB_NO_BARE_EXPORTS, or define itself under APP_OWNED
;   (SS8.0) -- MUST live in a translation unit that exports nothing else a
;   consumer may import -- other displaceable names included, their own
;   prefixed counterparts excepted -- and defines nothing else the
;   library's own code references.
;
; Until v0.16.0 both groups shared mul_8x8.o, which exported eight
; displaceable names dropped by TWO DIFFERENT SWITCHES:
;
;   SHARED_SQTAB_INIT   sqtab_init, mul_tables_init
;   SHARED_CT_MUL_8X8   ct_mul_8x8, mul_8x8, poly_prod_lo, poly_prod_hi,
;                       smc_sum_a_imm, smc_diff_a_imm
;
; Neither group is the other's prefixed counterpart, so the exception above
; does not cover them. A consumer owning §8.3 but NOT §8.1 defines the
; second group itself and still imports sqtab_init -- and that import
; genuinely needs the member, unlike the APP_OWNED buffer case where
; nothing pulled it in. So the member arrived carrying the §8.3 names.
; Measured against the shipped v0.14.0 default archive with the real
; cfg/x25519-example.cfg, no rebuild and no defines -- the §6.1 line-219
; "fetch the archive and link directly" path:
;
;   ld65: Error: Duplicate external identifier: 'smc_diff_a_imm'
;
; Raised by c64-ChaCha20-Poly1305, confirmed here, tracked at #128.
;
; THE GROUPING RULE, because a literal reading of §6.1 is unsatisfiable:
; smc_sum_a_imm / smc_diff_a_imm are labels on immediate operands INSIDE
; the ct_mul_8x8 body and cannot be separated from it by any split. So some
; grouping has to be read into the clause, and "group by which switch drops
; them" is the one that falls out of it -- §6.1 defines displaceable BY THE
; MECHANISM THAT DISPLACES IT, so the natural unit is what a single switch
; controls. Six §8.3 names, two §8.1 names, two members.
;
; DO NOT merge these files back together, and do not add a §8.3 name here.
; =============================================================================

.setcpu "6502"
.include "constants.s"

.ifndef SHARED_SQTAB_INIT
; §8.1 owner build: this TU carries the canonical table-build body and
; exports both names (sqtab_init = historical, mul_tables_init =
; contract-canonical alias).
.export sqtab_init, mul_tables_init
.else
; §8.1 deferring build (SPEC v0.9.0 import-never-stub rule): a
; deferring build MUST import the provider's canonical entry and MUST
; NOT export a stub — two exported canonical inits in one composed
; link is a defect (we were the clause's measured example: the old
; `rts` stub kept sqtab_init/mul_tables_init exported here, giving
; every composed link two mul_tables_init bodies). The historical
; sqtab_init name resolves as a link-time alias of the imported
; canonical entry so in-repo callers (main.s) keep working; it is NOT
; exported in this configuration.
.import mul_tables_init
sqtab_init := mul_tables_init
.endif

; sqtab_lo / sqtab_hi / LIB_SHARED_SQTAB_BASE are now defined in
; constants.s as `.ifndef`-guarded equates (c64-lib-contract §8.1
; shared-primitive adoption). Every translation unit that `.include`s
; constants.s sees the same values, so no `.import` or `.export`
; needed across TUs — each module derives the addresses locally. A
; multi-lib consumer passes `-D LIB_SHARED_SQTAB_BASE=0x<addr>` to every
; ca65 invocation; every lib agrees on the canonical base.
; --- Cold segment (issue #68) ------------------------------------------------
; sqtab_init (+ its sq_* temps) is init-only: sole caller is the boot
; sequence; runtime consumers read the sqtab TABLE at
; LIB_SHARED_SQTAB_BASE, not this code. The §8.3 ct_mul_8x8 body below
; stays in resident LIB_X25519_CODE deliberately — see the segment note there and
; docs/design/issue_68_cold_segment_split.md.
.segment "LIB_X25519_INIT_CODE"
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
.ifndef SHARED_SQTAB_INIT
mul_tables_init = sqtab_init    ; canonical contract-§8.1 alias

.proc sqtab_init
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
.endproc

; Temporaries for sqtab_init
sq_acc: .res 3, 0              ; 24-bit accumulator for i^2
sq_sh:  .res 3, 0              ; 24-bit shifted result (i^2 / 4)
sq_ad:  .res 2, 0              ; 16-bit addition term (2i+1)
sq_i:   .res 2, 0              ; 16-bit index counter (0..511)
.endif  ; SHARED_SQTAB_INIT (owner-build body + temps; deferring builds
