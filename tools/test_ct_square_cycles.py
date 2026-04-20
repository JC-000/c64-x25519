#!/usr/bin/env python3
"""CT cycle-count regression guard for fe25519_sqr.

Runs fe25519_sqr on inputs with sharply-different Hamming profiles
and asserts that per-call jiffy cost is within THRESHOLD_JIF across
all inputs. A failure here means Phase 6's CT invariants have been
violated by a recent change — secret-dependent timing has crept
back into the field-op hot path.

Baseline established against shipped v0.2.0 (commit cd9a663).

This is Phase 0 of the v0.3.0 perf-recovery plan: a guard that must
land before perf phases 1-5 start, so any future CT regression is
caught by the test suite rather than escaping into a release.

Mechanism: build a 6502 thunk that brackets BATCH_N back-to-back
``jsr fe25519_sqr`` calls inside a ``bench_start`` / ``bench_stop``
window, mirroring ``bench_fe_ops.py``'s sub-jiffy precision pattern.
Per-call jif = total_delta / BATCH_N (kept as float).

Usage:
    python3 tools/test_ct_square_cycles.py

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
# unused at runtime; matches bench_fe_ops.py).
BATCH_SUB_ADDR = 0x03B0

# Number of fe25519_sqr calls per batch. 200 amortizes the ±1-jif
# bench_start/bench_stop quantization down to ~0.005 jif resolution.
BATCH_N = 200

# Allowed spread (max - min per-call jif) across the input set.
# 1 jif = 1/60 s = ~17,045 NTSC cycles, ~85 cycles/call amortized over 200.
# Tight enough to catch real CT regressions, loose enough to absorb
# jiffy-clock quantization at the bench window boundary.
THRESHOLD_JIF = 1.0


# --- input set: sharply-different byte profiles -----------------------------
#
# Each input is a 32-byte little-endian fe25519 value chosen to exercise a
# distinct execution path that historically leaked secret-dependent timing:
#
#   dense_55  — every byte non-zero (alternating 0/1 bit pattern). Hits every
#               body of every outer-i in the squaring loop.
#   sparse_09 — one non-zero byte then all zeros. The X25519 basepoint shape;
#               exercises the zero-body paths Phase 5b had to fix.
#   mixed_mid — 16 zero bytes then 16 0xFF bytes. Half-and-half exercises the
#               phantom-slot guard at the i+j=64 boundary.
#   mixed_hi  — 24 zero bytes then 8 0xFF bytes. High-byte concentration
#               forces the mult66 regime (i >= 14).
#   diag_zeros — alternating zero / non-zero bytes. Targets the post-audit
#                @diag_prop path (2026-04-19). Pre-audit, @diag_prop had a
#                `beq @diag_skip` on `a[i] == 0` and a `bcc @diag_skip` on
#                the 16-bit diag-add carry — so this input (16 a[i]==0
#                bytes) would have short-circuited half the diagonal loop
#                iterations, creating a distinct timing profile from
#                dense_55 (all a[i] non-zero). Post-audit, the diagonal
#                ripple is unconditional and the cycle count matches the
#                dense profile.
#
INPUTS = [
    ("dense_55",   bytes([0x55] * 32)),
    ("sparse_09",  bytes([0x09]) + bytes(31)),
    ("mixed_mid",  bytes(16) + bytes([0xFF] * 16)),
    ("mixed_hi",   bytes(24) + bytes([0xFF] * 8)),
    ("diag_zeros", bytes([0x55 if (i & 1) else 0 for i in range(32)])),
]


def _read_ticks(transport, labels):
    ticks_data = read_bytes(transport, labels["bench_ticks"], 3)
    return (ticks_data[0] << 16) | (ticks_data[1] << 8) | ticks_data[2]


def _set_ptr(transport, labels, ptr_name, target_name):
    write_bytes(
        transport, labels[ptr_name],
        bytes([labels[target_name] & 0xFF, labels[target_name] >> 8]),
    )


def _prime_sqr_operand(transport, labels, le32):
    """Write the 32-byte LE input to fe25519_tmp1 and wire src1/dst pointers."""
    write_bytes(transport, labels["fe25519_tmp1"], le32)
    _set_ptr(transport, labels, "fe25519_src1", "fe25519_tmp1")
    _set_ptr(transport, labels, "fe25519_dst",  "fe25519_tmp3")


def _build_batch_thunk(labels, target_label, n):
    """Emit a 6502 subroutine that calls target N times inside bench_*.

    Layout at BATCH_SUB_ADDR (lifted from bench_fe_ops.py):
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


def _measure_input(transport, labels, name, le32):
    """Time BATCH_N back-to-back fe25519_sqr calls on `le32`. Return per-call jif."""
    _prime_sqr_operand(transport, labels, le32)
    total = _bench_op_batch(transport, labels, "fe25519_sqr", BATCH_N)
    return total / BATCH_N


def run(transport, labels):
    """Measure all inputs and return list of (name, per_call_jif) tuples."""
    return [(name, _measure_input(transport, labels, name, val))
            for name, val in INPUTS]


def report(measurements):
    """Pretty-print the measurement table to stdout."""
    print(f"\n--- fe25519_sqr CT cycle-count guard (batch={BATCH_N}) ---")
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
        lines = ["fe25519_sqr CT regression detected: per-call jif spread "
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
