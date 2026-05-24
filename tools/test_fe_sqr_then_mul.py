#!/usr/bin/env python3
"""test_fe_sqr_then_mul.py — W2-class state-leak regression for the
c64-lib-contract issue #15 SMC-patch refactor of reu_fetch_doubled_row.

Background
==========
reu_fetch_doubled_row's DMA #1 was refactored in v0.7.0 prep to
SMC-patch the canonical reu_fetch_mul_row primitive at its
X25519_REU_BANK immediate-operand byte (label
`reu_fetch_mul_row_bank_patch`), retargeting it to
X25519_REU_BANK_DOUBLED for one call, then restoring it to
X25519_REU_BANK before RTS. The refactor:

  1. Trusts the (private) autoload-latch invariant established by
     `reu_clear_wide`'s tail and re-established by DMA #1's explicit
     re-writes of c64_lo/hi/len/reu_reu_lo/addr_ctrl before delegating
     to reu_fetch_mul_row.
  2. Leaves the SMC patch byte in a guaranteed-canonical state
     (`X25519_REU_BANK`) on every return path.
  3. Keeps DMA #2 (256B carry-table fetch from bank +3) inline because
     its length/target/offset-derivation differ from reu_fetch_mul_row.

Risk register coverage:
  R1 (SMC patch restore window — incorrect restore would corrupt the
      next fe25519_mul row fetch):
        exercised by running fe25519_sqr(x) — which loops 22 times
        through the DMA path, each iteration SMC-patches + restores —
        and then a series of fe25519_mul(y, z), then comparing the
        product against pyca.

  R2 (autoload-state corruption between reu_fetch_doubled_row calls —
      iteration N+1's DMA #1 inherits iteration N's DMA #2 latch
      residue):
        exercised by the same fe25519_sqr loop: 22 iterations of
        reu_fetch_doubled_row → if iteration 2..22 inherit
        mul_dma_carry/len=256 from iteration N-1's DMA #2 instead of
        re-establishing the canonical mul_dma_lo/len=512 latch, the
        doubled-lo/hi tables in mul_dma_lo/hi are corrupt and the
        squaring result diverges from pyca.

  R3 (K=0 build not exercising the refactor):
        the lib-x25519-1764 build gates reu_fetch_doubled_row out
        entirely. R3 is verified at build time + by a zero-delta
        bench (separate; see docs/design/issue_15_smc_patch_doubled_fetch.md).

The test uses the same direct-memory + jsr() shape as
test_fe25519.py. It is deterministic given the seed.
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

# p = 2^255 - 19
P = (1 << 255) - 19

DEFAULT_SEED = 25519
DEFAULT_TRIALS = 8


def int_to_le32(val):
    return (val % P).to_bytes(32, "little")


def le32_to_int(data):
    return int.from_bytes(data, "little")


def rand_fe(rng):
    return rng.randint(1, P - 1)


def set_fe_ptrs(transport, labels, src1=None, src2=None, dst=None):
    if src1 is not None:
        write_bytes(transport, labels["fe25519_src1"],
                    bytes([src1 & 0xFF, src1 >> 8]))
    if src2 is not None:
        write_bytes(transport, labels["fe25519_src2"],
                    bytes([src2 & 0xFF, src2 >> 8]))
    if dst is not None:
        write_bytes(transport, labels["fe25519_dst"],
                    bytes([dst & 0xFF, dst >> 8]))


def write_fe(transport, addr, val):
    write_bytes(transport, addr, int_to_le32(val))


def read_fe(transport, addr):
    return le32_to_int(read_bytes(transport, addr, 32))


def c64_fe_sqr(transport, labels, a):
    """fe25519_sqr(a) -> a^2 mod p. Returns reduced field element."""
    write_fe(transport, labels["fe25519_tmp1"], a)
    set_fe_ptrs(transport, labels,
                src1=labels["fe25519_tmp1"],
                dst=labels["fe25519_tmp3"])
    jsr(transport, labels["fe25519_sqr"], timeout=120.0)
    jsr(transport, labels["fe25519_reduce_final"], timeout=5.0)
    return read_fe(transport, labels["fe25519_tmp3"])


def c64_fe_mul(transport, labels, a, b, dst_label="fe25519_tmp3"):
    """fe25519_mul(a, b) -> a*b mod p. Returns reduced field element.

    Allows a custom dst label so we can place mul's output somewhere
    sqr did NOT just write to, ruling out the "sqr's destination
    happens to alias mul's output" pseudo-pass mode.
    """
    write_fe(transport, labels["fe25519_tmp1"], a)
    write_fe(transport, labels["fe25519_tmp2"], b)
    set_fe_ptrs(transport, labels,
                src1=labels["fe25519_tmp1"],
                src2=labels["fe25519_tmp2"],
                dst=labels[dst_label])
    jsr(transport, labels["fe25519_mul"], timeout=120.0)
    set_fe_ptrs(transport, labels, dst=labels[dst_label])
    jsr(transport, labels["fe25519_reduce_final"], timeout=5.0)
    return read_fe(transport, labels[dst_label])


def run_phase(transport, labels, rng, trials, *, prefix_sqr):
    """Run a single phase: optionally one fe25519_sqr, then a series
    of fe25519_mul, asserting each mul matches pyca.

    Returns (passed, failed).
    """
    passed = failed = 0

    if prefix_sqr:
        # Run a non-trivial sqr; its value doesn't matter for the
        # subsequent muls (different operands), but the *state it
        # leaves in REU registers / autoload latch* is what we're
        # probing. Use a high-entropy operand so the sqr path's full
        # 22-iter DMA loop is exercised end-to-end.
        x = rand_fe(rng)
        sqr_x = c64_fe_sqr(transport, labels, x)
        expected = (x * x) % P
        if sqr_x != expected:
            print(f"  FAIL prefix sqr: x={x:#x}")
            print(f"    expected={expected:#x}")
            print(f"    got     ={sqr_x:#x}")
            failed += 1
            return passed, failed
        passed += 1

    # Now do `trials` random muls, alternating dst labels so we don't
    # accidentally read stale data.
    dst_labels = ["fe25519_tmp3", "fe25519_tmp4"]
    for i in range(trials):
        y = rand_fe(rng)
        z = rand_fe(rng)
        dst = dst_labels[i % 2]
        expected = (y * z) % P
        got = c64_fe_mul(transport, labels, y, z, dst_label=dst)
        if got == expected:
            passed += 1
        else:
            failed += 1
            print(f"  FAIL mul #{i} (dst={dst}):")
            print(f"    y={y:#x}")
            print(f"    z={z:#x}")
            print(f"    expected={expected:#x}")
            print(f"    got     ={got:#x}")
            # Don't break — first failure prints, subsequent ones add detail
            # via the assert below.
            assert got == expected, (
                f"mul #{i}: y={y} z={z} expected={expected} got={got}"
            )

    return passed, failed


def main():
    os.chdir(PROJECT_ROOT)

    seed = DEFAULT_SEED
    trials = DEFAULT_TRIALS
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--seed" and i + 1 < len(args):
            seed = int(args[i + 1]); i += 2
        elif args[i] == "--trials" and i + 1 < len(args):
            trials = int(args[i + 1]); i += 2
        else:
            i += 1

    print(f"Random seed: {seed} (reproduce with --seed {seed})")
    print(f"Trials per phase: {trials}")

    # Build (test_fe25519.py-style: skip via C64_SKIP_BUILD for fast re-runs).
    if not os.environ.get("C64_SKIP_BUILD"):
        print("Building...")
        subprocess.run(["make", "clean"], capture_output=True, cwd=PROJECT_ROOT)
        result = subprocess.run(["make"], capture_output=True, text=True,
                                cwd=PROJECT_ROOT)
        if result.returncode != 0:
            print(f"Build failed:\n{result.stderr}")
            sys.exit(1)
    if not os.path.exists(PRG_PATH):
        print(f"FATAL: {PRG_PATH} not present")
        sys.exit(1)

    labels = Labels.from_file(LABELS_PATH)
    required = [
        "fe25519_src1", "fe25519_src2", "fe25519_dst",
        "fe25519_sqr", "fe25519_mul", "fe25519_reduce_final",
        "fe25519_tmp1", "fe25519_tmp2", "fe25519_tmp3", "fe25519_tmp4",
    ]
    for name in required:
        if labels.address(name) is None:
            print(f"FATAL: '{name}' label not found in {LABELS_PATH}")
            sys.exit(1)

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

        # Safety trampoline
        write_bytes(transport, 0x0339, bytes([0x4C, 0x39, 0x03]))

        rng = random.Random(seed)
        total_passed = total_failed = 0

        # -------------------------------------------------------------
        # Phase A: mul-only baseline (no preceding sqr). Establishes
        # that fe25519_mul is correct in isolation against pyca, so
        # any failure in Phase B is necessarily a state-leak from sqr
        # → mul (not a pre-existing mul bug).
        # -------------------------------------------------------------
        print("\n--- Phase A: mul-only baseline (no preceding sqr) ---")
        p, f = run_phase(transport, labels, rng, trials, prefix_sqr=False)
        print(f"  {p} passed, {f} failed")
        total_passed += p
        total_failed += f

        # -------------------------------------------------------------
        # Phase B: sqr-then-mul. Each sub-trial: fresh sqr (exercises
        # the 22-iter DMA loop in fe25519_sqr, including the SMC
        # patch+restore around reu_fetch_mul_row inside
        # reu_fetch_doubled_row), then a series of muls. We loop the
        # whole phase so the sqr → mul transition is exercised many
        # times in the SAME VICE instance (cumulative state-leak
        # surface; W2's root cause manifested across many sqr/mul
        # interleavings, not just one).
        # -------------------------------------------------------------
        print("\n--- Phase B: sqr-then-mul (R1+R2 coverage) ---")
        outer_iters = 4
        for j in range(outer_iters):
            print(f"  sub-trial {j+1}/{outer_iters}:")
            p, f = run_phase(transport, labels, rng, trials, prefix_sqr=True)
            print(f"    {p} passed, {f} failed")
            total_passed += p
            total_failed += f

        # -------------------------------------------------------------
        # Phase C: interleaved sqr/mul (each mul is preceded by a
        # fresh sqr on the same operand, mirroring the
        # x25519_scalarmult Montgomery-ladder shape where the inner
        # field ops alternate sqr/mul/sqr/mul).
        # -------------------------------------------------------------
        print("\n--- Phase C: tight sqr/mul interleave (ladder shape) ---")
        for j in range(trials):
            x = rand_fe(rng)
            y = rand_fe(rng)
            # sqr first (stomps autoload latch via DMA #2)
            sx = c64_fe_sqr(transport, labels, x)
            sx_expected = (x * x) % P
            if sx != sx_expected:
                total_failed += 1
                print(f"  FAIL C sqr #{j}: x={x:#x}")
                print(f"    expected={sx_expected:#x}")
                print(f"    got     ={sx:#x}")
                assert sx == sx_expected
            else:
                total_passed += 1

            # mul next (must re-establish autoload latch via reu_clear_wide)
            mul = c64_fe_mul(transport, labels, x, y, dst_label="fe25519_tmp3")
            mul_expected = (x * y) % P
            if mul != mul_expected:
                total_failed += 1
                print(f"  FAIL C mul #{j}: x={x:#x}, y={y:#x}")
                print(f"    expected={mul_expected:#x}")
                print(f"    got     ={mul:#x}")
                assert mul == mul_expected
            else:
                total_passed += 1

        mgr.release(inst)

    print("\n" + "=" * 60)
    print(f"Results: {total_passed} passed, {total_failed} failed")
    print("=" * 60)
    sys.exit(0 if total_failed == 0 else 1)


if __name__ == "__main__":
    main()
