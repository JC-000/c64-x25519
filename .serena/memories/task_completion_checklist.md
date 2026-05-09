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

**Note (macOS):** `make test*` invokes `python3` (system Python),
which on this dev machine lacks `cryptography`. Prepend the harness
venv on PATH:
```
PATH=/Users/someone/.local/share/c64-test-harness/venv/bin:$PATH make test-slow
```

## 4. If you touched anything CT-relevant
- Update `docs/CT_ANALYSIS.md` — extend the leak catalogue (L1..Ln) if
  you added / removed / changed a leak site.
- Re-run `tools/ct_mul_brute_check.py` if the change touches `mul_8x8`
  or the quarter-square path.
- Re-run `tools/test_ct_square_cycles.py` (≤1 jif spread) if you
  touched `fe25519_sqr`. Treat as CT regression gate.
- Verify no new `(zp),y` indirect loads on secret operands and no new
  secret-dependent branches in the hot path.
- CT regressions are NOT allowed to be "fixed later" — correctness and
  CT-cleanliness take precedence over performance (this was the
  explicit call for Phase 1–6).

## 4b. If you touched anything STATE-CONTRACT-relevant
(REU register init, ZP usage, IRQ/NMI handling, caller invariants)
- Update `docs/CT_ANALYSIS.md` §State-contract defences — add an Sn
  entry alongside S1/S2. Keep it distinct from the L1–L24 timing-leak
  inventory; these are correctness fixes, not CT.
- Re-run `tools/test_issue33_adversarial.py --target vice` (all 8
  cases) to ensure S2 (REU defensive init) hasn't regressed.
- For meaningful state-contract work, also re-run on real U64E:
  `tools/test_issue33_adversarial.py --target u64 --case <name>` per
  case. ~230s/case at NTSC; uses the harness's cross-process device
  queue so safe to share with other agents.
- Update `docs/LIBRARY.md` §9 (Caller responsibilities) if the new
  defence relaxes a caller contract.

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
