; =============================================================================
; single_scan_sibling.s - the SIBLING archive member for the #132 leg
;
; Stand-in for c64-ChaCha20-Poly1305's src/lib/poly1305_lib.s built with
; -D SHARED_SQTAB_INIT: it owns nothing of §8.1 and imports x25519's
; canonical entry. `make lib-verify-single-scan` puts this member in its own
; archive, listed AFTER x25519.a.
;
; It imports the CANONICAL §8.1 name only. `sqtab_init` is x25519's
; historical alias and is not what a deferring sibling imports.
; =============================================================================

.setcpu "6502"

.export sibling_entry
.import mul_tables_init

.segment "CODE"
sibling_entry:
        jsr mul_tables_init
        rts
