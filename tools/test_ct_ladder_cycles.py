#!/usr/bin/env python3
"""test_ct_ladder_cycles.py — exact-cycle CT guard for the paths the
jiffy-based guards do not gate: the full x25519_scalarmult ladder,
fe25519_inv, fe25519_cswap, fe25519_add / _sub / _reduce_final and
x25519_clamp.

Mechanism: CIA1 timer pair via bench_cycles_start / bench_cycles_stop
(src/util.s) — immune to the `sei` that x25519_scalarmult holds for its
whole body (the jiffy clock does not tick there; bench_x25519.py explains).
The screen is blanked (vic_blank) so no VIC-II badline steals cycles, and
IRQs are masked by bench_cycles_start, so under VICE the count is exactly
deterministic: two inputs that take the same instruction stream produce
IDENTICAL cycle counts. Any difference is therefore data-dependent timing
by construction (REU DMA time is included: the CIA keeps counting phi2
while the 6502 is halted).

Threshold: the existing guards allow 1 jiffy (~17,045 cycles) of spread on
a single field op. Here the spread across the whole ladder (~10^8 cycles)
must be <= THRESHOLD_CYCLES; the exact per-input counts are printed so a
reviewer can see a zero spread rather than merely a small one.

Usage:
    C64_SKIP_BUILD=1 python3 tools/test_ct_ladder_cycles.py [--quick]
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
THUNK = 0x03B0                  # cassette-buffer scratch, as the other CT guards
THRESHOLD_CYCLES = 17045        # 1 NTSC jiffy — same budget as the jiffy guards


def le(n):
    return (n % (1 << 256)).to_bytes(32, "little")


def clamp(k):
    s = bytearray(k); s[0] &= 0xF8; s[31] = (s[31] & 0x7F) | 0x40
    return bytes(s)


def thunk(labels, target, pre=b""):
    """vic_blank; bench_cycles_start; <pre>; jsr target; bench_cycles_stop; rts"""
    def jsr_(a): return bytes([0x20, a & 0xFF, a >> 8])
    return (jsr_(labels["vic_blank"]) + jsr_(labels["bench_cycles_start"]) + pre +
            jsr_(target) + jsr_(labels["bench_cycles_stop"]) + bytes([0x60]))


def measure(t, labels, target, pre=b"", timeout=7200.0):
    write_bytes(t, THUNK, thunk(labels, target, pre))
    jsr(t, THUNK, timeout=timeout)
    return int.from_bytes(read_bytes(t, labels["bench_cycles"], 4), "little")


def ptr(t, labels, name, addr):
    write_bytes(t, labels[name], bytes([addr & 0xFF, addr >> 8]))


def table(title, rows):
    print(f"\n--- {title} ---")
    vals = [c for _, c in rows]
    for name, c in rows:
        print(f"  {name:<44s} {c:>12,d} cycles  (delta {c - min(vals):+d})")
    spread = max(vals) - min(vals)
    print(f"  {'spread':<44s} {spread:>12,d} cycles  (threshold {THRESHOLD_CYCLES:,d})")
    return spread


def main():
    quick = "--quick" in sys.argv
    if not os.environ.get("C64_SKIP_BUILD"):
        r = subprocess.run(["make"], capture_output=True, text=True, cwd=PROJECT_ROOT)
        assert r.returncode == 0, r.stderr
    labels = Labels.from_file(LABELS_PATH)
    reu_args = ["+reu"] if os.environ.get("C64_NO_REU") else ["-reu", "-reusize", "512"]
    config = ViceConfig(prg_path=PRG_PATH, warp=True, ntsc=True, sound=False, extra_args=reu_args)
    rng = random.Random(31337)
    failures = []

    with ViceInstanceManager(config=config) as mgr:
        inst = mgr.acquire(); t = inst.transport
        assert wait_for_text(t, "Q=QUIT", timeout=120.0) is not None
        write_bytes(t, 0x0339, bytes([0x4C, 0x39, 0x03]))
        t1, t2, t3 = labels["fe25519_tmp1"], labels["fe25519_tmp2"], labels["fe25519_tmp3"]

        # ---- determinism control: same input twice must be identical ----
        ptr(t, labels, "fe25519_src1", t1); ptr(t, labels, "fe25519_dst", t3)
        write_bytes(t, t1, le(rng.randrange(P)))
        a = measure(t, labels, labels["fe25519_sqr"]); b = measure(t, labels, labels["fe25519_sqr"])
        print(f"determinism control: fe25519_sqr same input twice: {a:,d} vs {b:,d}")
        assert a == b, "measurement is not deterministic; results below are meaningless"

        # ---- cheap ops ----
        rows = []
        for name, x, y in [("add: no carry, < p", 1, 2), ("add: sum >= p", P - 1, P - 1),
                           ("add: 2^256 overflow (2p-1 + p-1)", 2 * P - 1, P - 1),
                           ("add: 0+0", 0, 0)]:
            write_bytes(t, t1, le(x)); write_bytes(t, t2, le(y))
            ptr(t, labels, "fe25519_src1", t1); ptr(t, labels, "fe25519_src2", t2); ptr(t, labels, "fe25519_dst", t3)
            rows.append((name, measure(t, labels, labels["fe25519_add"], timeout=30)))
        s = table("fe25519_add", rows); failures += ["fe25519_add"] if s > THRESHOLD_CYCLES else []
        rows = []
        for name, x, y in [("sub: no borrow", 5, 2), ("sub: borrow", 0, P - 1),
                           ("sub: nc src1 no borrow (2p-1 - 0)", 2 * P - 1, 0), ("sub: 0-0", 0, 0)]:
            write_bytes(t, t1, le(x)); write_bytes(t, t2, le(y))
            rows.append((name, measure(t, labels, labels["fe25519_sub"], timeout=30)))
        s = table("fe25519_sub", rows); failures += ["fe25519_sub"] if s > THRESHOLD_CYCLES else []
        rows = []
        for name, x in [("reduce_final: 0", 0), ("reduce_final: p-1", P - 1), ("reduce_final: p", P),
                        ("reduce_final: 2p", 2 * P), ("reduce_final: 2p-1", 2 * P - 1)]:
            write_bytes(t, t3, le(x)); ptr(t, labels, "fe25519_dst", t3)
            rows.append((name, measure(t, labels, labels["fe25519_reduce_final"], timeout=30)))
        s = table("fe25519_reduce_final", rows); failures += ["fe25519_reduce_final"] if s > THRESHOLD_CYCLES else []
        rows = []
        for name, m in [("cswap mask $00", 0x00), ("cswap mask $FF", 0xFF), ("cswap mask $0F (malformed)", 0x0F)]:
            write_bytes(t, t1, le(rng.randrange(P))); write_bytes(t, t2, le(rng.randrange(P)))
            ptr(t, labels, "fe25519_src1", t1); ptr(t, labels, "fe25519_src2", t2)
            rows.append((name, measure(t, labels, labels["fe25519_cswap"], pre=bytes([0xA9, m]), timeout=30)))
        s = table("fe25519_cswap", rows); failures += ["fe25519_cswap"] if s > THRESHOLD_CYCLES else []
        rows = []
        for name, k in [("clamp 00*32", bytes(32)), ("clamp FF*32", bytes([0xFF] * 32))]:
            write_bytes(t, labels["x25_scalar"], k)
            rows.append((name, measure(t, labels, labels["x25519_clamp"], timeout=30)))
        s = table("x25519_clamp", rows); failures += ["x25519_clamp"] if s > THRESHOLD_CYCLES else []

        # ---- fe25519_inv ----
        rows = []
        inv_inputs = [("inv 0", 0), ("inv 1", 1), ("inv 2", 2), ("inv p-1", P - 1),
                      ("inv sparse 09", 9), ("inv 2^254", 1 << 254), ("inv random", rng.randrange(P)),
                      ("inv 2p-1 (non-canonical)", 2 * P - 1)]
        if quick:
            inv_inputs = inv_inputs[:4]
        for name, x in inv_inputs:
            write_bytes(t, t1, le(x)); ptr(t, labels, "fe25519_src1", t1); ptr(t, labels, "fe25519_dst", t3)
            rows.append((name, measure(t, labels, labels["fe25519_inv"], timeout=900)))
        s = table("fe25519_inv", rows); failures += ["fe25519_inv"] if s > THRESHOLD_CYCLES else []

        # ---- full ladder ----
        scalars = [("k=clamp(00*32)", clamp(bytes(32))), ("k=clamp(FF*32)", clamp(bytes([0xFF] * 32))),
                   ("k=clamp(55*32)", clamp(bytes([0x55] * 32))),
                   ("k=clamp(random)", clamp(bytes(rng.getrandbits(8) for _ in range(32))))]
        us = [("u=9", le(9)), ("u=0", le(0)), ("u=1", le(1)), ("u=p-1", le(P - 1)),
              ("u=random", le(rng.randrange(P)))]
        if quick:
            scalars, us = scalars[:2], us[:3]
        rows = []
        for sn, k in scalars:
            for un, u in us:
                write_bytes(t, labels["x25_scalar"], k); write_bytes(t, labels["x25_u"], u)
                c = measure(t, labels, labels["x25519_scalarmult"])
                rows.append((f"{sn} {un}", c))
                print(f"  {sn} {un}: {c:,d}", flush=True)
        s = table("x25519_scalarmult (full ladder)", rows)
        failures += ["x25519_scalarmult"] if s > THRESHOLD_CYCLES else []
        mgr.release(inst)

    assert not failures, f"CT cycle spread above threshold in: {failures}"
    print("\nPASS: every measured path has cycle spread within threshold "
          "(see exact deltas above; zero is the expectation under VICE).")


if __name__ == "__main__":
    main()
