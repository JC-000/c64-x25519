#!/usr/bin/env python3
"""test_opt_fast_mul.py -- Test and benchmark optimized inlined fe_mul.

Tests fe_mul correctness against Python reference for edge cases and random
inputs. Also verifies fe_sqr and fe_mul_a24 still work (they depend on
mul_8x8 or fe_mul). Benchmarks fe_mul with jiffy clock timing.

Usage:
    python3 tools/test_opt_fast_mul.py [--seed S] [--verbose]
"""

import os
import random
import subprocess
import sys
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


# ============================================================================
# Python reference
# ============================================================================

def fe_mul_ref(a, b):
    return (a * b) % P

def fe_sqr_ref(a):
    return (a * a) % P

def fe_mul_a24_ref(a):
    return (a * 121665) % P


def int_to_le32(val):
    return (val % P).to_bytes(32, "little")

def le32_to_int(data):
    return int.from_bytes(data, "little")

def rand_fe(rng):
    return rng.randint(0, P - 1)


# ============================================================================
# C64 helper functions
# ============================================================================

def set_fe_ptrs(transport, labels, src1=None, src2=None, dst=None):
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
    write_bytes(transport, addr, int_to_le32(val))


def read_fe(transport, addr):
    return le32_to_int(read_bytes(transport, addr, 32))


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


def bench_fe_mul(transport, labels, a, b):
    """Time a single fe_mul call in jiffy ticks."""
    write_fe(transport, labels["fe_tmp1"], a)
    write_fe(transport, labels["fe_tmp2"], b)
    set_fe_ptrs(transport, labels,
                src1=labels["fe_tmp1"],
                src2=labels["fe_tmp2"],
                dst=labels["fe_tmp3"])

    jsr(transport, labels["bench_start"])
    jsr(transport, labels["fe_mul"], timeout=120.0)
    jsr(transport, labels["bench_stop"])

    ticks_data = read_bytes(transport, labels["bench_ticks"], 3)
    ticks = (ticks_data[0] << 16) | (ticks_data[1] << 8) | ticks_data[2]
    return ticks


# ============================================================================
# Test functions
# ============================================================================

def test_fe_mul(transport, labels, rng):
    """Test fe_mul with edge cases and random inputs."""
    passed = failed = 0

    cases = [
        ("0*0", 0, 0),
        ("0*1", 0, 1),
        ("1*0", 1, 0),
        ("1*1", 1, 1),
        ("2*3", 2, 3),
        ("255*255", 255, 255),
        ("a*0", rand_fe(rng), 0),
        ("0*b", 0, rand_fe(rng)),
        ("1*random", 1, rand_fe(rng)),
        ("random*1", rand_fe(rng), 1),
    ]

    # Add 10 random pairs
    for i in range(10):
        a, b = rand_fe(rng), rand_fe(rng)
        cases.append((f"random #{i}", a, b))

    for name, a, b in cases:
        expected = fe_mul_ref(a, b)
        result = c64_fe_mul(transport, labels, a, b)
        if result == expected:
            passed += 1
            if VERBOSE:
                print(f"  PASS mul {name}")
        else:
            failed += 1
            print(f"  FAIL mul {name}:")
            print(f"    a = {a}")
            print(f"    b = {b}")
            print(f"    expected = {expected}")
            print(f"    got      = {result}")

    return passed, failed


def test_fe_sqr(transport, labels, rng):
    """Test fe_sqr still works (calls fe_mul internally)."""
    passed = failed = 0

    cases = [0, 1, 2, P - 1, rand_fe(rng), rand_fe(rng), rand_fe(rng)]

    for i, a in enumerate(cases):
        expected = fe_sqr_ref(a)
        result = c64_fe_sqr(transport, labels, a)
        if result == expected:
            passed += 1
            if VERBOSE:
                print(f"  PASS sqr #{i}")
        else:
            failed += 1
            print(f"  FAIL sqr #{i}: a={a}, expected={expected}, got={result}")

    return passed, failed


def test_fe_mul_a24(transport, labels, rng):
    """Test fe_mul_a24 still works (calls mul_8x8 directly)."""
    passed = failed = 0

    cases = [0, 1, 2, 121665, P - 1, rand_fe(rng), rand_fe(rng), rand_fe(rng)]

    for i, a in enumerate(cases):
        expected = fe_mul_a24_ref(a)
        result = c64_fe_mul_a24(transport, labels, a)
        if result == expected:
            passed += 1
            if VERBOSE:
                print(f"  PASS mul_a24 #{i}")
        else:
            failed += 1
            print(f"  FAIL mul_a24 #{i}: a={a}, expected={expected}, got={result}")

    return passed, failed


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
    print("Building...")
    subprocess.run(["make", "clean"], capture_output=True, cwd=PROJECT_ROOT)
    result = subprocess.run(["make"], capture_output=True, text=True,
                            cwd=PROJECT_ROOT)
    if result.returncode != 0:
        print(f"Build failed:\n{result.stderr}")
        sys.exit(1)
    print(f"Built: {PRG_PATH}")

    labels = Labels.from_file(LABELS_PATH)
    required = [
        "fe_src1", "fe_src2", "fe_dst",
        "fe_mul", "fe_sqr", "fe_mul_a24",
        "fe_tmp1", "fe_tmp2", "fe_tmp3",
        "bench_start", "bench_stop", "bench_ticks",
    ]
    for name in required:
        if labels.address(name) is None:
            print(f"FATAL: '{name}' label not found in {LABELS_PATH}")
            sys.exit(1)
    print(f"Labels loaded: {len(required)} required labels verified")

    # Launch VICE
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

        print("VICE ready, running tests...")

        # Safety loop
        write_bytes(transport, 0x0339, bytes([0x4C, 0x39, 0x03]))

        total_passed = 0
        total_failed = 0

        # --- Correctness tests ---
        test_groups = [
            ("fe_mul", lambda: test_fe_mul(transport, labels, rng)),
            ("fe_sqr", lambda: test_fe_sqr(transport, labels, rng)),
            ("fe_mul_a24", lambda: test_fe_mul_a24(transport, labels, rng)),
        ]

        for name, test_fn in test_groups:
            print(f"\n--- {name} ---")
            try:
                p, f = test_fn()
                total_passed += p
                total_failed += f
                status = "OK" if f == 0 else "FAIL"
                print(f"  {status}: {p}/{p + f} passed")
            except Exception as e:
                total_failed += 1
                print(f"  ERROR: {e}")
                import traceback
                traceback.print_exc()

        # --- Benchmark ---
        print(f"\n--- fe_mul benchmark (5 iterations) ---")
        bench_rng = random.Random(25519)
        mul_ticks = []
        for i in range(5):
            a = bench_rng.randint(1, P - 1)
            b = bench_rng.randint(1, P - 1)
            ticks = bench_fe_mul(transport, labels, a, b)
            mul_ticks.append(ticks)
            ms = ticks * 1000 / 60
            print(f"  fe_mul #{i}: {ticks} jiffies ({ms:.0f} ms)")

        avg_mul = sum(mul_ticks) / len(mul_ticks)
        print(f"  Average: {avg_mul:.1f} jiffies ({avg_mul * 1000 / 60:.0f} ms)")

        # Estimate X25519 time
        est_muls = 1031
        est_sqrs = 763
        est_total = (est_muls + est_sqrs) * avg_mul  # sqr = mul for estimation
        est_sec = est_total / 60
        print(f"\n--- Estimated full X25519 time ---")
        print(f"  {est_muls + est_sqrs} mul+sqr ops x {avg_mul:.1f} jiffies avg")
        print(f"  = {est_total:.0f} jiffies = {est_sec:.0f}s = {est_sec/60:.1f} min")

        mgr.release(inst)

    total = total_passed + total_failed
    print(f"\n{'='*60}")
    print(f"Results: {total_passed}/{total} passed, {total_failed} failed")
    print(f"{'='*60}")
    sys.exit(0 if total_failed == 0 else 1)


if __name__ == "__main__":
    main()
