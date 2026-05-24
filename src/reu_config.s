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

; --- Derived symbolic bank names (used by src/x25519_init.s) ---
;
; Prior to v0.7.0 prep these were spelled `4+X25519_REU_BANK` and
; `3+X25519_REU_BANK` inline inside reu_fetch_doubled_row. Naming them
; here lets the SPEC §8.2 + #15 follow-up SMC refactor land without
; touching every literal callsite, and keeps the "bank 3 = carry,
; banks 4..5 = doubled mul" mapping visible at the configuration
; boundary rather than buried in the fetch routine.
;
; See src/x25519_init.s comments at reu_fetch_doubled_row for the
; semantics; see also c64-lib-contract SPEC §8.2 "Related future
; promotions" bullet on the SMC-parameterised shared fetch (#15).
X25519_REU_BANK_DOUBLED = X25519_REU_BANK + 4
X25519_REU_BANK_CARRY   = X25519_REU_BANK + 3

; =============================================================================
; c64-lib-contract SPEC §8.2: Shared 8x8->16 REU multiplication table
; =============================================================================
;
; The 128 KB (a, b) -> a*b lookup table (256 rows x 512 bytes), occupying
; two contiguous REU banks. c64-x25519 and c64-nist-curves both build a
; bit-identical copy of this table today; SPEC §8.2 promotes it to a
; consumer-placement-overridable shared primitive so a consumer linking
; both libraries can supply one base bank via LIB_SHARED_REU_MUL_BANK
; and avoid a wasted 128 KB.
;
; Default (LIB_SHARED_REU_MUL_BANK = X25519_REU_BANK) keeps x25519's
; pre-§8.2 layout (banks 0+1) bit-identical for standalone builds. A
; consumer overrides via `ca65 --asm-define LIB_SHARED_REU_MUL_BANK=$N`
; (every translation unit must see the same value because the bank
; constant is baked in at assemble time).
;
; The actual init body lives in src/x25519_init.s under .ifndef
; SHARED_REU_MUL_INIT (migration gate). The canonical entry point is
; `reu_mul_tables_init` (alias of `reu_mul_init`).
.ifndef LIB_SHARED_REU_MUL_BANK
  LIB_SHARED_REU_MUL_BANK = X25519_REU_BANK
.endif

.ifndef LIB_SHARED_REU_MUL_OFFSET
  LIB_SHARED_REU_MUL_OFFSET = $0000
.endif

; Derived two-bank mask per SPEC §8.2 (the table claims `base` and
; `base + 1`). Consumers compose it into REU-region collision
; `.assert`s instead of rewriting `(1 .shl bank) | (1 .shl (bank+1))`
; at every callsite. Libraries OR it into their own
; LIB_<X>_REU_BANKS_USED (§5) when they consume the canonical primitive.
;
; `.shl` (not `<<`) matches the existing LIB_*_REU_BANKS_USED idiom in
; src/lib_version.s and the c64-lib-contract SPEC §8.2 canonical text.
LIB_SHARED_REU_MUL_BANKS_USED = (1 .shl LIB_SHARED_REU_MUL_BANK) | (1 .shl (LIB_SHARED_REU_MUL_BANK + 1))

; SPEC §8.2 assemble-time guards:
;   - offset $0000:  v0.x.0 row-stride constraint (start-of-bank required)
;   - base   < $FE:  the hi-half bank lives at base+1, so $FF has no successor
.assert LIB_SHARED_REU_MUL_OFFSET = $0000, error, "reu_mul must start at offset 0 within its bank pair (SPEC §8.2 v0.x.0)"
.assert LIB_SHARED_REU_MUL_BANK < $FE,     error, "reu_mul base bank must leave room for the hi-half bank at base+1 (SPEC §8.2)"

; --- SPEC §8.2 ZP scratch contract ---
;
; The canonical init exposes two ZP-scratch slot equates so a consumer
; can redirect the per-byte init counters when composing libraries that
; have different ZP-budget pressures. c64-x25519's existing reu_mul_init
; uses two bytes of CODE-segment scratch (`reu_init_a` / `reu_init_b`,
; declared inside the .proc; .global'd from x25519_init.s so the equates
; can resolve to them at link time). A consumer that pins these to real
; ZP can override either equate via `ca65 --asm-define`.
;
; Defaults point at the existing CODE-segment scratch slots so the
; standalone build is bit-identical. The `:= reu_init_a` form is a
; link-time alias (not a value-baked equate) so neither symbol must be
; resolved at the time constants.s is parsed.
.ifndef LIB_SHARED_REU_MUL_ZP_INIT_A
  .global reu_init_a
  LIB_SHARED_REU_MUL_ZP_INIT_A := reu_init_a
.endif
.ifndef LIB_SHARED_REU_MUL_ZP_INIT_B
  .global reu_init_b
  LIB_SHARED_REU_MUL_ZP_INIT_B := reu_init_b
.endif

; --- SPEC §8.2 staging-buffer contract ---
;
; The canonical per-row fetch (`reu_fetch_mul_row`) writes 512 bytes to a
; page-aligned pair of 256-byte staging buffers. c64-x25519's existing
; `mul_dma_lo` / `mul_dma_hi` labels (data.s) satisfy the shape; the
; canonical SPEC §8.2 names alias them via link-time references so a
; consumer that pre-defines either equate to a different page-aligned
; address can compose freely (every TU must agree on the override; same
; mechanism as the other LIB_SHARED_* equates).
;
; Page-alignment and adjacency are CT-critical (the fetch primitive's
; 4x-unrolled abs,y accumulator loop assumes no cross-page indexing);
; the .assert`s catch override mistakes at assemble time. Byte-level `&`
; masking is the existing repo idiom for the same kind of check (see
; constants.s LIB_SHARED_SQTAB_BASE asserts).
.ifndef LIB_SHARED_REU_MUL_STAGE_LO
  .global mul_dma_lo
  LIB_SHARED_REU_MUL_STAGE_LO := mul_dma_lo
.endif
.ifndef LIB_SHARED_REU_MUL_STAGE_HI
  .global mul_dma_hi
  LIB_SHARED_REU_MUL_STAGE_HI := mul_dma_hi
.endif

.assert (LIB_SHARED_REU_MUL_STAGE_LO & $00ff) = 0, lderror, "LIB_SHARED_REU_MUL_STAGE_LO must be page-aligned (SPEC §8.2)"
.assert (LIB_SHARED_REU_MUL_STAGE_HI & $00ff) = 0, lderror, "LIB_SHARED_REU_MUL_STAGE_HI must be page-aligned (SPEC §8.2)"
.assert LIB_SHARED_REU_MUL_STAGE_HI = LIB_SHARED_REU_MUL_STAGE_LO + $0100, lderror, "LIB_SHARED_REU_MUL_STAGE_HI must follow STAGE_LO by $0100 (SPEC §8.2)"

; --- Exports (suppressed when transitively .include'd via constants.s) ---
; Forced to absolute (16-bit) symbols. X25519_REU_BANK fits in a byte,
; which would otherwise let ca65 infer zeropage size and produce
; address-size-mismatch warnings on consumer-side `.import` declarations.
.ifndef REU_CONFIG_NO_EXPORTS

.export X25519_REU_BANK:         abs
.export X25519_REU_OFFSET:       abs
.export X25519_REU_BANK_DOUBLED: abs
.export X25519_REU_BANK_CARRY:   abs

; SPEC §8.2 canonical equates.
.export LIB_SHARED_REU_MUL_BANK:        abs
.export LIB_SHARED_REU_MUL_OFFSET:      abs
.export LIB_SHARED_REU_MUL_BANKS_USED:  abs

; SPEC §8.2 ZP scratch + staging buffer aliases. These are link-time
; aliases of x25519-private labels (reu_init_a/b in x25519_init.s,
; mul_dma_lo/hi in data.s), so the address-size hint must NOT be forced
; to `abs`: ca65 would emit a "size mismatch" warning since the target
; labels carry their own address sizes. Plain `.export` leaves
; resolution to the linker.
.export LIB_SHARED_REU_MUL_ZP_INIT_A
.export LIB_SHARED_REU_MUL_ZP_INIT_B
.export LIB_SHARED_REU_MUL_STAGE_LO
.export LIB_SHARED_REU_MUL_STAGE_HI

.endif ; REU_CONFIG_NO_EXPORTS

.endif ; REU_CONFIG_S_INCLUDED
