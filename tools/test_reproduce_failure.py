#!/usr/bin/env python3
"""test_reproduce_failure.py — Reproduce exact test_x25519.py --slow sequence.

Isolates what causes RFC 7748 vector 2 to fail by reproducing the exact
sequence: build -> clamp tests -> vector 1 -> vector 2.

If vector 2 fails, reads x25_x2 and x25_z2 from VICE memory and computes
the wrong answer (x2 * inv(z2) mod P) for comparison.
"""

import os
import subprocess
import sys
import time

from c64_test_harness import (
    Labels, ViceConfig, ViceInstanceManager,
    read_bytes, write_bytes, jsr, wait_for_text,
)

PROJECT_ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
PRG_PATH = os.path.join(PROJECT_ROOT, "build", "x25519.prg")
LABELS_PATH = os.path.join(PROJECT_ROOT, "build", "labels.txt")

P = (1 << 255) - 19


def clamp_ref(s):
    s = bytearray(s)
    s[0] &= 0xF8
    s[31] = (s[31] & 0x7F) | 0x40
    return bytes(s)


def fe_from_bytes(b):
    """Convert 32 little-endian bytes to integer."""
    return int.from_bytes(b, 'little')


def fe_to_bytes(n):
    """Convert integer to 32 little-endian bytes."""
    return (n % P).to_bytes(32, 'little')


def main():
    os.chdir(PROJECT_ROOT)

    # ---- Step 1: Build ----
    print("=" * 60)
    print("STEP 1: Rebuild (make clean && make)")
    print("=" * 60)
    subprocess.run(["make", "clean"], capture_output=True, cwd=PROJECT_ROOT)
    result = subprocess.run(["make"], capture_output=True, text=True, cwd=PROJECT_ROOT)
    if result.returncode != 0:
        print(f"Build failed:\n{result.stderr}")
        sys.exit(1)
    print(f"Build OK: {PRG_PATH}")

    # Load labels
    labels = Labels.from_file(LABELS_PATH)
    required = [
        "x25519_clamp", "x25519_scalarmult",
        "x25_scalar", "x25_u", "x25_result",
        "x25_x2", "x25_z2",
    ]
    for name in required:
        if labels.address(name) is None:
            print(f"FATAL: '{name}' label not found")
            sys.exit(1)
    print(f"Labels loaded, all {len(required)} required labels found")

    # ---- Step 2: Launch VICE ----
    print("\n" + "=" * 60)
    print("STEP 2: Launch VICE")
    print("=" * 60)
    config = ViceConfig(prg_path=PRG_PATH, warp=True, ntsc=True, sound=False,
                        extra_args=["-reu", "-reusize", "512"])

    with ViceInstanceManager(config=config) as mgr:
        inst = mgr.acquire()
        print(f"VICE PID={inst.pid}, port={inst.port}")

        transport = inst.transport
        grid = wait_for_text(transport, "Q=QUIT", timeout=60.0, verbose=False)
        if grid is None:
            print("FATAL: Main menu did not appear")
            sys.exit(1)
        print("VICE ready (Q=QUIT detected)")

        # Safety trampoline
        write_bytes(transport, 0x0339, bytes([0x4C, 0x39, 0x03]))

        all_passed = True

        # ---- Step 3: Clamp tests ----
        print("\n" + "=" * 60)
        print("STEP 3: Clamp tests (4 cases)")
        print("=" * 60)
        clamp_cases = [
            bytes(range(32)),
            bytes([0xFF] * 32),
            bytes([0x00] * 32),
            bytes([0xA5] * 32),
        ]
        for i, scalar in enumerate(clamp_cases):
            expected = clamp_ref(scalar)
            write_bytes(transport, labels["x25_scalar"], scalar)
            jsr(transport, labels["x25519_clamp"])
            result = read_bytes(transport, labels["x25_scalar"], 32)
            if result == expected:
                print(f"  Clamp #{i}: PASS")
            else:
                print(f"  Clamp #{i}: FAIL")
                print(f"    expected: {expected.hex()}")
                print(f"    got:      {result.hex()}")
                all_passed = False

        # ---- Step 4: Vector 1 ----
        print("\n" + "=" * 60)
        print("STEP 4: RFC 7748 vector 1")
        print("=" * 60)
        v1_scalar = bytes.fromhex(
            "a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4")
        v1_u = bytes.fromhex(
            "e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c")
        v1_expected = bytes.fromhex(
            "c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552")

        v1_scalar_clamped = clamp_ref(v1_scalar)
        write_bytes(transport, labels["x25_scalar"], v1_scalar_clamped)
        write_bytes(transport, labels["x25_u"], v1_u)
        print("  Running scalarmult (this takes ~100 min)...", flush=True)
        t0 = time.time()
        jsr(transport, labels["x25519_scalarmult"], timeout=7200.0)
        elapsed1 = time.time() - t0
        v1_result = read_bytes(transport, labels["x25_result"], 32)
        if v1_result == v1_expected:
            print(f"  Vector 1: PASS  ({elapsed1:.0f}s)")
        else:
            print(f"  Vector 1: FAIL  ({elapsed1:.0f}s)")
            print(f"    expected: {v1_expected.hex()}")
            print(f"    got:      {v1_result.hex()}")
            all_passed = False

        # ---- Step 5: Vector 2 ----
        print("\n" + "=" * 60)
        print("STEP 5: RFC 7748 vector 2")
        print("=" * 60)
        v2_scalar = bytes.fromhex(
            "4b66e9d4d1b4673c5ad22691957d6af5c11b6421e0ea01d42ca4169e7918ba0d")
        v2_u = bytes.fromhex(
            "e5210f12786811d3f4b7959d0538ae2c31dbe7106fc03c3efc4cd549c715a493")
        v2_expected = bytes.fromhex(
            "95cbde9476e8907d7aade45cb4b873f88b595a68799fa152e6f8f7647aac7957")

        v2_scalar_clamped = clamp_ref(v2_scalar)
        write_bytes(transport, labels["x25_scalar"], v2_scalar_clamped)
        write_bytes(transport, labels["x25_u"], v2_u)
        print("  Running scalarmult (this takes ~100 min)...", flush=True)
        t0 = time.time()
        jsr(transport, labels["x25519_scalarmult"], timeout=7200.0)
        elapsed2 = time.time() - t0
        v2_result = read_bytes(transport, labels["x25_result"], 32)
        if v2_result == v2_expected:
            print(f"  Vector 2: PASS  ({elapsed2:.0f}s)")
        else:
            print(f"  Vector 2: FAIL  ({elapsed2:.0f}s)")
            print(f"    expected: {v2_expected.hex()}")
            print(f"    got:      {v2_result.hex()}")
            all_passed = False

            # ---- Steps 7-8: Diagnostic dump ----
            print("\n" + "=" * 60)
            print("DIAGNOSTIC: Reading x25_x2 and x25_z2 from VICE memory")
            print("=" * 60)
            x2_bytes = read_bytes(transport, labels["x25_x2"], 32)
            z2_bytes = read_bytes(transport, labels["x25_z2"], 32)
            x2_val = fe_from_bytes(x2_bytes)
            z2_val = fe_from_bytes(z2_bytes)
            print(f"  x25_x2 raw: {x2_bytes.hex()}")
            print(f"  x25_z2 raw: {z2_bytes.hex()}")
            print(f"  x2 (int): {x2_val}")
            print(f"  z2 (int): {z2_val}")

            if z2_val == 0:
                print("  z2 is ZERO — cannot compute result")
            else:
                wrong_result_int = (x2_val * pow(z2_val, P - 2, P)) % P
                wrong_result = fe_to_bytes(wrong_result_int)
                print(f"  x2*inv(z2) mod P = {wrong_result.hex()}")
                print(f"  (this is what scalarmult computed)")
                print(f"  expected result:   {v2_expected.hex()}")

                # Also check: does the wrong result match what x25_result has?
                if wrong_result == v2_result:
                    print("  CONFIRMED: x25_result == x2*inv(z2) — error is in ladder, not in final inversion")
                else:
                    print("  NOTE: x25_result != x2*inv(z2) — error may be in final inversion step")
                    print(f"  x25_result:        {v2_result.hex()}")
                    print(f"  x2*inv(z2):        {wrong_result.hex()}")

        # ---- Release ----
        mgr.release(inst)

    # ---- Summary ----
    print("\n" + "=" * 60)
    if all_passed:
        print("ALL STEPS PASSED")
    else:
        print("FAILURE DETECTED — see above for details")
    print("=" * 60)
    sys.exit(0 if all_passed else 1)


if __name__ == "__main__":
    main()
