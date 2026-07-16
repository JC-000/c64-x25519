# c64-x25519 v0.7.0 — RFC 7748 decode fix + c64-lib-contract §8 completion

**Status:** Released 2026-07-16. Tag [`v0.7.0`](https://github.com/JC-000/c64-x25519/releases/tag/v0.7.0)
live on master at commit `43a633c`. Reproducible tarball attached to
the GitHub Release page; SHA256 + byte size recorded under
[Tarball](#tarball) below.

v0.7.0 carries **one correctness fix** and completes the
[c64-lib-contract](https://github.com/JC-000/c64-lib-contract) §8
shared-primitives adoption.

**The fix ([#64](https://github.com/JC-000/c64-x25519/issues/64)):**
`x25519_scalarmult` produced deterministically wrong results for any
peer u-coordinate with bit 255 set, from v0.4.0 through v0.6.0. RFC
7748 decodeUCoordinate requires masking that bit; the v0.4.0 W4 H1
change correctly stopped mutating the caller's `x25_u` buffer but
left the ladder's `z_3 = x_1 * (DA-CB)^2` step reading the unmasked
buffer — so x₁ and the masked x₃ disagreed by 19 (mod p). Caught by
RFC 7748 §5.2 vector 2 in `make test-slow` during release
verification; see `docs/CT_ANALYSIS.md` §S4 for the full account.
Conforming peers (canonical public keys < p) were never affected; no
secret leakage; no CT impact.

On the contract side, every §8.x clause of SPEC v0.4.0 that names
c64-x25519 as an adopter is now shipped, and the cross-adopter
byte-identity gate for the constant-time multiply body is green
across the whole library family:

1. **§8.2 `reu_mul`** — the 128 KB 8×8→16 REU multiplication table
   promoted to a shared primitive (with the §8.0 step-6 catch-loop
   precalc-table enumeration).
2. **Issue-15 SMC-patch refactor** — `reu_fetch_doubled_row`'s 512 B
   fetch delegates to the canonical §8.2 `reu_fetch_mul_row` via an
   SMC bank patch.
3. **§8.3 `ct_mul_8x8`** — the multiply body is now **byte-identical**
   to the canonical c64-ChaCha20-Poly1305 body (59 B, SHA-256
   `3ed9025b…`); the cross-adopter
   `ct_mul_brute_check.py` ratchet reports exit 0 across
   chacha == nist-curves == x25519.
4. **§8.0 conditional shared-primitives mask** — `LIB_X25519_SHARED_PRIMITIVES`
   reflects only what a given build configuration *owns*, making the
   consumer double-ownership `.assert` satisfiable for legitimately
   shared primitives.

**No CT posture change:** the L1–L29 leak catalogue stays closed
(`docs/CT_ANALYSIS.md`); the §8.3 body adoption re-verified L1/L2
under the canonical sum-first ordering, the #64 fix adds no
secret-dependent behaviour (state-contract entry S4), and the CT
cycle guards measure a 0.005 jif spread. **Default-build runtime
cost:** scalarmult ≈ +0.7 % vs v0.6.0 (from the issue-15 refactor +
code layout + one extra `fe25519_copy` at ladder init for #64 — see
Performance below), inside the 2 % gate set for the refactor.

Pure-additive ABI: zero public-symbol removals. Existing v0.6.0
consumers can adopt v0.7.0 without source edits — and should, for
the #64 fix.

See [`RELEASE_NOTES_v0.6.0.md`](RELEASE_NOTES_v0.6.0.md) for the
RAM-reclaim + bench-rehab + §8.1 story. Older notes:
[v0.5.0](RELEASE_NOTES_v0.5.0.md), [v0.4.0](RELEASE_NOTES_v0.4.0.md),
[v0.3.0](RELEASE_NOTES_v0.3.0.md), [v0.2.0](RELEASE_NOTES_v0.2.0.md),
[v0.1.0](RELEASE_NOTES_v0.1.0.md).

v0.7.0 implements five content PRs against master:

0. **The #64 fix PR** — RFC 7748 decodeUCoordinate x₁ desync
   (details in its own section below).

1. **PR [#59](https://github.com/JC-000/c64-x25519/pull/59)** —
   c64-lib-contract §8.2 `reu_mul` + §8.0 step-6 catch-loop adoption.
2. **PR [#61](https://github.com/JC-000/c64-x25519/pull/61)**
   (content reviewed as [#60](https://github.com/JC-000/c64-x25519/pull/60),
   re-targeted after a stale-base merge race) — issue-15 SMC-patch
   refactor of `reu_fetch_doubled_row`.
3. **PR [#62](https://github.com/JC-000/c64-x25519/pull/62)** —
   §8.3 canonical `ct_mul_8x8` body adoption.
4. **PR [#63](https://github.com/JC-000/c64-x25519/pull/63)** —
   §8.0 conditional shared-primitives mask + §8.3 bit `$0004`.

---

## RFC 7748 decodeUCoordinate fix (#64)

**Symptom.** `make test-slow` fails RFC 7748 §5.2 vector 2 — the only
vector in the suite whose u-coordinate has bit 255 set: expected
`95cbde94…`, got `1fb49abd…` (pyca confirms `95cbde94…`).

**Root cause.** The v0.4.0 W4 H1 fix (PR #38) stopped writing the
RFC-mandated bit-255 mask back into the caller's `x25_u` buffer and
applied it only to the `x25_x3` working copy — correct for the
no-mutation guarantee, but the ladder step
`z_3 = x_1 * (DA-CB)^2` (`src/x25519.s`) kept reading `x25_u`
directly as x₁. `2^255 ≡ 19 (mod p)`, so a bit-255-set input made
x₁ = decoded-u + 19 while x₃ = decoded-u — an inconsistent ladder and
a deterministically wrong result. A Python model with exactly that
asymmetry reproduces the C64's wrong output byte-for-byte.

**Fix.** New library-owned 32-byte-aligned buffer `x25_x1`
(`src/data.s`); ladder init snapshots the masked `x25_x3` into it
(one extra `fe25519_copy` per scalarmult), and the z₃ site reads
`x25_x1`. `x25_u` remains unmutated — W4 H1's guarantee is preserved.

**Impact window.** v0.4.0 → v0.6.0. Only non-canonical peer inputs
(u ≥ 2^255) trigger it; conforming X25519 public keys are < p.
Deterministic wrong output on public inputs — no secret leakage, no
timing change. Undetected for three releases because `make test-slow`
(the only suite running the MSB vector) was not exercised at the
v0.5.0/v0.6.0 release boundaries — v0.7.0's checklist makes it a
mandatory release gate.

Full account: `docs/CT_ANALYSIS.md` §S4 (state-contract defences).

---

## c64-lib-contract §8.2 — shared `reu_mul` table + §8.0 catch-loop (PR #59)

c64-x25519 and c64-nist-curves both build the same 128 KB 8×8→16
multiplication table in a REU bank pair at boot. SPEC §8.2 names one
canonical shape so a multi-lib consumer links (and boots) one copy.

What shipped:

- **Placement equates** in `src/reu_config.s`, `.ifndef`-guarded for
  consumer override: `LIB_SHARED_REU_MUL_BANK` / `_OFFSET`
  (pinned `$0000` in v0.x) / `_BANKS_USED`. Derived symbolic bank
  names `X25519_REU_BANK_DOUBLED` / `X25519_REU_BANK_CARRY` replace
  literal `4+` / `3+` offsets.
- **Canonical entry** `reu_mul_tables_init` (alias of `reu_mul_init`)
  and **migration gate** `SHARED_REU_MUL_INIT` — a consumer that
  defers table build to a sibling library defines the gate and this
  library's init body assembles out.
- **SMC patch-label export** `reu_fetch_mul_row_bank_patch` — the
  byte address of `reu_fetch_mul_row`'s bank-`lda` immediate,
  published for callers that re-target the fetch to another bank
  (used by the issue-15 refactor below).
- **§8.0 step-6 catch-loop**: `docs/precalc-tables.md` (per-table
  rationale) + three `LIB_PRECALC_TABLE` macro invocations in
  `src/lib_version.s` — `sqtab` (1024 B, RAM, shared), `reu_mul`
  (131072 B, REU, shared), `reu_mul_doubled` (196608 B = 3 REU banks,
  private, gated on `SQR_DMA_K`). Build-time discovery via
  `od65 --dump-exports build/lib_version.o | grep LIB_PRECALC`.
- Manifest bit `$0002` (`LIB_SHARED_PRIMITIVES_REU_MUL`).

See `docs/LIBRARY.md` §4.8 + §4.9.

---

## Issue-15 SMC-patch refactor of `reu_fetch_doubled_row` (PR #61)

`reu_fetch_doubled_row` (the 512 B pre-doubled-row fetch inside
`fe25519_sqr`'s DMA path) was structurally identical to the canonical
`reu_fetch_mul_row` with a different bank base. It now SMC-patches the
canonical primitive's bank byte (via `reu_fetch_mul_row_bank_patch`)
and delegates DMA #1 to it; the 256 B carry fetch (DMA #2) stays
inline. Tracked as
[c64-lib-contract#15](https://github.com/JC-000/c64-lib-contract/issues/15);
design doc: `docs/design/issue_15_smc_patch_doubled_fetch.md`.

Two things worth knowing:

- **Autoload-latch invariant.** The canonical fetch is
  3-register-touch and trusts the REU autoload latch between calls.
  Inside `fe25519_sqr`'s 22-iteration outer loop the latch is dirty
  on iterations 2..N (DMA #2 stomps it), so DMA #1 re-establishes the
  canonical 5-register state before the patched JSR. Those writes are
  **load-bearing, not redundant** — documented at three sites in
  `src/x25519_init.s` and guarded by the W2-class regression
  `tools/test_fe_sqr_then_mul.py` (60/60).
- **Measured cost:** `fe25519_sqr` +0.523 % at the time of the PR
  (≤ 2 % gate); the v0.7.0 release-boundary measurement lands at
  +1.5 % on `fe25519_sqr` including subsequent code-layout shift —
  still inside the gate. K=0 builds gate the whole refactor out
  (`.if ::SQR_DMA_K`), shrinking the 1764-variant archive.

---

## c64-lib-contract §8.3 — canonical `ct_mul_8x8` body (PR #62)

The branchless quarter-square multiply body existed in three divergent
per-library ports (different calling conventions, block orderings,
scratch placement), so a CT-relevant edit to one copy could silently
leave the others on a timing-variable shape. SPEC §8.3 (v0.4.0) pins
**one canonical body** — c64-ChaCha20-Poly1305's SMC-baked, sum-first
`ct_mul_8x8` — and enforces it mechanically: the cross-adopter
`ct_mul_brute_check.py` ratchet requires opcode-byte equality plus a
65 536-case functional brute-check, exit 0, before any body change
lands.

What shipped in x25519:

- `src/mul_8x8.s` rewritten to the canonical 59 B body
  (SHA-256 `3ed9025b…`, byte-identical to chacha and nist-curves;
  65536/65536 functional on real 6502). Sum-first ordering; the
  multiplier `a` is SMC-baked into two `adc #imm` sites
  (`smc_sum_a_imm` / `smc_diff_a_imm`) by the caller; `b` passes in
  `Y`. The legacy `mul_a/mul_b/mul_mask/mul_diff/mul_sum_pg` scratch
  is replaced by `ct_diff_raw` / `ct_sign_mask` (−28 B in
  `mul_8x8.o`: 251 → 223 B).
- **`mul_8x8` is retained as a back-compat alias label** at the same
  address; `ct_mul_8x8` is the canonical name. `reu_mul_init` (the
  sole caller) SMC-bakes `a` per outer-loop iteration.
- **Migration gate** `SHARED_CT_MUL_8X8` mirrors the §8.1/§8.2
  pattern: defined ⇒ this library's body assembles out and the
  designated owner's canonical body takes over at link time.
- **CT posture:** in x25519 the multiply body is **boot-only** (its
  sole caller is `reu_mul_init`'s public table enumeration), so it has
  no network-observable timing exposure; it retains full CT discipline
  as the canonical shared shape. L1/L2 closure re-verified under
  sum-first ordering — both fixes are location-agnostic
  (`docs/CT_ANALYSIS.md` Phase-1 note).

Resolved [c64-lib-contract#14](https://github.com/JC-000/c64-lib-contract/issues/14);
the §8.3 clause landed in SPEC v0.4.0 with the gate green across all
three adopters.

---

## §8.0 conditional shared-primitives mask + bit `$0004` (PR #63)

The v0.6/v0.7-prep mask OR'd its bits unconditionally, which made the
consumer disjointness `.assert` **unsatisfiable** for legitimately
shared primitives — two libs composed correctly with a
`SHARED_*_INIT` cutover still both claimed the bit
([c64-lib-contract#21](https://github.com/JC-000/c64-lib-contract/issues/21)).
SPEC v0.4.0 §8.0 fixes the contract; v0.7.0 adopts it:

- `LIB_X25519_SHARED_PRIMITIVES` is built from `_OWN_*`
  `.ifdef/.else` scratch equates — **a bit is set iff this build does
  NOT define that primitive's deferral switch**:

  | Bit | Constant | Dropped by |
  |---|---|---|
  | `$0001` | `LIB_SHARED_PRIMITIVES_SQTAB` | `SHARED_SQTAB_INIT` |
  | `$0002` | `LIB_SHARED_PRIMITIVES_REU_MUL` | `SHARED_REU_MUL_INIT` |
  | `$0004` | `LIB_SHARED_PRIMITIVES_CT_MUL_8X8` | `SHARED_CT_MUL_8X8` |

- Standalone build (no switches): `$0007`. Verified matrix via
  `od65 --dump-exports`: none=`$0007`, sqtab-deferred=`$0006`,
  reu_mul-deferred=`$0005`, ct_mul-deferred=`$0003`, all=`$0000`.
- New exported constant `LIB_SHARED_PRIMITIVES_CT_MUL_8X8 = $0004`
  (§8.3 allocation).

---

## Public-header sync + footprint refresh (release PR)

- **`src/x25519.inc`** now imports the full contract-level public
  surface that `make lib-verify` already asserted: canonical entries
  `reu_mul_tables_init`, `ct_mul_8x8` (+ `mul_8x8` alias), the §8.2
  SMC patch hook `reu_fetch_mul_row_bank_patch`, the
  `LIB_SHARED_REU_MUL_*` placement equates,
  `X25519_REU_BANK_DOUBLED` / `_CARRY`, and the four §5 aggregate
  manifest equates. These had been exported and smoke-verified since
  the PRs above but missing from the canonical header's `.import`
  block.
- **`LIB_X25519_RESIDENT_BYTES` re-measured** (od65 segment totals,
  2026-07-16): default `9224 → 9209` (−15 B: `mul_8x8.o` −28 from the
  §8.3 body, `fe25519.o` −6, `x25519.o` +19 from the #64 fix), 1764
  variant `9046 → 8895` (−151 B: additionally `x25519_init.o` −82 and
  `fe25519.o` −60 from the #61 `.if ::SQR_DMA_K` gating). The #64
  `x25_x1` buffer consumed existing align padding — DATA unchanged at
  3584 B.

---

## Manifest equates at v0.7.0

For default and 1764 variant builds (standalone, no deferral
switches):

| Symbol | Default | 1764 variant |
|---|---|---|
| `LIB_VERSION_MAJOR` | `0` | `0` |
| `LIB_VERSION_MINOR` | `7` | `7` |
| `LIB_VERSION_PATCH` | `0` | `0` |
| `LIB_ABI_VERSION`   | `1` | `1` |
| `LIB_X25519_ZP_USAGE_BYTES` | `85` | `85` |
| `LIB_X25519_REU_BANKS_USED` | `$3B << X25519_REU_BANK` | `$03 << X25519_REU_BANK` |
| `LIB_X25519_RESIDENT_BYTES` | `9209` | `8895` |
| `LIB_X25519_COLD_BYTES` | `0` | `0` |
| `LIB_X25519_SHARED_PRIMITIVES` | `$0007` | `$0007` |
| `LIB_SHARED_PRIMITIVES_SQTAB` | `$0001` | `$0001` |
| `LIB_SHARED_PRIMITIVES_REU_MUL` | `$0002` | `$0002` |
| `LIB_SHARED_PRIMITIVES_CT_MUL_8X8` | `$0004` | `$0004` |

`LIB_X25519_SHARED_PRIMITIVES` is conditional per §8.0 — the values
above are the standalone (all-owned) case; each deferral switch drops
its bit.

---

## Performance summary

Measured via the CIA1 32-bit cycle counter (`bench_cycles_*`) at the
release boundary (2026-07-16, `docs/perf_history.csv`). RFC 7748
basepoint-9 vec-0 PASS in all configurations.

### Default build

| Op | Cycles | Jif | vs v0.6.0 |
|---|---:|---:|---:|
| `x25519_scalarmult` | 263,581,957 | 15,463.5 | +0.73 % |
| `fe25519_mul` (batch=200) | 94,733 | 5.558 | 0 |
| `fe25519_sqr` (batch=200) | 103,512 | 6.073 | +1.46 % |
| `fe25519_mul_a24` (batch=200) | 7,595 | 0.446 | +0.34 % |
| `fe25519_add` (batch=200) | 2,192 | 0.129 | 0 |
| `fe25519_sub` (batch=200) | 1,664 | 0.098 | 0 |
| `fe25519_reduce_final` (batch=200) | 2,996 | 0.176 | 0 |
| `fe25519_cswap` (batch=200) | 1,515 | 0.089 | −0.5 % (layout) |
| `fe25519_inv` (single avg) | 29,170,252 | 1,711.3 | +1.4 % |

The +0.73 % scalarmult delta decomposes cleanly: the `fe25519_sqr`
increase (1,274 sqr per scalarmult × ≈1,489 cy ≈ 1.9 M cy) from the
issue-15 SMC-patch delegation (+0.523 % measured at PR time) plus
subsequent code-layout shift, and **+768 cy total** for the #64 fix's
one extra `fe25519_copy` at ladder init (measured pre-fix
263,581,189 → post-fix 263,581,957 on otherwise-identical trees).
Inside the ≤ 2 % gate accepted for the refactor; `fe25519_mul` is
bit-identical.

### 1764 variant

| Op | Cycles | Jif | Δ vs default |
|---|---:|---:|---:|
| `x25519_scalarmult` | 303,821,006 | 17,824.2 | +15.3 % |
| `fe25519_sqr` (batch=200) | 135,071 | 7.924 | +30.5 % |
| `fe25519_mul` (batch=200) | 94,733 | 5.558 | 0 (mul path unchanged) |
| `fe25519_inv` (single avg) | 37,726,777 | 2,213.3 | +29.3 % |

vs v0.6.0's 1764 numbers: scalarmult 304,179,528 → 303,821,006
(−0.12 %, layout noise) — as expected, the K=0 build gates the
issue-15 refactor out entirely. The variant premium narrows from
+16.2 % to +15.3 % because the *default* build absorbed the issue-15
cost, not because the variant got faster.

Full history: [`docs/perf_history.csv`](perf_history.csv) — the two
v0.7.0 release-boundary rows were recorded via `make bench-record` on
the release tree.

---

## Verification

- `make clean && make` — clean default build
- `make lib-verify` — all expected public symbols present (now
  including `LIB_SHARED_PRIMITIVES_CT_MUL_8X8`)
- `make lib-x25519-1764` — parallel archive + its own verify pass
- `make test` — pyca/cryptography reference vectors PASS
- `make test-vice` — full subset incl. CT cycle guards (0.005 jif
  spread) + `test_fe_sqr_then_mul.py` W2/autoload-latch guard (60/60)
  + `reduce_wide_carry` regressions (50/50 + 3/3) — ALL PASS
- `make test-slow` — full differential suite vs pyca — ALL PASS,
  **including RFC 7748 §5.2 vector 2 (the #64 MSB regression
  vector)**. `make test-slow` is now a mandatory release gate: the
  pre-fix run at this boundary is what caught #64 (25/26, vector 2
  FAIL), after two releases where the suite wasn't exercised.
- Local `tools/ct_mul_brute_check.py` — 0/65536 mismatches on real
  6502 (PR #62); cross-adopter contract gate exit 0 (chacha ==
  nist-curves == x25519, 59 B, SHA `3ed9025b…`)
- Conditional-mask matrix via `od65 --dump-exports` (PR #63):
  `$0007 / $0006 / $0005 / $0003 / $0000`
- `CA65FLAGS="-D SHARED_CT_MUL_8X8=1" make lib` — §8.3-deferring
  archive assembles clean

---

## Compatibility

v0.7.0 is **backward-compatible with v0.6.0** at every default
configuration. No public symbol removed. `LIB_VERSION_MAJOR`
unchanged at `0`. `LIB_ABI_VERSION` unchanged at `1`.

**Behavioural change (the #64 fix):** `x25519_scalarmult` now returns
the RFC-7748-correct result for u-coordinates with bit 255 set, where
v0.4.0–v0.6.0 returned a deterministically wrong value. Any consumer
that (incorrectly) depended on the old output for non-canonical
inputs will see different results; conforming peers are unaffected.
`x25_u` remains unmutated across the call (the W4 H1 guarantee).

New public symbols — all pure additions: `reu_mul_tables_init`,
`ct_mul_8x8`, `reu_fetch_mul_row_bank_patch`,
`LIB_SHARED_REU_MUL_BANK` / `_OFFSET` / `_BANKS_USED`,
`X25519_REU_BANK_DOUBLED` / `_CARRY`,
`LIB_SHARED_PRIMITIVES_REU_MUL`, `LIB_SHARED_PRIMITIVES_CT_MUL_8X8`,
the `LIB_PRECALC_*` equate families, and three new build-time
deferral switches (`SHARED_REU_MUL_INIT`, `SHARED_CT_MUL_8X8`, joining
`SHARED_SQTAB_INIT`).

One **observable value change** for consumers that read the manifest:
`LIB_X25519_SHARED_PRIMITIVES` in a standalone build is now `$0007`
(was `$0003`) — bit `$0002` was already claimed in v0.7-prep by PR
#59, and bit `$0004` is new in this release. Consumers using the §8.0
disjointness `.assert` get strictly better behaviour (the assert is
now satisfiable under legitimate sharing). `LIB_X25519_RESIDENT_BYTES`
shrinks to `9209` / `8895` (default / 1764).

The v1.0 deprecation flags from v0.6.0 (`mul_by_38`,
`reu_fetch_mul_row`, `x25_basepoint`) are unchanged — still doc-only,
symbols still resolve.

---

## Tarball

```
File:     c64-x25519-v0.7.0.tar.gz
Size:     103,812 bytes
SHA256:   807be6916debddd162f3c84d83e9bc7a7d5b1ec5c992b9f7bfdd0c55f0a1ac8a
```

Reproducible: same VERSION + same tag SHA → byte-identical tarball
(`git archive` is content-deterministic; `gzip -n` drops the
timestamp). Verified with two consecutive `make dist VERSION=v0.7.0`
runs producing the same SHA. Verify locally with:

```sh
git checkout v0.7.0
tools/build_release.sh v0.7.0     # or: make dist VERSION=v0.7.0
shasum -a 256 c64-x25519-v0.7.0.tar.gz
# expect: 807be6916debddd162f3c84d83e9bc7a7d5b1ec5c992b9f7bfdd0c55f0a1ac8a
```
