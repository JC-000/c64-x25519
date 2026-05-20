# c64-x25519 v0.6.0 — RAM reclamation + bench rehab + §8.1 sqtab adoption

**Status:** DRAFT until tagged. SHA256 + byte size of the
reproducible tarball will be filled in via a follow-up PR after the
`v0.6.0` tag is pushed and `tools/build_release.sh` runs.

v0.6.0 is the **RAM-reclamation + bench-rehab release**. It bundles
four user-visible concerns that surfaced from one piece of analysis
(`docs/REU_USAGE_ANALYSIS.md`):

1. Drop dead REU bank-2 usage; reclaim 51 bytes of CODE and one REU
   bank (Group C from the analysis).
2. Ship an opt-in `make lib-x25519-1764` build variant that lowers
   the minimum REU spec from 512 KB (1750) to 256 KB (stock 1764),
   at a measured +16.2 % scalarmult cost.
3. Rehabilitate the bench infrastructure. A previously-undetected
   PR #39 regression had been silently making
   `tools/test_ct_*_cycles.py` **trivially pass on a zero
   measurement** since v0.4.0; the fix also lights up
   `tools/bench_fe_mul.py` and gives the project a real per-op
   measurement story for the first time since v0.4.0.
4. Adopt [c64-lib-contract §8.1](https://github.com/JC-000/c64-lib-contract/pull/6)
   — the canonical shared 1 KB quarter-square table — so multi-lib
   PRGs can dedupe the primitive.

**No CT or correctness changes** vs v0.5.0. **No default-configuration
behavioural change** — scalarmult cycles are bit-identical within
code-layout noise (`261,640,265` → `261,681,380` cy, +0.02 %). RFC
7748 vec-0 PASS at every measurement.

Pure-additive ABI: zero public-symbol removals, zero default-build
behaviour shifts. Existing v0.5.0 consumers can adopt v0.6.0 without
source edits.

See [`RELEASE_NOTES_v0.5.0.md`](RELEASE_NOTES_v0.5.0.md) for the
prior c64-lib-contract §1/§2/§3/§5 adoption story. Older notes:
[v0.4.0](RELEASE_NOTES_v0.4.0.md),
[v0.3.0](RELEASE_NOTES_v0.3.0.md),
[v0.2.0](RELEASE_NOTES_v0.2.0.md),
[v0.1.0](RELEASE_NOTES_v0.1.0.md).

v0.6.0 implements three PRs against master:

1. **PR [#54](https://github.com/JC-000/c64-x25519/pull/54)** —
   REU re-examination + bench rehab + Group C bank-2 drop.
2. **PR [#55](https://github.com/JC-000/c64-x25519/pull/55)** —
   `make lib-x25519-1764` build variant + `bench_start`/`_stop`
   self-contained `php/plp` fix.
3. **PR [#56](https://github.com/JC-000/c64-x25519/pull/56)** —
   c64-lib-contract §8.1 shared-sqtab primitive adoption.

---

## Group C — bank-2 zero-stash removed (PR #54)

`reu_mul_init`'s `@init_done` previously STASHed 64 zero bytes to REU
bank 2 offset 0, used by the v0.3.0 `reu_clear_wide` which DMA-fetched
that block to clear `fe_wide`. The v0.4.0 W2 refactor rewrote
`reu_clear_wide` as a CPU clear (`sta fe_wide,x` × 64) and never
read bank 2 again. The stash sat as dead code through v0.5.0.

v0.6.0 removes it:

- `src/x25519_init.s:@init_done` — 25 lines deleted (`@zbuf` zeroing
  loop + 64-byte REU STASH to bank 2). Pre-configure-for-fetch tail
  retained.
- `src/lib_version.s` — `LIB_X25519_REU_BANKS_USED` flipped from
  `$3F << X25519_REU_BANK` (banks 0,1,2,3,4,5) to
  `$3B << X25519_REU_BANK` (banks 0, 1, 3, 4, 5). Bank 2 is now
  free for sibling consumers within the library's six-bank window.
- `src/lib_version.s` — `LIB_X25519_RESIDENT_BYTES`: `9275` → `9224`
  (−51 B in `x25519_init.o`'s CODE).
- `src/reu_config.s`, `src/x25519.inc`, `docs/LIBRARY.md` — doc-only
  updates describing bank 2 as "unused (legacy stash removed in
  v0.6 prep — free for sibling consumers)".

Verified: `make lib-verify` PASS, `make test-vice` PASS,
`bench_x25519` RFC 7748 vec-0 PASS at `261,681,380` cy (within
0.016 % of the v0.5.0 `261,640,265` baseline — pure code-layout
shift inside the CODE segment after the removed bytes).

---

## `make lib-x25519-1764` — 1764 build variant (PR #55)

Reclaims the doubled-mul-table cluster (REU banks 3, 4, 5 = 192 KB)
at a measured +16.2 % scalarmult cost. **Opt-in via a new make
target**; the default build keeps `SQR_DMA_K = 22` and the full
doubled-table path for 1750 / 512KB-modded REU owners.

```sh
make lib-x25519-1764       # produces build-1764/lib/libx25519.a + .o + .inc + cfg
```

Mechanism (all gated on a single `-D SQR_DMA_K=0` define that
`CA65FLAGS` threads to every `.s -> .o` rule):

- `src/x25519_init.s` — `.if ::SQR_DMA_K` guard skips the `@dbl_gen`
  loop and three doubled-table STASH blocks in `reu_mul_init`. Bank
  3 (carry table) + banks 4-5 (doubled lo+hi tables) are never
  written at init. CODE saved in `x25519_init.o`: −178 B (798 →
  620 = `8449 → 8193` smoke-test PRG bytes).
- `src/lib_version.s` — same `.if ::SQR_DMA_K` guard emits
  `LIB_X25519_REU_BANKS_USED = $03 << X25519_REU_BANK` (banks 0, 1
  only) and `LIB_X25519_RESIDENT_BYTES = 9046` so consumer cfg
  collision checks reflect the smaller claim. The `::` global-scope
  operator is load-bearing — ca65's `.if` inside a `.proc` only
  resolves local-scope symbols and fails with "Constant expression
  expected" without it.
- `Makefile:lib-x25519-1764` — runs `make lib lib-verify` with
  `BUILD_DIR=build-1764 LIB_DIR=build-1764/lib CA65FLAGS="-D
  SQR_DMA_K=0"` so the parallel build doesn't clobber the default.
- `Makefile` (default-build-relevant) — `CA65FLAGS` threaded through
  the `.s -> .o` pattern rule.

**Measured trade** (`docs/perf_history.csv` rows `v0.6-prep+benchfix`
and `v0.6-prep+1764`):

| Metric | Default | 1764 variant | Δ |
|---|---:|---:|---|
| `x25519_scalarmult` cy | 261,681,380 | 304,179,528 | **+16.2 %** |
| `fe25519_sqr` cy/call | 102,023 | 135,381 | +32.7 % |
| `fe25519_mul` cy/call | 94,737 | 94,737 | noise (mul path unchanged) |
| `LIB_X25519_RESIDENT_BYTES` | 9,224 | 9,046 | −178 B |
| `LIB_X25519_REU_BANKS_USED` | `$3B` | `$03` | banks 3,4,5 freed |
| Min REU spec | 512 KB (1750) | 256 KB (stock 1764) | hardware floor lowered |
| RFC 7748 vec-0 | PASS | PASS | — |

The variant prediction was off by ~3× during the pre-experiment
analysis (predicted +5.6 %, measured +16.2 %); root cause traced and
documented in `docs/REU_USAGE_ANALYSIS.md` ("Predicted vs measured").
The stale `2 sqr per ladder step` comment in `tools/bench_fe_mul.py`
was hiding the real `4 sqr per step` ladder shape; the correct count
is **1,274 sqr per scalarmult**, not 763. The variant scalarmult
delta divides cleanly: `42,498,148 cy / 33,358 cy = 1,274.00`.

---

## Bench rehab + perf-tracking infra (PRs #54 + #55)

### Why this matters

PR #39 (v0.4.0 prep, commit `47c0ad2`) refactored
`src/util.s:bench_start` to replace a matching `sei/cli` pair with a
single `sei` plus a stashed P register, intending to preserve the
caller's I-flag. The refactor accidentally left every
`bench_start / bench_stop` window running with IRQs masked. The
kernal jiffy clock at `$A0-$A2` is advanced by the IRQ handler, so
under `sei` it freezes and `bench_ticks` reads back 0.

This silently broke:
- **`tools/bench_fe_mul.py`** — reported 0 jif/call for every op
  from v0.4.0 through v0.5.0.
- **`tools/test_ct_*_cycles.py`** — the CT cycle-count guards (one
  per `fe25519_*` proc), which use the same jiffy bench path.
  They report `max - min` jif/call across structurally distinct
  inputs and PASS if `spread <= 1.0 jif`. With every measurement
  returning 0, every spread was `0.0 - 0.0 = 0` and **trivially
  passed**. The guards looked green in CI but were not actually
  verifying CT.

Both bugs went undetected because no other CT measurement noticed —
the underlying CT invariants of the v0.4.0 Phase-7 closure were
correct, so external symptoms (wrong scalarmult output, observable
timing leaks) didn't materialise. The fix in v0.6.0 restores
measurability without changing the underlying CT property.

### The fix (PR #55)

`src/util.s` `bench_start` / `bench_stop` rewritten to a balanced
`php / sei / work / plp / rts` shape. Each routine is now
self-contained:

- Saves caller's P on entry.
- Masks IRQs only for its own 3-byte critical section.
- Restores caller's P on exit (which restores their I-flag intact).
- The body of any `bench_start / bench_stop` window now runs with
  **whatever I-flag the caller had set up before the call** — exactly
  what callers of jiffy-based bench helpers need.

The static `bench_saved_p` slot is dropped (dead).

### CIA1 cycle counter in `bench_fe_ops.py`

PR #54 separately switched `tools/bench_fe_ops.py` to use the CIA1
32-bit cycle counter (`bench_cycles_start` / `bench_cycles_stop` in
`src/util.s`, which already existed for the scalarmult bench). This
is **cycle-exact and sei-safe** — works even for callers that wrap
their body in `sei` (which `x25519_scalarmult` itself does as a CT
defence). The bench now reports both raw cycles and derived jif/call.

The older jiffy helpers are kept (after the PR #55 fix) for
downstream callers that prefer the simpler `bench_start /
bench_stop` API and don't wrap in `sei`.

### Verification

Post-fix CT cycle-count guards on the default build (excerpt from
`make test-vice`):

```
--- fe25519_sqr CT cycle-count guard (batch=200) ---
  dense_55           6.47500
  sparse_09          6.47000
  mixed_mid          6.47500
  mixed_hi           6.47000
  diag_zeros         6.47500
  spread             0.00500  (threshold = 1.0)
PASS: per-call jif spread within threshold.
```

Real numbers across the inputs, real spread (0.005 jif), well under
the 1.0 jif threshold. **The CT property still holds; it's now
actually being verified.**

### Perf-tracking infrastructure (PR #54)

To prevent silent regressions like the PR #39 one from recurring,
v0.6.0 ships an append-only release-perf log driven by `make
bench-record`:

- `tools/bench_record.py` — runs `make`, parses `LIB_X25519_*`
  manifest equates from `build/labels.txt`, runs both bench scripts
  with `--json`, appends one row to `docs/perf_history.csv` tagged
  with `git_sha` (`-dirty` suffix if uncommitted).
- `tools/perf_diff.py` — markdown diff between any two CSV rows.
  Default: last two.
- `Makefile` — `make bench-record` and `make perf-diff` targets.
- `docs/perf_history.csv` — 6 measured rows so far (v0.5.0
  baseline → v0.5.0+exp variant → v0.6-prep+groupC → v0.6-prep+benchfix
  → v0.6-prep+1764 → v0.6-prep+section8).

Expected workflow: run `make bench-record` at every release boundary;
release notes' Trade-off table is one `make perf-diff` away.

---

## c64-lib-contract §8.1 — shared sqtab primitive (PR #56)

Five sibling crypto libs ship the same 1 KB 8x8 quarter-square
multiply table (`sqtab_lo` / `sqtab_hi`) at four different addresses.
A multi-lib PRG that vendors c64-x25519 + c64-ChaCha20-Poly1305
links two copies of the same table. c64-nist-curves had its table
silently corrupted at boot on 2026-05-17 when code growth pushed
neighbouring data into the table's address range.

[c64-lib-contract SPEC §8.1](https://github.com/JC-000/c64-lib-contract/pull/6)
(merged v0.2.0) defines a canonical shared form: a single
page-aligned equate (`LIB_SHARED_SQTAB_BASE`) with hard assemble-time
`.assert`s on page-alignment + lo→hi `+$0200` delta, a canonical
init proc name (`mul_tables_init`), and a migration gate
(`SHARED_SQTAB_INIT`) so libs adopt one at a time.

### What v0.6.0 ships

- **`src/constants.s`** — new `.ifndef`-guarded equates:
  ```ca65
  .ifndef LIB_SHARED_SQTAB_BASE
    LIB_SHARED_SQTAB_BASE = $7800
  .endif
  sqtab_lo = LIB_SHARED_SQTAB_BASE
  sqtab_hi = LIB_SHARED_SQTAB_BASE + $0200
  .assert (sqtab_lo & $00ff) = 0, error, "must be page-aligned"
  .assert sqtab_hi = sqtab_lo + $0200, error, "SMC dispatch contract"
  ```

  Every translation unit that `.include`s `constants.s` sees these
  equates. No `.export` / `.import` across TUs — a multi-lib link
  would otherwise collide on duplicate `sqtab_lo` exports.

- **`src/mul_8x8.s`** — new exports:
  ```ca65
  mul_tables_init = sqtab_init     ; canonical contract alias
  ```
  Both names resolve to the same address. New `.ifdef
  SHARED_SQTAB_INIT` gate around the table-build body: when defined,
  the proc collapses to a single `rts`. `mul_8x8.o` CODE shrinks
  **251 → 102 B (−149 B / −59 %)** in shared-init builds; the public
  symbols still resolve so existing callers don't break.

- **`src/lib_version.s`** — new manifest equates per SPEC §5 + §8.1:
  ```ca65
  LIB_SHARED_PRIMITIVES_SQTAB  = $0001     ; SPEC §8.1 bit
  LIB_X25519_SHARED_PRIMITIVES = LIB_SHARED_PRIMITIVES_SQTAB
  ```
  Append-only bitmask; future §8.x primitives claim the next free
  bit, deprecated primitives keep theirs reserved.

- **`cfg/x25519.cfg` + `cfg/x25519-example.cfg`** — legacy
  `SYMBOLS { sqtab_lo / sqtab_hi }` linker exports dropped (moved to
  source). SQTAB MEMORY reservation retained as default-address
  placement for the standalone PRG build.

- **`tests/lib_linkage/lib_linkage_stub.s`** + `Makefile lib-verify`
  — new public symbols added to the smoke-link's reference table
  and the expected-symbols grep.

### How a consumer asserts collision-free composition

```ca65
.import LIB_X25519_SHARED_PRIMITIVES
.import LIB_OTHER_SHARED_PRIMITIVES
.assert (LIB_X25519_SHARED_PRIMITIVES .and \
         LIB_OTHER_SHARED_PRIMITIVES) = 0, error, \
        "both libs claim a §8 primitive; one must build with \
         SHARED_SQTAB_INIT defined"
```

### How a consumer migrates to a single shared table

Pass `-D SHARED_SQTAB_INIT=1` to **every** c64-x25519 translation
unit at rebuild time. c64-x25519's `sqtab_init` / `mul_tables_init`
body becomes a no-op stub. The host program is then responsible for
calling some other library's canonical `mul_tables_init` (e.g.,
c64-https's, once that PR lands — see
[the SPEC PR body](https://github.com/JC-000/c64-lib-contract/pull/6)
for the c64-https stub-fix coordination).

c64-x25519's adoption is independent of any other lib's adoption.
Standalone builds (no `-D SHARED_SQTAB_INIT`) build the table
themselves, exactly as before.

---

## Deprecation notice for v1.0 (PR #54)

`src/x25519.inc` flags three public symbols as scheduled for removal
in v1.0:

| Symbol | What | Migration |
|---|---|---|
| `mul_by_38` | ~90 B CODE shift-and-add proc | use `mul38_lo_tab` / `mul38_hi_tab` direct lookup (already used internally) |
| `reu_fetch_mul_row` | ~25 B CODE REU DMA helper | inlined into `fe25519_mul`; no external migration needed if you call `fe25519_mul` |
| `x25_basepoint` | 32 B DATA constant `{9, 0×31}` buffer | call `x25519_base`, or initialise `x25_u` with the basepoint constant in your own code |

Bodies stay in place for v0.x ABI compatibility; v1.0 will drop
both the `.export` and the underlying bytes. Pin to v0.x if any of
these are load-bearing for your build.

---

## Manifest equates at v0.6.0

For default and 1764 variant builds:

| Symbol | Default | 1764 variant |
|---|---|---|
| `LIB_VERSION_MAJOR` | `0` | `0` |
| `LIB_VERSION_MINOR` | `6` | `6` |
| `LIB_VERSION_PATCH` | `0` | `0` |
| `LIB_ABI_VERSION`   | `1` | `1` |
| `LIB_X25519_ZP_USAGE_BYTES` | `85` | `85` |
| `LIB_X25519_REU_BANKS_USED` | `$3B << X25519_REU_BANK` | `$03 << X25519_REU_BANK` |
| `LIB_X25519_RESIDENT_BYTES` | `9224` | `9046` |
| `LIB_X25519_COLD_BYTES` | `0` | `0` |
| `LIB_X25519_SHARED_PRIMITIVES` | `$0001` (sqtab) | `$0001` (sqtab) |
| `LIB_SHARED_PRIMITIVES_SQTAB` | `$0001` | `$0001` |

---

## Performance summary

Measured via the CIA1 32-bit cycle counter (`bench_cycles_*`).
RFC 7748 basepoint-9 vec-0 PASS in all configurations.

### Default build

| Op | Cycles | Jif |
|---|---:|---:|
| `x25519_scalarmult` | 261,681,380 | 15,352.0 |
| `fe25519_mul` (batch=200) | 94,737 | 5.558 |
| `fe25519_sqr` (batch=200) | 102,023 | 5.985 |
| `fe25519_mul_a24` (batch=200) | 7,569 | 0.444 |
| `fe25519_inv` (single avg) | ≈28,766,000 | 1,687.6 |

### 1764 variant

| Op | Cycles | Jif | Δ vs default |
|---|---:|---:|---:|
| `x25519_scalarmult` | 304,179,528 | 17,845.2 | +16.2 % |
| `fe25519_sqr` (batch=200) | 135,381 | 7.939 | +32.7 % |
| `fe25519_mul` (batch=200) | 94,737 | 5.558 | 0 |

Full history: [`docs/perf_history.csv`](perf_history.csv) — six rows
covering v0.5.0 → v0.6-prep+section8.

---

## Verification

- `make clean && make` — clean default build
- `make lib-verify` — 8449 B, all expected symbols present
  (including `LIB_X25519_SHARED_PRIMITIVES`,
  `LIB_SHARED_PRIMITIVES_SQTAB`, `mul_tables_init`)
- `make lib-x25519-1764` — 8193 B parallel archive, manifest equates
  match the variant column above
- `make test-vice` — 256 + 64 + 128 + 49 fe tests + 4 CT cycle
  guards (now actually measuring; spreads ≤ 0.005 jif) + 50 + 3
  reduce_wide regressions — ALL PASS
- `make test-slow` — full RFC 7748 vector cross-check + 255-bit
  ladder checkpoint replay — recommended before merge (not run
  locally during PR construction; CI / hardware runs welcome)
- `bench_x25519` default — `261,681,380` cy / RFC 7748 vec-0 PASS
- `bench_x25519` 1764 variant — `304,179,528` cy / RFC 7748 PASS
- `CA65FLAGS="-D SHARED_SQTAB_INIT=1" make all` — `mul_8x8.o` CODE
  drops to 102 B as expected; multi-lib smoke path

---

## Compatibility

v0.6.0 is **backward-compatible with v0.5.0** at every default
configuration. No public symbol removed. `LIB_VERSION_MAJOR`
unchanged at `0`. `LIB_ABI_VERSION` unchanged at `1`.

The four new public symbols (`mul_tables_init`,
`LIB_X25519_SHARED_PRIMITIVES`, `LIB_SHARED_PRIMITIVES_SQTAB`, plus
the `lib-x25519-1764` Makefile target) are pure additions. Pre-v0.6
consumers see no change.

The three deprecation flags in `x25519.inc` are **doc-only**; the
underlying symbols still resolve.

---

## Tarball

(Will be filled in by the follow-up PR after `make dist
VERSION=v0.6.0` runs against the tagged commit. Mirrors PR #53's
v0.5.0 fill pattern.)

```
File:     c64-x25519-v0.6.0.tar.gz
Size:     <bytes>
SHA256:   <SHA256>
```

Reproducible: same VERSION + same tag SHA → byte-identical tarball
(`git archive` is content-deterministic; `gzip -n` drops the
timestamp). Verify locally with:

```sh
git checkout v0.6.0
tools/build_release.sh v0.6.0     # or: make dist VERSION=v0.6.0
shasum -a 256 c64-x25519-v0.6.0.tar.gz
```

Must match the SHA256 above.
