#!/usr/bin/env python3
"""test_opt_sqr.py — Test and benchmark the dedicated fe_sqr routine.

Tests:
  1. fe_sqr against Python reference for: 0, 1, 2, P-1, and 10 random values
  2. fe_sqr(a) == fe_mul(a, a) cross-check for several random values
  3. Benchmark fe_sqr vs fe_mul(a,a) to measure speedup

Usage:
    python3 tools/test_opt_sqr.py [--seed S] [--verbose]
"""

import os
import random
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

VERBOSE = False

# p = 2^255 - 19
P = (1 << 255) - 19


def robust_jsr(transport, addr, timeout=10.0, retries=3, poll_interval=0.2):
    """jsr() with retry for transient VICE connection failures."""
    for attempt in range(retries):
        try:
            return jsr(transport, addr, timeout=timeout, poll_interval=poll_interval)
        except Exception as e:
            if attempt < retries - 1:
                time.sleep(0.5)
                continue
            raise


def int_to_le32(val):
    """Convert integer to 32-byte little-endian bytes."""
    return (val % P).to_bytes(32, "little")


def le32_to_int(data):
    """Convert 32-byte little-endian bytes to integer."""
    return int.from_bytes(data, "little")


def rand_fe(rng):
    """Generate a random field element in [0, p-1]."""
    return rng.randint(0, P - 1)


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


def c64_fe_sqr(transport, labels, a):
    """Compute a^2 mod p on C64 via fe_sqr."""
    write_fe(transport, labels["fe_tmp1"], a)
    set_fe_ptrs(transport, labels,
                src1=labels["fe_tmp1"],
                dst=labels["fe_tmp3"])
    robust_jsr(transport, labels["fe_sqr"], timeout=120.0, poll_interval=2.0)
    return read_fe(transport, labels["fe_tmp3"])


def c64_fe_mul(transport, labels, a, b):
    """Compute a * b mod p on C64 via fe_mul."""
    write_fe(transport, labels["fe_tmp1"], a)
    write_fe(transport, labels["fe_tmp2"], b)
    set_fe_ptrs(transport, labels,
                src1=labels["fe_tmp1"],
                src2=labels["fe_tmp2"],
                dst=labels["fe_tmp3"])
    robust_jsr(transport, labels["fe_mul"], timeout=120.0, poll_interval=2.0)
    return read_fe(transport, labels["fe_tmp3"])


def bench_call(transport, labels, setup_fn, call_label, timeout=120.0):
    """Time a single call in jiffy ticks using bench_start/bench_stop."""
    setup_fn()
    robust_jsr(transport, labels["bench_start"])
    robust_jsr(transport, call_label, timeout=timeout, poll_interval=2.0)
    robust_jsr(transport, labels["bench_stop"])
    ticks_data = read_bytes(transport, labels["bench_ticks"], 3)
    ticks = (ticks_data[0] << 16) | (ticks_data[1] << 8) | ticks_data[2]
    return ticks


# ============================================================================
# Tests
# ============================================================================

def test_sqr_reference(transport, labels, rng):
    """Test fe_sqr against Python reference."""
    passed = failed = 0

    # Fixed test cases
    cases = [
        ("0", 0),
        ("1", 1),
        ("2", 2),
        ("P-1", P - 1),
    ]
    # Add 10 random cases
    for i in range(10):
        cases.append((f"random #{i}", rand_fe(rng)))

    for name, a in cases:
        expected = (a * a) % P
        result = c64_fe_sqr(transport, labels, a)
        if result == expected:
            passed += 1
            if VERBOSE:
                print(f"  PASS sqr ref {name}")
        else:
            failed += 1
            print(f"  FAIL sqr ref {name}:")
            print(f"    a        = {a}")
            print(f"    expected = {expected}")
            print(f"    got      = {result}")

    return passed, failed


def test_sqr_vs_mul(transport, labels, rng):
    """Test fe_sqr(a) == fe_mul(a, a) for random values."""
    passed = failed = 0

    for i in range(5):
        a = rand_fe(rng)
        sqr_result = c64_fe_sqr(transport, labels, a)
        mul_result = c64_fe_mul(transport, labels, a, a)
        if sqr_result == mul_result:
            passed += 1
            if VERBOSE:
                print(f"  PASS sqr_vs_mul #{i}")
        else:
            failed += 1
            print(f"  FAIL sqr_vs_mul #{i}:")
            print(f"    a          = {a}")
            print(f"    fe_sqr(a)  = {sqr_result}")
            print(f"    fe_mul(a,a)= {mul_result}")

    return passed, failed


def bench_sqr_vs_mul(transport, labels, rng, iterations=5):
    """Benchmark fe_sqr vs fe_mul(a,a) and report speedup."""
    print(f"\n--- Benchmark ({iterations} iterations) ---")

    sqr_ticks_list = []
    mul_ticks_list = []

    for i in range(iterations):
        a = rng.randint(1, P - 1)

        # Benchmark fe_sqr
        def setup_sqr():
            write_fe(transport, labels["fe_tmp1"], a)
            set_fe_ptrs(transport, labels,
                        src1=labels["fe_tmp1"],
                        dst=labels["fe_tmp3"])

        sqr_ticks = bench_call(transport, labels, setup_sqr, labels["fe_sqr"])
        sqr_ticks_list.append(sqr_ticks)

        # Benchmark fe_mul(a, a)
        def setup_mul():
            write_fe(transport, labels["fe_tmp1"], a)
            write_fe(transport, labels["fe_tmp2"], a)
            set_fe_ptrs(transport, labels,
                        src1=labels["fe_tmp1"],
                        src2=labels["fe_tmp2"],
                        dst=labels["fe_tmp3"])

        mul_ticks = bench_call(transport, labels, setup_mul, labels["fe_mul"])
        mul_ticks_list.append(mul_ticks)

        sqr_ms = sqr_ticks * 1000 / 60
        mul_ms = mul_ticks * 1000 / 60
        print(f"  #{i}: fe_sqr={sqr_ticks} jiffies ({sqr_ms:.0f}ms), "
              f"fe_mul={mul_ticks} jiffies ({mul_ms:.0f}ms)")

    avg_sqr = sum(sqr_ticks_list) / len(sqr_ticks_list)
    avg_mul = sum(mul_ticks_list) / len(mul_ticks_list)
    speedup = avg_mul / avg_sqr if avg_sqr > 0 else 0

    print(f"\n  Average fe_sqr: {avg_sqr:.1f} jiffies ({avg_sqr * 1000 / 60:.0f}ms)")
    print(f"  Average fe_mul: {avg_mul:.1f} jiffies ({avg_mul * 1000 / 60:.0f}ms)")
    print(f"  Speedup: {speedup:.2f}x")

    # Estimate X25519 impact
    # 255 ladder steps: 4 mul + 2 sqr each, plus inversion: 11 mul + 253 sqr
    est_muls = 255 * 4 + 11  # 1031
    est_sqrs = 255 * 2 + 253  # 763
    old_total = (est_muls + est_sqrs) * avg_mul  # old: sqr == mul
    new_total = est_muls * avg_mul + est_sqrs * avg_sqr
    savings = old_total - new_total
    print(f"\n  Estimated X25519 savings: {savings:.0f} jiffies "
          f"({savings / 60:.0f}s)")


# ============================================================================
# Main
# ============================================================================

def main():
    global VERBOSE
    os.chdir(PROJECT_ROOT)

    seed = random.randint(0, 2**32 - 1)
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--seed" and i + 1 < len(args):
            seed = int(args[i + 1])
            i += 2
        elif args[i] == "--verbose":
            VERBOSE = True
            i += 1
        else:
            i += 1

    rng = random.Random(seed)
    print(f"Random seed: {seed} (reproduce with --seed {seed})")

    # Build
    if not os.environ.get("C64_SKIP_BUILD"):
        print("Building...")
        subprocess.run(["make", "clean"], capture_output=True, cwd=PROJECT_ROOT)
        result = subprocess.run(["make"], capture_output=True, text=True,
                                cwd=PROJECT_ROOT)
        if result.returncode != 0:
            print(f"Build failed:\n{result.stderr}")
            sys.exit(1)
    print(f"Built: {PRG_PATH}")

    # Load labels
    labels = Labels.from_file(LABELS_PATH)
    required = [
        "fe_src1", "fe_src2", "fe_dst",
        "fe_mul", "fe_sqr",
        "fe_tmp1", "fe_tmp2", "fe_tmp3",
        "fe_wide",
        "bench_start", "bench_stop", "bench_ticks",
    ]
    for name in required:
        if labels.address(name) is None:
            print(f"FATAL: '{name}' label not found in {LABELS_PATH}")
            sys.exit(1)
    print(f"Labels loaded: {len(required)} required labels verified")

    # Launch VICE
    config = ViceConfig(prg_path=PRG_PATH, warp=True, ntsc=True, sound=False)

    with ViceInstanceManager(
        config=config,
        port_range_start=6510,
        port_range_end=6530,
    ) as mgr:
        inst = mgr.acquire()
        print(f"VICE PID={inst.pid}, port={inst.port}")

        transport = inst.transport
        grid = wait_for_text(transport, "Q=QUIT", timeout=60.0, verbose=False)
        if grid is None:
            print("FATAL: Main menu did not appear")
            sys.exit(1)

        print("VICE ready, running tests...")

        # Safety: write JMP $0339 at $0339 so CPU loops harmlessly
        write_bytes(transport, 0x0339, bytes([0x4C, 0x39, 0x03]))

        total_passed = 0
        total_failed = 0

        # Test 1: fe_sqr vs Python reference
        print("\n--- fe_sqr vs Python reference ---")
        p, f = test_sqr_reference(transport, labels, rng)
        total_passed += p
        total_failed += f
        status = "OK" if f == 0 else "FAIL"
        print(f"  {status}: {p}/{p + f} passed")

        # Test 2: fe_sqr vs fe_mul cross-check
        print("\n--- fe_sqr vs fe_mul(a,a) cross-check ---")
        p, f = test_sqr_vs_mul(transport, labels, rng)
        total_passed += p
        total_failed += f
        status = "OK" if f == 0 else "FAIL"
        print(f"  {status}: {p}/{p + f} passed")

        # Test 3: Benchmark
        if total_failed == 0:
            bench_sqr_vs_mul(transport, labels, rng)
        else:
            print("\nSkipping benchmark due to test failures.")

        mgr.release(inst)

    total = total_passed + total_failed
    print(f"\n{'='*60}")
    print(f"Results: {total_passed}/{total} passed, {total_failed} failed")
    print(f"{'='*60}")
    sys.exit(0 if total_failed == 0 else 1)


if __name__ == "__main__":
    main()
