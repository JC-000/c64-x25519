#!/usr/bin/env python3
"""CT cycle-count regression guard for fe25519_mul.

Runs fe25519_mul on input pairs with sharply-different Hamming profiles
and asserts that per-call jiffy cost is within THRESHOLD_JIF across
all inputs. A failure here means the L25/L26 closure (Phase-6-style
chain step + end-of-inner ripple, mirroring fe25519_sqr) has been
violated by a recent change - secret-dependent timing has crept back
into the field-op hot path.

This is the mul counterpart to ``tools/test_ct_square_cycles.py``.
Together they form the CT cycle-count gate for the two field-multiply
operations on the X25519 hot path.

Mechanism: build a 6502 thunk that brackets BATCH_N back-to-back
``jsr fe25519_mul`` calls inside a ``bench_start`` / ``bench_stop``
window, mirroring ``bench_fe_ops.py``'s sub-jiffy precision pattern.
Per-call jif = total_delta / BATCH_N (kept as float).

Usage:
    python3 tools/test_ct_mul_cycles.py

Exit code is non-zero on threshold violation so the Makefile target
fails the build.
"""

import os
import subprocess
import sys

from c64_test_harness import (
    Labels, ViceConfig, ViceInstanceManager,
    read_bytes, write_bytes, jsr, wait_for_text,
)

PROJECT_ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
PRG_PATH = os.path.join(PROJECT_ROOT, "build", "x25519.prg")
LABELS_PATH = os.path.join(PROJECT_ROOT, "build", "labels.txt")

# Scratch subroutine addr for batch-bench thunks (cassette buffer region,
# unused at runtime; matches bench_fe_ops.py / test_ct_square_cycles.py).
BATCH_SUB_ADDR = 0x03B0

# Number of fe25519_mul calls per batch. 200 amortizes the +/-1-jif
# bench_start/bench_stop quantization down to ~0.005 jif resolution.
BATCH_N = 200

# Allowed spread (max - min per-call jif) across the input set.
# 1 jif = 1/60 s = ~17,045 NTSC cycles. fe25519_mul is ~150-200 jif/call,
# so 1 jif of spread is well below 1% of total. Tight enough to catch
# real CT regressions, loose enough to absorb jiffy-clock quantization
# at the bench window boundary.
THRESHOLD_JIF = 1.0


# --- input set: structurally distinct byte profiles -------------------------
#
# Each input pair (a, b) is a tuple of 32-byte little-endian fe25519 values
# chosen to exercise a distinct execution path that historically leaked
# secret-dependent timing in fe25519_mul:
#
#   dense_55  - both operands every-byte non-zero (alternating 0/1 bits).
#               Hits every body of every outer-i unrolled iteration with
#               near-maximum carry density. Baseline for the slow path.
#   sparse_09 - one non-zero byte then all zeros. The X25519 basepoint
#               shape; exercises src1[i]==0 zero paths that L25 had to
#               close (zero-skip removed; row-0 DMA load = no-op).
#   mixed_mid - 16 zero bytes then 16 0xFF bytes on both sides.
#               Half-and-half exercises the phantom-slot guard at
#               i+j=64 boundary (body D's cpx mul_bound).
#   mixed_hi  - 24 zero bytes then 8 0xFF bytes on both sides.
#               High-byte concentration forces carry chains in the
#               upper half of the loop.
#   mul_zeros - alternating $00/$5A on both sides. Targets the L25
#               closure: pre-fix, src1[i]==0 took the `bne @nonzero_i
#               / jmp @skip_zero` short-circuit, skipping the entire
#               inner loop for half the outer iterations. Post-fix,
#               every outer-i runs all 32 inner iterations with the
#               row-0 DMA load yielding zero accumulation.
#   mul_ff    - runs of $FF on both sides (bytes [0,5,10,...] = $FF,
#               rest = $5A). Exercises L26 closure: pre-fix, every
#               body's `bcs @do_prop_X` took the rare-path branch,
#               kicking off a `cpx #64 / inx / bcs` carry-propagation
#               loop whose iteration count depended on the data
#               ($FF runs propagate further than non-$FF bytes).
#               Post-fix, all carries are threaded through mul_pending
#               and flushed by the unconditional end-of-inner ripple
#               (constant-count w.r.t. mul_pending).
#
INPUTS = [
    ("dense_55",   bytes([0x55] * 32),
                   bytes([0x55] * 32)),
    ("sparse_09",  bytes([0x09]) + bytes(31),
                   bytes([0x09]) + bytes(31)),
    ("mixed_mid",  bytes(16) + bytes([0xFF] * 16),
                   bytes(16) + bytes([0xFF] * 16)),
    ("mixed_hi",   bytes(24) + bytes([0xFF] * 8),
                   bytes(24) + bytes([0xFF] * 8)),
    ("mul_zeros",  bytes([(0x5A if (i & 1) else 0x00) for i in range(32)]),
                   bytes([(0x5A if (i & 1) else 0x00) for i in range(32)])),
    ("mul_ff",     bytes([(0xFF if (i % 5 == 0) else 0x5A) for i in range(32)]),
                   bytes([(0xFF if (i % 5 == 0) else 0x5A) for i in range(32)])),
]


def _read_ticks(transport, labels):
    ticks_data = read_bytes(transport, labels["bench_ticks"], 3)
    return (ticks_data[0] << 16) | (ticks_data[1] << 8) | ticks_data[2]


def _set_ptr(transport, labels, ptr_name, target_name):
    write_bytes(
        transport, labels[ptr_name],
        bytes([labels[target_name] & 0xFF, labels[target_name] >> 8]),
    )


def _prime_mul_operands(transport, labels, a32, b32):
    """Write the 32-byte LE inputs to fe25519_tmp1/tmp2 and wire src1/src2/dst."""
    write_bytes(transport, labels["fe25519_tmp1"], a32)
    write_bytes(transport, labels["fe25519_tmp2"], b32)
    _set_ptr(transport, labels, "fe25519_src1", "fe25519_tmp1")
    _set_ptr(transport, labels, "fe25519_src2", "fe25519_tmp2")
    _set_ptr(transport, labels, "fe25519_dst",  "fe25519_tmp3")


def _build_batch_thunk(labels, target_label, n):
    """Emit a 6502 subroutine that calls target N times inside bench_*.

    Layout at BATCH_SUB_ADDR (lifted from test_ct_square_cycles.py):
      jsr bench_start
      ldx #n ; stx $0200        (loop counter in page 2, BASIC input buf)
    loop:
      jsr target                (3 bytes)
      dec $0200                 (3 bytes)
      bne loop                  (2 bytes; branch offset -8)
      jsr bench_stop
      rts
    """
    if not (1 <= n <= 255):
        raise ValueError("n must fit in one byte (1..255)")
    target = labels[target_label]
    bs = labels["bench_start"]
    bp = labels["bench_stop"]
    code = bytearray()
    code += bytes([0x20, bs & 0xFF, bs >> 8])         # jsr bench_start
    code += bytes([0xA2, n])                           # ldx #n
    code += bytes([0x8E, 0x00, 0x02])                  # stx $0200
    code += bytes([0x20, target & 0xFF, target >> 8])  # jsr target  <- loop top
    code += bytes([0xCE, 0x00, 0x02])                  # dec $0200
    code += bytes([0xD0, 0xF8])                        # bne -8 -> jsr target
    code += bytes([0x20, bp & 0xFF, bp >> 8])          # jsr bench_stop
    code += bytes([0x60])                              # rts
    return bytes(code)


def _bench_op_batch(transport, labels, target_label, n):
    thunk = _build_batch_thunk(labels, target_label, n)
    write_bytes(transport, BATCH_SUB_ADDR, thunk)
    jsr(transport, BATCH_SUB_ADDR, timeout=300.0)
    return _read_ticks(transport, labels)


def _measure_input(transport, labels, name, a32, b32):
    """Time BATCH_N back-to-back fe25519_mul calls on (a,b). Return per-call jif."""
    _prime_mul_operands(transport, labels, a32, b32)
    total = _bench_op_batch(transport, labels, "fe25519_mul", BATCH_N)
    return total / BATCH_N


def run(transport, labels):
    """Measure all inputs and return list of (name, per_call_jif) tuples."""
    return [(name, _measure_input(transport, labels, name, a, b))
            for name, a, b in INPUTS]


def report(measurements):
    """Pretty-print the measurement table to stdout."""
    print(f"\n--- fe25519_mul CT cycle-count guard (batch={BATCH_N}) ---")
    print(f"  {'input':<10s}  {'per-call jif':>14s}")
    for name, per_call in measurements:
        print(f"  {name:<10s}  {per_call:>14.5f}")
    per_calls = [pc for _, pc in measurements]
    spread = max(per_calls) - min(per_calls)
    print(f"  {'spread':<10s}  {spread:>14.5f}  (threshold = {THRESHOLD_JIF})")
    return spread


def assert_within_threshold(measurements):
    """Raise AssertionError if spread exceeds THRESHOLD_JIF."""
    per_calls = [pc for _, pc in measurements]
    spread = max(per_calls) - min(per_calls)
    if spread > THRESHOLD_JIF:
        lines = ["fe25519_mul CT regression detected: per-call jif spread "
                 f"{spread:.5f} > {THRESHOLD_JIF} jif threshold"]
        for name, per_call in measurements:
            lines.append(f"  {name:<10s}  {per_call:.5f} jif/call")
        raise AssertionError("\n".join(lines))


def main():
    os.chdir(PROJECT_ROOT)

    if not os.path.exists(PRG_PATH):
        print("Building...")
        subprocess.run(["make"], capture_output=True, cwd=PROJECT_ROOT)
        if not os.path.exists(PRG_PATH):
            print("Build failed"); sys.exit(1)

    labels = Labels.from_file(LABELS_PATH)

    config = ViceConfig(prg_path=PRG_PATH, warp=True, ntsc=True, sound=False,
                        extra_args=["-reu", "-reusize", "512"])

    with ViceInstanceManager(config=config) as mgr:
        inst = mgr.acquire()
        print(f"VICE PID={inst.pid}, port={inst.port}")

        transport = inst.transport
        grid = wait_for_text(transport, "Q=QUIT", timeout=60.0, verbose=False)
        if grid is None:
            print("FATAL: Main menu did not appear"); sys.exit(1)

        # Safety loop at $0339 so errant control flow lands somewhere defined
        # (mirrors bench_fe_ops.py's trampoline).
        write_bytes(transport, 0x0339, bytes([0x4C, 0x39, 0x03]))

        measurements = run(transport, labels)
        report(measurements)

        try:
            assert_within_threshold(measurements)
        except AssertionError as exc:
            print(f"\nFAIL: {exc}")
            mgr.release(inst)
            sys.exit(1)

        mgr.release(inst)

    print("\nPASS: per-call jif spread within threshold.")


if __name__ == "__main__":
    main()
