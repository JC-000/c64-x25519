.setcpu "6502"

; =============================================================================
; c64-x25519 library version constants
;
; Consumers import these for assembly-time compatibility checks:
;
;   .import LIB_VERSION_MAJOR, LIB_VERSION_MINOR, LIB_VERSION_PATCH
;   .if LIB_VERSION_MAJOR <> 0 .or LIB_VERSION_MINOR < 5
;       .error "c64-x25519 v0.5 or newer is required"
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
LIB_VERSION_MINOR = 5
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
;   tables. At the default X25519_REU_BANK = 0, the library uses banks
;   0, 1, 3, 4, 5 (= mask $3B). Bank 2 is intentionally NOT claimed —
;   the v0.4.0 W2 refactor moved reu_clear_wide to a CPU clear and the
;   legacy bank-2 zero stash was removed in v0.6 prep. Mask is computed
;   as `$3B << X25519_REU_BANK` so an `-D X25519_REU_BANK=$N` override
;   of the bank base automatically shifts the claim. (Bank 7 is touched
;   transiently by reu_probe but restored before return; not counted as
;   a claim.)
;
; LIB_X25519_RESIDENT_BYTES
;   Approximate code + data footprint that must remain CPU-resident
;   in any consumer's address space. Measured from
;   `od65 --dump-segsize` on the library .o files:
;       CODE  total ≈ 4616 B   (x25519 + x25519_init + fe25519 +
;                               mul_8x8 + util; -51 B vs v0.5.0 after
;                               the v0.6-prep bank-2 stash removal)
;       DATA  total ≈ 3584 B   (page-aligned buffers + lookup tables
;                               in data.s; mixes mutable scratch and
;                               read-only tables in one segment)
;       SQTAB         1024 B   (runtime-built quarter-square table
;                               at fixed $7800-$7BFF)
;       --------------------------------------------------------------
;                            ≈ 9224 B total
;   (Refreshed 2026-05-20 after bank-2 stash drop. The three config .o
;   files ─ lib_version.o, zp_config.o, reu_config.o ─ contain only
;   equate declarations + .export directives and emit no CODE/DATA
;   bytes, so they don't shift this total.)
;
; LIB_X25519_COLD_BYTES
;   Approximate code + data footprint that a consumer MAY overlay-page
;   (load on demand from REU / banked RAM / external storage). The
;   library currently has no overlay-page candidates — reported as 0.
;   Note that reu_mul_init's body (~1 KB) is init-only and could in
;   principle be reclaimed after sqtab_init / reu_mul_init return; a
;   future release that splits it into a dedicated segment will bump
;   this equate.
; =============================================================================

; X25519_REU_BANK is .import'd so the linker can resolve the shift in
; LIB_X25519_REU_BANKS_USED. At assemble time the symbol is unresolved;
; ca65 emits the expression for ld65 to evaluate at link time.
.import X25519_REU_BANK

LIB_X25519_ZP_USAGE_BYTES = 85
LIB_X25519_REU_BANKS_USED = $3B << X25519_REU_BANK
LIB_X25519_RESIDENT_BYTES = 9224
LIB_X25519_COLD_BYTES     = 0

.export LIB_X25519_ZP_USAGE_BYTES: abs
.export LIB_X25519_REU_BANKS_USED: abs
.export LIB_X25519_RESIDENT_BYTES: abs
.export LIB_X25519_COLD_BYTES:     abs
