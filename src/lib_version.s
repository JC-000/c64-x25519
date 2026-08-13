.setcpu "6502"

; =============================================================================
; c64-x25519 library version constants — c64-lib-contract §1.
;
; TU-ISOLATION RULE (SPEC v0.7.0 §1): this translation unit exports the
; four §1 version equates and NOTHING else. ld65 links whole object
; members, so if the deprecated bare names below shared a member with
; anything a consumer legitimately imports (e.g. the §5 aggregates), the
; bare names would enter a two-library link uninvited and collide with a
; sibling library's identical bare exports (c64-lib-contract#43). The
; §5 aggregate / §8.x manifest surface lives in src/lib_manifest.s.
;
; Consumers import the prefixed forms for assembly-time compatibility
; checks:
;
;   .import LIB_X25519_VERSION_MAJOR, LIB_X25519_VERSION_MINOR
;   .if LIB_X25519_VERSION_MAJOR <> 0 .or LIB_X25519_VERSION_MINOR < 7
;       .error "c64-x25519 v0.7 or newer is required"
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
; See issue #45 for the contract this exposes, issues #77-#81 for the
; contract v0.7.0 prefixed-export migration.
; =============================================================================

LIB_X25519_VERSION_MAJOR = 0
LIB_X25519_VERSION_MINOR = 8
LIB_X25519_VERSION_PATCH = 0
LIB_X25519_ABI_VERSION   = 1

; Exported as absolute (16-bit) symbols, not zeropage. ca65 would otherwise
; infer zeropage size because the values fit in a byte, which then mismatches
; consumer `.import` declarations that default to absolute.
.export LIB_X25519_VERSION_MAJOR: abs
.export LIB_X25519_VERSION_MINOR: abs
.export LIB_X25519_VERSION_PATCH: abs
.export LIB_X25519_ABI_VERSION:   abs

.ifndef LIB_NO_BARE_EXPORTS
; Deprecated bare forms (contract v0.7.0; removed at contract v1.0).
; Identical across every contract library, so a consumer composing two
; or more libraries suppresses them build-wide with
; `ca65 -D LIB_NO_BARE_EXPORTS=1` and imports the prefixed forms only.
; Aliased to the prefixed equates rather than restating the literals: a
; release bump touches the four lines above, and the two forms cannot
; drift (SPEC §1).
LIB_VERSION_MAJOR = LIB_X25519_VERSION_MAJOR
LIB_VERSION_MINOR = LIB_X25519_VERSION_MINOR
LIB_VERSION_PATCH = LIB_X25519_VERSION_PATCH
LIB_ABI_VERSION   = LIB_X25519_ABI_VERSION

.export LIB_VERSION_MAJOR: abs
.export LIB_VERSION_MINOR: abs
.export LIB_VERSION_PATCH: abs
.export LIB_ABI_VERSION:   abs
.endif
