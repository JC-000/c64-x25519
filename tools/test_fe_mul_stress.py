#!/usr/bin/env python3
"""test_fe_mul_stress.py — Stress test for fe_mul (field multiplication mod 2^255-19).

Targets data-dependent carry bugs in the 2x inner loop unroll optimization
by exercising odd/even j positions, long carry chains, and boundary values.

Usage:
    python3 tools/test_fe_mul_stress.py [--seed S] [--verbose]
"""

import os
import random
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


def c64_fe_mul(transport, labels, a, b):
    """Compute a * b mod p on C64."""
    write_fe(transport, labels["fe_tmp1"], a)
    write_fe(transport, labels["fe_tmp2"], b)
    set_fe_ptrs(transport, labels,
                src1=labels["fe_tmp1"],
                src2=labels["fe_tmp2"],
                dst=labels["fe_tmp3"])
    jsr(transport, labels["fe_mul"], timeout=120.0)
    return read_fe(transport, labels["fe_tmp3"])


def bytes_to_int(b):
    """Convert raw bytes (little-endian) to integer."""
    return int.from_bytes(b, "little")


def run_test(transport, labels, name, a, b, passed, failed):
    """Run a single fe_mul test case with commutativity check."""
    expected = (a * b) % P

    result_ab = c64_fe_mul(transport, labels, a, b)
    if result_ab == expected:
        passed += 1
        if VERBOSE:
            print(f"  PASS {name}")
    else:
        failed += 1
        print(f"  FAIL {name}: a*b")
        print(f"    a        = 0x{a:064x}")
        print(f"    b        = 0x{b:064x}")
        print(f"    expected = 0x{expected:064x}")
        print(f"    got      = 0x{result_ab:064x}")
        diff = (result_ab - expected) % P
        print(f"    diff     = 0x{diff:064x}")

    # Commutativity: b*a should equal a*b
    if a != b:
        result_ba = c64_fe_mul(transport, labels, b, a)
        if result_ba == expected:
            passed += 1
            if VERBOSE:
                print(f"  PASS {name} (commutative)")
        else:
            failed += 1
            print(f"  FAIL {name}: b*a (commutativity)")
            print(f"    a        = 0x{a:064x}")
            print(f"    b        = 0x{b:064x}")
            print(f"    expected = 0x{expected:064x}")
            print(f"    got      = 0x{result_ba:064x}")
            if result_ab != result_ba:
                print(f"    NOTE: a*b != b*a  (a*b=0x{result_ab:064x})")
    else:
        # a == b, skip commutativity (trivially true)
        passed += 1
        if VERBOSE:
            print(f"  PASS {name} (commutative, trivial)")

    return passed, failed


def run_tests(transport, labels, rng):
    """Run all fe_mul stress test cases."""
    passed = 0
    failed = 0

    # === 1. Basic sanity ===
    print("\n--- Basic sanity ---")
    for name, a, b in [("0*0", 0, 0), ("0*1", 0, 1), ("1*1", 1, 1), ("2*3", 2, 3)]:
        passed, failed = run_test(transport, labels, name, a, b, passed, failed)

    # === 2. All-0xFF bytes * all-0xFF bytes (maximum carries everywhere) ===
    print("\n--- All-0xFF bytes (max carries) ---")
    all_ff = bytes_to_int(bytes([0xFF] * 32))
    passed, failed = run_test(transport, labels, "0xFF*32 x 0xFF*32",
                              all_ff, all_ff, passed, failed)

    # === 3. Near-prime: (2^255 - 20) * (2^255 - 20) ===
    print("\n--- Near-prime values ---")
    near_p = (1 << 255) - 20  # = P - 1
    passed, failed = run_test(transport, labels, "(P-1)*(P-1)",
                              near_p, near_p, passed, failed)

    # === 4. Alternating 0xFF/0x00 bytes (tests odd-j vs even-j in unrolled pair) ===
    print("\n--- Alternating byte patterns (odd/even j) ---")
    alt_fe_00 = bytes_to_int(bytes([0xFF if i % 2 == 0 else 0x00 for i in range(32)]))
    alt_ff_00 = bytes_to_int(bytes([0xFF if i % 2 == 0 else 0x00 for i in range(32)]))
    passed, failed = run_test(transport, labels, "alt_FF00 x alt_FF00",
                              alt_fe_00, alt_ff_00, passed, failed)

    # === 5. Opposite phase alternating ===
    alt_00_ff = bytes_to_int(bytes([0x00 if i % 2 == 0 else 0xFF for i in range(32)]))
    passed, failed = run_test(transport, labels, "alt_00FF x alt_FF00",
                              alt_00_ff, alt_fe_00, passed, failed)
    passed, failed = run_test(transport, labels, "alt_FF00 x alt_00FF",
                              alt_fe_00, alt_00_ff, passed, failed)

    # === 6. Single 0xFF byte at specific positions * all-0xFF ===
    print("\n--- Single 0xFF byte at specific positions ---")
    for pos in [0, 1, 15, 16, 30, 31]:
        b_bytes = bytearray(32)
        b_bytes[pos] = 0xFF
        single_ff = bytes_to_int(bytes(b_bytes))
        passed, failed = run_test(transport, labels,
                                  f"single_0xFF@byte{pos} x all_0xFF",
                                  single_ff, all_ff, passed, failed)

    # === 7. src2[j]=0 at odd positions only (tests beq @next_j_1st skip path) ===
    print("\n--- Zero at odd j positions (tests 1st-of-pair skip) ---")
    odd_zero = bytearray(32)
    for i in range(32):
        odd_zero[i] = 0x00 if i % 2 == 1 else 0xAB
    odd_zero_val = bytes_to_int(bytes(odd_zero))
    passed, failed = run_test(transport, labels, "odd_j_zero x all_0xFF",
                              odd_zero_val, all_ff, passed, failed)
    passed, failed = run_test(transport, labels, "all_0xFF x odd_j_zero",
                              all_ff, odd_zero_val, passed, failed)

    # === 8. src2[j]=0 at even positions only (tests beq @next_j skip path) ===
    print("\n--- Zero at even j positions (tests 2nd-of-pair skip) ---")
    even_zero = bytearray(32)
    for i in range(32):
        even_zero[i] = 0x00 if i % 2 == 0 else 0xCD
    even_zero_val = bytes_to_int(bytes(even_zero))
    passed, failed = run_test(transport, labels, "even_j_zero x all_0xFF",
                              even_zero_val, all_ff, passed, failed)
    passed, failed = run_test(transport, labels, "all_0xFF x even_j_zero",
                              all_ff, even_zero_val, passed, failed)

    # === 9. (P-1) * (P-1) ===
    print("\n--- (P-1) * (P-1) ---")
    p_minus_1 = P - 1
    passed, failed = run_test(transport, labels, "(P-1)*(P-1)",
                              p_minus_1, p_minus_1, passed, failed)

    # === 10. (P-1) * 2 and 2 * (P-1) ===
    print("\n--- (P-1) * 2 ---")
    passed, failed = run_test(transport, labels, "(P-1)*2",
                              p_minus_1, 2, passed, failed)

    # === 11. Large random cases ===
    print("\n--- Random cases (30 pairs) ---")
    for i in range(30):
        a = rng.randint(0, P - 1)
        b = rng.randint(0, P - 1)
        passed, failed = run_test(transport, labels, f"random#{i}",
                                  a, b, passed, failed)

    # === Extra: values designed to maximize carry propagation ===
    print("\n--- Carry chain stress ---")

    # Value where every byte is 0xFF except byte 0 (carry starts from byte 1)
    carry_start_1 = bytes_to_int(bytes([0x00] + [0xFF] * 31))
    passed, failed = run_test(transport, labels, "carry_from_byte1 x all_0xFF",
                              carry_start_1, all_ff, passed, failed)

    # Values with runs of 0xFF followed by 0x00 (carry chain then gap)
    for run_len in [4, 8, 15, 16]:
        pattern = bytearray(32)
        for i in range(run_len):
            pattern[i] = 0xFF
        val = bytes_to_int(bytes(pattern))
        passed, failed = run_test(transport, labels,
                                  f"0xFF_run{run_len} x all_0xFF",
                                  val, all_ff, passed, failed)

    # Multiply by values near powers of 256 (byte boundary carries)
    for shift in [8, 16, 24, 120, 128, 248]:
        val = (1 << shift) - 1
        if val >= P:
            val = val % P
        passed, failed = run_test(transport, labels,
                                  f"(2^{shift}-1) x (P-1)",
                                  val, p_minus_1, passed, failed)

    # Two large values with complementary byte patterns
    a_comp = bytes_to_int(bytes([0xAA] * 32))
    b_comp = bytes_to_int(bytes([0x55] * 32))
    passed, failed = run_test(transport, labels, "0xAA*32 x 0x55*32",
                              a_comp, b_comp, passed, failed)

    # Checkerboard at nibble level
    a_chk = bytes_to_int(bytes([0xF0] * 32))
    b_chk = bytes_to_int(bytes([0x0F] * 32))
    passed, failed = run_test(transport, labels, "0xF0*32 x 0x0F*32",
                              a_chk, b_chk, passed, failed)

    return passed, failed


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

    print(f"Random seed: {seed} (reproduce with --seed {seed})")
    rng = random.Random(seed)

    labels = Labels.from_file(LABELS_PATH)
    required = [
        "fe_src1", "fe_src2", "fe_dst",
        "fe_mul", "fe_tmp1", "fe_tmp2", "fe_tmp3",
    ]
    for name in required:
        if labels.address(name) is None:
            print(f"FATAL: '{name}' label not found in {LABELS_PATH}")
            sys.exit(1)
    print(f"Labels loaded: {len(required)} required labels verified")

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
        print("VICE ready")

        # Safety trampoline: JMP to self at $0339
        write_bytes(transport, 0x0339, bytes([0x4C, 0x39, 0x03]))

        passed, failed = run_tests(transport, labels, rng)

        mgr.release(inst)

    total = passed + failed
    print(f"\n{'='*60}")
    print(f"Results: {passed}/{total} passed, {failed} failed")
    print(f"{'='*60}")
    sys.exit(0 if failed == 0 else 1)


if __name__ == "__main__":
    main()
