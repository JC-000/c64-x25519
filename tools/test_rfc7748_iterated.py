#!/usr/bin/env python3
"""test_rfc7748_iterated.py — RFC 7748 §5.2 1x iterated test vector.

RFC 7748 §5.2 defines an iterated self-check for X25519:

    Set k = u = (32-byte little-endian) "0900...00"
    Loop:
        new_u  = X25519(k, u)
        u      = k
        k      = new_u

After 1 iteration, k must equal:
    422c8e7a 6227d7bc e11196e8 edcc4f13 51d2cea3 a6c4c6cd 87bc8c0a 48f2c1ee

(RFC also gives 1000 and 1_000_000 iteration vectors. Even a single ladder
takes ~100 minutes in VICE warp mode, so we only run the 1x iteration here.
The pyca/cryptography oracle is used as a sanity check that our copy of the
expected hex matches RFC 7748 §5.2; the C64 result is then compared to that.)

Same harness pattern as test_x25519.py (BinaryViceTransport via the
c64_test_harness package). Treats any byte-level mismatch as a hard
assertion failure.

Usage:
    python3 tools/test_rfc7748_iterated.py [--seed S] [--verbose] [--slow]

The 1x iteration is the slow path (single full scalarmult). It is gated on
--slow to match the existing test_x25519.py convention; without --slow this
test is a no-op and exits 0 with a SKIP message.
"""

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

VERBOSE = False
SLOW = False

# RFC 7748 §5.2: starting k = u = 0x0900..00 (little-endian: byte 0 = 9).
RFC7748_START = bytes([9]) + bytes(31)

# RFC 7748 §5.2: expected k after 1 iteration of the loop.
RFC7748_ITER1_EXPECTED_HEX = (
    "422c8e7a6227d7bce11196e8edcc4f13"
    "51d2cea3a6c4c6cd87bc8c0a48f2c1ee"
)


# ============================================================================
# C64 helpers (mirror test_x25519.py pattern)
# ============================================================================

def c64_x25519_scalarmult(transport, labels, scalar, u):
    """Compute scalar * u on C64. Returns 32-byte result."""
    write_bytes(transport, labels["x25_scalar"], scalar)
    write_bytes(transport, labels["x25_u"], u)
    jsr(transport, labels["x25519_scalarmult"], timeout=7200.0)
    return read_bytes(transport, labels["x25_result"], 32)


# ============================================================================
# Pure-Python sanity check on the expected vector
# ============================================================================

def pyca_iter1():
    """Run 1 iteration of the RFC 7748 §5.2 loop using pyca/cryptography.

    Returns the 32-byte k after iteration 1. Used to cross-check that our
    hard-coded RFC7748_ITER1_EXPECTED_HEX is in fact the value pyca produces
    for the documented starting state — i.e. we are not asserting against
    a typo of the RFC vector.
    """
    if not HAS_CRYPTO:
        return None
    k = RFC7748_START
    u = RFC7748_START
    # X25519 in pyca: priv is the scalar, pub is the u-coordinate; both 32 LE.
    priv = X25519PrivateKey.from_private_bytes(k)
    pub = X25519PublicKey.from_public_bytes(u)
    new_k = priv.exchange(pub)
    return new_k


# ============================================================================
# Tests
# ============================================================================

def test_iterated_1x(transport, labels):
    """Run 1 iteration of the RFC 7748 §5.2 loop on the C64; compare to RFC."""
    expected = bytes.fromhex(RFC7748_ITER1_EXPECTED_HEX)

    # Optional sanity gate: confirm the hex literal matches pyca for the same
    # starting state. If pyca disagrees, we have a bug in our copy of the
    # RFC vector — bail before paying the ~100 min ladder cost.
    pyca_result = pyca_iter1()
    if pyca_result is not None:
        assert pyca_result == expected, (
            "RFC7748_ITER1_EXPECTED_HEX disagrees with pyca/cryptography:\n"
            f"  expected (literal): {expected.hex()}\n"
            f"  pyca computed:      {pyca_result.hex()}"
        )
        if VERBOSE:
            print("  pyca cross-check on expected vector: OK")
    else:
        print("  WARN: pyca/cryptography unavailable; skipping oracle "
              "cross-check on the RFC literal")

    # Run iteration 1 on C64. The library applies clamping internally to
    # x25_scalar, so x25519_scalarmult(k, u) is equivalent to
    # X25519(k, u) in RFC 7748 §5.2 terms.
    k = RFC7748_START
    u = RFC7748_START
    print("    iter 1 (one full ladder, ~100 min in VICE warp)...",
          end="", flush=True)
    new_k = c64_x25519_scalarmult(transport, labels, k, u)

    if new_k == expected:
        print(" PASS")
        if VERBOSE:
            print(f"    k after iter 1: {new_k.hex()}")
        return 1, 0
    print(" FAIL")
    print(f"    expected: {expected.hex()}")
    print(f"    got:      {new_k.hex()}")
    assert new_k == expected, (
        f"RFC 7748 §5.2 iter 1 mismatch:\n"
        f"  expected {expected.hex()}\n"
        f"  got      {new_k.hex()}"
    )
    return 0, 1  # unreachable; assert above raises


# ============================================================================
# Main (mirrors test_x25519.py boilerplate)
# ============================================================================

def run_tests(transport, labels):
    if not SLOW:
        print("\n  (RFC 7748 §5.2 1x iterated test skipped — use --slow "
              "to enable)")
        return 0, 0

    total_passed = 0
    total_failed = 0
    print(f"\n--- RFC 7748 §5.2 iterated (1x) ---")
    try:
        p, f = test_iterated_1x(transport, labels)
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
    global VERBOSE, SLOW
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
        else:
            i += 1

    random.seed(seed)
    print(f"Random seed: {seed} (reproduce with --seed {seed})")

    if not SLOW:
        print("RFC 7748 §5.2 iterated test is gated on --slow "
              "(single ladder ~100 min in VICE warp mode).")
        print("  Re-run with: python3 tools/test_rfc7748_iterated.py --slow")
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

        # Safety: write JMP $0339 at $0339 so CPU loops harmlessly
        # after jsr() returns (prevents crash when BASIC ROM is banked out)
        write_bytes(transport, 0x0339, bytes([0x4C, 0x39, 0x03]))

        passed, failed = run_tests(transport, labels)

        mgr.release(inst)

    total = passed + failed
    print(f"\n{'='*60}")
    print(f"Results: {passed}/{total} passed, {failed} failed")
    print(f"{'='*60}")
    sys.exit(0 if failed == 0 else 1)


if __name__ == "__main__":
    main()
