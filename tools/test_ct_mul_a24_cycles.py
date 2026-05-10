#!/usr/bin/env python3
"""CT cycle-count regression guard for fe25519_mul_a24.

Runs fe25519_mul_a24 (multiply by 121665) on inputs with sharply-different
Hamming profiles and asserts that per-call jiffy cost is within
THRESHOLD_JIF across all inputs. A failure here means the L28a-k closure
(unconditional outer-i body + 2-byte cascade, plus 3 unconditional
reduction stages with fe_carry threading and end-of-reduction ripple)
has been violated by a recent change - secret-dependent timing has crept
back into the field-op surface.

This is the mul_a24 counterpart to ``tools/test_ct_square_cycles.py``,
``tools/test_ct_mul_cycles.py``, and ``tools/test_ct_reduce_wide_cycles.py``.

Mechanism: build a 6502 thunk that brackets BATCH_N back-to-back
``jsr fe25519_mul_a24`` calls inside a ``bench_start`` / ``bench_stop``
window, mirroring ``bench_fe_ops.py``'s sub-jiffy precision pattern.
Per-call jif = total_delta / BATCH_N (kept as float).

Usage:
    python3 tools/test_ct_mul_a24_cycles.py

Exit code is non-zero on threshold violation so the Makefile target
fails the build.
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

# Scratch subroutine addr for batch-bench thunks (cassette buffer region,
# unused at runtime; matches bench_fe_ops.py / test_ct_square_cycles.py).
BATCH_SUB_ADDR = 0x03B0

# Number of fe25519_mul_a24 calls per batch. 200 amortizes the +/-1-jif
# bench_start/bench_stop quantization down to ~0.005 jif resolution.
BATCH_N = 200

# Allowed spread (max - min per-call jif) across the input set.
# 1 jif = 1/60 s = ~17,045 NTSC cycles. fe25519_mul_a24 is ~10-15 jif/call,
# so 1 jif of spread is well below 10% of total. Tight enough to catch
# real CT regressions, loose enough to absorb jiffy-clock quantization
# at the bench window boundary.
THRESHOLD_JIF = 1.0


# Constants
P25519 = (1 << 255) - 19


def _le32_int_to_bytes(n):
    """Convert a non-negative integer < 2^256 to 32-byte little-endian."""
    return n.to_bytes(32, "little")


# --- input set: structurally distinct byte profiles -------------------------
#
# Each input is a 32-byte little-endian fe25519 value chosen to exercise a
# distinct execution path that historically leaked secret-dependent timing
# in fe25519_mul_a24:
#
#   zero      - all-zero operand. Pre-L28, this took the
#               `beq @skip_zero_a24` early-out at every outer-i (32 calls
#               saved per call; max time-saving leak). Post-L28, body
#               runs unconditionally with the a24_b{0..3}[0]=0
#               table-zero invariant absorbing the no-op cleanly.
#   one       - byte 0 = 1, rest = 0. Single-byte input; tests the
#               i=0 unconditional cascade absorption boundary.
#   two       - byte 0 = 2, rest = 0. Hits a different a24_bN row.
#   a24_const - bytes encode 121665 itself in LE: $41, $DB, $01,
#               rest = 0. Operand-symmetric input.
#   p_minus_1 - p - 1 = 2^255 - 20 (every byte $FF except byte 0 = $EC,
#               byte 31 = $7F). Maximum-density carry case in the
#               outer loop; pre-L28 the `bcc/inc/inc` cascade ran at
#               full length here while sparse inputs short-circuited.
#   ff_all    - all bytes $FF. Above-p value; exercises maximal carry
#               density and reduction-stage carry threading. Pre-L28,
#               the three reduction stages each took the rare-path
#               `bcc / cpx #32` propagation loop.
#   alt_AA    - alternating $AA bytes. Constant-density, no zero
#               bytes; pre-L28 NEVER short-circuited the outer loop.
#   alt_55    - alternating $55 bytes. Same density as alt_AA but
#               different bit pattern through a24_bN tables.
#
# Plus 4 reproducible-seeded random inputs spanning [0, 2^256).
#
def _build_inputs():
    seeded = []
    rng = random.Random(0xA24A24)  # reproducible
    for k in range(4):
        v = rng.randrange(0, 1 << 256)
        seeded.append((f"rand_{k}", _le32_int_to_bytes(v)))

    return [
        ("zero",      bytes(32)),
        ("one",       bytes([0x01]) + bytes(31)),
        ("two",       bytes([0x02]) + bytes(31)),
        ("a24_const", bytes([0x41, 0xDB, 0x01]) + bytes(29)),
        ("p_minus_1", _le32_int_to_bytes(P25519 - 1)),
        ("ff_all",    bytes([0xFF] * 32)),
        ("alt_AA",    bytes([0xAA] * 32)),
        ("alt_55",    bytes([0x55] * 32)),
    ] + seeded


INPUTS = _build_inputs()


def _read_ticks(transport, labels):
    ticks_data = read_bytes(transport, labels["bench_ticks"], 3)
    return (ticks_data[0] << 16) | (ticks_data[1] << 8) | ticks_data[2]


def _set_ptr(transport, labels, ptr_name, target_name):
    write_bytes(
        transport, labels[ptr_name],
        bytes([labels[target_name] & 0xFF, labels[target_name] >> 8]),
    )


def _prime_mul_a24_operand(transport, labels, le32):
    """Write the 32-byte LE input to fe25519_tmp1 and wire src1/dst pointers."""
    write_bytes(transport, labels["fe25519_tmp1"], le32)
    _set_ptr(transport, labels, "fe25519_src1", "fe25519_tmp1")
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


def _measure_input(transport, labels, name, le32):
    """Time BATCH_N back-to-back fe25519_mul_a24 calls. Return per-call jif."""
    _prime_mul_a24_operand(transport, labels, le32)
    total = _bench_op_batch(transport, labels, "fe25519_mul_a24", BATCH_N)
    return total / BATCH_N


def run(transport, labels):
    """Measure all inputs and return list of (name, per_call_jif) tuples."""
    return [(name, _measure_input(transport, labels, name, val))
            for name, val in INPUTS]


def report(measurements):
    """Pretty-print the measurement table to stdout."""
    print(f"\n--- fe25519_mul_a24 CT cycle-count guard (batch={BATCH_N}) ---")
    print(f"  {'input':<12s}  {'per-call jif':>14s}")
    for name, per_call in measurements:
        print(f"  {name:<12s}  {per_call:>14.5f}")
    per_calls = [pc for _, pc in measurements]
    spread = max(per_calls) - min(per_calls)
    print(f"  {'spread':<12s}  {spread:>14.5f}  (threshold = {THRESHOLD_JIF})")
    return spread


def assert_within_threshold(measurements):
    """Raise AssertionError if spread exceeds THRESHOLD_JIF."""
    per_calls = [pc for _, pc in measurements]
    spread = max(per_calls) - min(per_calls)
    if spread > THRESHOLD_JIF:
        lines = ["fe25519_mul_a24 CT regression detected: per-call jif spread "
                 f"{spread:.5f} > {THRESHOLD_JIF} jif threshold"]
        for name, per_call in measurements:
            lines.append(f"  {name:<12s}  {per_call:.5f} jif/call")
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
