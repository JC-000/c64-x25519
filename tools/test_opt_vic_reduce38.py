#!/usr/bin/env python3
"""test_opt_vic_reduce38.py — Test VIC-II blanking + mul_by_38 optimizations.

Verifies:
1. vic_blank/vic_unblank labels exist and routines work
2. Full fe25519 correctness suite (fe_add, fe_sub, fe_mul, fe_sqr,
   fe_mul_a24, fe_inv(1), fe_cswap, etc.) to ensure mul_by_38 is correct
3. Benchmarks fe_mul with and without VIC blanking

Usage:
    python3 tools/test_opt_vic_reduce38.py [--seed S] [--verbose]
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

def fe_add_ref(a, b):
    return (a + b) % P

def fe_sub_ref(a, b):
    return (a - b) % P

def fe_mul_ref(a, b):
    return (a * b) % P

def fe_sqr_ref(a):
    return (a * a) % P

def fe_inv_ref(a):
    return pow(a, P - 2, P)

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


def c64_fe_inv(transport, labels, a):
    write_fe(transport, labels["fe_tmp1"], a)
    set_fe_ptrs(transport, labels,
                src1=labels["fe_tmp1"],
                dst=labels["fe_tmp3"])
    jsr(transport, labels["fe_inv"], timeout=600.0)
    return read_fe(transport, labels["fe_tmp3"])


def c64_fe_mul_a24(transport, labels, a):
    write_fe(transport, labels["fe_tmp1"], a)
    set_fe_ptrs(transport, labels,
                src1=labels["fe_tmp1"],
                dst=labels["fe_tmp3"])
    jsr(transport, labels["fe_mul_a24"], timeout=60.0)
    return read_fe(transport, labels["fe_tmp3"])


def c64_fe_copy(transport, labels, a):
    write_fe(transport, labels["fe_tmp1"], a)
    set_fe_ptrs(transport, labels,
                src1=labels["fe_tmp1"],
                dst=labels["fe_tmp3"])
    jsr(transport, labels["fe_copy"])
    return read_fe(transport, labels["fe_tmp3"])


def c64_fe_zero(transport, labels):
    write_fe(transport, labels["fe_tmp3"], P - 1)
    set_fe_ptrs(transport, labels, dst=labels["fe_tmp3"])
    jsr(transport, labels["fe_zero"])
    return read_fe(transport, labels["fe_tmp3"])


def c64_fe_one(transport, labels):
    write_fe(transport, labels["fe_tmp3"], P - 1)
    set_fe_ptrs(transport, labels, dst=labels["fe_tmp3"])
    jsr(transport, labels["fe_one"])
    return read_fe(transport, labels["fe_tmp3"])


# ============================================================================
# Test functions
# ============================================================================

def test_vic_labels(labels):
    """Verify vic_blank/vic_unblank labels exist."""
    passed = failed = 0
    for name in ["vic_blank", "vic_unblank"]:
        addr = labels.address(name)
        if addr is not None:
            passed += 1
            if VERBOSE:
                print(f"  PASS {name} at ${addr:04X}")
        else:
            failed += 1
            print(f"  FAIL {name} label not found")
        assert addr is not None, f"{name} label not found"
    return passed, failed


def test_vic_blank_unblank(transport, labels):
    """Test that vic_blank clears DEN bit and vic_unblank sets it."""
    passed = failed = 0

    # Read initial $d011 value
    initial = read_bytes(transport, 0xd011, 1)[0]

    # Blank: should clear bit 4
    jsr(transport, labels["vic_blank"])
    after_blank = read_bytes(transport, 0xd011, 1)[0]
    if (after_blank & 0x10) == 0:
        passed += 1
        if VERBOSE:
            print(f"  PASS vic_blank: $d011=${after_blank:02X} (DEN=0)")
    else:
        failed += 1
        print(f"  FAIL vic_blank: $d011=${after_blank:02X} (DEN still set)")
    assert (after_blank & 0x10) == 0, (
        f"vic_blank: $d011=${after_blank:02X} (DEN still set)"
    )

    # Unblank: should set bit 4
    jsr(transport, labels["vic_unblank"])
    after_unblank = read_bytes(transport, 0xd011, 1)[0]
    if (after_unblank & 0x10) != 0:
        passed += 1
        if VERBOSE:
            print(f"  PASS vic_unblank: $d011=${after_unblank:02X} (DEN=1)")
    else:
        failed += 1
        print(f"  FAIL vic_unblank: $d011=${after_unblank:02X} (DEN still clear)")
    assert (after_unblank & 0x10) != 0, (
        f"vic_unblank: $d011=${after_unblank:02X} (DEN still clear)"
    )

    return passed, failed


def test_copy_zero_one(transport, labels):
    passed = failed = 0
    result = c64_fe_zero(transport, labels)
    if result == 0:
        passed += 1
        if VERBOSE: print("  PASS fe_zero")
    else:
        failed += 1
        print(f"  FAIL fe_zero: got {result}")
    assert result == 0, f"fe_zero: got {result}"

    result = c64_fe_one(transport, labels)
    if result == 1:
        passed += 1
        if VERBOSE: print("  PASS fe_one")
    else:
        failed += 1
        print(f"  FAIL fe_one: got {result}")
    assert result == 1, f"fe_one: got {result}"

    test_val = 0xDEADBEEF_CAFEBABE_12345678_9ABCDEF0
    result = c64_fe_copy(transport, labels, test_val)
    if result == test_val:
        passed += 1
        if VERBOSE: print("  PASS fe_copy")
    else:
        failed += 1
        print(f"  FAIL fe_copy: expected {test_val:#x}, got {result:#x}")
    assert result == test_val, f"fe_copy: expected {test_val:#x} got {result:#x}"

    return passed, failed


def test_add(transport, labels, rng):
    passed = failed = 0
    cases = [
        ("0+0", 0, 0),
        ("0+1", 0, 1),
        ("1+1", 1, 1),
        ("p-1+1", P - 1, 1),
        ("p-1+p-1", P - 1, P - 1),
        ("large+large", P - 10, 15),
    ]
    for i in range(6):
        a, b = rand_fe(rng), rand_fe(rng)
        cases.append((f"random #{i}", a, b))

    for name, a, b in cases:
        expected = fe_add_ref(a, b)
        result = c64_fe_add(transport, labels, a, b)
        if result == expected:
            passed += 1
            if VERBOSE: print(f"  PASS add {name}")
        else:
            failed += 1
            print(f"  FAIL add {name}: expected {expected}, got {result}")
        assert result == expected, (
            f"add {name}: expected {expected} got {result}"
        )
    return passed, failed


def test_sub(transport, labels, rng):
    passed = failed = 0
    cases = [
        ("0-0", 0, 0),
        ("1-0", 1, 0),
        ("1-1", 1, 1),
        ("0-1", 0, 1),
        ("10-20", 10, 20),
        ("p-1-0", P - 1, 0),
    ]
    for i in range(6):
        a, b = rand_fe(rng), rand_fe(rng)
        cases.append((f"random #{i}", a, b))

    for name, a, b in cases:
        expected = fe_sub_ref(a, b)
        result = c64_fe_sub(transport, labels, a, b)
        if result == expected:
            passed += 1
            if VERBOSE: print(f"  PASS sub {name}")
        else:
            failed += 1
            print(f"  FAIL sub {name}: expected {expected}, got {result}")
        assert result == expected, (
            f"sub {name}: expected {expected} got {result}"
        )
    return passed, failed


def test_mul(transport, labels, rng):
    passed = failed = 0
    cases = [
        ("0*0", 0, 0),
        ("0*1", 0, 1),
        ("1*1", 1, 1),
        ("2*3", 2, 3),
        ("a*0", rand_fe(rng), 0),
        ("1*a", 1, rand_fe(rng)),
    ]
    for i in range(4):
        a, b = rand_fe(rng), rand_fe(rng)
        cases.append((f"random #{i}", a, b))

    for name, a, b in cases:
        expected = fe_mul_ref(a, b)
        result = c64_fe_mul(transport, labels, a, b)
        if result == expected:
            passed += 1
            if VERBOSE: print(f"  PASS mul {name}")
        else:
            failed += 1
            print(f"  FAIL mul {name}:")
            print(f"    a = {a}")
            print(f"    b = {b}")
            print(f"    expected = {expected}")
            print(f"    got      = {result}")
        assert result == expected, (
            f"mul {name}: a={a} b={b} expected={expected} got={result}"
        )
    return passed, failed


def test_sqr(transport, labels, rng):
    passed = failed = 0
    cases = [0, 1, 2, P - 1, rand_fe(rng), rand_fe(rng), rand_fe(rng)]
    for i, a in enumerate(cases):
        expected = fe_sqr_ref(a)
        result = c64_fe_sqr(transport, labels, a)
        if result == expected:
            passed += 1
            if VERBOSE: print(f"  PASS sqr #{i}")
        else:
            failed += 1
            print(f"  FAIL sqr #{i}: a={a}, expected={expected}, got={result}")
        assert result == expected, (
            f"sqr #{i}: a={a} expected={expected} got={result}"
        )
    return passed, failed


def test_mul_a24(transport, labels, rng):
    passed = failed = 0
    cases = [0, 1, 2, 121665, P - 1, rand_fe(rng), rand_fe(rng), rand_fe(rng)]
    for i, a in enumerate(cases):
        expected = fe_mul_a24_ref(a)
        result = c64_fe_mul_a24(transport, labels, a)
        if result == expected:
            passed += 1
            if VERBOSE: print(f"  PASS mul_a24 #{i}")
        else:
            failed += 1
            print(f"  FAIL mul_a24 #{i}: a={a}, expected={expected}, got={result}")
        assert result == expected, (
            f"mul_a24 #{i}: a={a} expected={expected} got={result}"
        )
    return passed, failed


def test_inv(transport, labels, rng):
    passed = failed = 0
    cases = [1]
    for i, a in enumerate(cases):
        print(f"    inv test #{i} (a={a:#x})...", end="", flush=True)
        inv_a = c64_fe_inv(transport, labels, a)
        expected = fe_inv_ref(a)
        if inv_a == expected:
            passed += 1
            print(" PASS" if VERBOSE else " ok")
        else:
            failed += 1
            print(f" FAIL")
            print(f"    expected inv = {expected}")
            print(f"    got inv      = {inv_a}")
        assert inv_a == expected, (
            f"inv #{i}: a={a} expected={expected} got={inv_a}"
        )
    return passed, failed


def test_cswap(transport, labels, rng):
    passed = failed = 0
    a = rand_fe(rng)
    b = rand_fe(rng)
    cswap_addr = labels["fe_cswap"]
    trampoline = labels["input_buffer"]

    # No-swap (mask=$00)
    write_fe(transport, labels["fe_tmp1"], a)
    write_fe(transport, labels["fe_tmp2"], b)
    set_fe_ptrs(transport, labels,
                src1=labels["fe_tmp1"],
                src2=labels["fe_tmp2"])
    write_bytes(transport, trampoline, bytes([
        0xA9, 0x00,
        0x4C, cswap_addr & 0xFF, cswap_addr >> 8,
    ]))
    jsr(transport, trampoline)
    r_a = read_fe(transport, labels["fe_tmp1"])
    r_b = read_fe(transport, labels["fe_tmp2"])
    if r_a == a and r_b == b:
        passed += 1
        if VERBOSE: print("  PASS cswap no-swap")
    else:
        failed += 1
        print(f"  FAIL cswap no-swap")
    assert r_a == a and r_b == b, (
        f"cswap no-swap: a_changed={r_a != a} b_changed={r_b != b}"
    )

    # Swap (mask=$FF)
    write_fe(transport, labels["fe_tmp1"], a)
    write_fe(transport, labels["fe_tmp2"], b)
    set_fe_ptrs(transport, labels,
                src1=labels["fe_tmp1"],
                src2=labels["fe_tmp2"])
    write_bytes(transport, trampoline, bytes([
        0xA9, 0xFF,
        0x4C, cswap_addr & 0xFF, cswap_addr >> 8,
    ]))
    jsr(transport, trampoline)
    r_a = read_fe(transport, labels["fe_tmp1"])
    r_b = read_fe(transport, labels["fe_tmp2"])
    if r_a == b and r_b == a:
        passed += 1
        if VERBOSE: print("  PASS cswap swap")
    else:
        failed += 1
        print(f"  FAIL cswap swap")
    assert r_a == b and r_b == a, (
        f"cswap swap: expected ({b:#x},{a:#x}), got ({r_a:#x},{r_b:#x})"
    )

    return passed, failed


def test_add_sub_inverse(transport, labels, rng):
    passed = failed = 0
    for i in range(4):
        a = rand_fe(rng)
        b = rand_fe(rng)
        sum_ab = c64_fe_add(transport, labels, a, b)
        result = c64_fe_sub(transport, labels, sum_ab, b)
        if result == a:
            passed += 1
            if VERBOSE: print(f"  PASS add_sub_inverse #{i}")
        else:
            failed += 1
            print(f"  FAIL add_sub_inverse #{i}: expected {a}, got {result}")
        assert result == a, (
            f"add_sub_inverse #{i}: expected {a} got {result}"
        )
    return passed, failed


def test_reduce_final(transport, labels):
    passed = failed = 0
    cases = [
        ("p itself", P, 0),
        ("p+1", P + 1, 1),
        ("p-1", P - 1, P - 1),
        ("0", 0, 0),
        ("1", 1, 1),
    ]
    for name, val, expected in cases:
        raw = val.to_bytes(32, "little")
        write_bytes(transport, labels["fe_tmp3"], raw)
        set_fe_ptrs(transport, labels, dst=labels["fe_tmp3"])
        jsr(transport, labels["fe_reduce_final"])
        result = read_fe(transport, labels["fe_tmp3"])
        if result == expected:
            passed += 1
            if VERBOSE: print(f"  PASS reduce_final {name}")
        else:
            failed += 1
            print(f"  FAIL reduce_final {name}: expected {expected}, got {result}")
        assert result == expected, (
            f"reduce_final {name}: expected {expected} got {result}"
        )
    return passed, failed


# ============================================================================
# Benchmark
# ============================================================================

def bench_fe_mul(transport, labels, a, b, blank=False):
    """Time a single fe_mul call. If blank=True, blank screen first."""
    write_fe(transport, labels["fe_tmp1"], a)
    write_fe(transport, labels["fe_tmp2"], b)
    set_fe_ptrs(transport, labels,
                src1=labels["fe_tmp1"],
                src2=labels["fe_tmp2"],
                dst=labels["fe_tmp3"])

    if blank:
        jsr(transport, labels["vic_blank"])

    jsr(transport, labels["bench_start"])
    jsr(transport, labels["fe_mul"], timeout=120.0)
    jsr(transport, labels["bench_stop"])

    if blank:
        jsr(transport, labels["vic_unblank"])

    ticks_data = read_bytes(transport, labels["bench_ticks"], 3)
    ticks = (ticks_data[0] << 16) | (ticks_data[1] << 8) | ticks_data[2]
    return ticks


# ============================================================================
# Main
# ============================================================================

def run_tests(transport, labels, seed):
    rng = random.Random(seed)
    total_passed = 0
    total_failed = 0

    test_groups = [
        ("vic_blank/unblank labels", lambda: test_vic_labels(labels)),
        ("vic_blank/unblank function", lambda: test_vic_blank_unblank(transport, labels)),
        ("copy/zero/one", lambda: test_copy_zero_one(transport, labels)),
        ("reduce_final", lambda: test_reduce_final(transport, labels)),
        ("fe_add", lambda: test_add(transport, labels, rng)),
        ("fe_sub", lambda: test_sub(transport, labels, rng)),
        ("add/sub inverse", lambda: test_add_sub_inverse(transport, labels, rng)),
        ("fe_mul", lambda: test_mul(transport, labels, rng)),
        ("fe_sqr", lambda: test_sqr(transport, labels, rng)),
        ("fe_mul_a24", lambda: test_mul_a24(transport, labels, rng)),
        ("fe_cswap", lambda: test_cswap(transport, labels, rng)),
        ("fe_inv", lambda: test_inv(transport, labels, rng)),
    ]

    for name, test_fn in test_groups:
        print(f"\n--- {name} ---")
        # Assertion failures must propagate.
        p, f = test_fn()
        total_passed += p
        total_failed += f
        status = "OK" if f == 0 else "FAIL"
        print(f"  {status}: {p}/{p + f} passed")

    return total_passed, total_failed


def run_benchmark(transport, labels):
    """Benchmark fe_mul with and without VIC blanking."""
    rng = random.Random(25519)
    iterations = 3

    print(f"\n{'='*60}")
    print("BENCHMARK: fe_mul with VIC blanking comparison")
    print(f"{'='*60}")

    # Generate test values
    test_pairs = [(rng.randint(1, P - 1), rng.randint(1, P - 1))
                  for _ in range(iterations)]

    # Without blanking (screen on)
    print(f"\n--- fe_mul WITHOUT VIC blanking ({iterations} iterations) ---")
    normal_ticks = []
    for i, (a, b) in enumerate(test_pairs):
        ticks = bench_fe_mul(transport, labels, a, b, blank=False)
        normal_ticks.append(ticks)
        ms = ticks * 1000 / 60
        print(f"  #{i}: {ticks} jiffies ({ms:.0f} ms)")
    avg_normal = sum(normal_ticks) / len(normal_ticks)

    # With blanking (screen off)
    print(f"\n--- fe_mul WITH VIC blanking ({iterations} iterations) ---")
    blank_ticks = []
    for i, (a, b) in enumerate(test_pairs):
        ticks = bench_fe_mul(transport, labels, a, b, blank=True)
        blank_ticks.append(ticks)
        ms = ticks * 1000 / 60
        print(f"  #{i}: {ticks} jiffies ({ms:.0f} ms)")
    avg_blank = sum(blank_ticks) / len(blank_ticks)

    # Report
    print(f"\n--- Comparison ---")
    print(f"  Screen ON:  {avg_normal:.1f} jiffies avg ({avg_normal * 1000 / 60:.0f} ms)")
    print(f"  Screen OFF: {avg_blank:.1f} jiffies avg ({avg_blank * 1000 / 60:.0f} ms)")
    if avg_normal > 0:
        speedup = (avg_normal - avg_blank) / avg_normal * 100
        print(f"  Speedup:    {speedup:.1f}%")


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
        "fe_copy", "fe_zero", "fe_one",
        "fe_add", "fe_sub", "fe_mul", "fe_sqr", "fe_inv",
        "fe_cswap", "fe_mul_a24", "fe_reduce_final",
        "fe_tmp1", "fe_tmp2", "fe_tmp3", "fe_tmp4",
        "fe_wide", "fe_p",
        "cassette_buf", "input_buffer",
        "vic_blank", "vic_unblank",
        "bench_start", "bench_stop", "bench_ticks",
        "mul_by_38",
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

        # Run correctness tests
        passed, failed = run_tests(transport, labels, seed)

        # Run benchmark unconditionally: asserts halt on failure, so if we
        # got here the correctness tests all passed.
        run_benchmark(transport, labels)

        mgr.release(inst)

    total = passed + failed
    print(f"\n{'='*60}")
    print(f"Results: {passed}/{total} passed, {failed} failed")
    print(f"{'='*60}")
    sys.exit(0 if failed == 0 else 1)


if __name__ == "__main__":
    main()
