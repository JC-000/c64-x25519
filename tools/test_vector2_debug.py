#!/usr/bin/env python3
"""test_vector2_debug.py — Debug RFC 7748 vector 2 failure.

Runs the full x25519_scalarmult on vector 2, then reads x2, z2, x3, z3
after completion to determine whether the bug is in the ladder loop or
in the final inversion/multiply.

This test takes ~100 minutes in VICE warp mode.
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

# RFC 7748 vector 2
SCALAR_HEX = "4b66e9d4d1b4673c5ad22691957d6af5c11b6421e0ea01d42ca4169e7918ba0d"
U_HEX      = "e5210f12786811d3f4b7959d0538ae2c31dbe7106fc03c3efc4cd549c715a493"
EXPECTED_HEX = "95cbde9476e8907d7aade45cb4b873f88b595a68799fa152e6f8f7647aac7957"

P = (1 << 255) - 19


def clamp_scalar(s_bytes):
    """Clamp scalar per RFC 7748."""
    s = bytearray(s_bytes)
    s[0] &= 0xF8
    s[31] = (s[31] & 0x7F) | 0x40
    return bytes(s)


def fe_from_bytes(b):
    """Little-endian bytes -> integer."""
    return int.from_bytes(b, 'little')


def fe_to_bytes(n):
    """Integer -> 32 little-endian bytes."""
    return (n % P).to_bytes(32, 'little')


def main():
    os.chdir(PROJECT_ROOT)

    # Load labels
    labels = Labels.from_file(LABELS_PATH)
    required = [
        "x25519_scalarmult",
        "x25_scalar", "x25_u", "x25_result",
        "x25_x2", "x25_z2", "x25_x3", "x25_z3",
    ]
    for name in required:
        if labels.address(name) is None:
            print(f"FATAL: '{name}' label not found in {LABELS_PATH}")
            sys.exit(1)
    print(f"Labels loaded: {len(required)} required labels verified")

    # Prepare inputs
    scalar_raw = bytes.fromhex(SCALAR_HEX)
    u_raw = bytes.fromhex(U_HEX)
    expected = bytes.fromhex(EXPECTED_HEX)

    scalar_clamped = clamp_scalar(scalar_raw)
    u_masked = bytearray(u_raw)
    u_masked[31] &= 0x7F
    u_masked = bytes(u_masked)

    print(f"Scalar (clamped): {scalar_clamped.hex()}")
    print(f"U-coord (masked): {u_masked.hex()}")
    print(f"Expected result:  {expected.hex()}")

    # Python reference computation
    print("\n--- Python reference ---")
    from test_x25519 import x25519_ref
    py_result = x25519_ref(scalar_clamped, u_masked)
    print(f"Python x25519:    {py_result.hex()}")
    if py_result == expected:
        print("  Python matches expected: YES")
    else:
        print("  Python matches expected: NO (reference impl bug?)")

    # Launch VICE
    config = ViceConfig(prg_path=PRG_PATH, warp=True, ntsc=True, sound=False,
                        extra_args=["-reu", "-reusize", "512"])

    with ViceInstanceManager(config=config) as mgr:
        inst = mgr.acquire()
        print(f"\nVICE PID={inst.pid}, port={inst.port}")

        transport = inst.transport
        grid = wait_for_text(transport, "Q=QUIT", timeout=60.0, verbose=False)
        if grid is None:
            print("FATAL: Main menu did not appear")
            mgr.release(inst)
            sys.exit(1)

        print("VICE ready.")

        # Safety trampoline
        write_bytes(transport, 0x0339, bytes([0x4C, 0x39, 0x03]))

        # Write inputs
        write_bytes(transport, labels["x25_scalar"], scalar_clamped)
        write_bytes(transport, labels["x25_u"], u_masked)

        # Verify inputs written correctly
        check_s = read_bytes(transport, labels["x25_scalar"], 32)
        check_u = read_bytes(transport, labels["x25_u"], 32)
        assert check_s == scalar_clamped, "Scalar write verification failed!"
        assert check_u == u_masked, "U-coord write verification failed!"
        print("Inputs written and verified.")

        # Run scalarmult (this takes ~100 minutes)
        print("\nCalling x25519_scalarmult... (expect ~100 minutes in warp)")
        sys.stdout.flush()
        jsr(transport, labels["x25519_scalarmult"], timeout=7200)
        print("x25519_scalarmult returned.")

        # Read results
        result = read_bytes(transport, labels["x25_result"], 32)
        x2 = read_bytes(transport, labels["x25_x2"], 32)
        z2 = read_bytes(transport, labels["x25_z2"], 32)
        x3 = read_bytes(transport, labels["x25_x3"], 32)
        z3 = read_bytes(transport, labels["x25_z3"], 32)

        mgr.release(inst)

    # Analysis
    print("\n" + "=" * 60)
    print("RESULTS")
    print("=" * 60)

    print(f"\nx25_result: {result.hex()}")
    print(f"expected:   {expected.hex()}")
    if result == expected:
        print(">>> RESULT MATCHES EXPECTED <<<")
    else:
        print(">>> RESULT DOES NOT MATCH EXPECTED <<<")

    print(f"\nx25_x2: {x2.hex()}")
    print(f"x25_z2: {z2.hex()}")
    print(f"x25_x3: {x3.hex()}")
    print(f"x25_z3: {z3.hex()}")

    # Cross-check: compute x2 * inv(z2) mod P in Python
    x2_int = fe_from_bytes(x2)
    z2_int = fe_from_bytes(z2)
    x3_int = fe_from_bytes(x3)
    z3_int = fe_from_bytes(z3)

    print(f"\nx2 (int): {x2_int}")
    print(f"z2 (int): {z2_int}")

    if z2_int == 0:
        print("WARNING: z2 is zero! Cannot compute x2/z2.")
        py_x2_over_z2 = None
    else:
        z2_inv = pow(z2_int, P - 2, P)
        py_x2_over_z2 = (x2_int * z2_inv) % P
        py_x2_over_z2_bytes = fe_to_bytes(py_x2_over_z2)
        print(f"\nPython x2*inv(z2) mod P: {py_x2_over_z2_bytes.hex()}")

        if py_x2_over_z2_bytes == expected:
            print(">>> x2*inv(z2) matches EXPECTED — ladder loop is CORRECT, inversion/final-mul is the BUG <<<")
        elif py_x2_over_z2_bytes == result:
            print(">>> x2*inv(z2) matches x25_result — inversion is consistent with x2/z2 <<<")
            print(">>> But doesn't match expected — ladder loop has the BUG <<<")
        else:
            print(">>> x2*inv(z2) matches NEITHER expected NOR x25_result — something is very wrong <<<")

        # Also check if result matches x2*inv(z2)
        result_int = fe_from_bytes(result)
        if result_int == py_x2_over_z2:
            print("\nx25_result == x2*inv(z2): YES (assembly inversion/final-mul is correct)")
        else:
            print(f"\nx25_result == x2*inv(z2): NO")
            print(f"  x25_result as int: {result_int}")
            print(f"  x2*inv(z2) as int: {py_x2_over_z2}")
            print("  Assembly inversion/final-mul may have a bug")

    # Also compute x3/z3 for completeness
    if z3_int != 0:
        z3_inv = pow(z3_int, P - 2, P)
        py_x3_over_z3 = (x3_int * z3_inv) % P
        print(f"\nPython x3*inv(z3) mod P: {fe_to_bytes(py_x3_over_z3).hex()}")

    print("\nDone.")
    sys.exit(0 if result == expected else 1)


if __name__ == "__main__":
    main()
