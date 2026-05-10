#!/usr/bin/env python3
"""test_x25519_edge_u.py — Edge-case u-coordinate tests for x25519_scalarmult.

Per RFC 7748 §6.1, certain u-coordinates yield well-known outputs and the
spec explicitly permits all-zero output for low-order points (without
requiring rejection). These are the points that an attacker controls if
they can choose Bob's public key.

This test exercises x25519_scalarmult with the following u-coordinates:

    Boundary u-values
    -----------------
      u = 0                                 (all-zero u)
      u = 1                                 (low byte 0x01, rest 0)
      u = p - 1 = 2^255 - 20                (largest valid u < p)
      u = p     = 2^255 - 19                (canonical p; high bit not masked
                                             by RFC, so 0..2^255-1 is valid;
                                             internally library masks high
                                             bit on input — included for
                                             completeness)
      u = 2^255 - 1                         (high bit set; RFC §5 says high
                                             bit of u MUST be masked)

    Curve25519 low-order u-coordinates (order-1, order-2, order-4, order-8)
    -----------------------------------------------------------------------
      u = 0                                 (already above)
      u = 1                                 (already above)
      u = 325606250916557431795983626356110631294008115727848805560023387167927233504
      u = 39382357235489614581723060781553021112529911719440698176882885853963445705823
      u = 2^255 - 19 - 1                    (= p - 1, already above)

For each (scalar, u), the C64 result must match pyca/cryptography to the
byte. RFC 7748 §6.1 permits all-zero output for low-order points but does
not require it; the library is conformant either way as long as it agrees
with the oracle on every input.

A small set of randomized 32-byte clamped scalars is paired with each
edge-u to broaden coverage without paying for huge iteration counts.

Each X25519 scalarmult takes ~100 minutes in VICE warp mode. The test is
gated on --slow.

Usage:
    python3 tools/test_x25519_edge_u.py [--seed S] [--verbose] [--slow]
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
SLOW = False
SCALARS_PER_U = 1  # number of random scalars per edge-u (each ~100 min)

# Make tools/ importable so we can pull in the cryptography-backed reference.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    import ref_x25519  # noqa: E402
except ImportError:
    ref_x25519 = None

P = (1 << 255) - 19


# ============================================================================
# Edge u-coordinate catalogue
# ============================================================================

# Curve25519 low-order points (the well-known order-{1,2,4,8} u-coordinates).
# Source: RFC 7748 §6.1 / Bernstein "Curve25519: new Diffie-Hellman speed
# records" — these are the u-coordinates of points P with kP = identity for
# small k. pyca/cryptography returns all-zero shared secrets for these.
LOW_ORDER_U_INTS = [
    0,
    1,
    325606250916557431795983626356110631294008115727848805560023387167927233504,
    39382357235489614581723060781553021112529911719440698176882885853963445705823,
    P - 1,                       # = 2^255 - 20
]


def _u_int_to_bytes(u_val: int) -> bytes:
    """Encode a u-coordinate integer as 32 little-endian bytes.

    RFC 7748 §5: u-coordinates are encoded as 32-byte LE; the C64 library
    masks the high bit on input internally, so values >= 2^255 are first
    masked. We pre-mask here so the bytes we write match what pyca will
    consume on its side as well (pyca masks too).
    """
    return (u_val % (1 << 256)).to_bytes(32, "little")


def edge_u_catalogue():
    """Yield (label, u_bytes) pairs for the edge-u test sweep."""
    seen = set()

    def emit(label, u_bytes):
        if u_bytes in seen:
            return
        seen.add(u_bytes)
        return (label, u_bytes)

    items = []

    def add(label, u_bytes):
        rec = emit(label, u_bytes)
        if rec is not None:
            items.append(rec)

    # Boundary u-values
    add("u = 0",            _u_int_to_bytes(0))
    add("u = 1",            _u_int_to_bytes(1))
    add("u = p - 1",        _u_int_to_bytes(P - 1))
    add("u = p",            _u_int_to_bytes(P))
    add("u = 2^255 - 1",    _u_int_to_bytes((1 << 255) - 1))

    # Curve25519 low-order u-coordinates (deduped against boundaries above).
    for u_val in LOW_ORDER_U_INTS:
        add(f"low-order u = {u_val}", _u_int_to_bytes(u_val))

    return items


# ============================================================================
# C64 helpers
# ============================================================================

def c64_x25519_scalarmult(transport, labels, scalar, u):
    """Compute scalar * u on C64. Returns 32-byte result."""
    write_bytes(transport, labels["x25_scalar"], scalar)
    write_bytes(transport, labels["x25_u"], u)
    jsr(transport, labels["x25519_scalarmult"], timeout=7200.0)
    return read_bytes(transport, labels["x25_result"], 32)


def _clamp_scalar_bytes(scalar: bytes) -> bytes:
    """Apply RFC 7748 scalar clamping. Caller-side so the oracle and the
    C64 see the same input."""
    s = bytearray(scalar)
    s[0] &= 0xF8
    s[31] = (s[31] & 0x7F) | 0x40
    return bytes(s)


# ============================================================================
# Tests
# ============================================================================

def test_edge_u_sweep(transport, labels, rng, scalars_per_u):
    """For each catalogued edge-u, cross-check against pyca/cryptography."""
    if ref_x25519 is None:
        print("  SKIP: ref_x25519 not importable")
        return 0, 0

    passed = failed = 0
    catalogue = edge_u_catalogue()
    print(f"  ({len(catalogue)} edge-u values × {scalars_per_u} scalar(s) "
          f"= {len(catalogue) * scalars_per_u} ladders)")

    for label, u_bytes in catalogue:
        for j in range(scalars_per_u):
            scalar = bytes(rng.randint(0, 255) for _ in range(32))
            scalar = _clamp_scalar_bytes(scalar)

            expected_hex = ref_x25519.x25519_scalarmult(
                scalar.hex(), u_bytes.hex())
            expected = bytes.fromhex(expected_hex)

            print(f"    {label} scalar#{j}...", end="", flush=True)
            got = c64_x25519_scalarmult(transport, labels, scalar, u_bytes)

            if got == expected:
                passed += 1
                print(" PASS")
                if VERBOSE:
                    if int.from_bytes(got, "little") == 0:
                        print(f"      (all-zero output, as expected for "
                              f"low-order u — RFC 7748 §6.1)")
                    else:
                        print(f"      out: {got.hex()}")
            else:
                failed += 1
                print(" FAIL")
                print(f"      scalar:   {scalar.hex()}")
                print(f"      u:        {u_bytes.hex()}")
                print(f"      expected: {expected.hex()}")
                print(f"      got:      {got.hex()}")
            assert got == expected, (
                f"edge-u {label} scalar#{j}: scalar={scalar.hex()} "
                f"u={u_bytes.hex()} expected={expected.hex()} "
                f"got={got.hex()}"
            )
    return passed, failed


# ============================================================================
# Main
# ============================================================================

def run_tests(transport, labels, seed, scalars_per_u):
    rng = random.Random(seed)
    if not SLOW:
        print("\n  (edge-u sweep skipped — use --slow to enable)")
        return 0, 0

    total_passed = 0
    total_failed = 0
    print(f"\n--- x25519_scalarmult edge-u sweep ---")
    try:
        p, f = test_edge_u_sweep(transport, labels, rng, scalars_per_u)
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
    global VERBOSE, SLOW, SCALARS_PER_U
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
        elif args[i] == "--scalars-per-u" and i + 1 < len(args):
            SCALARS_PER_U = int(args[i + 1])
            i += 2
        else:
            i += 1

    random.seed(seed)
    print(f"Random seed: {seed} (reproduce with --seed {seed})")

    if not SLOW:
        print("Edge-u sweep is gated on --slow "
              "(each ladder ~100 min in VICE warp mode).")
        print("  Re-run with: python3 tools/test_x25519_edge_u.py --slow")
        sys.exit(0)

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
        "x25519_scalarmult",
        "x25_scalar", "x25_u", "x25_result",
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

        write_bytes(transport, 0x0339, bytes([0x4C, 0x39, 0x03]))

        passed, failed = run_tests(transport, labels, seed, SCALARS_PER_U)

        mgr.release(inst)

    total = passed + failed
    print(f"\n{'='*60}")
    print(f"Results: {passed}/{total} passed, {failed} failed")
    print(f"{'='*60}")
    sys.exit(0 if failed == 0 else 1)


if __name__ == "__main__":
    main()
