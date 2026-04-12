#!/usr/bin/env python3
"""test_x25519.py — Direct-memory X25519 scalar multiplication tests.

Tests x25519_clamp, x25519_scalarmult, and x25519_base against
RFC 7748 vectors and Python cryptography library.

Each X25519 scalarmult takes ~100 minutes in VICE warp mode due to
~2550 field multiplications + 1 field inversion (TCP monitor overhead).
By default, only fast tests (clamp) are run. Use --slow to include
scalarmult tests (expect 2+ hours per test).

Usage:
    python3 tools/test_x25519.py [--seed S] [--verbose] [--slow]
"""

import json
import os
import random
import subprocess
import sys


from c64_test_harness import (
    Labels, ViceConfig, ViceInstanceManager,
    read_bytes, write_bytes, jsr, wait_for_text,
)

try:
    from cryptography.hazmat.primitives.asymmetric.x25519 import (
        X25519PrivateKey, X25519PublicKey,
    )
    from cryptography.hazmat.primitives import serialization
    HAS_CRYPTO = True
except ImportError:
    HAS_CRYPTO = False

PROJECT_ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
PRG_PATH = os.path.join(PROJECT_ROOT, "build", "x25519.prg")
LABELS_PATH = os.path.join(PROJECT_ROOT, "build", "labels.txt")
VECTORS_PATH = os.path.join(PROJECT_ROOT, "test", "rfc7748_vectors.json")

VERBOSE = False
SLOW = False
RANDOM_N = 10  # number of random scalars / u-coords to cross-check

# Make tools/ importable so we can pull in the cryptography-backed reference.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    import ref_x25519  # noqa: E402
except ImportError:
    ref_x25519 = None


# ============================================================================
# C64 helpers
# ============================================================================

def c64_x25519_clamp(transport, labels, scalar):
    """Clamp a scalar on C64. Returns clamped scalar bytes."""
    write_bytes(transport, labels["x25_scalar"], scalar)
    jsr(transport, labels["x25519_clamp"])
    return read_bytes(transport, labels["x25_scalar"], 32)


def c64_x25519_scalarmult(transport, labels, scalar, u):
    """Compute scalar * u on C64. Returns 32-byte result."""
    write_bytes(transport, labels["x25_scalar"], scalar)
    write_bytes(transport, labels["x25_u"], u)
    # Already clamped by caller or test
    jsr(transport, labels["x25519_scalarmult"], timeout=7200.0)
    return read_bytes(transport, labels["x25_result"], 32)


def c64_x25519_base(transport, labels, scalar):
    """Compute scalar * basepoint(9) on C64. Returns 32-byte result."""
    write_bytes(transport, labels["x25_scalar"], scalar)
    jsr(transport, labels["x25519_base"], timeout=7200.0)
    return read_bytes(transport, labels["x25_result"], 32)


# ============================================================================
# Python reference
# ============================================================================

def clamp_ref(scalar):
    """Clamp scalar per RFC 7748."""
    s = bytearray(scalar)
    s[0] &= 0xF8
    s[31] = (s[31] & 0x7F) | 0x40
    return bytes(s)


def x25519_ref(scalar, u):
    """X25519 scalar multiplication (pure Python reference)."""
    P = (1 << 255) - 19

    def fe25519_add(a, b):
        return (a + b) % P

    def fe25519_sub(a, b):
        return (a - b) % P

    def fe25519_mul(a, b):
        return (a * b) % P

    def fe25519_sqr(a):
        return (a * a) % P

    def fe25519_inv(a):
        return pow(a, P - 2, P)

    def cswap(swap, x_2, x_3):
        if swap:
            return x_3, x_2
        return x_2, x_3

    # Decode scalar and u
    k = int.from_bytes(scalar, 'little')
    u_val = int.from_bytes(u, 'little')
    u_val &= (1 << 255) - 1  # mask high bit of u

    a24 = 121665
    x_2 = 1
    z_2 = 0
    x_3 = u_val
    z_3 = 1
    swap = 0

    for t in range(254, -1, -1):
        k_t = (k >> t) & 1
        swap ^= k_t
        x_2, x_3 = cswap(swap, x_2, x_3)
        z_2, z_3 = cswap(swap, z_2, z_3)
        swap = k_t

        A = fe25519_add(x_2, z_2)
        AA = fe25519_sqr(A)
        B = fe25519_sub(x_2, z_2)
        BB = fe25519_sqr(B)
        E = fe25519_sub(AA, BB)
        C = fe25519_add(x_3, z_3)
        D = fe25519_sub(x_3, z_3)
        DA = fe25519_mul(D, A)
        CB = fe25519_mul(C, B)
        x_3 = fe25519_sqr(fe25519_add(DA, CB))
        z_3 = fe25519_mul(u_val, fe25519_sqr(fe25519_sub(DA, CB)))
        x_2 = fe25519_mul(AA, BB)
        z_2 = fe25519_mul(E, fe25519_add(AA, fe25519_mul(a24, E)))

    x_2, x_3 = cswap(swap, x_2, x_3)
    z_2, z_3 = cswap(swap, z_2, z_3)
    result = fe25519_mul(x_2, fe25519_inv(z_2))
    return result.to_bytes(32, 'little')


# ============================================================================
# Tests
# ============================================================================

def test_clamp(transport, labels):
    """Test x25519_clamp against reference."""
    passed = failed = 0

    cases = [
        bytes(range(32)),
        bytes([0xFF] * 32),
        bytes([0x00] * 32),
        bytes([0xA5] * 32),
    ]

    for i, scalar in enumerate(cases):
        expected = clamp_ref(scalar)
        result = c64_x25519_clamp(transport, labels, scalar)
        if result == expected:
            passed += 1
            if VERBOSE:
                print(f"  PASS clamp #{i}")
        else:
            failed += 1
            print(f"  FAIL clamp #{i}:")
            print(f"    expected: {expected.hex()}")
            print(f"    got:      {result.hex()}")
        assert result == expected, (
            f"clamp #{i}: expected {expected.hex()} got {result.hex()}"
        )

    return passed, failed


def test_rfc7748_vectors(transport, labels):
    """Test x25519_scalarmult with RFC 7748 §6.1 vectors."""
    passed = failed = 0

    with open(VECTORS_PATH) as f:
        vectors = json.load(f)

    # Defensive: only read the keys we need; ignore extensions added elsewhere.
    for vec in vectors.get("x25519_scalarmult", []):
        scalar = bytes.fromhex(vec["scalar"])
        u = bytes.fromhex(vec["u_coordinate"])
        expected = bytes.fromhex(vec["expected"])

        # Clamp scalar first
        scalar = clamp_ref(scalar)

        print(f"    {vec['desc']}...", end="", flush=True)
        result = c64_x25519_scalarmult(transport, labels, scalar, u)

        if result == expected:
            passed += 1
            print(" PASS")
        else:
            failed += 1
            print(" FAIL")
            print(f"    expected: {expected.hex()}")
            print(f"    got:      {result.hex()}")
        assert result == expected, (
            f"{vec.get('desc', 'rfc7748')}: expected {expected.hex()} "
            f"got {result.hex()}"
        )

    return passed, failed


def _clamp_scalar_bytes(scalar: bytes) -> bytes:
    s = bytearray(scalar)
    s[0] &= 0xF8
    s[31] = (s[31] & 0x7F) | 0x40
    return bytes(s)


def test_random_scalars(transport, labels, rng, n):
    """Cross-check n random clamped scalars against cryptography-backed ref.

    Each trial ends in an ``assert`` so any mismatch halts the script.
    """
    if ref_x25519 is None:
        print("  SKIP: ref_x25519 not importable")
        return 0, 0
    passed = failed = 0
    # Fixed u = basepoint (9), well-known nontrivial input.
    u_bytes = bytes([9]) + bytes(31)
    u_hex = u_bytes.hex()
    for i in range(n):
        scalar = bytes(rng.randint(0, 255) for _ in range(32))
        scalar = _clamp_scalar_bytes(scalar)
        expected_hex = ref_x25519.x25519_scalarmult(scalar.hex(), u_hex)
        expected = bytes.fromhex(expected_hex)
        got = c64_x25519_scalarmult(transport, labels, scalar, u_bytes)
        if got == expected:
            passed += 1
            if VERBOSE:
                print(f"  PASS random scalar #{i}")
        else:
            failed += 1
            print(f"  FAIL random scalar #{i}")
            print(f"    scalar:   {scalar.hex()}")
            print(f"    expected: {expected.hex()}")
            print(f"    got:      {got.hex()}")
        assert got == expected, (
            f"random scalar #{i} mismatch: scalar={scalar.hex()} "
            f"expected={expected.hex()} got={got.hex()}"
        )
    return passed, failed


def test_random_u_coords(transport, labels, rng, n):
    """Cross-check n random u-coords (fixed scalar) against cryptography ref.

    Each u-coord has the high bit of byte 31 cleared per RFC 7748 §5.
    Each trial ends in an ``assert`` so any mismatch halts the script.
    """
    if ref_x25519 is None:
        print("  SKIP: ref_x25519 not importable")
        return 0, 0
    passed = failed = 0
    # Fixed (clamped) scalar — RFC 7748 §6.1 vector 1's scalar.
    scalar_hex = "a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4"
    scalar = _clamp_scalar_bytes(bytes.fromhex(scalar_hex))
    for i in range(n):
        u = bytearray(rng.randint(0, 255) for _ in range(32))
        u[31] &= 0x7F  # RFC 7748: mask high bit of u
        u_bytes = bytes(u)
        expected_hex = ref_x25519.x25519_scalarmult(scalar.hex(), u_bytes.hex())
        expected = bytes.fromhex(expected_hex)
        got = c64_x25519_scalarmult(transport, labels, scalar, u_bytes)
        if got == expected:
            passed += 1
            if VERBOSE:
                print(f"  PASS random u #{i}")
        else:
            failed += 1
            print(f"  FAIL random u #{i}")
            print(f"    u:        {u_bytes.hex()}")
            print(f"    expected: {expected.hex()}")
            print(f"    got:      {got.hex()}")
        assert got == expected, (
            f"random u #{i} mismatch: u={u_bytes.hex()} "
            f"expected={expected.hex()} got={got.hex()}"
        )
    return passed, failed


def test_basepoint(transport, labels):
    """Test x25519_base (scalar * basepoint 9)."""
    passed = failed = 0

    with open(VECTORS_PATH) as f:
        vectors = json.load(f)

    for vec in vectors.get("x25519_basepoint", []):
        scalar = bytes.fromhex(vec["scalar"])
        expected = bytes.fromhex(vec["expected"])

        print(f"    {vec['desc']}...", end="", flush=True)
        result = c64_x25519_base(transport, labels, scalar)

        if result == expected:
            passed += 1
            print(" PASS")
        else:
            failed += 1
            print(" FAIL")
            print(f"    expected: {expected.hex()}")
            print(f"    got:      {result.hex()}")
        assert result == expected, (
            f"basepoint {vec.get('desc', '')}: expected {expected.hex()} "
            f"got {result.hex()}"
        )

    return passed, failed


# ============================================================================
# Main
# ============================================================================

def run_tests(transport, labels, seed):
    """Run all test groups."""
    rng = random.Random(seed)
    total_passed = 0
    total_failed = 0

    test_groups = [
        ("x25519_clamp", lambda: test_clamp(transport, labels)),
    ]

    if SLOW:
        test_groups += [
            ("RFC 7748 vectors", lambda: test_rfc7748_vectors(transport, labels)),
            ("basepoint multiply", lambda: test_basepoint(transport, labels)),
            (f"random scalars x{RANDOM_N}",
             lambda: test_random_scalars(transport, labels, rng, RANDOM_N)),
            (f"random u-coords x{RANDOM_N}",
             lambda: test_random_u_coords(transport, labels, rng, RANDOM_N)),
        ]
    elif "--random" in sys.argv and RANDOM_N > 0:
        test_groups += [
            (f"random scalars x{RANDOM_N}",
             lambda: test_random_scalars(transport, labels, rng, RANDOM_N)),
            (f"random u-coords x{RANDOM_N}",
             lambda: test_random_u_coords(transport, labels, rng, RANDOM_N)),
        ]
    else:
        print("\n  (scalarmult tests skipped — use --slow or --random N to enable)")


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

    return total_passed, total_failed


def main():
    global VERBOSE, SLOW, RANDOM_N
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
        elif args[i] == "--slow":
            SLOW = True
            i += 1
        elif args[i] == "--random":
            # Optional N argument; defaults to RANDOM_N if next token is a flag.
            if i + 1 < len(args) and not args[i + 1].startswith("--"):
                RANDOM_N = int(args[i + 1])
                i += 2
            else:
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
        "x25519_clamp", "x25519_scalarmult", "x25519_base",
        "x25_scalar", "x25_u", "x25_result",
        "x25_x2", "x25_z2", "x25_x3", "x25_z3",
        "x25_basepoint",
        "fe25519_src1", "fe25519_src2", "fe25519_dst",
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
        # after jsr() returns (prevents crash when BASIC ROM is banked out)
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
