; =============================================================================
; zp_supply_stub.s - the consumer's own ZP slot supply, for lib-verify builds
; made with -D ZP_CONFIG_NO_EXPORTS=1.
;
; In that mode zp_config.o exports nothing, so a consumer that .importzp's
; any slot must export it from one of its own objects. lib_linkage_stub.s
; imports every roster slot; this TU exports every roster slot. Both lists
; come from expanding x25519_zp_roster (src/zp_config.s), so a slot added
; to the roster is imported by the stub and supplied here with no edit.
;
; Assembled with the same ALL_DEFINES as the library TUs (slot overrides
; included), so the addresses exported here are the ones the library
; objects were assembled with. Linked only in that mode (Makefile,
; LIB_ZP_SUPPLY); in the default mode zp_config.o is the supplier.
; =============================================================================

.setcpu "6502"

.ifndef ZP_CONFIG_NO_EXPORTS
.error "zp_supply_stub.s is the consumer-side supply for -D ZP_CONFIG_NO_EXPORTS=1 builds; without it zp_config.o exports every slot and this TU would duplicate them"
.endif

; Defines every slot (.ifndef-guarded default or -D override); exports none.
.include "zp_config.s"

.macro zp_supply_export p1, p2, name, addr, size
  .exportzp name
.endmacro
x25519_zp_roster zp_supply_export, 0, 0
.delmacro zp_supply_export
