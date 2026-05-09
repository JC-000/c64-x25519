# Task Completion Checklist

After making any change in this repo, run the appropriate subset:

## 1. Always (no toolchain required)
```
make test-ref     # or: python3 tools/ref_x25519.py
```
Fails fast if the Python reference is broken. Cheapest sanity check.

## 2. If you touched `src/*.s` or `cfg/*.cfg`
```
make clean
make              # must build build/x25519.prg without errors
```
If `make lib` is relevant to the change, also:
```
make lib
make lib-verify   # smoke-links libx25519.a via tests/lib_linkage stub
```

## 3. If you touched field arithmetic, multiply, or ladder code
Full differential suite against pyca/cryptography via VICE:
```
make test-slow
```
This runs: `ref_x25519`, `test_fe25519`, `test_fe_mul_stress`,
`test_fe_sqr_stress`, `test_fe_reduce_wide_carry`, `test_opt_sqr`,
`test_opt_karatsuba`, `test_opt_fast_mul`, `test_opt_vic_reduce38`,
`test_mul38_tables`, `test_x25519 --slow`, and
`test_ladder_checkpoint --start 0 --count 255`. Requires a working
VICE install.

For a faster subset while iterating, use:
```
make test-vice
```

## 4. If you touched anything CT-relevant
- Update `docs/CT_ANALYSIS.md` — extend the leak catalogue (L1..Ln) if
  you added / removed / changed a leak site.
- Re-run `tools/ct_mul_brute_check.py` if the change touches `mul_8x8`
  or the quarter-square path.
- Verify no new `(zp),y` indirect loads on secret operands and no new
  secret-dependent branches in the hot path.
- CT regressions are NOT allowed to be "fixed later" — correctness and
  CT-cleanliness take precedence over performance (this was the
  explicit call for Phase 1–6).

## 5. If you touched the public API (`src/x25519.inc` or any
   `fe25519_*` / `x25519_*` export)
- Verify semver intent: additive → minor; breaking → major.
- Update `docs/LIBRARY.md` §Public API.
- If there is a release in flight, update
  `docs/RELEASE_NOTES_v*.md`.
- Run `make lib-verify` — it asserts the expected public symbols are
  still present in the linked archive.

## 6. If you touched benches or timing claims in docs
- Re-measure via `tools/bench_x25519.py` / `bench_fe_mul.py` /
  `bench_fe_ops.py`, on a stock C64 profile with `jsr vic_blank`.
- Update the performance table in `README.md` and
  `docs/RELEASE_NOTES_*.md` to match. Don't leave stale jiffy counts.

## What NOT to do
- Don't commit generated artifacts (`build/`, `build/lib/`) — they are
  `.gitignore`d.
- Don't "fix" a failing differential test by editing the test — the
  whole point is pyca/cryptography is the oracle. The asm is wrong
  until proven otherwise.
- Don't introduce mocks/reimplementations of X25519 inside the test
  suite for convenience — shared-bug risk.
