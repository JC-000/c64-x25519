#!/usr/bin/env python3
"""test_fe_sqr_stress.py — Stress test fe_sqr for data-dependent carry bugs.

Cross-checks fe_sqr(a) against fe_mul(a, a) and Python reference.
Designed to stress the shift-before-accumulate optimization with inputs
that produce 17-bit shifted products and carry overflow.

Usage:
    python3 tools/test_fe_sqr_stress.py [--seed S]
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

P = (1 << 255) - 19


def int_to_le32(val):
    return (val % P).to_bytes(32, "little")


def le32_to_int(data):
    return int.from_bytes(data, "little")


def set_fe_ptrs(transport, labels, src1=None, src2=None, dst=None):
    if src1 is not None:
        write_bytes(transport, labels["fe_src1"], bytes([src1 & 0xFF, src1 >> 8]))
    if src2 is not None:
        write_bytes(transport, labels["fe_src2"], bytes([src2 & 0xFF, src2 >> 8]))
    if dst is not None:
        write_bytes(transport, labels["fe_dst"], bytes([dst & 0xFF, dst >> 8]))


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
    # fe_mul no longer calls fe_reduce_final internally; canonicalize for test
    jsr(transport, labels["fe_reduce_final"], timeout=5.0)
    return read_fe(transport, labels["fe_tmp3"])


def c64_fe_sqr(transport, labels, a):
    write_fe(transport, labels["fe_tmp1"], a)
    set_fe_ptrs(transport, labels,
                src1=labels["fe_tmp1"],
                dst=labels["fe_tmp3"])
    jsr(transport, labels["fe_sqr"], timeout=120.0)
    # fe_sqr no longer calls fe_reduce_final internally; canonicalize for test
    jsr(transport, labels["fe_reduce_final"], timeout=5.0)
    return read_fe(transport, labels["fe_tmp3"])


def check(name, a, sqr_result, mul_result, expected):
    """Check results and print diagnostics on failure.

    Returns (pass_count, fail_count) for counting purposes but ALSO raises
    an AssertionError on any mismatch so the script halts loudly.
    """
    sqr_ok = sqr_result == expected
    mul_ok = mul_result == expected
    cross_ok = sqr_result == mul_result

    if sqr_ok and mul_ok and cross_ok:
        return 1, 0

    # Something failed
    print(f"  FAIL {name}:")
    print(f"    input       = 0x{a:064x}")
    print(f"    expected    = 0x{expected:064x}")
    print(f"    fe_sqr(a)   = 0x{sqr_result:064x}  {'OK' if sqr_ok else 'MISMATCH'}")
    print(f"    fe_mul(a,a) = 0x{mul_result:064x}  {'OK' if mul_ok else 'MISMATCH'}")
    print(f"    sqr==mul    = {cross_ok}")
    assert sqr_ok and mul_ok and cross_ok, (
        f"{name}: sqr_ok={sqr_ok} mul_ok={mul_ok} cross_ok={cross_ok} "
        f"expected=0x{expected:064x} sqr=0x{sqr_result:064x} "
        f"mul=0x{mul_result:064x}"
    )
    return 0, 1  # unreachable, but keep the return shape


def build_test_cases(rng):
    """Build all test cases: (name, value) pairs."""
    cases = []

    # --- Boundary values ---
    cases.append(("zero", 0))
    cases.append(("one", 1))
    cases.append(("two", 2))
    cases.append(("P-1", P - 1))

    # --- All-0xFF: maximum 17-bit shifted products ---
    cases.append(("all-0xFF", int.from_bytes(b'\xff' * 32, 'little') % P))

    # --- 0x7FFFFFFF...FF: high bit clear, max magnitude below 2^255 ---
    val = int.from_bytes(b'\xff' * 31 + b'\x7f', 'little')
    cases.append(("0x7FFF..FF", val % P))

    # --- 0xFF at specific byte positions ---
    for pos in [0, 15, 31]:
        b = bytearray(32)
        b[pos] = 0xFF
        val = int.from_bytes(bytes(b), 'little')
        cases.append((f"0xFF@byte{pos}", val % P))

    # --- Alternating 0xFF/0x00 ---
    b = bytearray(32)
    for i in range(32):
        b[i] = 0xFF if i % 2 == 0 else 0x00
    cases.append(("alt-FF00", int.from_bytes(bytes(b), 'little') % P))

    b = bytearray(32)
    for i in range(32):
        b[i] = 0x00 if i % 2 == 0 else 0xFF
    cases.append(("alt-00FF", int.from_bytes(bytes(b), 'little') % P))

    # --- Near-prime values ---
    cases.append(("P-2", P - 2))
    cases.append(("P-19", P - 19))
    cases.append(("P-20", P - 20))

    # --- Values that maximize carry propagation in shifted products ---
    # All bytes 0x80 (bit 7 set in every byte)
    b = bytes([0x80] * 32)
    cases.append(("all-0x80", int.from_bytes(b, 'little') % P))

    # All bytes 0xFE (just below 0xFF, still large products)
    b = bytes([0xFE] * 32)
    cases.append(("all-0xFE", int.from_bytes(b, 'little') % P))

    # Byte pattern 0xFF, 0x7F alternating (large * medium products)
    b = bytearray(32)
    for i in range(32):
        b[i] = 0xFF if i % 2 == 0 else 0x7F
    cases.append(("alt-FF7F", int.from_bytes(bytes(b), 'little') % P))

    # High half all 0xFF, low half all 0x00
    b = b'\x00' * 16 + b'\xff' * 16
    cases.append(("hi-FF-lo-00", int.from_bytes(b, 'little') % P))

    # Low half all 0xFF, high half all 0x00
    b = b'\xff' * 16 + b'\x00' * 16
    cases.append(("lo-FF-hi-00", int.from_bytes(b, 'little') % P))

    # --- 30 random cases ---
    for i in range(30):
        cases.append((f"random#{i:02d}", rng.randint(0, P - 1)))

    return cases


def main():
    os.chdir(PROJECT_ROOT)
    seed = random.randint(0, 2**32 - 1)
    if "--seed" in sys.argv:
        idx = sys.argv.index("--seed")
        seed = int(sys.argv[idx + 1])
    print(f"Random seed: {seed} (reproduce with --seed {seed})")
    rng = random.Random(seed)

    labels = Labels.from_file(LABELS_PATH)
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
        write_bytes(transport, 0x0339, bytes([0x4C, 0x39, 0x03]))

        cases = build_test_cases(rng)
        passed = 0
        failed = 0

        print(f"\n--- fe_sqr stress test: {len(cases)} cases ---")
        print("Each case: fe_sqr(a) vs Python, fe_mul(a,a) vs Python, fe_sqr vs fe_mul\n")

        for i, (name, a) in enumerate(cases):
            expected = (a * a) % P
            sqr_result = c64_fe_sqr(transport, labels, a)
            mul_result = c64_fe_mul(transport, labels, a, a)
            p, f = check(name, a, sqr_result, mul_result, expected)
            passed += p
            failed += f
            tag = "OK" if f == 0 else "FAIL"
            print(f"  [{i+1:3d}/{len(cases)}] {tag} {name}")

        mgr.release(inst)

    print(f"\nResults: {passed}/{passed+failed} passed, {failed} failed")
    sys.exit(0 if failed == 0 else 1)


if __name__ == "__main__":
    main()
