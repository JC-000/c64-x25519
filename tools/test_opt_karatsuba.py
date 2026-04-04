#!/usr/bin/env python3
"""test_opt_karatsuba.py — Tests for Karatsuba fe_mul optimization.

Tests fe_mul correctness with extensive cases including edge cases
for the Karatsuba split (zero halves, max values, carries across halves).
Also verifies fe_sqr and fe_mul_a24 still work, and benchmarks fe_mul.

Usage:
    python3 tools/test_opt_karatsuba.py [--seed S] [--verbose]
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
    jsr(transport, labels["fe_reduce_final"], timeout=5.0)
    return read_fe(transport, labels["fe_tmp3"])


def c64_fe_sqr(transport, labels, a):
    write_fe(transport, labels["fe_tmp1"], a)
    set_fe_ptrs(transport, labels,
                src1=labels["fe_tmp1"],
                dst=labels["fe_tmp3"])
    jsr(transport, labels["fe_sqr"], timeout=120.0)
    jsr(transport, labels["fe_reduce_final"], timeout=5.0)
    return read_fe(transport, labels["fe_tmp3"])


def c64_fe_mul_a24(transport, labels, a):
    write_fe(transport, labels["fe_tmp1"], a)
    set_fe_ptrs(transport, labels,
                src1=labels["fe_tmp1"],
                dst=labels["fe_tmp3"])
    jsr(transport, labels["fe_mul_a24"], timeout=60.0)
    return read_fe(transport, labels["fe_tmp3"])


# ============================================================================
# Test functions
# ============================================================================

def test_fe_mul(transport, labels, rng):
    """Test fe_mul with basic, edge, and random cases."""
    passed = failed = 0

    cases = [
        ("0*0", 0, 0),
        ("0*1", 0, 1),
        ("1*0", 1, 0),
        ("1*1", 1, 1),
        ("2*3", 2, 3),
        ("a*0", rand_fe(rng), 0),
        ("0*a", 0, rand_fe(rng)),
        ("1*a", 1, rand_fe(rng)),
        ("a*1", rand_fe(rng), 1),
    ]

    # Edge cases for Karatsuba split
    # Values with all-zero low half (bytes 0-15 = 0)
    hi_only_a = rng.randint(1, (1 << 128) - 1) << 128
    hi_only_a = hi_only_a % P
    hi_only_b = rng.randint(1, (1 << 128) - 1) << 128
    hi_only_b = hi_only_b % P
    cases.append(("hi_only * hi_only", hi_only_a, hi_only_b))

    # Values with all-zero high half (bytes 16-31 = 0)
    lo_only_a = rng.randint(1, (1 << 128) - 1)
    lo_only_b = rng.randint(1, (1 << 128) - 1)
    cases.append(("lo_only * lo_only", lo_only_a, lo_only_b))

    # Mix: one has zero low, other has zero high
    cases.append(("hi_only * lo_only", hi_only_a, lo_only_b))
    cases.append(("lo_only * hi_only", lo_only_a, hi_only_b))

    # Values near P (all bytes 0xFF-ish)
    cases.append(("(P-1)*(P-1)", P - 1, P - 1))
    cases.append(("(P-1)*2", P - 1, 2))
    cases.append(("(P-2)*(P-3)", P - 2, P - 3))

    # Values that maximize carry in aL+aH (all 0xFF bytes)
    max_bytes = int.from_bytes(b'\xff' * 32, 'little') % P
    cases.append(("max_bytes * max_bytes", max_bytes, max_bytes))

    # Value where aL = aH = 0xFF * 16 bytes (maximizes sum carry)
    sym_val = int.from_bytes(b'\xff' * 16 + b'\xff' * 16, 'little') % P
    cases.append(("symmetric_ff * symmetric_ff", sym_val, sym_val))

    # 15+ random pairs
    for i in range(18):
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
            print(f"    a = {a:#066x}")
            print(f"    b = {b:#066x}")
            print(f"    expected = {expected:#066x}")
            print(f"    got      = {result:#066x}")

    return passed, failed


def test_fe_sqr(transport, labels, rng):
    """Test fe_sqr still works correctly (it calls fe_mul)."""
    passed = failed = 0

    cases = [
        ("0", 0),
        ("1", 1),
        ("2", 2),
        ("P-1", P - 1),
    ]
    for i in range(5):
        cases.append((f"random #{i}", rand_fe(rng)))

    for name, a in cases:
        expected = fe_sqr_ref(a)
        result = c64_fe_sqr(transport, labels, a)
        if result == expected:
            passed += 1
            if VERBOSE:
                print(f"  PASS sqr {name}")
        else:
            failed += 1
            print(f"  FAIL sqr {name}:")
            print(f"    a = {a:#066x}")
            print(f"    expected = {expected:#066x}")
            print(f"    got      = {result:#066x}")

    return passed, failed


def test_fe_mul_a24(transport, labels, rng):
    """Test fe_mul_a24 still works (doesn't use fe_mul, but verify nothing broke)."""
    passed = failed = 0

    cases = [0, 1, 2, 121665, P - 1]
    for i in range(3):
        cases.append(rand_fe(rng))

    for i, a in enumerate(cases):
        expected = fe_mul_a24_ref(a)
        result = c64_fe_mul_a24(transport, labels, a)
        if result == expected:
            passed += 1
            if VERBOSE:
                print(f"  PASS mul_a24 #{i}")
        else:
            failed += 1
            print(f"  FAIL mul_a24 #{i}: a={a:#066x}")
            print(f"    expected = {expected:#066x}")
            print(f"    got      = {result:#066x}")

    return passed, failed


def bench_fe_mul(transport, labels, rng, iterations=3):
    """Benchmark fe_mul timing."""
    print(f"\n--- fe_mul benchmark ({iterations} iterations) ---")
    ticks_list = []

    for i in range(iterations):
        a = rng.randint(1, P - 1)
        b = rng.randint(1, P - 1)

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
        ticks_list.append(ticks)
        ms = ticks * 1000 / 60  # NTSC: 60 Hz jiffy clock
        print(f"  fe_mul #{i}: {ticks} jiffies ({ms:.0f} ms)")

    avg = sum(ticks_list) / len(ticks_list)
    print(f"  Average: {avg:.1f} jiffies ({avg * 1000 / 60:.0f} ms)")
    return avg


# ============================================================================
# Main
# ============================================================================

def run_tests(transport, labels, seed):
    rng = random.Random(seed)
    total_passed = 0
    total_failed = 0

    test_groups = [
        ("fe_mul (Karatsuba)", lambda: test_fe_mul(transport, labels, rng)),
        ("fe_sqr (via Karatsuba)", lambda: test_fe_sqr(transport, labels, rng)),
        ("fe_mul_a24 (unchanged)", lambda: test_fe_mul_a24(transport, labels, rng)),
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

    # Benchmark
    bench_fe_mul(transport, labels, rng)

    return total_passed, total_failed


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

    random.seed(seed)
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
        "fe_mul", "fe_sqr", "fe_mul_a24",
        "fe_tmp1", "fe_tmp2", "fe_tmp3",
        "fe_wide",
        "bench_start", "bench_stop", "bench_ticks",
        "input_buffer",
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

        # Safety: write JMP $0339 at $0339 so CPU loops harmlessly
        write_bytes(transport, 0x0339, bytes([0x4C, 0x39, 0x03]))

        passed, failed = run_tests(transport, labels, seed)

        mgr.release(inst)

    total = passed + failed
    print(f"\n{'='*60}")
    print(f"Results: {passed}/{total} passed, {failed} failed")
    print(f"{'='*60}")
    sys.exit(0 if failed == 0 else 1)


if __name__ == "__main__":
    main()
