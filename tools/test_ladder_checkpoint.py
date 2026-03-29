#!/usr/bin/env python3
"""test_ladder_checkpoint.py -- Step-by-step Montgomery ladder test on C64.

Runs the X25519 Montgomery ladder step-by-step on the C64, using C64 field
operations (fe_add, fe_sub, fe_mul, fe_sqr, fe_mul_a24) for all arithmetic.
Compares intermediate state after each step against Python reference
checkpoints from test/vector2_ladder_checkpoints.json.

Usage:
    python3 tools/test_ladder_checkpoint.py [--start N] [--count N] [--seed S]

Examples:
    python3 tools/test_ladder_checkpoint.py                # steps 0-9
    python3 tools/test_ladder_checkpoint.py --start 10 --count 20
    python3 tools/test_ladder_checkpoint.py --start 0 --count 255  # full run (~2h)
"""

import json
import os
import sys
import time

from c64_test_harness import (
    Labels, ViceConfig, ViceInstanceManager,
    read_bytes, write_bytes, jsr, wait_for_text,
)

PROJECT_ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
PRG_PATH = os.path.join(PROJECT_ROOT, "build", "x25519.prg")
LABELS_PATH = os.path.join(PROJECT_ROOT, "build", "labels.txt")
CHECKPOINTS_PATH = os.path.join(PROJECT_ROOT, "test", "vector2_ladder_checkpoints.json")

P = (1 << 255) - 19


# ============================================================================
# Field element helpers (same as test_fe25519.py)
# ============================================================================

def int_to_le32(val):
    """Convert integer to 32-byte little-endian bytes."""
    return (val % P).to_bytes(32, "little")


def le32_to_int(data):
    """Convert 32-byte little-endian bytes to integer."""
    return int.from_bytes(data, "little")


def set_fe_ptrs(transport, labels, src1=None, src2=None, dst=None):
    """Set fe_src1, fe_src2, fe_dst zero-page pointers."""
    if src1 is not None:
        write_bytes(transport, labels["fe_src1"],
                    bytes([src1 & 0xFF, src1 >> 8]))
    if src2 is not None:
        write_bytes(transport, labels["fe_src2"],
                    bytes([src2 & 0xFF, src2 >> 8]))
    if dst is not None:
        write_bytes(transport, labels["fe_dst"],
                    bytes([dst & 0xFF, dst >> 8]))


def write_fe(transport, addr, val):
    """Write a field element (integer) to C64 memory as 32-byte LE."""
    write_bytes(transport, addr, int_to_le32(val))


def read_fe(transport, addr):
    """Read a 32-byte LE field element from C64 memory, return as integer."""
    return le32_to_int(read_bytes(transport, addr, 32))


# ============================================================================
# C64 field operations
# ============================================================================

def c64_fe_add(transport, labels, a, b):
    write_fe(transport, labels["fe_tmp1"], a)
    write_fe(transport, labels["fe_tmp2"], b)
    set_fe_ptrs(transport, labels,
                src1=labels["fe_tmp1"],
                src2=labels["fe_tmp2"],
                dst=labels["fe_tmp3"])
    jsr(transport, labels["fe_add"])
    return read_fe(transport, labels["fe_tmp3"])


def c64_fe_sub(transport, labels, a, b):
    write_fe(transport, labels["fe_tmp1"], a)
    write_fe(transport, labels["fe_tmp2"], b)
    set_fe_ptrs(transport, labels,
                src1=labels["fe_tmp1"],
                src2=labels["fe_tmp2"],
                dst=labels["fe_tmp3"])
    jsr(transport, labels["fe_sub"])
    return read_fe(transport, labels["fe_tmp3"])


def c64_fe_mul(transport, labels, a, b):
    write_fe(transport, labels["fe_tmp1"], a)
    write_fe(transport, labels["fe_tmp2"], b)
    set_fe_ptrs(transport, labels,
                src1=labels["fe_tmp1"],
                src2=labels["fe_tmp2"],
                dst=labels["fe_tmp3"])
    jsr(transport, labels["fe_mul"], timeout=120.0)
    return read_fe(transport, labels["fe_tmp3"])


def c64_fe_sqr(transport, labels, a):
    write_fe(transport, labels["fe_tmp1"], a)
    set_fe_ptrs(transport, labels,
                src1=labels["fe_tmp1"],
                dst=labels["fe_tmp3"])
    jsr(transport, labels["fe_sqr"], timeout=120.0)
    return read_fe(transport, labels["fe_tmp3"])


def c64_fe_mul_a24(transport, labels, a):
    write_fe(transport, labels["fe_tmp1"], a)
    set_fe_ptrs(transport, labels,
                src1=labels["fe_tmp1"],
                dst=labels["fe_tmp3"])
    jsr(transport, labels["fe_mul_a24"], timeout=60.0)
    return read_fe(transport, labels["fe_tmp3"])


# ============================================================================
# Montgomery ladder step (all arithmetic on C64)
# ============================================================================

def ladder_step(transport, labels, x2, z2, x3, z3, u):
    """One Montgomery ladder step using C64 field ops."""
    A = c64_fe_add(transport, labels, x2, z2)
    B = c64_fe_sub(transport, labels, x2, z2)
    AA = c64_fe_sqr(transport, labels, A)
    BB = c64_fe_sqr(transport, labels, B)
    E = c64_fe_sub(transport, labels, AA, BB)
    C = c64_fe_add(transport, labels, x3, z3)
    D = c64_fe_sub(transport, labels, x3, z3)
    DA = c64_fe_mul(transport, labels, D, A)
    CB = c64_fe_mul(transport, labels, C, B)
    da_plus_cb = c64_fe_add(transport, labels, DA, CB)
    x3_new = c64_fe_sqr(transport, labels, da_plus_cb)
    da_minus_cb = c64_fe_sub(transport, labels, DA, CB)
    da_minus_cb_sq = c64_fe_sqr(transport, labels, da_minus_cb)
    z3_new = c64_fe_mul(transport, labels, u, da_minus_cb_sq)
    x2_new = c64_fe_mul(transport, labels, AA, BB)
    a24_E = c64_fe_mul_a24(transport, labels, E)
    aa_plus_a24e = c64_fe_add(transport, labels, AA, a24_E)
    z2_new = c64_fe_mul(transport, labels, E, aa_plus_a24e)
    return x2_new, z2_new, x3_new, z3_new


# ============================================================================
# Main test logic
# ============================================================================

def load_checkpoints():
    """Load reference checkpoints from JSON."""
    with open(CHECKPOINTS_PATH) as f:
        data = json.load(f)
    return data


def get_scalar_and_u(data):
    """Return clamped scalar bytes and masked u value."""
    scalar_bytes = bytearray.fromhex(data["scalar_hex"])
    scalar_bytes[0] &= 0xF8
    scalar_bytes[31] = (scalar_bytes[31] & 0x7F) | 0x40

    u_bytes = bytearray.fromhex(data["u_hex"])
    u_bytes[31] &= 0x7F
    u = int.from_bytes(u_bytes, "little")

    return scalar_bytes, u


def get_scalar_bit(scalar_bytes, bit_pos):
    """Extract a single bit from the scalar (little-endian byte order)."""
    byte_idx = bit_pos // 8
    bit_within = bit_pos % 8
    return (scalar_bytes[byte_idx] >> bit_within) & 1


def checkpoint_state(cp):
    """Extract (x2, z2, x3, z3) from a checkpoint dict."""
    return (
        int(cp["x2"], 16),
        int(cp["z2"], 16),
        int(cp["x3"], 16),
        int(cp["z3"], 16),
    )


def run_ladder_range(transport, labels, data, start, count):
    """Run ladder steps [start, start+count) on C64 and compare checkpoints.

    Returns (passed, failed, first_fail_step).
    """
    checkpoints = data["checkpoints"]
    scalar_bytes, u = get_scalar_and_u(data)

    # Initialize state
    if start == 0:
        x2, z2, x3, z3 = 1, 0, u, 1
        prev_bit = 0
    else:
        # Load state from checkpoint at step (start-1)
        prev_cp = checkpoints[start - 1]
        x2, z2, x3, z3 = checkpoint_state(prev_cp)
        prev_bit = prev_cp["bit"]

    passed = 0
    failed = 0
    first_fail_step = None
    end = min(start + count, 255)

    t0 = time.time()

    for step in range(start, end):
        step_t0 = time.time()
        bit_pos = 254 - step
        bit = get_scalar_bit(scalar_bytes, bit_pos)
        swap = bit ^ prev_bit

        # Conditional swap
        if swap:
            x2, x3 = x3, x2
            z2, z3 = z3, z2

        # Ladder step using C64 field ops
        x2, z2, x3, z3 = ladder_step(transport, labels, x2, z2, x3, z3, u)

        # Compare against reference
        ref = checkpoints[step]
        ref_x2, ref_z2, ref_x3, ref_z3 = checkpoint_state(ref)

        step_elapsed = time.time() - step_t0

        if x2 == ref_x2 and z2 == ref_z2 and x3 == ref_x3 and z3 == ref_z3:
            passed += 1
            print(f"  Step {step:3d} (bit[{bit_pos}]={bit}): OK  ({step_elapsed:.1f}s)")
        else:
            failed += 1
            if first_fail_step is None:
                first_fail_step = step
            print(f"  Step {step:3d} (bit[{bit_pos}]={bit}): FAIL  ({step_elapsed:.1f}s)")
            if x2 != ref_x2:
                print(f"    x2 expected: {ref_x2:#066x}")
                print(f"    x2 got:      {x2:#066x}")
            if z2 != ref_z2:
                print(f"    z2 expected: {ref_z2:#066x}")
                print(f"    z2 got:      {z2:#066x}")
            if x3 != ref_x3:
                print(f"    x3 expected: {ref_x3:#066x}")
                print(f"    x3 got:      {x3:#066x}")
            if z3 != ref_z3:
                print(f"    z3 expected: {ref_z3:#066x}")
                print(f"    z3 got:      {z3:#066x}")
            # Stop on first failure
            print(f"\n  Stopping at first failure (step {step}).")
            break

        prev_bit = bit

    total_elapsed = time.time() - t0
    print(f"\n  Elapsed: {total_elapsed:.1f}s ({passed + failed} steps, "
          f"{total_elapsed / max(passed + failed, 1):.1f}s/step avg)")

    return passed, failed, first_fail_step


def main():
    os.chdir(PROJECT_ROOT)

    # Parse arguments
    start = 0
    count = 10
    seed = 42  # unused but accepted for consistency

    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--start" and i + 1 < len(args):
            start = int(args[i + 1])
            i += 2
        elif args[i] == "--count" and i + 1 < len(args):
            count = int(args[i + 1])
            i += 2
        elif args[i] == "--seed" and i + 1 < len(args):
            seed = int(args[i + 1])
            i += 2
        else:
            print(f"Unknown argument: {args[i]}")
            i += 1

    print(f"Montgomery ladder checkpoint test")
    print(f"  Steps: {start} to {min(start + count, 255) - 1}")
    print(f"  RFC 7748 vector 2")
    print()

    # Load reference checkpoints
    data = load_checkpoints()
    print(f"Loaded {len(data['checkpoints'])} reference checkpoints")

    # Verify reference data integrity
    if not data.get("match", False):
        print("WARNING: Reference data result does not match expected!")

    # Load labels
    labels = Labels.from_file(LABELS_PATH)
    required = [
        "fe_src1", "fe_src2", "fe_dst",
        "fe_add", "fe_sub", "fe_mul", "fe_sqr", "fe_mul_a24",
        "fe_tmp1", "fe_tmp2", "fe_tmp3",
    ]
    for name in required:
        if labels.address(name) is None:
            print(f"FATAL: '{name}' label not found in {LABELS_PATH}")
            sys.exit(1)
    print(f"Labels loaded: {len(required)} required labels verified")

    # Launch VICE
    config = ViceConfig(prg_path=PRG_PATH, warp=True, ntsc=True, sound=False)

    with ViceInstanceManager(config=config) as mgr:
        inst = mgr.acquire()
        print(f"VICE PID={inst.pid}, port={inst.port}")

        transport = inst.transport
        grid = wait_for_text(transport, "Q=QUIT", timeout=60.0, verbose=False)
        if grid is None:
            print("FATAL: Main menu did not appear")
            sys.exit(1)

        print("VICE ready\n")

        # Safety trampoline: JMP $0339 at $0339
        write_bytes(transport, 0x0339, bytes([0x4C, 0x39, 0x03]))

        print(f"Running ladder steps {start}..{min(start + count, 255) - 1}:")
        passed, failed, first_fail = run_ladder_range(
            transport, labels, data, start, count
        )

        mgr.release(inst)

    print(f"\n{'=' * 60}")
    print(f"Results: {passed}/{passed + failed} steps passed, {failed} failed")
    if first_fail is not None:
        print(f"First failure at step {first_fail}")
    print(f"{'=' * 60}")

    sys.exit(0 if failed == 0 else 1)


if __name__ == "__main__":
    main()
