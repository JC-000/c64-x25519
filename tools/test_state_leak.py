#!/usr/bin/env python3
"""test_state_leak.py — Test for state leaks between x25519_scalarmult calls.

Checks whether running RFC 7748 vector 1 before vector 2 causes vector 2
to fail, which would indicate leftover state from a previous computation.

Test plan:
  1. Run vector 2 ALONE in a fresh VICE instance — should pass.
  2. In a NEW VICE instance, run vector 1 then vector 2 — check if vector 2
     still passes.
  3. If vector 2 fails only after vector 1, we have confirmed a state leak.

Each scalarmult takes ~15 minutes in warp mode, so expect ~45 min total.
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

# RFC 7748 §6.1 test vectors
VECTOR_1 = {
    "name": "Vector 1",
    "scalar": bytes.fromhex(
        "a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4"
    ),
    "u": bytes.fromhex(
        "e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c"
    ),
    "expected": bytes.fromhex(
        "c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552"
    ),
}

VECTOR_2 = {
    "name": "Vector 2",
    "scalar": bytes.fromhex(
        "4b66e9d4d1b4673c5ad22691957d6af5c11b6421e0ea01d42ca4169e7918ba0d"
    ),
    "u": bytes.fromhex(
        "e5210f12786811d3f4b7959d0538ae2c31dbe7106fc03c3efc4cd549c715a493"
    ),
    "expected": bytes.fromhex(
        "95cbde9476e8907d7aade45cb4b873f88b595a68799fa152e6f8f7647aac7957"
    ),
}


def clamp_scalar(scalar):
    """Clamp scalar per RFC 7748."""
    s = bytearray(scalar)
    s[0] &= 0xF8
    s[31] = (s[31] & 0x7F) | 0x40
    return bytes(s)


def mask_u(u):
    """Mask high bit of u-coordinate per RFC 7748."""
    b = bytearray(u)
    b[31] &= 0x7F
    return bytes(b)


def c64_x25519_scalarmult(transport, labels, scalar_bytes, u_bytes):
    """Compute scalar * u on C64. Returns 32-byte result."""
    write_bytes(transport, labels["x25_scalar"], scalar_bytes)
    write_bytes(transport, labels["x25_u"], u_bytes)
    jsr(transport, labels["x25519_scalarmult"], timeout=7200)
    return read_bytes(transport, labels["x25_result"], 32)


def run_vector(transport, labels, vec):
    """Run a single test vector. Returns (passed: bool, result: bytes)."""
    scalar = clamp_scalar(vec["scalar"])
    u = mask_u(vec["u"])
    result = c64_x25519_scalarmult(transport, labels, scalar, u)
    passed = result == vec["expected"]
    return passed, result


def setup_vice(mgr):
    """Acquire a VICE instance, wait for menu, install safety trampoline."""
    inst = mgr.acquire()
    print(f"  VICE PID={inst.pid}, port={inst.port}")
    transport = inst.transport

    grid = wait_for_text(transport, "Q=QUIT", timeout=60.0, verbose=False)
    if grid is None:
        print("  FATAL: Main menu did not appear")
        sys.exit(1)

    # Safety trampoline: JMP $0339 at $0339
    write_bytes(transport, 0x0339, bytes([0x4C, 0x39, 0x03]))
    return inst, transport


def print_result(vec_name, passed, result, expected):
    """Print pass/fail for a vector."""
    if passed:
        print(f"  {vec_name}: PASS")
    else:
        print(f"  {vec_name}: FAIL")
        print(f"    expected: {expected.hex()}")
        print(f"    got:      {result.hex()}")


def main():
    os.chdir(PROJECT_ROOT)

    # Load labels
    labels = Labels.from_file(LABELS_PATH)
    required = [
        "x25519_scalarmult", "x25_scalar", "x25_u", "x25_result",
    ]
    for name in required:
        if labels.address(name) is None:
            print(f"FATAL: '{name}' label not found in {LABELS_PATH}")
            sys.exit(1)
    print(f"Labels loaded ({len(required)} required labels verified)")

    config = ViceConfig(prg_path=PRG_PATH, warp=True, ntsc=True, sound=False)

    v2_alone_passed = False
    v2_after_v1_passed = False

    # ------------------------------------------------------------------
    # Phase 1: Vector 2 alone (fresh VICE instance)
    # ------------------------------------------------------------------
    print("\n" + "=" * 60)
    print("PHASE 1: Vector 2 ALONE (fresh VICE instance)")
    print("=" * 60)

    with ViceInstanceManager(config=config) as mgr:
        inst, transport = setup_vice(mgr)

        print("  Running Vector 2...")
        passed, result = run_vector(transport, labels, VECTOR_2)
        print_result("Vector 2 (alone)", passed, result, VECTOR_2["expected"])
        v2_alone_passed = passed

        mgr.release(inst)

    # ------------------------------------------------------------------
    # Phase 2: Vector 1 then Vector 2 (same VICE instance)
    # ------------------------------------------------------------------
    print("\n" + "=" * 60)
    print("PHASE 2: Vector 1 THEN Vector 2 (same VICE instance)")
    print("=" * 60)

    with ViceInstanceManager(config=config) as mgr:
        inst, transport = setup_vice(mgr)

        print("  Running Vector 1...")
        v1_passed, v1_result = run_vector(transport, labels, VECTOR_1)
        print_result("Vector 1", v1_passed, v1_result, VECTOR_1["expected"])

        print("  Running Vector 2 (after Vector 1)...")
        passed, result = run_vector(transport, labels, VECTOR_2)
        print_result("Vector 2 (after V1)", passed, result, VECTOR_2["expected"])
        v2_after_v1_passed = passed

        mgr.release(inst)

    # ------------------------------------------------------------------
    # Summary
    # ------------------------------------------------------------------
    print("\n" + "=" * 60)
    print("SUMMARY")
    print("=" * 60)
    print(f"  Vector 2 alone:     {'PASS' if v2_alone_passed else 'FAIL'}")
    print(f"  Vector 2 after V1:  {'PASS' if v2_after_v1_passed else 'FAIL'}")

    if v2_alone_passed and not v2_after_v1_passed:
        print("\n  ** STATE LEAK CONFIRMED **")
        print("  Vector 2 passes alone but fails after Vector 1.")
        print("  Something from Vector 1 is leaking into Vector 2.")
        sys.exit(1)
    elif not v2_alone_passed and not v2_after_v1_passed:
        print("\n  Vector 2 fails in both cases — bug is NOT a state leak.")
        print("  The computation is broken regardless of prior state.")
        sys.exit(1)
    elif v2_alone_passed and v2_after_v1_passed:
        print("\n  Both pass — no state leak detected.")
        sys.exit(0)
    else:
        print("\n  Unexpected: V2 fails alone but passes after V1.")
        sys.exit(1)


if __name__ == "__main__":
    main()
