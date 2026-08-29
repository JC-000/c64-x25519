#!/usr/bin/env python3
"""test_fe_adversarial_bigint.py — carry/borrow corner cases for fe25519_*.

ORACLE CAVEAT (read before trusting a green run): there is no pyca/hazmat
API for individual field operations, so — exactly like every existing
tools/test_fe*.py — the expected values here are Python big-int
arithmetic mod p (`(a*b) % P`, `pow(a, P-2, P)`). That is the
mathematical definition, not a reimplementation of the ladder, but it is
NOT the project's hazmat oracle: a mistaken belief about the field
(e.g. which p, which encoding) would be shared. The end-to-end hazmat
KATs (tools/test_x25519*.py) are the only shared-bug-free gate; this file
adds corner coverage those KATs reach only by luck.

Two input classes:
  in-contract   operands are within the documented Inv3 bound (< 2^256, i.e.
                <= 2p+37 — the corrected bound, audit 2026-08-28 A2) and
                canonical/non-canonical pairing the ladder actually
                produces (non-canonical operand is src1 for sub; either
                operand for mul/sqr/add/mul_a24/inv/reduce_final input
                <= 2p).  Hard-asserted.  Raw (pre-reduce_final) mul/sqr
                output is additionally asserted <= 2^256-1 = 2p+37 (Inv3 as
                corrected: (2p-1)^2 measures raw 2p+1, the search-max case
                2p+37; the old "<= 2p" claim was false).
  out-of-contract  operands above 2p (e.g. all-FF = 2^256-1) or sub with the
                non-canonical operand on the src2 side. Reported as INFO,
                never asserted: the library documents no behaviour there.

Usage:
    C64_SKIP_BUILD=1 python3 tools/test_fe_adversarial_bigint.py
"""

import os
import random
import subprocess
import sys

from c64_test_harness import (
    Labels, ViceConfig, ViceInstanceManager,
    read_bytes, write_bytes, jsr, wait_for_text,
)

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
BUILD_DIR = os.environ.get("X25519_BUILD_DIR", "build")
if not os.path.isabs(BUILD_DIR):
    BUILD_DIR = os.path.join(PROJECT_ROOT, BUILD_DIR)
PRG_PATH = os.path.join(BUILD_DIR, "x25519.prg")
LABELS_PATH = os.path.join(BUILD_DIR, "labels.txt")

P = (1 << 255) - 19
TWO_P = 2 * P
ALL_FF = (1 << 256) - 1
RAW_MAX = ALL_FF  # corrected Inv3 raw ceiling: 2^256-1 = 2p+37 (A2)


def le(n):
    assert 0 <= n < (1 << 256)
    return n.to_bytes(32, "little")


class FE:
    def __init__(self, t, l):
        self.t, self.l = t, l
        self.t1, self.t2, self.t3 = l["fe25519_tmp1"], l["fe25519_tmp2"], l["fe25519_tmp3"]
        self.n = 0

    def ptrs(self, src1=None, src2=None, dst=None):
        for name, a in (("fe25519_src1", src1), ("fe25519_src2", src2), ("fe25519_dst", dst)):
            if a is not None:
                write_bytes(self.t, self.l[name], bytes([a & 0xFF, a >> 8]))

    def raw(self):
        return int.from_bytes(read_bytes(self.t, self.t3, 32), "little")

    def reduce_final(self):
        self.ptrs(dst=self.t3)
        jsr(self.t, self.l["fe25519_reduce_final"], timeout=10.0)
        return self.raw()

    def binop(self, op, a, b, timeout=120.0):
        write_bytes(self.t, self.t1, le(a)); write_bytes(self.t, self.t2, le(b))
        self.ptrs(self.t1, self.t2, self.t3)
        jsr(self.t, self.l[op], timeout=timeout)
        self.n += 1
        return self.raw()

    def unop(self, op, a, timeout=120.0):
        write_bytes(self.t, self.t1, le(a))
        self.ptrs(self.t1, None, self.t3)
        jsr(self.t, self.l[op], timeout=timeout)
        self.n += 1
        return self.raw()


FAILURES = []


def report(kind, label, ok, detail=""):
    tag = {"C": "PASS" if ok else "FAIL", "I": "INFO-ok" if ok else "INFO-differs"}[kind]
    print(f"  [{tag}] {label}{('  ' + detail) if detail and not ok else ''}", flush=True)
    if kind == "C" and not ok:
        FAILURES.append(f"{label} {detail}")


def model_reduce_wide(prod):
    """Python model of fe_reduce_wide's fold (2^256 = 38 mod p), used ONLY
    to SEARCH for inputs that maximise the raw output; the C64's raw output
    is compared against exp mod p, never against this model."""
    M = (1 << 256) - 1
    lo, hi = prod & M, prod >> 256
    r = lo + 38 * hi
    c, r = r >> 256, r & M
    r += 38 * c
    c, r = r >> 256, r & M
    return r + 38 * c


def main():
    if not os.environ.get("C64_SKIP_BUILD"):
        r = subprocess.run(["make"], capture_output=True, text=True, cwd=PROJECT_ROOT)
        assert r.returncode == 0, r.stderr
    labels = Labels.from_file(LABELS_PATH)
    reu_args = ["+reu"] if os.environ.get("C64_NO_REU") else ["-reu", "-reusize", "512"]
    config = ViceConfig(prg_path=PRG_PATH, warp=True, ntsc=True, sound=False, extra_args=reu_args)
    rng = random.Random(0x25519)
    R = [rng.randrange(P) for _ in range(3)]

    with ViceInstanceManager(config=config) as mgr:
        inst = mgr.acquire(); t = inst.transport
        assert wait_for_text(t, "Q=QUIT", timeout=120.0) is not None
        write_bytes(t, 0x0339, bytes([0x4C, 0x39, 0x03]))
        fe = FE(t, labels)

        # ---------------- mul / sqr (raw <= 2p, then canonical) ------------
        print("--- fe25519_mul / fe25519_sqr ---")
        mul_cases = [
            ("C", "(p-1)*(p-1)", P - 1, P - 1),
            ("C", "(p-1)*(2p-1)", P - 1, TWO_P - 1),
            ("C", "(2p-1)*(2p-1)", TWO_P - 1, TWO_P - 1),
            ("C", "2p*2p", TWO_P, TWO_P),
            ("C", "p*p", P, P),
            ("C", "p*1", P, 1),
            ("C", "(p+1)*(p+1)", P + 1, P + 1),
            ("C", "(2^255-1)*(2^255-1)", (1 << 255) - 1, (1 << 255) - 1),
            ("C", "(2^255)*(2^255)", 1 << 255, 1 << 255),
            ("C", "(2^255+18)*(2^255+18) [=p+37 squared, all limbs carry]", (1 << 255) + 18, (1 << 255) + 18),
            ("C", "(2p-1)*random", TWO_P - 1, R[0]),
            ("C", "random*(2p-1)", R[0], TWO_P - 1),
            ("C", "byte-FF-except-lo * same", (ALL_FF - 0xFF) - (1 << 255), (ALL_FF - 0xFF) - (1 << 255)),
            ("C", "2p-38 (=2^256-76) * 2p-38", TWO_P - 38, TWO_P - 38),
            ("I", "all-FF * all-FF (2^256-1, above 2p)", ALL_FF, ALL_FF),
            ("I", "all-FF * 1", ALL_FF, 1),
            ("I", "(2p+1)*(2p+1)", TWO_P + 1, TWO_P + 1),
        ]
        for kind, label, a, b in mul_cases:
            raw = fe.binop("fe25519_mul", a, b)
            exp = (a * b) % P
            got = fe.reduce_final()
            ok = got == exp and (kind == "I" or raw <= RAW_MAX)
            report(kind, "mul " + label, ok,
                   f"raw=0x{raw:064x} raw<=2p+37={raw <= RAW_MAX} got=0x{got:064x} exp=0x{exp:064x}")
            if a == b:
                raw = fe.unop("fe25519_sqr", a)
                got = fe.reduce_final()
                ok = got == exp and (kind == "I" or raw <= RAW_MAX)
                report(kind, "sqr " + label, ok,
                       f"raw=0x{raw:064x} raw<=2p+37={raw <= RAW_MAX} got=0x{got:064x} exp=0x{exp:064x}")

        # --- raw-output bound probe: search (a,b) <= 2p maximising the fold ---
        best = max(((model_reduce_wide((TWO_P - i) * (TWO_P - j)), TWO_P - i, TWO_P - j)
                    for i in range(1, 60) for j in range(i, 60)), key=lambda x: x[0])
        for label, a, b in [("search-max (2p-i)(2p-j)", best[1], best[2]),
                            ("(2p-1)*(2p-1) [raw=2p+1 measured]", TWO_P - 1, TWO_P - 1)]:
            raw = fe.binop("fe25519_mul", a, b); got = fe.reduce_final(); exp = (a * b) % P
            report("C", f"mul {label}: canonical result", got == exp, f"got=0x{got:064x} exp=0x{exp:064x}")
            report("C", f"mul {label}: documented Inv3 raw<=2p+37 (CT_ANALYSIS L27f/L29d, "
                   f"test_fe_reduce_wide_bound.py)", raw <= RAW_MAX,
                   f"raw=2p+{raw - TWO_P} (model predicted 2p+{model_reduce_wide(a*b) - TWO_P})")
            if a == b:
                raw = fe.unop("fe25519_sqr", a); got = fe.reduce_final()
                report("C", f"sqr {label}: canonical result", got == exp, f"got=0x{got:064x} exp=0x{exp:064x}")
                report("C", f"sqr {label}: documented Inv3 raw<=2p+37", raw <= RAW_MAX, f"raw=2p+{raw - TWO_P}")

        # sqr on every 32-byte pattern with bytes in {00, FF, 80, 7F} runs
        for pat in ("ff00", "00ff", "ff7f", "80ff", "ff80", "7fff", "fffe", "01ff"):
            b = bytes.fromhex(pat) * 16
            a = int.from_bytes(b, "little")
            kind = "C" if a <= TWO_P else "I"
            raw = fe.unop("fe25519_sqr", a); got = fe.reduce_final()
            exp = (a * a) % P
            report(kind, f"sqr pattern {pat}x16 (a<=2p={a <= TWO_P})",
                   got == exp and (kind == "I" or raw <= RAW_MAX),
                   f"raw=0x{raw:064x} got=0x{got:064x} exp=0x{exp:064x}")

        # ---------------- reduce_final -----------------------------------
        print("--- fe25519_reduce_final (input <= 2p is the contract) ---")
        for kind, label, v in [("C", "2p", TWO_P), ("C", "2p-1", TWO_P - 1), ("C", "p+1", P + 1),
                               ("C", "p+18", P + 18), ("C", "p+19 = 2^255", P + 19),
                               ("C", "2^255-1 = p+18", (1 << 255) - 1),
                               # fe_reduce_wide's real ceiling is 2^256-1 = 2p+37 (see the
                               # bound probe above), so these are IN contract for the ladder:
                               ("C", "2p+1 (measured raw sqr/mul output)", TWO_P + 1),
                               ("C", "2p+19", TWO_P + 19), ("C", "2p+37 = 2^256-1 (fold ceiling)", ALL_FF),
                               ("I", "2^256-1 again (idempotent)", ALL_FF)]:
            write_bytes(t, fe.t3, le(v))
            got = fe.reduce_final()
            report(kind, f"reduce_final({label})", got == v % P, f"got=0x{got:064x} exp=0x{v % P:064x}")

        # ---------------- add / sub ---------------------------------------
        print("--- fe25519_add / fe25519_sub (one operand may be <= 2p) ---")
        add_cases = [
            ("C", "(p-1)+(p-1)", P - 1, P - 1), ("C", "(2p-1)+(p-1)", TWO_P - 1, P - 1),
            ("C", "(p-1)+(2p-1)", P - 1, TWO_P - 1), ("C", "2p+0", TWO_P, 0),
            ("C", "p+p", P, P), ("C", "2p+(p-1)", TWO_P, P - 1), ("C", "(p+1)+(p-1)", P + 1, P - 1),
            ("C", "(2^255-1)+(2^255-1)", (1 << 255) - 1, (1 << 255) - 1),
            ("I", "(2p-1)+(2p-1)", TWO_P - 1, TWO_P - 1), ("I", "all-FF + 1", ALL_FF, 1),
        ]
        for kind, label, a, b in add_cases:
            got = fe.binop("fe25519_add", a, b, timeout=10.0)
            exp = (a + b) % P
            # add's own output contract: canonical iff one operand canonical
            report(kind, f"add {label}", got % P == exp and (kind == "I" or got <= TWO_P),
                   f"got=0x{got:064x} exp=0x{exp:064x}")
        sub_cases = [
            ("C", "0-(p-1)", 0, P - 1), ("C", "0-1", 0, 1), ("C", "p-(p-1)", P, P - 1),
            ("C", "(2p-1)-0", TWO_P - 1, 0), ("C", "(2p-1)-(p-1)", TWO_P - 1, P - 1),
            ("C", "2p-(p-1)", TWO_P, P - 1), ("C", "(p+1)-(p-1)", P + 1, P - 1),
            ("C", "1-(p-1)", 1, P - 1), ("C", "(p-1)-(p-1)", P - 1, P - 1),
            ("C", "p-p", P, P), ("C", "(2^255)-(p-1)", 1 << 255, P - 1),
            ("I", "0-(2p-1) (nc on src2)", 0, TWO_P - 1), ("I", "1-2p (nc on src2)", 1, TWO_P),
            ("I", "(p-1)-(p+1) (nc on src2)", P - 1, P + 1),
        ]
        for kind, label, a, b in sub_cases:
            got = fe.binop("fe25519_sub", a, b, timeout=10.0)
            exp = (a - b) % P
            report(kind, f"sub {label}", got % P == exp and (kind == "I" or got <= TWO_P),
                   f"got=0x{got:064x} exp=0x{exp:064x}")

        # ---------------- mul_a24 -----------------------------------------
        print("--- fe25519_mul_a24 ---")
        # Canonical inputs a < p for which lo + 38*hi of a*121665 crosses 2^256:
        # fe25519_mul_a24's @final_ripple (src/fe25519.s ~2055) adds through
        # byte 31 with `adc #0` and DROPS the carry out of byte 31 (2^256 = 38
        # mod p), so the result is a*121665 - 38 mod p. Search from the fold:
        # the smallest a per hi with a*121665 >= (hi+1)*2^256 - 38*hi.
        # ~577,892 canonical a values below p hit this (all hi in 0..60832).
        A24 = 121665
        drop_carry = []
        for hi in (60000, 60001, 30000, 1, 60832):
            a = -(-(((hi + 1) << 256) - 38 * hi) // A24)
            if (a * A24) >> 256 == hi and a < P:
                drop_carry.append((f"a<p with byte-31 carry dropped (hi={hi})", a))
        assert len(drop_carry) >= 3, "search produced too few witnesses"
        for label, a in drop_carry:
            got = fe.unop("fe25519_mul_a24", a, timeout=60.0)
            exp = (a * A24) % P
            got_c = fe.reduce_final()
            report("C", f"mul_a24({label}) a=0x{a:064x}", got_c == exp,
                   f"raw=0x{got:064x} got=0x{got_c:064x} exp=0x{exp:064x} (got-exp) mod p={(got_c - exp) % P}")
        for kind, label, a in [("C", "p-1", P - 1), ("C", "2p-1", TWO_P - 1), ("C", "2p", TWO_P),
                               ("C", "p", P), ("C", "p+1", P + 1), ("C", "2^255-1", (1 << 255) - 1),
                               ("C", "2^255", 1 << 255), ("C", "0x7F..7F", int("7f" * 32, 16)),
                               ("C", "random", R[1]),
                               # fe_reduce_wide's ceiling is 2^256-1, and E = AA - BB (sub, no
                               # borrow) passes a raw AA straight into mul_a24, so these are reachable:
                               ("C", "2p+1", TWO_P + 1), ("C", "2p+19", TWO_P + 19),
                               ("C", "2p+37 = all-FF (fold ceiling)", ALL_FF)]:
            got = fe.unop("fe25519_mul_a24", a, timeout=60.0)
            exp = (a * 121665) % P
            got_c = fe.reduce_final()
            report(kind, f"mul_a24({label})", got_c == exp and (kind == "I" or got <= TWO_P),
                   f"raw=0x{got:064x} got=0x{got_c:064x} exp=0x{exp:064x}")

        # ---------------- inv ---------------------------------------------
        print("--- fe25519_inv (each ~265 field ops) ---")
        for kind, label, a in [("C", "0", 0), ("C", "1", 1), ("C", "2", 2), ("C", "19", 19),
                               ("C", "p-1", P - 1), ("C", "p-2", P - 2), ("C", "2^254", 1 << 254),
                               ("C", "p (=0, non-canonical)", P), ("C", "p+1 (=1, non-canonical)", P + 1),
                               ("C", "2p-1 (=p-1, non-canonical)", TWO_P - 1),
                               ("C", "2^255-1 (=18)", (1 << 255) - 1), ("C", "random", R[2])]:
            got = fe.unop("fe25519_inv", a, timeout=900.0)
            exp = pow(a % P, P - 2, P)
            report(kind, f"inv({label})", got == exp,
                   f"got=0x{got:064x} exp=0x{exp:064x} a*got%p={(a * got) % P}")

        # ---------------- phantom slot -----------------------------------
        print("--- mul_src2_buf[32] phantom zero is load-bearing (documented) ---")
        write_bytes(t, labels["mul_src2_buf"] + 32, bytes([0xFF]))
        a = TWO_P - 1
        raw = fe.unop("fe25519_sqr", a); got = fe.reduce_final()
        exp = (a * a) % P
        report("I", "sqr(2p-1) with mul_src2_buf[32]=$FF (host trampled the phantom slot)",
               got == exp, f"got=0x{got:064x} exp=0x{exp:064x}")
        write_bytes(t, labels["mul_src2_buf"] + 32, bytes([0x00]))
        raw = fe.unop("fe25519_sqr", a); got = fe.reduce_final()
        report("C", "sqr(2p-1) after restoring the phantom zero", got == exp,
               f"got=0x{got:064x} exp=0x{exp:064x}")

        mgr.release(inst)
    assert fe.n > 40, "vacuous run"
    if FAILURES:
        print(f"\nFAIL: {len(FAILURES)} in-contract case(s):")
        for f in FAILURES:
            print("  " + f)
        sys.exit(1)
    print(f"PASS: {fe.n} field-op calls checked (big-int model, see caveat)")


if __name__ == "__main__":
    main()
