# c64-x25519 v0.11.1 — §6.6/§6.7 placement guards, consumer-reachable suppression knobs

PATCH release (`LIB_X25519_ABI_VERSION` stays 3 — no export-surface
change; **zero runtime change**, PRG byte-identical to v0.8.0 through
v0.11.0, SHA256 `905bb969…b95acc`). Rolls up PRs #98 and #100:
contract SPEC v0.10.0–v0.10.3 phase-2 adoption plus the #99 fix.

## Why a consumer should take this tag

**The SQTAB placement hazard is now a named link error, both ways.**
Since the contract #63 audit this library documented a fully silent
failure: nothing emits into the SQTAB segment, so a cfg whose region
diverged from `LIB_SHARED_SQTAB_BASE` — or an image growing into the
window — linked clean and `sqtab_init` overwrote 1 KB of live data at
boot. The §6.7 guard TU (`src/main.s`, never archived; base derived
source-level per v0.10.2) now asserts all three conditions as
`lderror` with named messages:

```
image overruns the sqtab window (LIB_SHARED_SQTAB_BASE)
cfg SQTAB region base disagrees with LIB_SHARED_SQTAB_BASE
cfg SQTAB region reserves less than 1024 bytes
```

The second and third are the region-agreement superset beyond the
SPEC minimum (a diverged region still linked clean under the
three-line form — measured at base `0x2A00`). Consumers writing their
own cfg mirror the same asserts against their map; both shipped cfgs
now set `define = yes` on MAIN, and `make lib-verify-guards` proves
all guards fire (including the v0.10.2 constraint-3 overrun
acceptance test).

**§6.6 consumer-mirror footprint assert** — the normative form
(single-line, `lderror`, RESIDENT+COLD as a pair, `<=`) ships in
LIBRARY.md and lives as a working example in the verify stub.

**`ZP_CONFIG_NO_EXPORTS` / `REU_CONFIG_NO_EXPORTS` are now
consumer-reachable** (#99, filed from the wireguard v0.11.0 bump):
both knobs were assigned unguarded in `constants.s`, making the
documented `-D` suppression route a hard redefinition in every TU.
Now `.ifndef`-guarded; the supplies-own-slots consumer model works as
documented (measured: the issue's repro builds clean; the suppressed
`zp_config.o` exports nothing; the default build is unchanged).

**Renamed-override loud-trip**: `-D poly_carry=<addr>` (pre-v0.11.0
spelling) no longer silently loses the relocation — it fails by name
pointing at `mul_carry`.

## §6.6 footprint pairs per shipped archive (obligation 2)

| Archive (this tag) | `RESIDENT_BYTES` | `COLD_BYTES` |
|---|---:|---:|
| `x25519.a` (default) | 8383 | 826 |
| `x25519-1764.a` (`SQR_DMA_K=0`) | 8247 | 648 |
| `x25519-onchip.a` (`X25519_ONCHIP_MUL=1`) | 8207 | 160 |
| `x25519-app-owned.a` (all §8.x deferred) | 8300 | 302 |

All od65-measured exact; custom deferral combinations derive by the
per-switch deltas encoded in `src/lib_manifest.s` (sqtab −160 COLD,
reu pair −364/−186 COLD by `SQR_DMA_K` and −20 RESIDENT, ct −63
RESIDENT). Declared values currently sit at measured equality; the
§6.6 round-up-vs-exact question is pending a SPEC ruling
(c64-lib-contract#76 item 3) — if round-up wins, the values and the
verify locks move together in a later release.

## Docs

CLAUDE.md refreshed to current state (release/CT-catalogue/module
inventory/REU-claim/build-commands — several claims dated to v0.3.0);
canonical §6.1 basenames referenced throughout.

## No perf / CT deltas

PRG byte-identical to v0.8.0
(`905bb969f027d02b4671ab04436d8c817b2f3fcfe31200af98931f6151b95acc`);
bench rows, hardware A/B results, and CT catalogue L1–L30 carry
forward unchanged.

## Tarball (DRAFT — filled by the post-tag SHA-fill PR)

```
File:     c64-x25519-v0.11.1.tar.gz
Size:     DRAFT
SHA256:   DRAFT
```
