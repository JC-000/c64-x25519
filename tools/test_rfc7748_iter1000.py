#!/usr/bin/env python3
"""test_rfc7748_iter1000.py — RFC 7748 §5.2 iterated vectors (1 and 1,000).

Replaces the never-passing tools/test_rfc7748_iterated.py, which

  (a) hard-codes a wrong 1-iteration literal (its tail
      ...e11196e8edcc4f1351d2cea3a6c4c6cd87bc8c0a48f2c1ee is not the RFC's
      ...a1350b3e2bb7279f7897b87bb6854b783c60e80311ae3079) — its own pyca
      sanity gate rejects it before the ladder runs, so the test has never
      passed; and
  (b) claims "the library applies clamping internally to x25_scalar" — it
      does not (src/x25519.s x25519_scalarmult reads x25_scalar as-is;
      only x25519_base clamps). RFC 7748 X25519(k, u) clamps k, so the
      caller must clamp before x25519_scalarmult.

Loop per RFC 7748 §5.2:
    k = u = 0x09 || 0^31
    repeat N: (k, u) = (X25519(k, u), k)

Expected k after 1 and 1,000 iterations are the RFC literals verbatim.
Every iteration is also checked against pyca/cryptography so a divergence
is localised to the iteration where it first appears. Hard asserts; any
mismatch aborts with the iteration number, the inputs and both outputs.

Cost: ~18 s per ladder under VICE warp on an M-series host (measured
2026-08-28; the "~100 min" in older tool docstrings is stale by ~300x),
so --iterations 1000 is ~5 h.

Usage:
    C64_SKIP_BUILD=1 python3 tools/test_rfc7748_iter1000.py [--iterations N]
"""

import os
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

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
BUILD_DIR = os.environ.get("X25519_BUILD_DIR", os.path.join(PROJECT_ROOT, "build"))
PRG_PATH = os.path.join(BUILD_DIR, "x25519.prg")
LABELS_PATH = os.path.join(BUILD_DIR, "labels.txt")

START = bytes([9]) + bytes(31)

# RFC 7748 §5.2, verbatim.
EXPECTED = {
    1: bytes.fromhex("422c8e7a6227d7bca1350b3e2bb7279f"
                     "7897b87bb6854b783c60e80311ae3079"),
    1000: bytes.fromhex("684cf59ba83309552800ef566f2f4d3c"
                        "1c3887c49360e3875f2eb94d99532c51"),
}


def clamp(k):
    s = bytearray(k)
    s[0] &= 0xF8
    s[31] = (s[31] & 0x7F) | 0x40
    return bytes(s)


def hazmat(k, u):
    return X25519PrivateKey.from_private_bytes(k).exchange(
        X25519PublicKey.from_public_bytes(u))


def c64_scalarmult(t, labels, k_clamped, u):
    write_bytes(t, labels["x25_scalar"], k_clamped)
    write_bytes(t, labels["x25_u"], u)
    jsr(t, labels["x25519_scalarmult"], timeout=7200.0)
    return read_bytes(t, labels["x25_result"], 32)


def main():
    iterations = 1000
    args = sys.argv[1:]
    if "--iterations" in args:
        iterations = int(args[args.index("--iterations") + 1])
    assert iterations in EXPECTED, "only 1 and 1000 have RFC literals"

    if not os.environ.get("C64_SKIP_BUILD"):
        r = subprocess.run(["make"], capture_output=True, text=True, cwd=PROJECT_ROOT)
        assert r.returncode == 0, r.stderr

    labels = Labels.from_file(LABELS_PATH)
    reu_args = ["+reu"] if os.environ.get("C64_NO_REU") else ["-reu", "-reusize", "512"]
    config = ViceConfig(prg_path=PRG_PATH, warp=True, ntsc=True, sound=False,
                        extra_args=reu_args)
    with ViceInstanceManager(config=config) as mgr:
        inst = mgr.acquire()
        t = inst.transport
        assert wait_for_text(t, "Q=QUIT", timeout=120.0) is not None, "no main menu"
        write_bytes(t, 0x0339, bytes([0x4C, 0x39, 0x03]))
        print(f"VICE PID={inst.pid}; iterations={iterations}", flush=True)

        k = u = START
        t_start = time.time()
        done = 0
        for i in range(1, iterations + 1):
            exp = hazmat(k, u)
            got = c64_scalarmult(t, labels, clamp(k), u)
            assert got == exp, (
                f"iteration {i}: C64 disagrees with pyca\n"
                f"  k={k.hex()}\n  u={u.hex()}\n"
                f"  pyca={exp.hex()}\n  c64 ={got.hex()}")
            # x25519_reu_fault lands with the REU settle work (PR #116);
            # skip the fault assertion on a tree that does not export it.
            if labels.address("x25519_reu_fault") is not None:
                fault = read_bytes(t, labels["x25519_reu_fault"], 1)[0]
                assert fault == 0, f"iteration {i}: x25519_reu_fault=${fault:02x}"
            k, u = got, k
            done = i
            if i % 10 == 0 or i == 1:
                el = time.time() - t_start
                print(f"  iter {i}/{iterations} ok  ({el/i:.1f} s/ladder, "
                      f"{el/60:.1f} min elapsed)", flush=True)
        mgr.release(inst)

    assert done == iterations, f"loop ran {done} != {iterations}"
    assert k == EXPECTED[iterations], (
        f"RFC 7748 §5.2 {iterations}-iteration mismatch\n"
        f"  expected {EXPECTED[iterations].hex()}\n  got      {k.hex()}")
    print(f"PASS: RFC 7748 §5.2 {iterations}-iteration vector matches "
          f"({done} ladders, all pyca-checked)")


if __name__ == "__main__":
    main()
