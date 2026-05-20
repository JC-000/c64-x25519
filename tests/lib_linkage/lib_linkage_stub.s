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
        .addr sqtab_init, mul_tables_init, reu_mul_init
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
public_version_refs:
        .word LIB_VERSION_MAJOR, LIB_VERSION_MINOR
        .word LIB_VERSION_PATCH, LIB_ABI_VERSION

; ZP slot exports from src/zp_config.s. .importzp + .byte references
; force ld65 to pull zp_config.o out of the archive.
.importzp fe25519_src1, fe25519_src2, fe25519_dst
.importzp fe_carry, poly_carry
public_zp_refs:
        .byte fe25519_src1, fe25519_src2, fe25519_dst
        .byte fe_carry, poly_carry

; REU layout equates from src/reu_config.s. .word reference forces ld65
; to pull reu_config.o out of the archive.
.import X25519_REU_BANK, X25519_REU_OFFSET
public_reu_refs:
        .word X25519_REU_BANK, X25519_REU_OFFSET

; Manifest aggregate equates (c64-lib-contract §5). Same .word reference
; trick to force ld65 archive-member resolution of lib_version.o.
.import LIB_X25519_ZP_USAGE_BYTES, LIB_X25519_REU_BANKS_USED
.import LIB_X25519_RESIDENT_BYTES, LIB_X25519_COLD_BYTES
; c64-lib-contract §8.1 shared-primitives bitmask (v0.6+).
.import LIB_X25519_SHARED_PRIMITIVES, LIB_SHARED_PRIMITIVES_SQTAB
public_manifest_refs:
        .word LIB_X25519_ZP_USAGE_BYTES, LIB_X25519_REU_BANKS_USED
        .word LIB_X25519_RESIDENT_BYTES, LIB_X25519_COLD_BYTES
        .word LIB_X25519_SHARED_PRIMITIVES, LIB_SHARED_PRIMITIVES_SQTAB
