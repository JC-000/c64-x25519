# Suggested Commands

## Build
```
make              # builds build/x25519.prg (standalone test harness)
make all          # same as `make`
make clean        # wipe build/*.o, PRG, labels, lib dir
make lib          # build build/lib/libx25519.a + .o + x25519.inc + cfg
make lib-verify   # build lib + smoke-test it via tests/lib_linkage stub
```

## Test (fast / no VICE)
```
make test         # python3 tools/ref_x25519.py
make test-ref     # alias; pure Python reference self-test
```

## Test (slow / requires VICE + built .prg)
```
make test-slow    # full suite: ref + fe25519 + fe_mul/sqr stress +
                  # reduce_wide_carry regression + opt_{sqr,karatsuba,
                  # fast_mul,vic_reduce38} + mul38_tables + x25519
                  # --slow + ladder_checkpoint --start 0 --count 255
make test-vice    # shorter VICE subset (mul38, fe25519, fe_mul/sqr
                  # stress, reduce_wide_carry)
```

## Individual Python tools (all under `tools/`)
```
python3 tools/ref_x25519.py
python3 tools/test_fe25519.py
python3 tools/test_fe_mul_stress.py
python3 tools/test_fe_sqr_stress.py
python3 tools/test_fe_reduce_wide_carry.py
python3 tools/test_x25519.py [--slow]
python3 tools/test_ladder_checkpoint.py --start 0 --count 255
python3 tools/bench_x25519.py
python3 tools/bench_fe_mul.py
python3 tools/bench_fe_ops.py
python3 tools/ct_mul_brute_check.py
```

## Lint / format
No explicit linter or formatter is configured (ca65 assembly +
hand-crafted Python). No `ruff`, `black`, `pytest` config in the repo.
Python tools are run directly via `python3 tools/...`.

## Python environment gotcha (macOS, this dev machine)
The Makefile's `make test` / `make test-slow` targets invoke `python3`
(system Python). On this machine the system `python3` lacks
`cryptography`, while the c64-test-harness venv has it. To run the
suite, prepend the venv on PATH:
```
PATH=/Users/someone/.local/share/c64-test-harness/venv/bin:$PATH make test-slow
```
For one-off scripts (e.g. `tools/test_issue33_adversarial.py --target u64`),
invoke the venv Python directly:
```
/Users/someone/.local/share/c64-test-harness/venv/bin/python tools/<script>.py [args]
```

## Issue #33 / S2 regression test
`tools/test_issue33_adversarial.py` — adversarial REU-state harness,
8 cases. Use to verify the S2 defensive-init fix hasn't regressed.
```
# VICE (fast, ~15s/case warp)
/Users/someone/.local/share/c64-test-harness/venv/bin/python tools/test_issue33_adversarial.py --target vice --case <name>
# Real U64E (~230s/case at NTSC, queues device via harness lock)
/Users/someone/.local/share/c64-test-harness/venv/bin/python tools/test_issue33_adversarial.py --target u64 --case <name>
```
Cases: `clean`, `h1_audit`, `reu_low_dirty`, `reu_addr_ctrl_dirty`,
`reu_full_dirty`, `nmi_corrupts_zp40`, `irq_during_call`. All should
match RFC 7748 §6.1 vec-1 hash post-fix.

## Git / GitHub
```
git status
git log --oneline -20
git diff
gh repo view JC-000/c64-x25519
gh issue list
gh pr list
gh issue view 20   # CT remediation tracking issue
```

## Darwin / macOS specifics
- Shell: zsh (not bash). `shopt` etc. are unavailable — use `setopt`.
- Prefer BSD `sed`/`grep` behavior; GNU long options (e.g. `sed -i''`)
  differ from Linux. The Makefile uses a single BSD-compatible `sed`
  invocation on labels.
- `sha256sum` is not installed by default; the README integration
  walkthrough assumes it. Use `shasum -a 256` as the macOS equivalent
  if you need to verify a release tarball locally.
- VICE must be installed separately (`brew install vice` or similar)
  for `make test-slow` / `make test-vice`.
- `cc65` suite must be on `$PATH` for `ca65`/`ld65`/`ar65` — install
  via `brew install cc65`.
