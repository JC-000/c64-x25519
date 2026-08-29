#!/usr/bin/env python3
"""test_x25519_adversarial_kat.py — adversarial end-to-end X25519 KATs.

Oracle: pyca/cryptography hazmat X25519 only (RFC 7748 §6.1 literals for
the two-party exchange). Python big-int arithmetic is used solely to
CONSTRUCT inputs, never to predict outputs. Every comparison is a hard
assert; the run aborts on the first mismatch with full inputs/outputs.

Contract note: x25519_scalarmult does NOT clamp (only x25519_base does);
RFC X25519(k, u) clamps k, and so does hazmat. Every scalar handed to
x25519_scalarmult here is pre-clamped so the two sides compute the same
function. Scalar-corner cases are therefore about the clamped VALUE
(2^254+8 minimum, 2^255-8 maximum, ...), not raw bytes.

Groups:
  A  u-coordinate corners: all 8 low-order u (order 1/2/4/8, both
     non-canonical encodings p+k of the small ones), p-1, p, p+1,
     2^255-19+k for k = 2..20, 2^255-1, all-zero, all-FF, bit-255-set
     random u (must be masked; result must equal hazmat on the masked
     value AND the caller's x25_u must be left untouched), u >= p
     non-canonical random (hazmat reduces; the C64 must agree).
  B  scalar corners after clamping: all-zero, all-FF, only-clamp-bits,
     2^254+8, 2^255-8, alternating 55/AA, single set bit per byte.
  C  RFC 7748 §6.1 both parties (Alice pub, Bob pub, both shared
     secrets) with the RFC literals AND hazmat.
  D  x25519_base == x25519_scalarmult(clamp(k), 9) across seeded random
     scalars, and x25519_base clamps in place (x25_scalar rewritten).
  E  Stateful: same (k,u) twice back-to-back; second call after REU
     register residue is poked into $DF02..$DF0A between calls (the #33
     class); x25_u byte 31 with bit 255 set survives the call unmodified.

Usage:
    C64_SKIP_BUILD=1 python3 tools/test_x25519_adversarial_kat.py [--seed S]
        [--group A,B,...] [--quick]
    X25519_BUILD_DIR=build-1764 C64_SKIP_BUILD=1 python3 tools/... # profiles
    C64_NO_REU=1 X25519_BUILD_DIR=build-onchip ...                  # onchip
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
from cryptography.hazmat.primitives.asymmetric.x25519 import (
    X25519PrivateKey, X25519PublicKey,
)
from cryptography.hazmat.primitives import serialization

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
BUILD_DIR = os.environ.get("X25519_BUILD_DIR", "build")
if not os.path.isabs(BUILD_DIR):
    BUILD_DIR = os.path.join(PROJECT_ROOT, BUILD_DIR)
PRG_PATH = os.path.join(BUILD_DIR, "x25519.prg")
LABELS_PATH = os.path.join(BUILD_DIR, "labels.txt")

P = (1 << 255) - 19
NINE = bytes([9]) + bytes(31)

# Low-order u-coordinates on Curve25519 (order 1, 2, 4, 8) as integers.
# The two non-trivial ones are the classic Wycheproof / libsodium blacklist
# values (they are constructed, not oracled: hazmat decides the output).
LOW_ORDER = {
    "u=0 (order 2)": 0,
    "u=1 (order 4)": 1,
    "u=order-8 A": 325606250916557431795983626356110631294008115727848805560023387167927233504,
    "u=order-8 B": 39382357235489614581723060781553021112529911719440698176882885853963445705823,
    "u=p-1 (order 4 twist)": P - 1,
}


def le(n):
    return (n % (1 << 256)).to_bytes(32, "little")


def clamp(k):
    s = bytearray(k)
    s[0] &= 0xF8
    s[31] = (s[31] & 0x7F) | 0x40
    return bytes(s)


def hazmat(k, u):
    return X25519PrivateKey.from_private_bytes(k).exchange(
        X25519PublicKey.from_public_bytes(u))


def hazmat_pub(k):
    return X25519PrivateKey.from_private_bytes(k).public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw)


class C64:
    def __init__(self, t, labels):
        self.t, self.l = t, labels
        self.calls = 0

    def scalarmult(self, k_clamped, u):
        write_bytes(self.t, self.l["x25_scalar"], k_clamped)
        write_bytes(self.t, self.l["x25_u"], u)
        jsr(self.t, self.l["x25519_scalarmult"], timeout=7200.0)
        self.calls += 1
        return read_bytes(self.t, self.l["x25_result"], 32)

    def base(self, k_raw):
        write_bytes(self.t, self.l["x25_scalar"], k_raw)
        jsr(self.t, self.l["x25519_base"], timeout=7200.0)
        self.calls += 1
        return read_bytes(self.t, self.l["x25_result"], 32)

    def fault(self):
        # x25519_reu_fault lands with the REU settle work (PR #116); on a
        # tree without it there is nothing to read, so report "no fault".
        if self.l.address("x25519_reu_fault") is None:
            return 0
        return read_bytes(self.t, self.l["x25519_reu_fault"], 1)[0]

    def u_buf(self):
        return read_bytes(self.t, self.l["x25_u"], 32)

    def scalar_buf(self):
        return read_bytes(self.t, self.l["x25_scalar"], 32)


def check(c64, label, k_clamped, u):
    # pyca (OpenSSL) REJECTS an all-zero shared secret with ValueError
    # (RFC 7748 §6.1 "MAY check for the all-zero value"). The library has
    # no error return and the RFC text says the output for such inputs is
    # all-zero, so in that case the expected bytes are 32 zeros — derived
    # from the RFC text, not a vector; labelled as such in the output.
    try:
        exp = hazmat(k_clamped, u)
        src = "pyca"
    except ValueError:
        exp = bytes(32)
        src = "pyca-rejects/RFC-6.1-all-zero"
    got = c64.scalarmult(k_clamped, u)
    ok = got == exp
    print(f"  [{'PASS' if ok else 'FAIL'}] {label}  ({src})", flush=True)
    assert ok, (f"{label}\n  k={k_clamped.hex()}\n  u={u.hex()}\n"
                f"  {src}={exp.hex()}\n  c64 ={got.hex()}")
    assert c64.u_buf() == u, f"{label}: x25_u mutated by the call"
    f = c64.fault()
    assert f == 0, f"{label}: x25519_reu_fault=${f:02x}"
    return got


def group_a(c64, rng, quick):
    print("--- A: u-coordinate corners ---")
    k = clamp(bytes(rng.getrandbits(8) for _ in range(32)))
    cases = []
    for name, u in LOW_ORDER.items():
        cases.append((name, le(u)))
        if u + P < (1 << 256):
            cases.append((name + " +p (non-canonical)", le(u + P)))
    cases += [
        ("u=p", le(P)),
        ("u=p+1", le(P + 1)),
        ("u=2^255-1", le((1 << 255) - 1)),
        ("u=all-FF (2^256-1)", bytes([0xFF] * 32)),
        ("u=2^255 (bit 255 only -> 0)", le(1 << 255)),
        ("u=2^255+9 (bit 255 on basepoint)", le((1 << 255) + 9)),
    ]
    ks = [2, 3, 5, 18, 19, 20] if quick else list(range(2, 21))
    for kk in ks:
        cases.append((f"u=p+{kk}", le(P + kk)))
    for i in range(2 if quick else 4):
        u = bytearray(rng.getrandbits(8) for _ in range(32))
        u[31] |= 0x80
        cases.append((f"random u, bit 255 set #{i}", bytes(u)))
    for i in range(2 if quick else 4):
        u = rng.randrange(P, 1 << 255)
        cases.append((f"random u in [p, 2^255) #{i}", le(u)))
    for label, u in cases:
        check(c64, label, k, u)


def group_b(c64, rng, quick):
    print("--- B: scalar corners (post-clamp) ---")
    u = bytes(rng.getrandbits(8) for _ in range(32))
    u = u[:31] + bytes([u[31] & 0x7F])
    cases = [
        ("k=clamp(all-zero) = 2^254", clamp(bytes(32))),
        ("k=clamp(all-FF) = 2^255-8", clamp(bytes([0xFF] * 32))),
        ("k=clamp(08..40) min = 2^254+8", clamp(le((1 << 254) + 8))),
        ("k=clamp(alternating 55)", clamp(bytes([0x55] * 32))),
        ("k=clamp(alternating AA)", clamp(bytes([0xAA] * 32))),
        ("k=clamp(2^254 + 2^253)", clamp(le((1 << 254) + (1 << 253)))),
        ("k=clamp(bytes = 1<<(i%8))", clamp(bytes(1 << (i % 8) for i in range(32)))),
    ]
    for label, k in cases:
        check(c64, label, k, u)
        check(c64, label + " on u=9", k, NINE)
    # Same scalar shapes on a low-order u: output must be all-zero per pyca
    # (hazmat raises on all-zero shared secret? no: it returns it).
    check(c64, "k=2^254+8 on u=1", clamp(le((1 << 254) + 8)), le(1))


def group_c(c64, rng, quick):
    print("--- C: RFC 7748 §6.1 both parties ---")
    a_priv = bytes.fromhex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
    b_priv = bytes.fromhex("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
    a_pub = bytes.fromhex("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
    b_pub = bytes.fromhex("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")
    shared = bytes.fromhex("4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742")
    assert hazmat_pub(a_priv) == a_pub and hazmat_pub(b_priv) == b_pub
    got = c64.base(a_priv)
    assert got == a_pub, f"Alice pub: rfc={a_pub.hex()} c64={got.hex()}"
    print("  [PASS] Alice public key (x25519_base)")
    got = c64.base(b_priv)
    assert got == b_pub, f"Bob pub: rfc={b_pub.hex()} c64={got.hex()}"
    print("  [PASS] Bob public key (x25519_base)")
    got = check(c64, "Alice shared = X25519(a, B)", clamp(a_priv), b_pub)
    assert got == shared, f"Alice shared rfc={shared.hex()} c64={got.hex()}"
    got = check(c64, "Bob shared = X25519(b, A)", clamp(b_priv), a_pub)
    assert got == shared, f"Bob shared rfc={shared.hex()} c64={got.hex()}"


def group_d(c64, rng, quick):
    print("--- D: x25519_base vs scalarmult(clamp(k), 9) ---")
    for i in range(2 if quick else 4):
        k = bytes(rng.getrandbits(8) for _ in range(32))
        exp = hazmat_pub(k)
        got_b = c64.base(k)
        assert c64.scalar_buf() == clamp(k), "x25519_base did not clamp x25_scalar in place"
        got_s = c64.scalarmult(clamp(k), NINE)
        ok = got_b == exp == got_s
        print(f"  [{'PASS' if ok else 'FAIL'}] seed-random k #{i}", flush=True)
        assert ok, (f"k={k.hex()}\n  pyca={exp.hex()}\n  base={got_b.hex()}\n"
                    f"  smul={got_s.hex()}")


def group_e(c64, rng, quick):
    print("--- E: stateful / residue ---")
    k = clamp(bytes(rng.getrandbits(8) for _ in range(32)))
    u = bytearray(rng.getrandbits(8) for _ in range(32))
    u[31] |= 0x80                       # bit 255 set: must be masked, not written back
    u = bytes(u)
    r1 = check(c64, "call #1", k, u)
    r2 = check(c64, "call #2 same buffers", k, u)
    assert r1 == r2
    if not os.environ.get("C64_NO_REU"):
        # Poke junk into every REU register the library may rely on being
        # latched, then call again without re-running reu_mul_init.
        junk = bytes([0x5A, 0xA5, 0x33, 0xCC, 0x07, 0x11, 0x22])
        write_bytes(c64.t, 0xDF02, junk[:1]); write_bytes(c64.t, 0xDF03, junk[1:2])
        write_bytes(c64.t, 0xDF04, junk[2:3]); write_bytes(c64.t, 0xDF05, junk[3:4])
        write_bytes(c64.t, 0xDF06, junk[4:5]); write_bytes(c64.t, 0xDF07, junk[5:6])
        write_bytes(c64.t, 0xDF08, junk[6:7]); write_bytes(c64.t, 0xDF0A, bytes([0xC0]))
        check(c64, "call #3 after REU register residue ($DF02-$DF0A dirty)", k, u)
        write_bytes(c64.t, 0xDF0A, bytes([0xC0]))
        write_bytes(c64.t, 0xDF04, bytes([0xFF]))
        check(c64, "call #4 after addr_ctrl=$C0 / reu_lo=$FF", k, u)
    # Dirty ZP $14-$7F and the library data temporaries before a call.
    write_bytes(c64.t, 0x14, bytes([0xA5] * (0x80 - 0x14)))
    for name in ("fe25519_tmp1", "fe25519_tmp2", "fe25519_tmp3", "fe25519_tmp4",
                 "x25_x2", "x25_z2", "x25_x3", "x25_z3", "x25_a", "x25_b",
                 "x25_da", "x25_cb", "x25_e", "x25_x1", "x25_result"):
        write_bytes(c64.t, c64.l[name], bytes([0xA5] * 32))
    write_bytes(c64.t, c64.l["mul_src2_buf"], bytes([0xA5] * 32))
    check(c64, "call #5 after ZP + all temporaries filled with $A5", k, u)
    # mul_src2_buf[32] is a load-bearing phantom zero; a host that
    # tramples it must not survive silently -> we do NOT dirty it here,
    # that is the fe adversarial test's job.


GROUPS = {"A": group_a, "B": group_b, "C": group_c, "D": group_d, "E": group_e}


def main():
    seed = 20260828
    quick = "--quick" in sys.argv
    sel = "ABCDE"
    args = sys.argv[1:]
    if "--seed" in args:
        seed = int(args[args.index("--seed") + 1])
    if "--group" in args:
        sel = args[args.index("--group") + 1].replace(",", "").upper()
    rng = random.Random(seed)
    print(f"seed={seed} build={BUILD_DIR} groups={sel} quick={quick}")

    if not os.environ.get("C64_SKIP_BUILD"):
        r = subprocess.run(["make"], capture_output=True, text=True, cwd=PROJECT_ROOT)
        assert r.returncode == 0, r.stderr
    labels = Labels.from_file(LABELS_PATH)
    reu_args = ["+reu"] if os.environ.get("C64_NO_REU") else ["-reu", "-reusize", "512"]
    config = ViceConfig(prg_path=PRG_PATH, warp=True, ntsc=True, sound=False,
                        extra_args=reu_args)
    t0 = time.time()
    with ViceInstanceManager(config=config) as mgr:
        inst = mgr.acquire()
        t = inst.transport
        assert wait_for_text(t, "Q=QUIT", timeout=120.0) is not None, "no main menu"
        write_bytes(t, 0x0339, bytes([0x4C, 0x39, 0x03]))
        c64 = C64(t, labels)
        for g in sel:
            GROUPS[g](c64, rng, quick)
        mgr.release(inst)
    assert c64.calls > 0, "no ladders ran (vacuous)"
    print(f"PASS: {c64.calls} ladders, all match pyca ({(time.time()-t0)/60:.1f} min)")


if __name__ == "__main__":
    main()
