; =============================================================================
; data.s - Data buffers for fe25519 and X25519
; =============================================================================

.setcpu "6502"

; --- Exported data labels ---
.export fe25519_tmp1, fe25519_tmp2, fe25519_tmp3, fe25519_tmp4
.export x25_x2, x25_z2, x25_x3, x25_z3
.export x25_a, x25_b, x25_da, x25_cb, x25_e
.export x25_scalar, x25_u, x25_result, x25_x1
.export x25_basepoint, fe_p
.export mul_cached_a, mul_src2_buf
.export mul38_lo_tab, mul38_hi_tab
.export sqr_lo, sqr_hi
.export a24_b0, a24_b1, a24_b2, a24_b3
.export x25519_reu_fault
.export x25519_reu_settle_cnt   ; REU_SETTLE slow path: cross-TU internal, not API
.export x25519_reu_settle_smp   ; REU_SETTLE slow path: cross-TU internal, not API

.segment "LIB_X25519_DATA"

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
        .byte $ed              ; page+$20
        .res 30, $ff
        .byte $7f

; x_1 for the Montgomery ladder: the RFC 7748 decodeUCoordinate result
; (x25_u with bit 255 masked), written once by x25519_scalarmult at
; ladder init. The ladder's z_3 = x_1 * (DA-CB)^2 step MUST read this
; masked copy, never x25_u directly — x25_u is the caller's buffer and
; is deliberately left unmutated (W4 H1), so for inputs with bit 255
; set it differs from the decoded u by 19 (2^255 ≡ 19 mod p) and would
; desynchronize x_1 from the masked x_3 (RFC 7748 §5.2 vector-2
; regression, broken v0.4.0 → v0.6.0).
x25_x1:
        .res 32, 0             ; page+$40

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
.assert (x25_x1       & $1F) = 0, lderror, "x25_x1 must be 32-byte aligned"

; --- fe25519_mul optimization buffers ---
mul_cached_a:
        .byte 0                ; cached src1[i] for inlined multiply

; --- REU settle fault byte (c64-lib-contract SPEC v0.13.0 §8.2) ---
; Sticky. Cleared at reu_mul_init / reu_probe entry; the REU_SETTLE
; macro (src/constants.s) ORs in $01 when its bounded spin expires
; without seeing END OF BLOCK and $02 when $DF00 bit 5 (VERIFY ERROR)
; was observed. Never cleared by the library otherwise — a host reads
; it after any REU-touching call to learn whether every DMA since the
; last init/probe was confirmed complete. Always 0 under the onchip
; profile (no REU is touched). Not alignment-sensitive: it is a single
; byte read/written by absolute address only.
x25519_reu_fault:
        .byte 0
; x25519_reu_settle_slow's spin counter and last status sample. Written
; only when a status read did not show exactly END OF BLOCK (never
; observed on hardware); in memory so the settle clobbers A only.
; Cross-TU internal (exported because the slow path lives in
; x25519_init.s and the data here) — part of the linked name surface,
; NOT part of the API; consumers must not reference them.
x25519_reu_settle_cnt:
        .byte 0
x25519_reu_settle_smp:
        .byte 0

; mul_src2_buf is 33 bytes, NOT 32. Byte 32 is a load-bearing zero
; (the "phantom slot") relied on by fe25519_sqr body B. Body B
; processes cross-term pairs in an unrolled loop and the final
; iteration of i=31 reads src2[32]; that read MUST observe a zero
; byte to keep the cross-term sum honest. Since body B never
; writes the slot back, .res 33, 0 above guarantees byte 32 stays
; zero for the lifetime of the program — but a future caller MUST
; NOT shrink this buffer to 32 bytes or repurpose byte 32 for
; anything else, and any change here must be paired with a re-run
; of tools/test_fe_sqr_stress.py and tools/test_ct_square_cycles.py.
mul_src2_buf:
        .res 33, 0            ; 32-byte src2 copy + 1-byte phantom slot

; --- REU DMA target buffers: MOVED to src/mul_stage.s at v0.14.0 ---
;
; mul_dma_lo / mul_dma_hi / mul_dma_carry used to live here. They are an
; APP_OWNED surface (§8.0) — a consumer providing the §8.2 multiply tables
; defines and places them itself — and c64-lib-contract SPEC v1.2.0 §6.1
; member isolation requires such a symbol to live in a TU defining nothing
; else the library's own code references. Here they shared a member with
; the 33 names below and above, every one of them library-referenced, so
; any reference to any of them pulled data.o in and dragged the buffers
; along, colliding with the consumer's definitions. That is what
; c64-nist-curves v0.12.0 shipped; it cost c64-https every configuration
; (contract#179).
;
; Do not move them back, and do not add anything to src/mul_stage.s.

; (sqtab2_lo / sqtab2_hi removed after Phase 2: the branchless CT
;  quarter-square path in fe25519_sqr no longer needs a second
;  negative-diff table — ~512 bytes of binary reclaimed.)

; --- mul_by_38 lookup tables ---
; mul38_lo_tab[i] = low byte of (i * 38)
; mul38_hi_tab[i] = high byte of (i * 38)
;
; The `.align 256` is a CT INVARIANT and is load-bearing. Both tables are
; indexed `abs,y` with a secret byte over the full 0..255 range in
; mul_by_38, so an unaligned base makes some indices cross a page and cost
; an extra cycle — a data-dependent time.
;
; It is explicit here as of v0.15.0. Before that these two tables were
; page-aligned only BY ACCIDENT: they followed the three exact 256-byte
; mul_dma_* buffers, which followed a `.align 256`, so the location
; counter happened to arrive page-aligned and no directive said so.
; Moving the mul_dma_* block to src/mul_stage.s for §6.1 member isolation
; dropped mul38_lo_tab to $1A85, and `tools/test_ct_ladder_cycles.py`
; measured the ladder's cycle spread going 0 -> 83,342 against a 17,045
; threshold. Nothing else caught it: every functional test passed, all
; seven profiles built, and the existing page-alignment asserts covered
; only the buffers that moved, not the table that silently lost its
; alignment behind them.
;
; The asserts below now cover every secret-indexed table in this file, so
; an alignment inherited from a neighbour can never again be silently
; spent by an edit somewhere else.
        .align 256
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

; --- CT alignment: provenance audit, not a directive sweep ---
;
; The durable question is not "does every secret-indexed table have an
; .align?" but "what makes each one aligned, and what would have to change
; for that to stop being true?" A sweep for .align directives answers
; neither unguarded case. Audited 2026-09-06 across this file,
; src/mul_stage.s and src/constants.s:
;
;   table                provenance                       guard
;   mul38_lo_tab         .align directive                 lderror
;   mul38_hi_tab         derived (predecessor is 256 B)   lderror
;   sqr_lo               .align directive                 lderror
;   sqr_hi               derived                          lderror
;   a24_b0               .align directive                 lderror
;   a24_b1..b3           derived                          lderror
;   mul_dma_lo           .align directive (mul_stage.s)   lderror
;   mul_dma_hi/carry     derived      (mul_stage.s)       lderror
;   sqtab_lo/hi          CONSUMER EQUATE (constants.s)    error
;
; Two things that audit is checking, both of which a directive sweep
; misses:
;
;   1. THE ABSOLUTE-LITERAL CLASS IS ABSENT HERE, and that is a finding,
;      not an omission. A table pinned to a literal address (`tab = $6000`)
;      is unguarded in the opposite direction from a derived one: no split
;      can ever disturb it, so it always looks correctly placed, and it
;      breaks on a one-character edit instead. c64-ChaCha20-Poly1305 has
;      that shape. We do not. If anyone ever adds one, it needs an assert
;      with `error`, not `lderror`.
;
;   2. THE KEYWORD IS NOT COSMETIC. For a relocatable address ca65 defers
;      the check to ld65 whatever keyword is written, so an `error` on one
;      of these would be a link-time check you might believe was
;      assemble-time. For sqtab_lo/hi both sides are assemble-time
;      constants (a consumer -D), so `error` there is genuinely
;      assemble-time and is the right choice. Matching keyword to
;      provenance is what makes the diagnostic honest about when it fires.
;
; CT alignment asserts for every secret-indexed table in this file.
; mul38_hi_tab, sqr_hi and a24_b1..b3 carry no `.align` of their own —
; each follows a table of exactly 256 bytes, so its alignment is DERIVED
; from its predecessor's. That is fine and deliberate, but it is only safe
; while it is checked: these asserts are what makes the derivation an
; invariant rather than a coincidence. Do not delete one because the table
; "obviously" follows an aligned one.
.assert (mul38_lo_tab & $00FF) = 0, lderror, "mul38_lo_tab must be page-aligned (CT invariant: abs,y indexed by a secret byte in mul_by_38)"
.assert (mul38_hi_tab & $00FF) = 0, lderror, "mul38_hi_tab must be page-aligned (CT invariant: abs,y indexed by a secret byte in mul_by_38)"
.assert (sqr_lo & $00FF) = 0,       lderror, "sqr_lo must be page-aligned (CT invariant: abs,y indexed by a secret byte in fe25519_sqr)"
.assert (sqr_hi & $00FF) = 0,       lderror, "sqr_hi must be page-aligned (CT invariant: abs,y indexed by a secret byte in fe25519_sqr)"

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

.assert (a24_b0 & $00FF) = 0, lderror, "a24_b0 must be page-aligned (CT invariant: abs,y indexed by a secret byte in fe25519_mul_a24)"
.assert (a24_b1 & $00FF) = 0, lderror, "a24_b1 must be page-aligned (CT invariant: abs,y indexed by a secret byte in fe25519_mul_a24)"
.assert (a24_b2 & $00FF) = 0, lderror, "a24_b2 must be page-aligned (CT invariant: abs,y indexed by a secret byte in fe25519_mul_a24)"
.assert (a24_b3 & $00FF) = 0, lderror, "a24_b3 must be page-aligned (CT invariant: abs,y indexed by a secret byte in fe25519_mul_a24)"
