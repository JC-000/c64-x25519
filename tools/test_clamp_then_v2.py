#!/usr/bin/env python3
"""test_clamp_then_v2.py — Check whether running 4 clamp tests before
vector 2 causes vector 2 to fail.

Runs everything in a SINGLE VICE instance:
  1. Four clamp tests (same cases as test_x25519.py)
  2. RFC 7748 vector 2 scalarmult
"""

import os
import sys

from c64_test_harness import (
    Labels, ViceConfig, ViceInstanceManager,
    read_bytes, write_bytes, jsr, wait_for_text,
)

PROJECT_ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
PRG_PATH = os.path.join(PROJECT_ROOT, "build", "x25519.prg")
LABELS_PATH = os.path.join(PROJECT_ROOT, "build", "labels.txt")


# ---- Reference helpers ----

def clamp_ref(s):
    s = bytearray(s)
    s[0] &= 0xF8
    s[31] = (s[31] & 0x7F) | 0x40
    return bytes(s)


def c64_x25519_clamp(transport, labels, scalar):
    write_bytes(transport, labels["x25_scalar"], scalar)
    jsr(transport, labels["x25519_clamp"])
    return read_bytes(transport, labels["x25_scalar"], 32)


def c64_x25519_scalarmult(transport, labels, scalar, u):
    write_bytes(transport, labels["x25_scalar"], scalar)
    write_bytes(transport, labels["x25_u"], u)
    jsr(transport, labels["x25519_scalarmult"], timeout=7200.0)
    return read_bytes(transport, labels["x25_result"], 32)


# ---- Vector 2 data ----

V2_SCALAR = bytes.fromhex(
    "4b66e9d4d1b4673c5ad22691957d6af5c11b6421e0ea01d42ca4169e7918ba0d"
)
V2_U = bytes.fromhex(
    "e5210f12786811d3f4b7959d0538ae2c31dbe7106fc03c3efc4cd549c715a493"
)
V2_EXPECTED = bytes.fromhex(
    "95cbde9476e8907d7aade45cb4b873f88b595a68799fa152e6f8f7647aac7957"
)


def main():
    os.chdir(PROJECT_ROOT)
    labels = Labels.from_file(LABELS_PATH)
    config = ViceConfig(prg_path=PRG_PATH, warp=True, ntsc=True, sound=False,
                        extra_args=["-reu", "-reusize", "512"])

    failed = 0

    with ViceInstanceManager(config=config) as mgr:
        inst = mgr.acquire()
        print(f"VICE PID={inst.pid}, port={inst.port}")
        transport = inst.transport
        grid = wait_for_text(transport, "Q=QUIT", timeout=60.0, verbose=False)
        if grid is None:
            print("FATAL: Main menu did not appear")
            sys.exit(1)
        print("VICE ready")
        write_bytes(transport, 0x0339, bytes([0x4C, 0x39, 0x03]))

        # ---- Step 1: Four clamp tests ----
        print("\n--- Clamp tests ---")
        clamp_cases = [
            bytes(range(32)),
            bytes([0xFF] * 32),
            bytes([0x00] * 32),
            bytes([0xA5] * 32),
        ]
        for i, scalar in enumerate(clamp_cases):
            expected = clamp_ref(scalar)
            result = c64_x25519_clamp(transport, labels, scalar)
            if result == expected:
                print(f"  PASS clamp #{i}")
            else:
                failed += 1
                print(f"  FAIL clamp #{i}:")
                print(f"    expected: {expected.hex()}")
                print(f"    got:      {result.hex()}")

        # ---- Step 2: Vector 2 scalarmult ----
        print("\n--- Vector 2 scalarmult ---")
        scalar_clamped = clamp_ref(V2_SCALAR)
        u_masked = bytearray(V2_U)
        u_masked[31] &= 0x7F
        u_masked = bytes(u_masked)

        print(f"  scalar (clamped): {scalar_clamped.hex()}")
        print(f"  u (masked):       {u_masked.hex()}")
        print(f"  expected result:  {V2_EXPECTED.hex()}")
        print("  Running scalarmult (this takes ~10 minutes)...", flush=True)

        result = c64_x25519_scalarmult(transport, labels, scalar_clamped, u_masked)

        if result == V2_EXPECTED:
            print(f"  PASS vector 2")
            print(f"    result: {result.hex()}")
        else:
            failed += 1
            print(f"  FAIL vector 2:")
            print(f"    expected: {V2_EXPECTED.hex()}")
            print(f"    got:      {result.hex()}")

        mgr.release(inst)

    print(f"\n{'='*60}")
    if failed == 0:
        print("ALL PASSED — clamp tests do NOT cause vector 2 to fail")
    else:
        print(f"FAILED: {failed} test(s) failed")
    print(f"{'='*60}")
    sys.exit(0 if failed == 0 else 1)


if __name__ == "__main__":
    main()
