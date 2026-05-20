.setcpu "6502"

; =============================================================================
; reu_config.s - public REU layout configuration for c64-x25519.
;
; Per c64-lib-contract SPEC.md §3 (REU layout contract). Consumer projects
; that compose c64-x25519 alongside other REU-using libraries (P-256
; precompute, ChaCha20 scratch, etc.) need to relocate c64-x25519's six
; mul-table banks to avoid silent bank collisions. The two equates below
; let them do so via `--asm-define`.
;
; Bank allocation at the default base
; -----------------------------------
;
; c64-x25519 claims five REU banks for its precomputed multiplication
; tables, allocated as follows (relative to X25519_REU_BANK):
;
;   bank + 0   ; 8x8->16 mul tables, lo+hi, for a = 0..127   (full bank)
;   bank + 1   ; 8x8->16 mul tables, lo+hi, for a = 128..255 (full bank)
;   bank + 2   ; unused (legacy zero stash removed in v0.6 prep — free
;              ;         for sibling consumers within the reserved range)
;   bank + 3   ; 17th-bit carry bytes for doubled tables     (256 bytes/row)
;   bank + 4   ; pre-doubled mul tables, lo+hi, a = 0..127   (full bank)
;   bank + 5   ; pre-doubled mul tables, lo+hi, a = 128..255 (full bank)
;
; The library also uses bank + 7 transiently during `reu_probe` (sentinel
; round-trip), which is restored before the probe returns.
;
; Total claimed range: 5 banks (bank + 2 is held within the bank-allocation
; window but not touched). Probe transiently touches a 7th bank but does
; not claim it.
;
; Default override
; ----------------
;
; X25519_REU_BANK = 0 → banks 0..5 used (= original v0.4.0 layout).
;
; A consumer overrides via `ca65 --asm-define X25519_REU_BANK=$03` (or by
; pre-defining the symbol in a wrapper .s) when rebuilding the library
; from source. Every library translation unit must be assembled with the
; same value because the bank constant is baked in at assemble time.
;
; X25519_REU_OFFSET is published as a contract-compliance equate, but
; the current library implementation places each table at offset 0
; within its bank (the tables span full banks). Changing the offset
; would require code changes; the equate exists today so consumers can
; assert against it.
; =============================================================================

.ifndef REU_CONFIG_S_INCLUDED
REU_CONFIG_S_INCLUDED = 1

.ifndef X25519_REU_BANK
  X25519_REU_BANK = $00
.endif

.ifndef X25519_REU_OFFSET
  X25519_REU_OFFSET = $0000
.endif

; --- Exports (suppressed when transitively .include'd via constants.s) ---
; Forced to absolute (16-bit) symbols. X25519_REU_BANK fits in a byte,
; which would otherwise let ca65 infer zeropage size and produce
; address-size-mismatch warnings on consumer-side `.import` declarations.
.ifndef REU_CONFIG_NO_EXPORTS

.export X25519_REU_BANK:   abs
.export X25519_REU_OFFSET: abs

.endif ; REU_CONFIG_NO_EXPORTS

.endif ; REU_CONFIG_S_INCLUDED
