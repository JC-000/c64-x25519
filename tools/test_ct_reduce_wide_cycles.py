#!/usr/bin/env python3
"""CT cycle-count regression guard for fe_reduce_wide (P7-D3, L27a-f).

Mirrors the structure of tools/test_ct_square_cycles.py but targets the
fe_reduce_wide closure landed in P7-D3. fe_reduce_wide is an internal
helper (not exported), so this test reaches it indirectly through
fe25519_mul, whose tail call is `jsr fe_reduce_wide`. Any
secret-dependent timing inside fe_reduce_wide leaks through fe25519_mul's
overall jiffy cost.

Pre-P7-D3, fe_reduce_wide had four distinct timing classes leaked under
L27a-f:

    L27a — `beq @reduce1_zero` early-out per byte: leaked the Hamming
           weight of fe_wide[32..63] (the upper-half of the 64-byte
           product, which is secret-derived).
    L27c — `beq @done` after fe_carry==0 check.
    L27d — `bcc @done` post fe_carry*38 add into fe_wide[0..1].
    L27e — `bcc @done` after the rare-overflow @prop3 path.
    L27f — secret-dependent termination of @prop2 / @prop3 inc loops.

Post-closure, all four paths run to completion with public-count
branches only. The cycle-spread across pathologically-different inputs
must be ≤ THRESHOLD_JIF.

Inputs are chosen so that the fe_wide state inside fe_reduce_wide
exhibits the patterns that historically drove distinct paths:

    smallxsmall — small * small; fe_wide upper half is mostly zero.
                  Pre-fix, this hit the @reduce1_zero shortcut on
                  ~24 of 32 iterations (massive timing skew vs dense).
    densexdense — every byte 0x55; fe_wide upper half is dense.
                  Pre-fix, this took the long @reduce1 path on every
                  iteration. New test target: this should now match
                  smallxsmall to within THRESHOLD_JIF.
    p_minus_1   — (p-1) * (p-1); maximizes fe_wide upper-half
                  magnitude and produces a final-carry-out pattern that
                  used to trigger the L27d/L27e overflow paths.
    near_p      — operand pair where (a*b) is just under p, so the
                  reduce produces a value with byte 0..1 near $FF —
                  exercising the cascade #1 ripple chain end-to-end.
    diag_zeros  — alternating zero / non-zero bytes; reuses the
                  diag_zeros pattern from test_ct_square_cycles.py to
                  drive an upper-half with isolated zero bytes
                  interspersed with non-zero bytes (former @reduce1_zero
                  alternation, the worst-case Hamming-weight leak shape).

Threshold note:
    The 1.0-jif threshold assumes the surrounding fe25519_mul / fe_cmp_p
    / fe25519_reduce_final / fe25519_sub stack is also CT-closed
    (P7-D3 siblings L25, L26, L28, L29). Until those land, the spread
    will reflect the union of all open leak sites, not just
    fe_reduce_wide. The test will pass cleanly once all P7-D3 closures
    are integrated and serves as a permanent forward-looking gate after
    that point.

Usage:
    python3 tools/test_ct_reduce_wide_cycles.py
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

# Scratch subroutine addr for batch-bench thunks (cassette buffer region;
# matches bench_fe_ops.py / test_ct_square_cycles.py).
BATCH_SUB_ADDR = 0x03B0

# Number of fe25519_mul calls per batch. 100 keeps each window under the
# bench-stop overflow margin while still amortizing ±1-jif quantization
# down to ~0.01 jif resolution (fe25519_mul is ~10x heavier than fe25519_sqr).
BATCH_N = 100

# Allowed spread (max - min per-call jif) across the input set.
# Same threshold as test_ct_square_cycles.py for consistency. The P7-D3
# expected closure cost of ~+120 jif/scalarmult divided across the
# ~6500 fe_reduce_wide invocations per ladder ≈ <0.02 jif/call —
# well within 1.0-jif quantization noise.
THRESHOLD_JIF = 1.0


P = (1 << 255) - 19


def _le32(n):
    return (n & ((1 << 256) - 1)).to_bytes(32, "little")


# --- input set: crafted to drive different former-fe_reduce_wide paths ---
INPUTS = [
    # L27a path: upper half of fe_wide mostly zero (small operands).
    ("smallxsmall", _le32(0x09), _le32(0x05)),

    # L27a path inverse: fe_wide upper half dense (every byte non-zero).
    ("densexdense", bytes([0x55] * 32), bytes([0x55] * 32)),

    # L27d/L27e overflow paths: maximize fe_wide upper-half magnitude.
    ("p_minus_1",   _le32(P - 1), _le32(P - 1)),

    # Cascade #1 ripple: near-p produces values with high-order bits set.
    ("near_p",      _le32(P - 0xDEAD), _le32(P - 0xBEEF)),

    # Hamming-weight leak shape: alternating zeros/non-zeros in upper half.
    ("diag_zeros",  bytes([0x55 if (i & 1) else 0 for i in range(32)]),
                    bytes([0x55 if (i & 1) else 0 for i in range(32)])),
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
    """Write a, b to tmp1, tmp2; wire src1/src2/dst pointers."""
    write_bytes(transport, labels["fe25519_tmp1"], a32)
    write_bytes(transport, labels["fe25519_tmp2"], b32)
    _set_ptr(transport, labels, "fe25519_src1", "fe25519_tmp1")
    _set_ptr(transport, labels, "fe25519_src2", "fe25519_tmp2")
    _set_ptr(transport, labels, "fe25519_dst",  "fe25519_tmp3")


def _build_batch_thunk(labels, target_label, n):
    """Emit a 6502 subroutine that calls target N times inside bench_*.

    Layout at BATCH_SUB_ADDR (lifted from bench_fe_ops.py /
    test_ct_square_cycles.py):
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
    """Time BATCH_N back-to-back fe25519_mul calls. Return per-call jif."""
    _prime_mul_operands(transport, labels, a32, b32)
    total = _bench_op_batch(transport, labels, "fe25519_mul", BATCH_N)
    return total / BATCH_N


def run(transport, labels):
    """Measure all inputs and return list of (name, per_call_jif) tuples."""
    return [(name, _measure_input(transport, labels, name, a, b))
            for name, a, b in INPUTS]


def report(measurements):
    """Pretty-print the measurement table to stdout."""
    print(f"\n--- fe_reduce_wide CT cycle-count guard "
          f"(via fe25519_mul, batch={BATCH_N}) ---")
    print(f"  {'input':<14s}  {'per-call jif':>14s}")
    for name, per_call in measurements:
        print(f"  {name:<14s}  {per_call:>14.5f}")
    per_calls = [pc for _, pc in measurements]
    spread = max(per_calls) - min(per_calls)
    print(f"  {'spread':<14s}  {spread:>14.5f}  (threshold = {THRESHOLD_JIF})")
    return spread


def assert_within_threshold(measurements):
    """Raise AssertionError if spread exceeds THRESHOLD_JIF."""
    per_calls = [pc for _, pc in measurements]
    spread = max(per_calls) - min(per_calls)
    if spread > THRESHOLD_JIF:
        lines = ["fe_reduce_wide CT regression detected: per-call jif spread "
                 f"{spread:.5f} > {THRESHOLD_JIF} jif threshold"]
        for name, per_call in measurements:
            lines.append(f"  {name:<14s}  {per_call:.5f} jif/call")
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
        # (mirrors test_ct_square_cycles.py).
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
