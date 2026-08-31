; =============================================================================
; lib_linkage_stub.s - Minimal downstream app used by `make lib-verify`
;
; This file exists purely to prove that build/lib/libx25519.a can actually
; be linked against a non-harness program. It imports a small cross-section
; of the public API, calls one routine, and returns. The `make lib-verify`
; target assembles this, links it with libx25519.a via cfg/x25519-example.cfg,
; and asserts that the resulting PRG is non-empty and that the expected
; symbols resolved.
;
; This is the "tarball isn't dead weight" smoke test, not a correctness test.
; =============================================================================

.setcpu "6502"

; ld65's LOADADDR segment needs this import to land the 2-byte load header.
.export __LOADADDR__: absolute = 1

; Pull in the library's public header. This .import's every public symbol
; so any regression that removes one will fail at link time here, which is
; exactly the smoke test we want.
;
; The header is the ONLY import surface for those symbols. This stub used
; to restate ~12 of them in its own `.import` lines below; those are gone
; deliberately, for two reasons:
;   (1) the header's contract#164 guards must GOVERN. A hand-rolled bare
;       `.import X25519_REU_BANK` here shadowed the header's .ifndef/.else
;       pair, so `-D X25519_REU_BANK=` died on "Symbol already defined" in
;       this file before the header's placement .assert could ever run --
;       i.e. lib-verify never exercised the shipped header's import block.
;   (2) a second surface list drifts silently: the header could add, gate
;       or rename an import and this stub would keep linking against its
;       own stale copy.
; What stays local is what the header cannot supply: the two `.importzp`
; ZP-slot lines, `__MAIN_SIZE__` (a linker-provided consumer symbol), and
; every `.word`/`.byte`/`.addr` reference block -- ca65 emits an import
; record only for a REFERENCED symbol, so those references are what
; actually force the archive-member pulls this smoke test is checking.
.include "x25519.inc"

; LOADADDR segment: 2-byte PRG load header.
.segment "LOADADDR"
        .addr $0801

; BASIC stub: SYS 2064 -> $0810
.segment "BASICSTUB"
        .word @basic_end        ; ptr to next BASIC line
        .word 10                ; line number
        .byte $9e               ; SYS token
        .byte "2064"
        .byte 0                 ; end of line
@basic_end:
        .word 0                 ; end of BASIC program

.segment "CODE"
        .res 3, $00             ; pad so start lands at $0810

start:
        ; One real call into the library: clamp the scalar buffer the
        ; library itself provides. No init required for clamping —
        ; it's pure byte manipulation.
        jsr x25519_clamp
        rts

; Reference every public symbol so that ld65's archive-member resolution
; pulls every library .o into the link. Without these references, ar65
; would only extract the modules reachable from x25519_clamp, and the
; smoke test wouldn't actually prove util.o / etc. are linkable.
;
; This table is unreferenced and dead-code, but ca65 will still emit
; the relocation entries for each address, which is what ld65 needs
; to see to resolve the archive members.
public_refs:
        .addr mul_tables_init
.ifndef SHARED_SQTAB_INIT
        ; x25519-own historical name — absent from a §8.1 deferral
        ; build (import-never-stub); canonical reference above stays.
        .addr sqtab_init
.endif
.if ::X25519_ONCHIP_MUL = 0
.ifndef SHARED_REU_MUL_INIT
        ; x25519-private init name — absent from a §8.2 deferral build
        ; (the canonical reu_mul_tables_init reference below stays and
        ; resolves against the provider stand-in; see
        ; shared_provider_stub.s / `make lib-verify-shared`).
        .addr reu_mul_init
.endif
.endif
        .addr x25519_clamp, x25519_scalarmult, x25519_base
        .addr fe25519_add, fe25519_sub, fe25519_mul, fe25519_sqr
        .addr fe25519_copy, fe25519_zero, fe25519_one, fe25519_cswap
        .addr fe25519_inv, fe25519_reduce_final, fe25519_mul_a24
        .addr x25_scalar, x25_u, x25_result, x25_basepoint
        .addr vic_blank, vic_unblank
        .addr bench_start, bench_stop, bench_ticks
        .addr bench_cycles_start, bench_cycles_stop, bench_cycles

; Version constants — integer equates, referenced via .word so ld65 pulls
; lib_version.o into the archive resolution. .byte would fail because
; ca65 cannot prove the import fits in a byte until link time.
;
; The PREFIXED forms (contract v0.7.0 §1) are the primary reference —
; they exist in every build mode and are what forces the lib_version.o
; member pull. The deprecated bare forms are additionally referenced
; only when the archive still exports them (gated on the same
; LIB_NO_BARE_EXPORTS define the archive build uses; CA65FLAGS
; propagates to this stub's assembly, so the two sides stay in step).
public_version_refs:
        .word LIB_X25519_VERSION_MAJOR, LIB_X25519_VERSION_MINOR
        .word LIB_X25519_VERSION_PATCH, LIB_X25519_ABI_VERSION
.ifndef LIB_NO_BARE_EXPORTS
        .word LIB_VERSION_MAJOR, LIB_VERSION_MINOR
        .word LIB_VERSION_PATCH, LIB_ABI_VERSION
.endif

; ZP slot exports from src/zp_config.s. .importzp + .byte references
; force ld65 to pull zp_config.o out of the archive.
.importzp fe25519_src1, fe25519_src2, fe25519_dst
.importzp fe_carry, mul_carry
public_zp_refs:
        .byte fe25519_src1, fe25519_src2, fe25519_dst
        .byte fe_carry, mul_carry

; REU layout equates from src/reu_config.s. .word reference forces ld65
; to pull reu_config.o out of the archive.
.if ::X25519_ONCHIP_MUL = 0
; c64-lib-contract §8.2 placement equates (v0.7-prep+).
; Derived symbolic bank names (also exported from reu_config.s).
public_reu_refs:
        .word X25519_REU_BANK, X25519_REU_OFFSET
        .word LIB_X25519_SHARED_REU_MUL_BANK, LIB_X25519_SHARED_REU_MUL_OFFSET
        .word LIB_X25519_SHARED_REU_MUL_BANKS_USED
        .word X25519_REU_BANK_DOUBLED, X25519_REU_BANK_CARRY
.endif ; X25519_ONCHIP_MUL = 0 (issue #72 — REU config surface)

; Manifest aggregate equates (c64-lib-contract §5). Same .word reference
; trick to force ld65 archive-member resolution of lib_manifest.o
; (split out of lib_version.o per SPEC v0.7.0 §1 TU isolation,
; issues #78/#79).
; §8.x ownership + consumes masks (SPEC v0.4.0 conditional form +
; v0.5.0 companion). The per-primitive bit constants are NOT imported:
; since issues #77/#78 they are unexported assemble-time equates that
; arrive via x25519.inc (SPEC §8.0 copy-the-block shape) — referenced
; below as plain constants, and asserted ABSENT from stub.labels by
; the lib-verify LIB_VERIFY_SYMS_ABSENT_ALWAYS check.
; §6.6 consumer-mirror footprint assert (SPEC v0.10.0): the declared
; pair must fit the consumer's own MAIN budget. lderror (imported
; operands), pair, <=, single-line — the normative form. Doubles as
; the living example the shipped cfg cannot carry (ld65 cfg syntax
; has no assert).
.import __MAIN_SIZE__
.assert (LIB_X25519_RESIDENT_BYTES + LIB_X25519_COLD_BYTES) <= __MAIN_SIZE__, lderror, "x25519 declared footprint exceeds the MAIN budget"

public_manifest_refs:
        .word LIB_X25519_ZP_USAGE_BYTES, LIB_X25519_REU_BANKS_USED
        .word LIB_X25519_RESIDENT_BYTES, LIB_X25519_COLD_BYTES
        .word LIB_X25519_SHARED_PRIMITIVES
        .word LIB_X25519_SHARED_CONSUMES
        .word LIB_SHARED_PRIMITIVES_SQTAB, LIB_SHARED_PRIMITIVES_REU_MUL
        .word LIB_SHARED_PRIMITIVES_CT_MUL_8X8

; c64-lib-contract §8.0 catch-loop exports (v0.7-prep+) are emitted by
; the LIB_PRECALC_TABLE macro invocations in lib_manifest.s. We do NOT
; .import them here because the SIZE export for reu_mul (131072) is
; auto-sized to `far` by ca65 and the 6502 target has no `far` import
; address-size hint to match. The smoke check for these symbols lives
; in the lib-verify shell target (grep against stub.labels), which
; doesn't need them in a stub.o-side import to resolve.

.if ::X25519_ONCHIP_MUL = 0
; SPEC §8.2 canonical entry point (v0.7-prep+).
; SPEC §8.2 SMC patch hook (v0.7-prep+); unlocks the #15 follow-up.
public_spec_82_refs:
        .addr reu_mul_tables_init
        .addr reu_fetch_mul_row_bank_patch
.endif ; X25519_ONCHIP_MUL = 0 (issue #72 — §8.2 surface absent in onchip)
