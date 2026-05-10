#!/usr/bin/env python3
"""test_fe_reduce_wide_bound.py — strict R <= 2*p bound regression for
fe25519_mul's post-fe_reduce_wide output.

Background
----------
The L29 constant-time `fe25519_reduce_final` performs exactly TWO
unconditional iterations of (compare-with-p, masked subtract-p). The
2-iteration count is sufficient *iff* the value handed to
fe25519_reduce_final is bounded above by 2*p. The library guarantees
this via Inv3: every fe25519_mul / fe25519_sqr completes with the raw
fe_reduce_wide output already in [0, 2*p).

This test is a runtime safety net for that bound: if some future
refactor of fe_reduce_wide (or upstream of it) accidentally lets the
post-reduce value exceed 2*p, fe25519_reduce_final will silently
return non-canonical output and downstream comparisons / equality
checks will start failing (or worse, fail differently for different
inputs, leaking timing).

What it does
------------
For each of N pseudo-random (a, b) pairs:
  1. Write a, b into fe25519_tmp1, fe25519_tmp2.
  2. Set src1=tmp1, src2=tmp2, dst=tmp3.
  3. jsr fe25519_mul.
  4. Read raw bytes from tmp3 (NO fe25519_reduce_final between jsr and
     read — we are explicitly checking the pre-reduce_final range).
  5. Assert int(tmp3, "little") < 2*p.

Also checks correctness modulo p: raw_value % p == (a * b) % p.

Pre-fix: this test would pass on the v0.3.0 codebase since fe_reduce_wide
already produced R <= 2p; the test is a permanent safety net for any
future change that might break that bound.

Usage:
    python3 tools/test_fe_reduce_wide_bound.py

Exit: 0 on success, 1 on failure.
"""

import os
import random
import sys

from c64_test_harness import (
    Labels, ViceConfig, ViceInstanceManager,
    read_bytes, write_bytes, jsr, wait_for_text,
)

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
PRG_PATH = os.path.join(PROJECT_ROOT, "build", "x25519.prg")
LABELS_PATH = os.path.join(PROJECT_ROOT, "build", "labels.txt")

P = (1 << 255) - 19
TWO_P = 2 * P
N_CASES = 50
SEED = 0xBADC0DE29  # deterministic


def set_ptrs(t, labels, src1=None, src2=None, dst=None):
    for name, addr in [("fe25519_src1", src1),
                       ("fe25519_src2", src2),
                       ("fe25519_dst", dst)]:
        if addr is not None:
            write_bytes(t, labels[name], bytes([addr & 0xFF, addr >> 8]))


def gen_input(rng):
    """Generate a 32-byte little-endian field element. Mix of:
       - fully random in [0, 2^256)  (most common)
       - canonical in [0, p)
       - near-2^256-1 (high-MSB stress)
       - near-p (boundary stress)
    """
    bucket = rng.randrange(8)
    if bucket == 0:
        v = P - rng.randrange(1, 1 << 16)
    elif bucket == 1:
        v = (1 << 256) - 1 - rng.randrange(1 << 16)
    elif bucket == 2:
        v = rng.randrange(P)
    else:
        v = rng.randrange(1 << 256)
    return v.to_bytes(32, "little")


def run_case(t, labels, tmps, idx, a_bytes, b_bytes):
    t1, t2, t3 = tmps
    write_bytes(t, t1, a_bytes)
    write_bytes(t, t2, b_bytes)
    set_ptrs(t, labels, src1=t1, src2=t2, dst=t3)
    jsr(t, labels["fe25519_mul"], timeout=120.0)
    raw = read_bytes(t, t3, 32)
    raw_int = int.from_bytes(raw, "little")
    a_int = int.from_bytes(a_bytes, "little")
    b_int = int.from_bytes(b_bytes, "little")
    expected_mod = (a_int * b_int) % P

    bound_ok = raw_int < TWO_P
    mod_ok = (raw_int % P) == expected_mod
    ok = bound_ok and mod_ok

    if not ok:
        print(f"  [FAIL] case {idx}")
        print(f"         a       = {a_bytes.hex()}")
        print(f"         b       = {b_bytes.hex()}")
        print(f"         raw     = {raw.hex()}")
        print(f"         raw/P   = {raw_int / P:.6f}  (need < 2.0)")
        print(f"         bound_ok={bound_ok} mod_ok={mod_ok}")
    return ok


def main():
    if not os.path.exists(PRG_PATH):
        print(f"ERROR: {PRG_PATH} not found — run `make` first", file=sys.stderr)
        return 1

    labels = Labels.from_file(LABELS_PATH)
    t1 = labels["fe25519_tmp1"]
    t2 = labels["fe25519_tmp2"]
    t3 = labels["fe25519_tmp3"]

    config = ViceConfig(
        prg_path=PRG_PATH, warp=True, ntsc=True, sound=False,
        extra_args=["-reu", "-reusize", "512"],
    )

    print("fe_reduce_wide R<=2p strict-bound regression test")
    print(f"  N_CASES = {N_CASES}")
    print(f"  seed    = 0x{SEED:x}")
    print(f"  P       = 2^255 - 19")
    print(f"  bound   = raw_post_reduce_wide < 2*P")
    print()

    rng = random.Random(SEED)

    with ViceInstanceManager(config=config) as mgr:
        inst = mgr.acquire()
        t = inst.transport
        if wait_for_text(t, "Q=QUIT", timeout=60.0) is None:
            print("ERROR: C64 did not reach main menu", file=sys.stderr)
            mgr.release(inst)
            return 1
        # Infinite-loop trap at $0339 (mirrors test_fe_reduce_wide_carry.py)
        write_bytes(t, 0x0339, bytes([0x4C, 0x39, 0x03]))

        passed = 0
        for i in range(N_CASES):
            a = gen_input(rng)
            b = gen_input(rng)
            if run_case(t, labels, (t1, t2, t3), i, a, b):
                passed += 1

        mgr.release(inst)

    print()
    print(f"Results: {passed}/{N_CASES} PASS")
    return 0 if passed == N_CASES else 1


if __name__ == "__main__":
    sys.exit(main())
