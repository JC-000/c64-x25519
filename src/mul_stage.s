.setcpu "6502"

; =============================================================================
; c64-x25519 §8.2 staging buffers — ISOLATED TRANSLATION UNIT
; =============================================================================
;
; This file defines the three REU DMA landing buffers and NOTHING ELSE, and
; it must stay that way. It is not a stylistic split.
;
; c64-lib-contract SPEC v1.2.2 §6.1 "Member isolation" (quote the TAG you
; conform to -- §6.1 was corrected twice on 2026-09-06 and the v1.2.0
; wording, which lacked the prefixed-counterparts exception, would have made
; this very file non-conformant):
;
;   ld65 links whole archive members. A symbol a consumer may displace --
;   suppress under LIB_NO_BARE_EXPORTS, or define itself under APP_OWNED
;   (SS8.0) -- MUST live in a translation unit that exports nothing else a
;   consumer may import -- other displaceable names included, THEIR OWN
;   PREFIXED COUNTERPARTS EXCEPTED -- and defines nothing else the
;   library's own code references. Otherwise the member arrives uninvited
;   and its displaceable names collide -- with the consumer's own
;   definitions, or with the identical bare name a sibling library exports
;   -- and the consumer can repair neither: member surgery is banned above.
;
; mul_dma_lo/hi/carry are an APP_OWNED surface: a consumer that provides
; the §8.2 multiply tables itself defines and places them in its own tree.
; ld65 pulls an archive member only to resolve a STILL-UNRESOLVED import,
; so when the consumer's own object defines them they are already in the
; symbol table before the archive is scanned, this member is never pulled,
; and there is no duplicate. That is the ordinary archive weak-default
; idiom, and it only works while this member defines nothing else.
;
; Until v0.14.0 these lived in src/data.s beside fe_p, x25_scalar,
; fe25519_tmp1..4, sqr_lo/hi, mul38_lo/hi_tab and the §8.2 settle state —
; 33 other names, all referenced by the library's own code. Any one of
; them pulled data.o in and dragged the buffers along, so a consumer's
; APP_OWNED definitions collided and the only remedies were ar65 member
; surgery (banned by §6.1) or abandoning the release. That is not
; hypothetical: it is exactly what c64-nist-curves v0.12.0 shipped, and it
; cost c64-https all three of its configurations (c64-lib-contract#179,
; c64-nist-curves#149).
;
; DO NOT add anything to this file. Not the settle state — that is the
; specific symbol whose import broke the sibling. Not a helper, not a
; constant, not a second buffer that library code touches. Anything here
; that the library references re-arms the whole failure.
;
; The buffers' REFERRERS must stay outside this TU, and do:
;   src/fe25519.s:54       .import mul_dma_lo, mul_dma_hi, mul_dma_carry
;                          (8x `adc mul_dma_*,y` in the multiply inner
;                          loop; `sta mul_dma_lo/hi,y` in the onchip
;                          generator)
;   src/x25519_init.s:50   .import ... (indexed stores, plus the address
;                          baked into the REU transfer descriptors as
;                          `lda #<(mul_dma_lo)` immediates)
;   src/reu_config.s       .global for the LIB_SHARED_REU_MUL_STAGE_*
;                          aliases and their §8.2 pin asserts
; =============================================================================

.export mul_dma_lo, mul_dma_hi, mul_dma_carry

.segment "LIB_X25519_DATA"

; --- REU DMA target buffers (page-aligned for LDA abs,Y without penalty) ---
        .align 256             ; align to next page boundary
mul_dma_lo:
        .res 256, 0           ; DMA target: lo bytes of a*b for current a
mul_dma_hi:
        .res 256, 0           ; DMA target: hi bytes of a*b for current a
mul_dma_carry:
        .res 256, 0           ; DMA target: 17th-bit carry of 2*a*b (0 or 1)

; Page alignment of mul_dma_lo/hi is a CT invariant, not a perf hint:
; the eight `adc mul_dma_*,y` sites in fe25519_mul (and the sqr DMA
; bodies) index with secret Y over the full 0..255 range — an
; unaligned base would add a data-dependent page-cross cycle. It was
; previously asserted only indirectly via the LIB_SHARED_REU_MUL_STAGE
; aliases in src/reu_config.s; issue #72 made it explicit, and it moved
; here with the buffers at v0.14.0 so the assert cannot be separated
; from what it guards.
;
; These stay lderror rather than error: the addresses are link-time.
.assert (mul_dma_lo & $00FF) = 0, lderror, "mul_dma_lo must be page-aligned (CT invariant)"
.assert (mul_dma_hi & $00FF) = 0, lderror, "mul_dma_hi must be page-aligned (CT invariant)"
.assert (mul_dma_carry & $00FF) = 0, lderror, "mul_dma_carry must be page-aligned (CT invariant)"
