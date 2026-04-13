#!/usr/bin/env python3
"""test_fe_reduce_wide_carry.py — regression test for fe_reduce_wide carry bug.

Regression test for the cpx-clobbers-carry bug in fe_reduce_wide's @prop2/@prop3
carry-propagation loops (fixed 2026-04-13). The broken pattern was:

    lda fe_wide,x
    adc #0           ; intended to propagate C from prior arithmetic
    sta fe_wide,x
    bcc @done
    inx
    cpx #32          ; CLOBBERS C
    bcc @loop_top    ; back to adc #0 with wrong C

`cpx` sets the carry flag based on the comparison, so on the second-and-later
iterations of the loop the `adc #0` saw C from `cpx` (not from the arithmetic),
silently dropping the +1 that needed to propagate further. Fix: use
`inc fe_wide,x; bne @done` (same pattern already used correctly in
fe25519_mul_a24). See feedback_6502_cpx_clobbers_carry.md for the pattern.

The bug triggered on a specific 4-step cascade:
  1. first-pass carry-out nonzero
  2. 38*fe_carry added to fe_wide[0..1] produced a carry into fe_wide[2]
  3. fe_wide[2] == $FF so the carry had to propagate to fe_wide[3]
  4. fe_wide[3] != $FF so the loop should terminate after one more byte

This test uses the minimal failing inputs discovered at Montgomery ladder
step 172 of test_x25519.py --slow --seed 3115981863:

  u        = d93626eb28ae6efdbe231f2ea1411537d123b5fe8e9625146daed29e6267cc55
  noncanon = 72b74a1a536c4d21ae4d1e4db0ef51166113cac16dc0bcd74ca620df4f335fcd
             (== canonical 85b7...4d + p; arises from fe_sqr of DA-CB
              returning a non-canonical value, which Phase 6's "skip
              reduce_final on intermediates" optimization then passes
              straight into fe_mul)

Three cases are tested:
  A) fe_mul(u, noncanon)      — original trigger
  B) fe_mul(u, canon)         — control (always passed, even pre-fix)
  C) fe_mul(noncanon, u)      — operand-order swap

Pre-fix: case A byte[3] came out 0x29 instead of 0x2a.

Usage:
    python3 tools/test_fe_reduce_wide_carry.py

Exit: 0 on success, 1 on failure.
"""

import os
import sys

from c64_test_harness import (
    Labels, ViceConfig, ViceInstanceManager,
    read_bytes, write_bytes, jsr, wait_for_text,
)

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
PRG_PATH = os.path.join(PROJECT_ROOT, "build", "x25519.prg")
LABELS_PATH = os.path.join(PROJECT_ROOT, "build", "labels.txt")

P = (1 << 255) - 19

# Canonical u-coord from the failing test (high bit cleared per decodeU).
U = bytes.fromhex("d93626eb28ae6efdbe231f2ea1411537d123b5fe8e9625146daed29e6267cc55")
U = bytes(U[:31]) + bytes([U[31] & 0x7F])

# Non-canonical DAmCB_sq from ladder step 172, = canonical + p.
NONCANON = bytes.fromhex("72b74a1a536c4d21ae4d1e4db0ef51166113cac16dc0bcd74ca620df4f335fcd")
CANON = (int.from_bytes(NONCANON, "little") % P).to_bytes(32, "little")

U_int = int.from_bytes(U, "little")
CANON_int = int.from_bytes(CANON, "little")
EXPECTED = ((U_int * CANON_int) % P).to_bytes(32, "little")


def set_ptrs(t, labels, src1=None, src2=None, dst=None):
    for name, addr in [("fe25519_src1", src1),
                       ("fe25519_src2", src2),
                       ("fe25519_dst", dst)]:
        if addr is not None:
            write_bytes(t, labels[name], bytes([addr & 0xFF, addr >> 8]))


def run_case(t, labels, tmps, label, src1_bytes, src2_bytes):
    t1, t2, t3 = tmps
    write_bytes(t, t1, src1_bytes)
    write_bytes(t, t2, src2_bytes)
    set_ptrs(t, labels, src1=t1, src2=t2, dst=t3)
    jsr(t, labels["fe25519_mul"], timeout=120.0)
    jsr(t, labels["fe25519_reduce_final"], timeout=5.0)
    got = read_bytes(t, t3, 32)
    ok = got == EXPECTED
    status = "PASS" if ok else "FAIL"
    print(f"  [{status}] {label}")
    if not ok:
        diffs = [(i, e, g) for i, (e, g) in enumerate(zip(EXPECTED, got)) if e != g]
        print(f"         expected = {EXPECTED.hex()}")
        print(f"         got      = {got.hex()}")
        print(f"         diffs    = {diffs}")
    return ok


def main():
    labels = Labels.from_file(LABELS_PATH)
    t1 = labels["fe25519_tmp1"]
    t2 = labels["fe25519_tmp2"]
    t3 = labels["fe25519_tmp3"]

    config = ViceConfig(
        prg_path=PRG_PATH, warp=True, ntsc=True, sound=False,
        extra_args=["-reu", "-reusize", "512"],
    )

    print("fe_reduce_wide carry-propagation regression test")
    print(f"  u    = {U.hex()}")
    print(f"  nc   = {NONCANON.hex()}")
    print(f"  expt = {EXPECTED.hex()}")
    print()

    with ViceInstanceManager(config=config) as mgr:
        inst = mgr.acquire()
        t = inst.transport
        if wait_for_text(t, "Q=QUIT", timeout=60.0) is None:
            print("ERROR: C64 did not reach main menu", file=sys.stderr)
            mgr.release(inst)
            return 1
        # Install an infinite-loop trap at $0339 so the C64 won't run past
        # our jsr() calls. diff_mul_minimal.py used this trick; preserved here.
        write_bytes(t, 0x0339, bytes([0x4C, 0x39, 0x03]))

        results = []
        results.append(run_case(
            t, labels, (t1, t2, t3),
            "A  fe_mul(u, noncanon)   — original trigger",
            U, NONCANON,
        ))
        results.append(run_case(
            t, labels, (t1, t2, t3),
            "B  fe_mul(u, canonical)  — control",
            U, CANON,
        ))
        results.append(run_case(
            t, labels, (t1, t2, t3),
            "C  fe_mul(noncanon, u)   — operand-order swap",
            NONCANON, U,
        ))

        mgr.release(inst)

    passed = sum(results)
    total = len(results)
    print()
    print(f"Results: {passed}/{total} PASS")
    return 0 if passed == total else 1


if __name__ == "__main__":
    sys.exit(main())
