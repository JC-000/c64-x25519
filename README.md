# c64-x25519

X25519 Diffie-Hellman (RFC 7748) for the Commodore 64.

An optimized implementation of X25519 / Curve25519 scalar multiplication written in ca65 6502 assembly, targeting the stock C64 with a 1750 REU — plus an opt-in `lib-x25519-onchip` build variant that needs no REU at all, computing multiplication rows on the 6502 for expansion-less and accelerated hosts. Validated against pyca/cryptography via VICE emulator and hardware-compatible test harness.

## Status

**v0.13.0 released 2026-08-31 (DRAFT until tagged)** — [GitHub release](https://github.com/JC-000/c64-x25519/releases/tag/v0.13.0) — a
build-integrity and evidence release. **Zero runtime change: the PRG is
byte-identical to v0.12.0** at `08d1fef1…f333`, 8628 B — everything here
is documentation, header, build-invalidation and verification machinery.
Two documented consumer overrides produced the wrong artifact at exit 0
(c64-lib-contract#164): `CONTRACT_STAMP` now invalidates **linked**
outputs, not just objects and archives — GNU Make 3.81's whole-second
mtime granularity let `make all` keep the previous config's PRG after a
knob change — and the header's `.import`s take the guarded-iff-the-TU-
guards shape, with an `.else` asserting any override against the
library's exported value (#121). c64-lib-contract SPEC **v0.17.0 §15**
evidence debt is discharged (#123): the §5 footprint pair is now
**measured** with `od65` instead of being two hand-written literals
compared against each other, `ct_mul_brute_check.py` gained `--mutate`,
and `lib-verify` gained eight per-check negative legs plus a
two-profile footprint demonstration. Twelve documentation defects fixed,
including four consumer snippets that taught a `$`-valued define (which
reaches ca65 as **0** through make, with no diagnostic anywhere) — now
rejected by `make lib-verify-docs`. **Consumer action:**
`reu_fetch_mul_row` / `reu_fetch_doubled_row` clobber **A and C**, not A
only, and always have — if you JSR either directly across a live carry,
add a `clc` and re-test (see §1 of the release notes). MINOR (`reu_probe`
added to the header's imports); ABI stays 3. Contract-aligned through
SPEC v0.17.0. See
[`docs/RELEASE_NOTES_v0.13.0.md`](docs/RELEASE_NOTES_v0.13.0.md).

**v0.12.0 released 2026-08-29** — [GitHub release](https://github.com/JC-000/c64-x25519/releases/tag/v0.12.0) (tarball 143,836 B, SHA256 `b6b7c930…4902`) — c64-lib-contract SPEC **v0.13.0 §8.2**
made REU completion checking normative (contract#146; tracked here as
#115): after every REU execute, read `$DF00`, confirm bit 6 (END OF
BLOCK) before the next register access, and leave the bracketed
post-execute settle. All twelve execute sites now carry the
`REU_SETTLE` macro; the spin bound `X25519_REU_SETTLE_ITER` (default 8)
is a §6.2 knob, and faults land in the new sticky `x25519_reu_fault`
byte, which `reu_probe` folds into its C=0 return. Conformant at
≤ 48 MHz on U64E fw 3.15; 64 MHz is unbracketed. The release also
carries the 2026-08-28 adversarial audit (#117,
[`docs/AUDIT_2026-08-28.md`](docs/AUDIT_2026-08-28.md)): `fe25519_mul_a24`
dropped the carry out of byte 31 (result short by 38 for ~5.8e5
canonical inputs — proof-level, ≈2^-236 per ladder step, but wrong
output; fixed in CT shape, L32), the documented `fe_reduce_wide` bound
was corrected, and two tests that had never been able to pass were
repaired and wired into `test-slow` with a new adversarial suite. RFC
7748 §5.2 1,000-iteration vector PASS on the shipped code. Cost, total:
+0.47 % scalarmult (15,389 → 15,462 jif), +120 B resident (8383 → 8503).
MINOR (new export + new knob); ABI stays 3. Contract-aligned through SPEC v0.15.0 (v0.12.x
/ v0.14.0 are §13.x networking, N/A here; v0.14.1 is a §8.2 wording
PATCH that keeps this implementation conformant). See
[`docs/RELEASE_NOTES_v0.12.0.md`](docs/RELEASE_NOTES_v0.12.0.md) and
`docs/LIBRARY.md` §4.12.

**v0.11.3 released 2026-08-23** — [GitHub release](https://github.com/JC-000/c64-x25519/releases/tag/v0.11.3) — a build-correctness
release. Two defects were live in every release through v0.11.2, both in
the canonical §6.1 build surface. `make lib` failed outright after any
profile target had run (`cp: build/lib/cfg/x25519-example.cfg: No such
file or directory`) — order-only prerequisite semantics, not a missing
`mkdir` (#109). And §6.2 knob changes were silently ignored on a warm
tree: `-D SHARED_CT_MUL_8X8=1` shipped the *owner* archive to a consumer
asking for the deferring one, and `-D LIB_NO_BARE_EXPORTS=1` did not
suppress at all — the exact contract#43 collision that flag exists to
prevent, so passing it was not evidence it took effect (#110, contract#127).
Both are the same shape: green in isolation, broken in composition, with
nothing building the sequence. The onchip × deferral intersection is now
covered too, link-only. Zero runtime change — the PRG is byte-identical
to v0.11.0–v0.11.2; ABI stays 3. Contract-aligned through SPEC v0.11.1.
See [`docs/RELEASE_NOTES_v0.11.3.md`](docs/RELEASE_NOTES_v0.11.3.md).

**v0.11.2 released 2026-08-15** — [GitHub release](https://github.com/JC-000/c64-x25519/releases/tag/v0.11.2) — a documentation-accuracy release. The
`vic_blank` speedup was documented as "~20-25%" in eight places since
v0.1.0; the real figure on the 25-row text screen this library runs is
**~6%** (NTSC; ~5.5% PAL), confirmed by three independent measurements
and by the badline arithmetic (#103). The bench that should have caught
the drift now can: it moved off the jiffy clock — too coarse to resolve
a 6% effect, and the likely source of the inflated number — onto the
cycle-exact CIA1 counter, with its previously-printed-only result now a
`make test-slow` assertion. Also contract v0.10.4–v0.10.6 alignment,
including a §6.3 guard making `X25519_PROFILE` select its axis or fail
loudly (#106). Zero runtime change — the PRG is byte-identical to
v0.11.0 and v0.11.1; ABI stays 3. See
[`docs/RELEASE_NOTES_v0.11.2.md`](docs/RELEASE_NOTES_v0.11.2.md).

**v0.11.1 released 2026-08-15** — [GitHub release](https://github.com/JC-000/c64-x25519/releases/tag/v0.11.1) — §6.6/§6.7 placement guards: the
long-documented silent SQTAB divergence hazard is now a named link
error in every failure direction (with negative verify legs proving
the guards fire), the consumer footprint-assert pattern ships in its
normative form, and the `*_CONFIG_NO_EXPORTS` suppression knobs are
consumer-reachable (#99). Zero runtime change; ABI stays 3. See
[`docs/RELEASE_NOTES_v0.11.1.md`](docs/RELEASE_NOTES_v0.11.1.md).

**v0.11.0 released 2026-08-15** — [GitHub release](https://github.com/JC-000/c64-x25519/releases/tag/v0.11.0) — the phase-3 fleet-wave release:
contract SPEC v0.9.0–v0.9.2 §6-chapter migration (defines-forwarding,
import-never-stub, fetch deferral, truthful per-config manifests,
`lib-app-owned`, canonical `x25519[-variant].a` basenames) plus the
contract #82/#83 composed-link fixes. **`LIB_X25519_ABI_VERSION`
2 → 3** (bare `LIB_SHARED_REU_MUL_*` + ZP-trio export removals,
`poly_carry` → `mul_carry`). Zero runtime change — PRG byte-identical
to v0.8.0. See
[`docs/RELEASE_NOTES_v0.11.0.md`](docs/RELEASE_NOTES_v0.11.0.md).

**v0.10.1 released 2026-08-14** — [GitHub release](https://github.com/JC-000/c64-x25519/releases/tag/v0.10.1) — contract alignment sweep (PR #89):
the consumer version-guard snippets now actually assemble (the old
`.if` forms were rejected by ca65 on imported symbols — SPEC v0.8.1
`.assert`/`lderror` forms shipped, ABI-generation gate added), cfg
attribute failure modes declared per SPEC v0.8.0 §4 (including the
fully-silent SQTAB region/equate divergence), onchip footprint doc
figures corrected to measured values, `lib-verify` per-profile value
locks. Zero code change. See
[`docs/RELEASE_NOTES_v0.10.1.md`](docs/RELEASE_NOTES_v0.10.1.md).

**v0.10.0 released 2026-08-14** — [GitHub release](https://github.com/JC-000/c64-x25519/releases/tag/v0.10.0) — `LIB_X25519_ABI_VERSION` **1 → 2**
(erratum: the v0.9.0 `LIB_SHARED_PRIMITIVES_*` export removal was a
breaking export change under contract v0.7.5's clarified
generation-counter semantics; the counter catches up here) + the
contract v0.7.4 `precalc_table.inc` re-copy (#85/#86 — six
`Address size mismatch` link warnings on the `_REGION`/`_SHARED`
manifest imports → zero). Zero code change; PRG remains byte-identical
to v0.8.0. See
[`docs/RELEASE_NOTES_v0.10.0.md`](docs/RELEASE_NOTES_v0.10.0.md).

**v0.9.0 released 2026-08-13** — [GitHub release](https://github.com/JC-000/c64-x25519/releases/tag/v0.9.0) — c64-lib-contract SPEC v0.7.0/v0.5.0
manifest migration (#77–#81, PR #82): library-prefixed manifest
exports (`LIB_X25519_VERSION_*`, `LIB_X25519_PRECALC_*`), the
`LIB_NO_BARE_EXPORTS` composing-consumer gate, the
`LIB_X25519_SHARED_CONSUMES` companion mask, and un-exported §8.x bit
constants — a consumer can now link c64-x25519 and
c64-ChaCha20-Poly1305 in one PRG and import both manifests. Zero code
change: the PRG is byte-identical to v0.8.0, so all v0.8.0 perf and
CT results carry over. One narrow migration edge for hand-written
`.import LIB_SHARED_PRIMITIVES_*` lines (see
[`docs/RELEASE_NOTES_v0.9.0.md`](docs/RELEASE_NOTES_v0.9.0.md)).

**v0.8.0 released 2026-07-27** — [GitHub release](https://github.com/JC-000/c64-x25519/releases/tag/v0.8.0). — rolls up the
cold-segment split (#68/#69), the SPEC §4 segment-prefix migration
(#70/#71), and the **`X25519_ONCHIP_MUL` no-REU build profile**
(#72/#73). One consumer action item: ld65 cfgs need the three new
`LIB_X25519_*` segment declarations (see the migration callout in
[`docs/RELEASE_NOTES_v0.8.0.md`](docs/RELEASE_NOTES_v0.8.0.md)).
Hardware-measured on both Ultimate generations: onchip is **1.85×
faster at 48 MHz (U64E)** and **2.00× at 64 MHz (C64U)**, crossovers
~17/~20 MHz on those devices (~7.7 MHz projected for a real 1750);
stock-clock users keep the default build. Details below and in the
release notes.

**Since v0.7.0 (v0.8-prep on master)** — cold-segment split
([#68](https://github.com/JC-000/c64-x25519/issues/68)): init-only
code (`sqtab_init`, `reu_mul_init`, `reu_probe`) moved to the new
`LIB_X25519_INIT_CODE` segment (c64-lib-contract SPEC §4 naming, the
library's first prefixed segment), declared last in MAIN so consumers
can reclaim it as a contiguous RAM tail after boot.
`LIB_X25519_COLD_BYTES` is real for the first time: 826 B default /
648 B `lib-x25519-1764`, with `LIB_X25519_RESIDENT_BYTES` dropping to
8383 / 8247 (SPEC §5 disjoint partition). The §8.3 `ct_mul_8x8` body
deliberately stays resident (owner-mode composition + CT-gate access).
**Consumer cfg change required on upgrade**: your ld65 cfg must
declare the new segment — see `docs/LIBRARY.md` §4.10 and
`cfg/x25519-example.cfg` constraint 5. Standalone builds unchanged.

- Full SPEC §4 segment-prefix migration
  ([#70](https://github.com/JC-000/c64-x25519/issues/70),
  [#71](https://github.com/JC-000/c64-x25519/pull/71)): library
  sources now emit `LIB_X25519_CODE` / `LIB_X25519_DATA` instead of
  the default ld65 `CODE` / `DATA` names (pure rename, zero byte
  movement; `main.s` is harness code and keeps plain `CODE`).
  **Consumer cfg must add the two segments** — `LIB_X25519_CODE` and
  `LIB_X25519_DATA` (the latter with the CT-load-bearing
  `align = 256`) — bundled with #68's cfg change so consumers
  migrate once. See `docs/LIBRARY.md` §3/§4 and
  `cfg/x25519-example.cfg` constraints 1–2.

- New `make lib-x25519-onchip` build variant
  ([#72](https://github.com/JC-000/c64-x25519/issues/72)):
  `fe25519_mul` generates its multiplication rows on the 6502 via a
  constant-time generator over the §8.3 `ct_mul_8x8` body, so the
  profile issues **no REU traffic at all** — the library's first
  no-REU configuration, boot obligation `sqtab_init` only,
  `LIB_X25519_REU_BANKS_USED = 0`, `LIB_X25519_SHARED_PRIMITIVES =
  $0005`. Slower at stock clock (449,589,657 cy = 1.718× default;
  the REU tables exist because they win at 1 MHz); aimed at turbo
  hosts, where REU DMA is a wall-clock floor that CPU acceleration
  cannot lift. Additive and opt-in — the default build is
  byte-identical with the profile undefined. **Hardware-measured
  (same-boot A/B, oracle-gated): 1.85× at 48 MHz on the U64E, 2.00×
  at 64 MHz on the C64U**; measured crossovers ~17 MHz (U64E) /
  ~20 MHz (C64U), ~7.7 MHz projected for a real discrete 1750 (the
  Ultimates' FPGA REUs transfer ~3× faster than 1 cy/byte under
  turbo). Also proven on a no-REU stock configuration on both
  devices and in REU-less VICE. CT audit: `L30a-d` in
  `docs/CT_ANALYSIS.md`; full measurement story in
  `docs/design/issue_72_onchip_mul.md`.

---

**v0.7.0 released 2026-07-16** — [GitHub release](https://github.com/JC-000/c64-x25519/releases/tag/v0.7.0),
MIT licensed. **RFC 7748 decode fix** + the
c64-lib-contract **§8 shared-primitives completion release**. Every
§8.x clause of SPEC v0.4.0 that names c64-x25519 as an adopter is
shipped. Pure-additive ABI vs v0.6.0; no CT posture change (L1–L29
stays closed).

Headline (vs v0.6.0):

- **RFC 7748 decodeUCoordinate fix**
  ([#64](https://github.com/JC-000/c64-x25519/issues/64) /
  [#65](https://github.com/JC-000/c64-x25519/pull/65)): since v0.4.0,
  `x25519_scalarmult` returned deterministically wrong results for
  peer u-coordinates with bit 255 set — the W4 H1 no-mutation change
  masked the working copy x₃ but the ladder kept reading the caller's
  unmasked `x25_u` as x₁ (off by 19 mod p). Fixed with a library-owned
  masked `x25_x1` snapshot; `x25_u` stays unmutated. Conforming peers
  (canonical keys < p) were never affected; no secret leakage; no CT
  impact (`docs/CT_ANALYSIS.md` §S4). Caught by RFC 7748 §5.2 vector 2
  in `make test-slow`, now a mandatory release gate.
- **§8.2 `reu_mul` + §8.0 catch-loop adoption**
  ([#59](https://github.com/JC-000/c64-x25519/pull/59)): the 128 KB
  8×8→16 REU multiplication table promoted to a shared primitive.
  `LIB_SHARED_REU_MUL_BANK` placement equate, `SHARED_REU_MUL_INIT`
  migration gate, canonical `reu_mul_tables_init` entry,
  `reu_fetch_mul_row_bank_patch` SMC hook, plus the §8.0 step-6
  precalc-table enumeration (`docs/precalc-tables.md` +
  `LIB_PRECALC_TABLE` equates). See [`docs/LIBRARY.md`](docs/LIBRARY.md)
  §4.8 + §4.9.
- **Issue-15 SMC-patch refactor**
  ([#61](https://github.com/JC-000/c64-x25519/pull/61)):
  `reu_fetch_doubled_row`'s 512 B fetch delegates to the canonical
  §8.2 `reu_fetch_mul_row` via SMC bank patch; carry fetch stays
  inline. Autoload-latch invariant documented at three sites in
  `src/x25519_init.s`; W2-class guard `tools/test_fe_sqr_then_mul.py`
  (60/60). Cost: `fe25519_sqr` +1.5 % at the release boundary (≤ 2 %
  gate); gated out entirely at K=0.
- **§8.3 canonical `ct_mul_8x8` body**
  ([#62](https://github.com/JC-000/c64-x25519/pull/62)): the multiply
  body is **byte-identical** to the canonical c64-ChaCha20-Poly1305
  `ct_mul_8x8` (59 B, SHA `3ed9025b…`; cross-adopter
  `ct_mul_brute_check.py` gate exit 0 across chacha == nist-curves ==
  x25519, 65536/65536 functional). `mul_8x8` retained as back-compat
  alias; new `SHARED_CT_MUL_8X8` migration gate. Boot-only in x25519
  (no network-observable exposure); CT discipline retained as the
  canonical shared shape.
- **§8.0 conditional shared-primitives mask + bit `$0004`**
  ([#63](https://github.com/JC-000/c64-x25519/pull/63)):
  `LIB_X25519_SHARED_PRIMITIVES` now reports only what a build
  configuration *owns* — each deferral switch drops its bit, making
  the consumer double-ownership `.assert` satisfiable under
  legitimate sharing. Standalone: `$0007`.
- **Header sync + footprint refresh** (release PR): `src/x25519.inc`
  gains the contract-level imports that were exported-but-undeclared;
  `LIB_X25519_RESIDENT_BYTES` re-measured — `9209` default / `8895`
  1764 variant (−15 / −151 B vs v0.6.0, including the +19 B #64 fix).

Runtime: scalarmult `263,581,957` cy / `15,463.5` jif (≈ +0.7 % vs
v0.6.0: the issue-15 `fe25519_sqr` delta + the #64 init copy;
`fe25519_mul` bit-identical). RFC 7748 vec-0 PASS.

See [`docs/RELEASE_NOTES_v0.7.0.md`](docs/RELEASE_NOTES_v0.7.0.md)
for the full story.

---

**v0.6.0 released 2026-05-20** — [GitHub release](https://github.com/JC-000/c64-x25519/releases/tag/v0.6.0),
MIT licensed. RAM-reclaim + bench-rehab + build-variant +
c64-lib-contract §8.1 adoption. **Pure-additive ABI** vs v0.5.0: zero
removals, no default behavioural change.

Headline (vs v0.5.0):

- **−51 B RESIDENT_BYTES** from removing the dead bank-2 REU zero
  stash; `LIB_X25519_REU_BANKS_USED` flips `$3F → $3B` (banks 0, 1,
  3, 4, 5; bank 2 free for sibling consumers). PR [#54](https://github.com/JC-000/c64-x25519/pull/54).
- **New `make lib-x25519-1764` build variant** — opt-in archive
  targeting 256 KB REU (stock 1764). Drops the doubled-mul cluster
  (banks 3/4/5), reports `LIB_X25519_REU_BANKS_USED = $03` /
  `LIB_X25519_RESIDENT_BYTES = 9046`. Costs +16.2 % on scalarmult
  (15,352 → 17,845 jif) in exchange for −192 KB REU + −178 B CODE,
  lowering the hardware floor from 1750 → 1764. PR [#55](https://github.com/JC-000/c64-x25519/pull/55).
- **Bench observability rehab.** `tools/bench_fe_ops.py` switched
  to the CIA1 cycle counter (cycle-exact, sei-safe), both bench
  scripts emit `--json` sidecars. `src/util.s` `bench_start /
  bench_stop` restored to a self-contained `php / plp` shape —
  fixes a silent PR #39 regression that had been **trivially
  passing the CT cycle guards** (`tools/test_ct_*_cycles.py`) by
  returning `0 jif spread` since v0.4.0. Post-fix, those guards
  measure real per-call jif (≤ 0.005 jif spread; CT property
  holds and is now actually verified). PRs [#54](https://github.com/JC-000/c64-x25519/pull/54) +
  [#55](https://github.com/JC-000/c64-x25519/pull/55).
- **c64-lib-contract §8.1 adoption** — the canonical shared
  quarter-square table. New equate `LIB_SHARED_SQTAB_BASE`
  (default `$7800`, `.ifndef`-overridable); new `mul_tables_init`
  canonical alias; new `SHARED_SQTAB_INIT` migration gate that
  shrinks `mul_8x8.o` CODE 251 → 102 B (−149 B) when a multi-lib
  host supplies the canonical init elsewhere; new
  `LIB_X25519_SHARED_PRIMITIVES = $0001` (`LIB_SHARED_PRIMITIVES_SQTAB`)
  manifest equate per SPEC §5. PR [#56](https://github.com/JC-000/c64-x25519/pull/56).
- **Perf-tracking infrastructure.** `make bench-record` appends a
  row to `docs/perf_history.csv`; `make perf-diff` prints the
  markdown delta vs the previous row; `tools/perf_diff.py` powers
  the diff. Used at every v0.6 release boundary; documented
  trade-offs in `docs/REU_USAGE_ANALYSIS.md`. PR [#54](https://github.com/JC-000/c64-x25519/pull/54).
- **v1.0 deprecation notice.** `src/x25519.inc` flags `mul_by_38`,
  `reu_fetch_mul_row`, `x25_basepoint` for removal in v1.0
  (uncalled / superseded). PR [#54](https://github.com/JC-000/c64-x25519/pull/54).

Runtime is bit-identical to v0.5.0 at the default configuration
(scalarmult `261,681,380` cy / `15,352` jif; RFC 7748 vec-0 PASS).
The `+0.02 %` shift vs v0.5.0's `261,640,265` cy is pure code-layout
noise from the bank-2 stash removal.

See [`docs/RELEASE_NOTES_v0.6.0.md`](docs/RELEASE_NOTES_v0.6.0.md)
for the full story.

**v0.5.0 released 2026-05-20** — [GitHub release](https://github.com/JC-000/c64-x25519/releases/tag/v0.5.0), MIT licensed. c64-lib-contract §1/§2/§3/§5 adoption.
A library-ingestion release with no CT or correctness changes.
v0.5.0 ships the four sections of [c64-lib-contract](https://github.com/JC-000/c64-lib-contract)
that consumer projects (c64-https, c64-wireguard) need to compose
c64-x25519 alongside sibling crypto libraries without source
patching:

- **§1 Version identification** ([#45](https://github.com/JC-000/c64-x25519/issues/45) / [#47](https://github.com/JC-000/c64-x25519/pull/47)): new
  `src/lib_version.s` exports `LIB_VERSION_MAJOR/_MINOR/_PATCH`
  and `LIB_ABI_VERSION` for consumer version guards (link-time
  `.assert`/`lderror` since SPEC v0.8.1).
- **§2 Zero-page contract** ([#44](https://github.com/JC-000/c64-x25519/issues/44) / [#48](https://github.com/JC-000/c64-x25519/pull/48)): every consumer-
  overridable ZP slot moved to a dedicated `src/zp_config.s` with
  `.exportzp` declarations, so consumer modules can `.importzp`
  individual slots without dragging in BASIC/KERNAL hardware
  equates via `constants.s`.
- **§3 REU layout contract** ([#43](https://github.com/JC-000/c64-x25519/issues/43) / [#49](https://github.com/JC-000/c64-x25519/pull/49)): new `src/reu_config.s`
  exports `X25519_REU_BANK` (default `0`) and `X25519_REU_OFFSET`
  (default `$0000`), `.ifndef`-guarded for `ca65 -D` override.
  13 bank-immediate sites in `x25519_init.s` rewritten to
  `+X25519_REU_BANK` so consumers can relocate the six-bank mul-
  table claim without source patches.
- **§5 Aggregate manifest equates** ([#46](https://github.com/JC-000/c64-x25519/issues/46) / [#50](https://github.com/JC-000/c64-x25519/pull/50)): four exports for
  consumer-side cfg fit/collision checks: `LIB_X25519_ZP_USAGE_BYTES = 85`,
  `LIB_X25519_REU_BANKS_USED = $3B << X25519_REU_BANK` (banks 0, 1, 3, 4, 5),
  `LIB_X25519_RESIDENT_BYTES = 8383` (as of the v0.8-prep #68 split;
  9209 at v0.7.0), `LIB_X25519_COLD_BYTES = 826` (was 0 pre-split).
  (Bank 2 dropped + 51 CODE bytes reclaimed in v0.6 prep after the
  REU usage audit — see [`docs/REU_USAGE_ANALYSIS.md`](docs/REU_USAGE_ANALYSIS.md).)
  A second v0.6-prep `make lib-x25519-1764` build variant lowers the
  minimum REU spec to 256 KB (stock 1764) by gating out the
  doubled-table cluster in banks 3/4/5; that variant reports
  `LIB_X25519_REU_BANKS_USED = $03` and `LIB_X25519_RESIDENT_BYTES = 8247`
  (as of the v0.8-prep #68 split; 8895 at v0.7.0) at +16.2 % scalarmult
  cost.

All changes are pure-additive: no symbol removals, no behaviour
change at default configuration. v0.4.0 consumers can adopt v0.5.0
without source edits. The §4 (segment naming) and §6 (build target
variants) sections of the contract were deferred at v0.5.0 (§4 has
since closed via #68 + #70 in v0.8-prep; §6 remains open). See
[`docs/RELEASE_NOTES_v0.5.0.md`](docs/RELEASE_NOTES_v0.5.0.md) for
the full adoption story.

**v0.4.0 released 2026-05-10** — Phase 7 LANDED: full L1-L29 CT
closure across the entire `fe25519_*` / `mul_8x8` /
`x25519_scalarmult` surface. v0.4.0 closed the v0.4.0-disclosed
27 secret-data-dependent branches across 5 leak families
(L25 / L26a-d / L27a-f / L28a-k / L29a-e) in `src/fe25519.s` —
`fe25519_mul`, `fe_reduce_wide`, `fe25519_mul_a24`,
`fe25519_add`, `fe25519_sub`, `fe_cmp_p`,
`fe25519_reduce_final`. The library is **L1-L29 CT-clean** for
network-facing deployments. Per-proc CT cycle-count guards
(`make test-vice`) report spreads of 0.000-0.01 jif across
structurally distinct inputs, well under the 1.0 jif threshold.
ZP claim grew to 85 bytes at `$14-$16, $1C, $1E-$2A, $2C-$2F,
$40-$7F`. See
[`docs/RELEASE_NOTES_v0.4.0.md`](docs/RELEASE_NOTES_v0.4.0.md)
for the full Phase 7 closure mechanism and migration guidance.

**v0.3.0 released 2026-04-19** — [GitHub release](https://github.com/JC-000/c64-x25519/releases/tag/v0.3.0),
MIT licensed. A perf-recovery + full-CT-certification minor release:
`x25519_scalarmult` (basepoint 9) lands at **12,070 jiffies
(~201.2 s NTSC / ~241.4 s PAL)**, which is **−415 jif (−3.3 %) vs
v0.2.0's 12,485 jif** and **+26.8 % vs v0.1.0's 9,520-jif baseline**.
Two independent bodies of work:

1. **Perf recovery (Phases 1–3).** Rewrites `fe25519_sqr`'s hot path
   without touching any CT invariant: SMC-literal hoist +
   register-threaded abs-math (Phase 1, −247 jif), `SQR_DMA_K` retune
   14→22 (Phase 2, −347 jif), and chain-step address-math +
   ripple-setup fold (Phase 3, −1,152 jif, overshooting its −425 jif
   plan estimate). Phase 3's PR includes an 8-invariant correctness
   walkthrough. Phase 0 ships a CT cycle-count regression guard
   (`tools/test_ct_square_cycles.py`) asserting `fe25519_sqr` stays
   data-independent to within 1 jif.

2. **Full CT certification (L23 + L24 audit closures).** v0.3.0 is
   the first release with **full field-op + outer-ladder side-channel
   posture**. PR [#31](https://github.com/JC-000/c64-x25519/pull/31)
   closes L23a/b/c in `fe25519_sqr`'s `@diag_prop` diagonal-term carry
   path (+1,330 jif) with a Phase-6-style unconditional ripple. PR
   [#30](https://github.com/JC-000/c64-x25519/pull/30) closes L24a/b
   in the Montgomery ladder — two scalar-bit-dependent branches in
   the bit loop — with a branchless `cmp/sbc/eor` bit-to-mask idiom
   (0 jif regression). `fe25519_cswap` is verified CT-clean by
   inspection (no source change). All 24 catalogued leaks (L1–L24)
   are now closed. The library's outermost primitive no longer leaks
   scalar-bit information through branch timing.

Post-release CT cycle-guard spread is **0.045 jif** across five
structurally distinct inputs (3× tighter than the pre-audit 0.150
spread; the `@diag_prop` fix tightened the per-call timing
distribution). **Public API unchanged** from v0.2.0. See
[`docs/RELEASE_NOTES_v0.3.0.md`](docs/RELEASE_NOTES_v0.3.0.md) for
the full release notes and [`docs/CT_ANALYSIS.md`](docs/CT_ANALYSIS.md)
for the underlying leak inventory.

**v0.2.0 released 2026-04-19** — [GitHub release](https://github.com/JC-000/c64-x25519/releases/tag/v0.2.0),
MIT licensed. Constant-time remediation of issue
[#20](https://github.com/JC-000/c64-x25519/issues/20) is **complete**
for the `fe25519_*` / `mul_8x8` surface. Phases 0–6 have fixed all
22 catalogued secret-dependent branches and page-cross leaks (L1–L22)
across `mul_8x8`, `fe25519_mul`, and `fe25519_sqr` (including
`fe25519_sqr`'s cross-term carry-cascade path, which now uses an
unconditional per-body pending-carry chain plus a public-indexed
end-of-inner ripple). Every branch in the field-op hot path now
depends only on public loop indices. Hosts can now override the
library's zero-page layout via `.ifndef` guards in `src/constants.s`
to compose with sibling c64 crypto libraries — see
[`docs/LIBRARY.md`](docs/LIBRARY.md) §4.2. Public API is unchanged
from v0.1.0. See [`docs/CT_ANALYSIS.md`](docs/CT_ANALYSIS.md) for
the full leak inventory, threat model, landing history, Phase 6
correctness/CT argument, and remaining non-critical audit items
(the `@diag_prop` diagonal path and the outer `x25519_scalarmult`
ladder/cswap audit).

**v0.1.0 released 2026-04-13** — [GitHub release](https://github.com/JC-000/c64-x25519/releases/tag/v0.1.0), MIT licensed. The `fe25519_*` and `x25519_*` public API is locked for the v0.1.0 series and follows semver: additive changes bump the minor version, breaking API changes bump the major. `make test-slow` passes all assertions across 11 test suites against pyca/cryptography as the external reference.

## Performance

| Operation | Cost |
|---|---|
| `x25519_scalarmult` (basepoint 9, v0.8.0 default build) | **262,318,045 cycles / ~4.3 min NTSC** (−0.48% vs v0.7.0, layout win) |
| `x25519_scalarmult` (v0.8.0 `lib-x25519-onchip`, stock 1 MHz) | 449,589,657 cycles / ~7.3 min NTSC (1.718× default — stock users keep the default build) |
| `x25519_scalarmult` (onchip vs default, turbo hardware) | **1.85× faster @ 48 MHz (U64E), 2.00× @ 64 MHz (C64U)** — same-boot A/B, oracle-gated; crossovers ~17/~20 MHz |
| `x25519_scalarmult` (basepoint 9, v0.4.0 / Phase 7 landed) | 15,350 jiffies / ~256.4s NTSC / ~307.7s PAL (261,640,265 cycles, CIA1-timer measurement) |
| `x25519_scalarmult` (basepoint 9, v0.3.0) | 12,070 jiffies / ~201.2s NTSC / ~241.4s PAL |
| `x25519_scalarmult` (basepoint 9, v0.2.0) | 12,485 jiffies / ~208.1s NTSC / ~249.7s PAL |
| `x25519_scalarmult` (basepoint 9, v0.1.0 baseline) | 9,520 jiffies / ~158.7s NTSC |
| `fe25519_mul` | 5.98 jiffies/call (v0.4.0, CT spread 0.000) |
| `fe25519_sqr` | 6.44 jiffies/call (v0.4.0, CT spread 0.005) |
| `fe25519_mul_a24` | 0.475-0.480 jiffies/call (v0.4.0, CT spread 0.005) |

All measurements on stock C64 with VIC-II blanked (`jsr vic_blank`),
median of 3 runs. Blanking is worth ~6 % on the plain 25-row text
screen the harness runs (~5.5 % on PAL); it is not the ~20-25 % this
repo previously documented (issue #103) — see
[`docs/LIBRARY.md`](docs/LIBRARY.md) §Methodology for the badline
arithmetic. v0.3.0 combines two independent bodies of work on
the v0.2.0 baseline: the Phases 1–3 `fe25519_sqr` hot-path rewrite
recovers **1,746 jif** from the v0.1.0→v0.2.0 regression without
touching any CT invariant, and the L23 + L24 audit closures cost back
**~1,330 jif** for full outer-ladder side-channel certification. Net
vs v0.2.0: **−415 jif (−3.3 %)** and fully CT-certified. The library
runs at **+26.8 % vs the v0.1.0 baseline** (vs +31.1 % at v0.2.0)
and **~32.9 % faster than the original un-optimized ~18,000-jiffy
baseline** (vs ~31 % at v0.2.0, ~47.1 % at v0.1.0). See
[`docs/RELEASE_NOTES_v0.3.0.md`](docs/RELEASE_NOTES_v0.3.0.md) for the
full perf and CT-posture story.

## Requirements

- **CPU:** 6502 (stock C64)
- **Assembler:** ca65/ld65 (cc65 suite)
- **REU:** 1750 REU or equivalent (6 banks of 64 KB = 384 KB required for mul tables) — default build. Lowered to 256 KB by `make lib-x25519-1764`, and removed entirely by `make lib-x25519-onchip` (see "Build variants" below)
- **RAM:** BASIC ROM banked out at startup; library owns specific ZP + RAM regions
- **Test harness:** VICE emulator + `c64-test-harness` Python package

See [`docs/LIBRARY.md`](docs/LIBRARY.md) for the full integration guide, memory map, and public API reference.

## Quick start (upstream test harness)

```
make              # builds build/x25519.prg (standalone test harness)
make test-slow    # full RFC 7748 + differential tests via VICE
```

## Integrating into your own project

c64-x25519 is designed to be **vendored as source** into downstream C64 projects rather than linked as a system library. The current **v0.5.0** release hosts a downloadable tarball asset; new integrations should pin to it. Verify the SHA256 before extracting.

**v0.5.0 (current — recommended for new integrations):**

```
curl -LO https://github.com/JC-000/c64-x25519/releases/download/v0.5.0/c64-x25519-v0.5.0.tar.gz
echo "d79fe1a508c6f8612e2290e396c2ce3928a6c3b0c3d672e755418b83b0182a91  c64-x25519-v0.5.0.tar.gz" | sha256sum -c
mkdir -p vendor && tar -xzf c64-x25519-v0.5.0.tar.gz -C vendor/
```

**v0.4.0 (pinned — pre-c64-lib-contract, full L1-L29 CT):**

```
curl -LO https://github.com/JC-000/c64-x25519/releases/download/v0.4.0/c64-x25519-v0.4.0.tar.gz
echo "74e3d252760c15de34c35a2e3419bab4de999f2fb084182fe3b6c423047192fe  c64-x25519-v0.4.0.tar.gz" | sha256sum -c
mkdir -p vendor && tar -xzf c64-x25519-v0.4.0.tar.gz -C vendor/
```

> **Note on the legacy v0.1.0 / v0.2.0 / v0.3.0 download URLs below.** The release-page asset uploads for v0.1.0, v0.2.0, and v0.3.0 were lost in a remote-history reset and are not currently hosted (the `releases/download/v0.X.0/...` URLs return HTTP 404). The git tags themselves remain intact and the source can be reconstructed via `git archive` from the tag, but the resulting tarball will not byte-match the SHA256 values recorded below — those SHAs are kept as a record of the originally-published artifacts. For a current-recipe reproducible build of any v0.5.0+ release from its tag, see `tools/build_release.sh` (or `make dist VERSION=v0.5.0`). Note: v0.4.0's tarball used a smaller file list (no contract files); `make dist VERSION=v0.4.0` no longer reproduces its recorded SHA — the v0.4.0 entry above shows the SHA of the originally-published artifact, which remains downloadable.

**v0.3.0 (pinned — pre-Phase-7, L1-L24 closed):**

```
curl -LO https://github.com/JC-000/c64-x25519/releases/download/v0.3.0/c64-x25519-v0.3.0.tar.gz
echo "799d3998559001a102c2e5d4f782f69a7e03feaf31316b3d689176544d05c28d  c64-x25519-v0.3.0.tar.gz" | sha256sum -c
mkdir -p vendor && tar -xzf c64-x25519-v0.3.0.tar.gz -C vendor/
```

**v0.2.0 (pinned — full CT remediation, pre-perf-recovery):**

```
curl -LO https://github.com/JC-000/c64-x25519/releases/download/v0.2.0/c64-x25519-v0.2.0.tar.gz
echo "18e573e9c86e81b17f27a0c51becb782a0d0f79f67d30247e0242789c11f22e8  c64-x25519-v0.2.0.tar.gz" | sha256sum -c
mkdir -p vendor && tar -xzf c64-x25519-v0.2.0.tar.gz -C vendor/
```

**v0.1.0 (pinned — for historical or API-identical builds):**

```
curl -LO https://github.com/JC-000/c64-x25519/releases/download/v0.1.0/c64-x25519-v0.1.0.tar.gz
echo "901dd7ebb59e686ae15f7fd9d0b5df82c7cbc8f4516408e1ffaf38ba6bf4c971  c64-x25519-v0.1.0.tar.gz" | sha256sum -c
mkdir -p vendor && tar -xzf c64-x25519-v0.1.0.tar.gz -C vendor/
```

The tarball contains:

- Library source (`src/*.s`) — the 8 `.s` files you assemble with `ca65`
- Public header (`src/x25519.inc`)
- Starter linker config (`cfg/x25519-example.cfg`)
- Integration guide (`docs/LIBRARY.md`) + release notes
- `LICENSE` and `ORIGIN.txt.template` for provenance tracking

Copy `ORIGIN.txt.template` → `ORIGIN.txt` in your vendored copy, fill in the `date_imported` / `local_modifications` fields, then assemble the source with `ca65` from your own build system.

See [`docs/LIBRARY.md`](docs/LIBRARY.md) §4 and §4.1 for the full integration walkthrough.

Per the [c64-lib-contract](https://github.com/JC-000/c64-lib-contract) ABI contract, consumers can additionally `.import` the prefixed `LIB_X25519_VERSION_*` / `LIB_X25519_ABI_VERSION` equates and gate with `.assert ..., lderror` (SPEC v0.8.1 — `.if` cannot evaluate an imported symbol; the guard fires at link time, before anything runs) — a defense-in-depth assert on top of git-submodule SHA pinning. See `docs/LIBRARY.md` §4.3.

**REU bank base override.** Per [c64-lib-contract §3](https://github.com/JC-000/c64-lib-contract/blob/master/SPEC.md#3-reu-layout-contract), the six contiguous REU banks the library claims (mul tables + carry table + zero block) can be relocated at assemble time:

```sh
ca65 -D X25519_REU_BANK=3 -o build/x25519_init.o src/x25519_init.s
# ...rebuild every library .o with the same -D value, then re-archive.
```

`X25519_REU_BANK` defaults to `0` (banks 0–5). Setting it to `3` shifts the library's claim to banks 3–8, leaving banks 0–2 free for a sibling REU consumer. Every library translation unit must be assembled with the same value because the bank constant is baked in at assemble time. The library's standalone `make` / `make lib` build always uses the default; consumer projects rebuild from source with the override. See `docs/LIBRARY.md` §4.5 for the override walkthrough and §4.4 for the `LIB_X25519_REU_BANKS_USED` aggregate bitmask consumers can `.assert` against for compile-time collision detection.

**Build variants.** Three profiles build from the same source tree; the default is what `make lib` produces.

```sh
make lib                  # default — 512 KB REU (1750), fastest at stock clock
make lib-x25519-1764      # 256 KB REU (stock 1764), drops the pre-doubled tables
make lib-x25519-onchip    # no REU at all — multiplication rows generated on the 6502
```

`lib-x25519-onchip` ([#72](https://github.com/JC-000/c64-x25519/issues/72)) replaces `fe25519_mul`'s per-row REU DMA fetch with a constant-time on-chip generator built on the c64-lib-contract §8.3 `ct_mul_8x8` body. It is the first configuration that issues no REU traffic whatsoever: the boot obligation is `sqtab_init` alone, `LIB_X25519_REU_BANKS_USED` reports `0`, and it runs on a stock expansion-less C64. Consumers must assemble with `-D X25519_ONCHIP_MUL=1` so `x25519.inc`'s gated REU import surface matches the archive.

**If you are running at stock clock, keep the default build.** The onchip profile is unavoidably slower there — REU DMA hands the CPU a finished product row that the generator has to compute instead. Its purpose is accelerated hosts, where the REU transfers at the ~1 MHz bus rate no matter how fast the CPU is clocked and the row fetches become a wall-clock floor that turbo cannot lift; and hosts with no REU available at any price. Measured costs and the turbo crossover clock are pending VICE measurement, with wall-clock claims additionally gated on a hardware A/B at 16 / 48 / 64 MHz.

See `docs/LIBRARY.md` §4.11 for the integration details and manifest deltas, `docs/design/issue_72_onchip_mul.md` for the design, and `docs/CT_ANALYSIS.md` L30a-d for the constant-time audit of the generator.

Upstream maintainers can also reproduce the release tarball locally via `make lib` (which builds `build/lib/x25519.a` — canonical §6.1 basename, with `libx25519.a` alongside as the deprecated dialect — and individual `.o` files for in-tree verification) — this is not what downstream projects consume.

## Testing and audit posture

Cryptographic results are differentially tested against [pyca/cryptography](https://github.com/pyca/cryptography) — not against a repo-local reimplementation. This avoids the class of failure where the test code and the assembly under test share a bug. Random inputs with reproducible seeds, hard assertions on every comparison.

The test suite caught a latent `fe_reduce_wide` carry-propagation bug in v0.1.0 prep (fixed in `48092b5`) via differential testing on a random u-coord that exercised a specific `$FF`-boundary cascade. A permanent regression test prevents recurrence, and an audit of all similar `adc #0` sites in `src/*.s` confirmed zero other instances of the bug pattern.

## Security notes

- **Full side-channel posture (v0.4.0, Phase 7 landed).** All 29
  catalogued leak families (L1-L29 in
  [`docs/CT_ANALYSIS.md`](docs/CT_ANALYSIS.md)) are now closed.
  L1-L22 (v0.2.0): branchless CT `mul_8x8` + `fe25519_sqr`
  rewrite + zero-skip removal + Phase-6 carry-chain.
  L23a/b/c (v0.3.0 PR #31): `fe25519_sqr` `@diag_prop`
  unconditional ripple. L24a/b (v0.3.0 PR #30): branchless
  `cmp/sbc/eor` bit-to-mask in the Montgomery ladder bit loop.
  **L25 / L26a-d / L27a-f / L28a-k / L29a-e (v0.4.0 Phase 7):**
  closes the field-op surface beyond `fe25519_sqr` — `fe25519_mul`,
  `fe_reduce_wide`, `fe25519_mul_a24`, `fe25519_add`,
  `fe25519_sub`, `fe_cmp_p`, `fe25519_reduce_final` all rewritten
  with the four Phase-7 closure templates (`lda#0/sbc#0/eor#$FF`
  mask + masked sub-p tail; Phase-6 Option F per-body pending
  chain; `dey/bne` cascades gated by `mul38_lo_tab[0]=0`;
  `fe_carry`-threaded reduction stages). `fe25519_cswap` remains
  CT-clean by inspection. **v0.4.0 is the first release with the
  entire `fe25519_*` / `mul_8x8` / `x25519_scalarmult` surface
  CT-clean** for network-facing deployments where the scalar is
  a long-lived ECDH private key. Per-proc CT cycle-count guards
  in `make test-vice` (`test_ct_square_cycles.py`,
  `test_ct_mul_cycles.py`, `test_ct_mul_a24_cycles.py`,
  `test_ct_reduce_wide_cycles.py`, plus the output-bound
  regression `test_fe_reduce_wide_bound.py`) report spreads of
  0.000-0.01 jif across structurally distinct inputs.
- **State-contract defences (post-v0.3.0, on master).** Two
  correctness-class fixes that complement the L1–L24 timing-leak
  posture by hardening the library against caller state pollution
  when composed with sibling REU consumers (see
  [`docs/CT_ANALYSIS.md`](docs/CT_ANALYSIS.md) §State-contract
  defences). **S1** ([PR #35](https://github.com/JC-000/c64-x25519/pull/35)):
  `x25519_scalarmult` is wrapped in `php / sei … plp` — IRQs are
  library-masked for the full call. **S2**
  ([PR #36](https://github.com/JC-000/c64-x25519/pull/36), closes
  [#33](https://github.com/JC-000/c64-x25519/issues/33)): defensive
  zero of `reu_reu_lo` ($DF04) and `reu_addr_ctrl` ($DF0A) at
  scalarmult entry. Closes a wrong-result-not-hang vector in TLS
  composition (caller residue caused `reu_clear_wide` to fill
  `fe_wide` with garbage). Hardware-confirmed on Ultimate 64 Elite
  via `tools/test_issue33_adversarial.py`. ~6 cycles total cost,
  CT-neutral.
- **No RNG.** Key generation is the caller's job.
- **X25519 only.** No Ed25519, no X448, no hash functions, no KDF/AEAD/HKDF.

## License

MIT — see [LICENSE](LICENSE).

## Acknowledgments

Phase 1–10 optimization work throughout 2026-03 and 2026-04. Test-hardening infrastructure from the 2026-04-11 audit pass is what enabled the Phase 10 correctness fix to be caught by differential testing before release.
