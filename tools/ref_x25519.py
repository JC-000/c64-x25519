#!/usr/bin/env python3
"""ref_x25519.py — Authoritative X25519 / Curve25519 field reference.

This module is the *strong* reference for X25519 scalar multiplication and
field arithmetic mod P = 2^255 - 19, intended for use by tests as a known-good
oracle. X25519 itself is delegated to ``cryptography.hazmat`` (BoringSSL /
OpenSSL underneath) so we are not validating our own assembly against our own
Python — we are validating it against an audited library.

Public API:

    x25519_scalarmult(scalar_hex: str, u_hex: str) -> str
        RFC 7748 X25519: 32-byte scalar (clamping is applied internally) times
        32-byte u-coordinate (high bit masked internally), returned as hex.

    fe25519_mul(a, b) -> int    # (a * b) mod P
    fe25519_sqr(a)    -> int    # (a * a) mod P
    fe25519_inv(a)    -> int    # a^(P-2) mod P  (multiplicative inverse)
    fe25519_add(a, b) -> int    # (a + b) mod P
    fe25519_sub(a, b) -> int    # (a - b) mod P

Run as a script to execute the RFC 7748 vector self-test.
"""

from __future__ import annotations

# P = 2^255 - 19
P = (1 << 255) - 19

try:
    from cryptography.hazmat.primitives.asymmetric.x25519 import (
        X25519PrivateKey,
        X25519PublicKey,
    )
    from cryptography.hazmat.primitives import serialization
    _HAS_CRYPTO = True
except ImportError:  # pragma: no cover
    _HAS_CRYPTO = False


# ----------------------------------------------------------------------------
# Field arithmetic mod P = 2^255 - 19
# ----------------------------------------------------------------------------

def fe25519_add(a: int, b: int) -> int:
    return (a + b) % P


def fe25519_sub(a: int, b: int) -> int:
    return (a - b) % P


def fe25519_mul(a: int, b: int) -> int:
    return (a * b) % P


def fe25519_sqr(a: int) -> int:
    return (a * a) % P


def fe25519_inv(a: int) -> int:
    """Multiplicative inverse via Fermat's little theorem: a^(P-2) mod P."""
    return pow(a, P - 2, P)


# ----------------------------------------------------------------------------
# X25519 (delegated to cryptography library)
# ----------------------------------------------------------------------------

def _raw_to_private_key(scalar: bytes) -> "X25519PrivateKey":
    return X25519PrivateKey.from_private_bytes(scalar)


def _raw_to_public_key(u: bytes) -> "X25519PublicKey":
    return X25519PublicKey.from_public_bytes(u)


def x25519_scalarmult(scalar_hex: str, u_hex: str) -> str:
    """Compute X25519(scalar, u) per RFC 7748 and return as 64-char hex.

    The cryptography library applies the standard scalar clamping
    (s[0] &= 248, s[31] &= 127, s[31] |= 64) and masks the high bit of u
    internally, matching RFC 7748 §5.
    """
    if not _HAS_CRYPTO:
        raise RuntimeError(
            "ref_x25519.x25519_scalarmult requires the 'cryptography' package"
        )
    scalar = bytes.fromhex(scalar_hex)
    u = bytes.fromhex(u_hex)
    if len(scalar) != 32 or len(u) != 32:
        raise ValueError("scalar and u must be 32-byte hex strings")

    priv = _raw_to_private_key(scalar)
    pub = _raw_to_public_key(u)
    shared = priv.exchange(pub)
    return shared.hex()


# ----------------------------------------------------------------------------
# Self-test: RFC 7748 §6.1 vectors
# ----------------------------------------------------------------------------

# Authoritative RFC 7748 §5.2 / §6.1 test vectors.
RFC7748_VECTORS = [
    {
        "desc": "RFC 7748 §5.2 vector 1",
        "scalar": "a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4",
        "u":      "e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c",
        "out":    "c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552",
    },
    {
        "desc": "RFC 7748 §5.2 vector 2",
        "scalar": "4b66e9d4d1b4673c5ad22691957d6af5c11b6421e0ea01d42ca4169e7918ba0d",
        "u":      "e5210f12786811d3f4b7959d0538ae2c31dbe7106fc03c3efc4cd549c715a493",
        "out":    "95cbde9476e8907d7aade45cb4b873f88b595a68799fa152e6f8f7647aac7957",
    },
]


def _selftest() -> int:
    if not _HAS_CRYPTO:
        print("FAIL: 'cryptography' package not installed; cannot self-test")
        return 1

    failures = 0
    for vec in RFC7748_VECTORS:
        got = x25519_scalarmult(vec["scalar"], vec["u"])
        ok = got == vec["out"]
        status = "PASS" if ok else "FAIL"
        print(f"  {status} {vec['desc']}")
        if not ok:
            print(f"    expected: {vec['out']}")
            print(f"    got:      {got}")
            failures += 1

    # Smoke-check the field ops: a * a^-1 == 1, fe25519_add/sub round-trip.
    a = 0xdeadbeefcafebabe1234567890abcdef0fedcba987654321aabbccddeeff0011
    assert fe25519_mul(a % P, fe25519_inv(a % P)) == 1, "fe25519_inv self-check failed"
    assert fe25519_sub(fe25519_add(a % P, 12345), 12345) == a % P, "add/sub round-trip"
    assert fe25519_sqr(7) == 49
    print("  PASS field arithmetic smoke checks")
    return failures


if __name__ == "__main__":
    import sys
    sys.exit(_selftest())
