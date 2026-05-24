.setcpu "6502"

; Pull SQR_DMA_K (controls fe25519_sqr's DMA-vs-mult66 path threshold;
; see src/constants.s) and X25519_REU_BANK so the LIB_X25519_* manifest
; equates below can react to the build-time configuration. constants.s
; already sets ZP_CONFIG_NO_EXPORTS / REU_CONFIG_NO_EXPORTS so this
; transitive include doesn't double-emit consumer-facing exports.
.include "constants.s"

; =============================================================================
; c64-x25519 library version constants
;
; Consumers import these for assembly-time compatibility checks:
;
;   .import LIB_VERSION_MAJOR, LIB_VERSION_MINOR, LIB_VERSION_PATCH
;   .if LIB_VERSION_MAJOR <> 0 .or LIB_VERSION_MINOR < 6
;       .error "c64-x25519 v0.6 or newer is required"
;   .endif
;
; Versioning policy: semver 2.0.0 - https://semver.org/
;   MAJOR             - incompatible API changes (symbol removals,
;                       calling-convention changes)
;   MINOR             - additive API changes (new exports, no removals
;                       or renames of existing exports)
;   PATCH             - bugfix or perf improvement with no API change
;   LIB_ABI_VERSION   - ABI compatibility level. Bumped only when the
;                       public symbol set or calling convention
;                       changes. Coarser than MINOR; consumers that
;                       don't care about which patch level can pin to
;                       ABI alone.
;
; The library is currently in the v0.x pre-stable series. MINOR bumps
; may add public symbols but will not remove or rename existing
; symbols without a MAJOR bump. Consumers should pin to a specific
; git tag, not track the mainline branch.
;
; See issue #45 for the contract this exposes.
; =============================================================================

LIB_VERSION_MAJOR = 0
LIB_VERSION_MINOR = 6
LIB_VERSION_PATCH = 0
LIB_ABI_VERSION   = 1

; Exported as absolute (16-bit) symbols, not zeropage. ca65 would otherwise
; infer zeropage size because the values fit in a byte, which then mismatches
; consumer `.import` declarations that default to absolute.
.export LIB_VERSION_MAJOR: abs
.export LIB_VERSION_MINOR: abs
.export LIB_VERSION_PATCH: abs
.export LIB_ABI_VERSION:   abs

; =============================================================================
; Aggregate manifest equates (c64-lib-contract §5)
;
; These four integer equates let a consumer cfg do assemble-time fit /
; collision checks before kicking off a 30-min compile + test cycle.
; SPEC §5 allows the numbers to be approximate ("within 5% is fine");
; the library author refreshes them when a release substantively
; changes any one of them.
;
; LIB_X25519_ZP_USAGE_BYTES
;   Total bytes of ZP slots c64-x25519 claims while running. Sum of
;   every `.exportzp`-ed slot in src/zp_config.s plus the (unexported)
;   fe_wide region in constants.s:
;     $14-$16 fe_cmp_mask/fe_subp_rhs/fe_add_carry_mask  = 3 B
;     $1C     poly_carry                                  = 1 B
;     $1E-$2A fe25519_src1..x25_prev_bit (contiguous)     = 13 B
;     $2C-$2F x25_byte_idx..mul_ripple_start              = 4 B
;     $40-$7F fe_wide (CT/SMC-pinned)                     = 64 B
;     ------------------------------------------------------------
;                                                          85 B total
;   (Prior in-source comments and README claimed "87 bytes" via a
;   stale double-count of $24-$25 within the $1E-$2A range; PR #51
;   landed the textual cleanup so README / constants.s / x25519.inc
;   / LIBRARY.md now agree with this equate.)
;
; LIB_X25519_REU_BANKS_USED
;   Bitmask of REU banks claimed for the precomputed multiplication
;   tables. Depends on the SQR_DMA_K build constant:
;
;     SQR_DMA_K > 0 (default, =22):
;       Banks 0, 1, 3, 4, 5 used (= base mask $3B). Mul tables + the
;       pre-doubled tables for fe25519_sqr's DMA path. Library needs a
;       512 KB REU (1750) at minimum.
;
;     SQR_DMA_K = 0 (lib-x25519-1764 build variant):
;       Banks 0, 1 only (= base mask $03). fe25519_sqr's DMA dispatch
;       never fires; the inline mult66 path handles every cross-term.
;       Doubled-table generation in reu_mul_init is gated out. Library
;       fits a 256 KB REU (1764). +16.2 % scalarmult cost — see
;       docs/REU_USAGE_ANALYSIS.md.
;
;   Bank 2 is intentionally NOT claimed in either configuration — the
;   v0.4.0 W2 refactor moved reu_clear_wide to a CPU clear and the
;   legacy bank-2 zero stash was removed in v0.6 prep.
;
;   Mask is computed as `<base> << X25519_REU_BANK` so an
;   `-D X25519_REU_BANK=$N` override of the bank base automatically
;   shifts the claim. (Bank 7 is touched transiently by reu_probe but
;   restored before return; not counted as a claim.)
;
; LIB_X25519_RESIDENT_BYTES
;   Approximate code + data footprint that must remain CPU-resident
;   in any consumer's address space. Depends on the SQR_DMA_K build
;   constant (the 1764 variant drops the @dbl_gen / doubled-stash
;   sections from reu_mul_init):
;
;     SQR_DMA_K > 0 (default, =22):
;       CODE  total ≈ 4616 B   (x25519 + x25519_init + fe25519 +
;                               mul_8x8 + util)
;       DATA  total ≈ 3584 B
;       SQTAB         1024 B
;       ---------------------------------------------------------------
;                            ≈ 9224 B total
;
;     SQR_DMA_K = 0 (lib-x25519-1764 variant):
;       CODE  total ≈ 4438 B   (x25519_init.o drops to 620 B; −178 B
;                               vs the default after the gated-out
;                               @dbl_gen + 3 doubled-stash blocks)
;       DATA  total ≈ 3584 B
;       SQTAB         1024 B
;       ---------------------------------------------------------------
;                            ≈ 9046 B total
;
;   (Refreshed 2026-05-20. The three config .o files ─ lib_version.o,
;   zp_config.o, reu_config.o ─ contain only equate declarations +
;   .export directives and emit no CODE/DATA bytes, so they don't
;   shift these totals.)
;
; LIB_X25519_COLD_BYTES
;   Approximate code + data footprint that a consumer MAY overlay-page
;   (load on demand from REU / banked RAM / external storage). The
;   library currently has no overlay-page candidates — reported as 0.
;   Note that reu_mul_init's body (~1 KB) is init-only and could in
;   principle be reclaimed after sqtab_init / reu_mul_init return; a
;   future release that splits it into a dedicated segment will bump
;   this equate.
;
; LIB_X25519_SHARED_PRIMITIVES
;   c64-lib-contract §5 + §8.0/§8.1/§8.2 append-only bitmask. One bit
;   per contract-§8 shared primitive the library consumes:
;     bit $0001  LIB_SHARED_PRIMITIVES_SQTAB    — 8x8 quarter-square
;                                                  multiply table (§8.1)
;     bit $0002  LIB_SHARED_PRIMITIVES_REU_MUL  — 128 KB 8x8->16 REU
;                                                  multiplication table (§8.2)
;   c64-x25519 consumes both:
;     - sqtab: mul_8x8 + the mult66 path inside fe25519_sqr both read
;       sqtab_lo / sqtab_hi at runtime.
;     - reu_mul: reu_mul_init builds 256 rows × 512 B in REU banks
;       LIB_SHARED_REU_MUL_BANK / +1; reu_fetch_mul_row DMAs them
;       row-by-row into mul_dma_lo/hi.
;   A consumer composing c64-x25519 with another shared-primitives
;   adopter asserts:
;     .import LIB_X25519_SHARED_PRIMITIVES, LIB_<other>_SHARED_PRIMITIVES
;     .assert (LIB_X25519_SHARED_PRIMITIVES .and \
;              LIB_<other>_SHARED_PRIMITIVES) = 0, error, \
;              "double-claim on a shared primitive — one lib must \
;               build with SHARED_SQTAB_INIT / SHARED_REU_MUL_INIT defined"
;   to catch the case where both libs would build the same table
;   without a SHARED_*_INIT cutover.
; =============================================================================

; X25519_REU_BANK comes in via the `.include "constants.s"` at the top
; of this file (which transitively includes reu_config.s with
; REU_CONFIG_NO_EXPORTS set so we don't re-emit the public export
; here). The shift in LIB_X25519_REU_BANKS_USED below resolves at
; assemble time when SQR_DMA_K is known and at link time for the
; bank-base shift.

LIB_X25519_ZP_USAGE_BYTES = 85
.if SQR_DMA_K
LIB_X25519_REU_BANKS_USED = $3B << X25519_REU_BANK
LIB_X25519_RESIDENT_BYTES = 9224
.else
LIB_X25519_REU_BANKS_USED = $03 << X25519_REU_BANK
LIB_X25519_RESIDENT_BYTES = 9046
.endif
LIB_X25519_COLD_BYTES     = 0

; c64-lib-contract §5 / §8.x shared-primitives bitmask. Bit allocation
; is append-only — bits are never reused even if a primitive is later
; deprecated, so old consumer cfg `.assert`s keep parsing.
;
;   bit $0001 (SPEC §8.1): the 8x8 quarter-square multiply table.
;   bit $0002 (SPEC §8.2): the 128 KB 8x8->16 REU multiplication table.
;
; ORed together → $0003 for c64-x25519 (consumes both).
LIB_SHARED_PRIMITIVES_SQTAB   = $0001
LIB_SHARED_PRIMITIVES_REU_MUL = $0002
LIB_X25519_SHARED_PRIMITIVES  = LIB_SHARED_PRIMITIVES_SQTAB | LIB_SHARED_PRIMITIVES_REU_MUL

.export LIB_X25519_ZP_USAGE_BYTES: abs
.export LIB_X25519_REU_BANKS_USED: abs
.export LIB_X25519_RESIDENT_BYTES: abs
.export LIB_X25519_COLD_BYTES:     abs
.export LIB_X25519_SHARED_PRIMITIVES: abs
.export LIB_SHARED_PRIMITIVES_SQTAB:   abs
.export LIB_SHARED_PRIMITIVES_REU_MUL: abs

; =============================================================================
; c64-lib-contract SPEC §8.0 catch-loop: precalc-table enumeration
; =============================================================================
;
; Per SPEC §8.0 step-6, every adopter MUST enumerate its precalculated
; tables (size >= 256 B AND one of: REU-resident / hot-loop-read /
; page-aligned) in two forms:
;
;   1. Doc-level — docs/precalc-tables.md (name, size, region, source,
;      classification, rationale). The rationale field is load-bearing
;      for the cross-adopter audit (e.g. "could c448 / Ed448 ever land
;      with the same pre-doubling trick?").
;   2. Assembler-level — LIB_PRECALC_TABLE macro invocations (below),
;      each emitting 3 exported equates: LIB_PRECALC_<name>_{SIZE,
;      REGION,SHARED}. Build-time discovery via
;      `od65 --dump-exports build/lib_version.o | grep LIB_PRECALC`.
;
; Both forms MUST stay in lock-step. Asymmetry between them blocks
; adopter PRs per the intake-reviewer rule in c64-lib-contract
; adopters.md step 6.
;
; The canonical macro source `precalc_table.inc` is copied verbatim
; from c64-lib-contract's repo root; do not edit the local copy.
;
; Canonical names "sqtab" (§8.1) and "reu_mul" (§8.2) are NORMATIVE —
; do not prefix them with library/curve names. The cross-adopter audit
; `od65 --dump-exports build/*.o | grep LIB_PRECALC_<name>_SIZE`
; depends on every adopter exporting the same symbol family.
; =============================================================================

.include "precalc_table.inc"

LIB_PRECALC_TABLE "sqtab",           1024,   PRECALC_REGION_RAM, PRECALC_SHARED_YES
LIB_PRECALC_TABLE "reu_mul",         131072, PRECALC_REGION_REU, PRECALC_SHARED_YES
.if SQR_DMA_K
; The pre-doubled tables (banks +3..+5) only exist in the default
; SQR_DMA_K > 0 build; gated out in the lib-x25519-1764 variant so this
; macro invocation does not emit LIB_PRECALC_reu_mul_doubled_* exports
; in that build (matches the LIB_X25519_REU_BANKS_USED mask flip).
;
; Size = 3 × 65,536 B (one full REU bank each):
;   bank LIB_SHARED_REU_MUL_BANK + 3: 17th-bit carry table, 256 B × 256 rows = 64 KB
;   bank LIB_SHARED_REU_MUL_BANK + 4: doubled lo+hi, a = 0..127             = 64 KB
;   bank LIB_SHARED_REU_MUL_BANK + 5: doubled lo+hi, a = 128..255           = 64 KB
;                                                                  total: 196608 B
LIB_PRECALC_TABLE "reu_mul_doubled", 196608, PRECALC_REGION_REU, PRECALC_SHARED_NO
.endif
