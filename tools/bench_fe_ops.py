#!/usr/bin/env python3
"""bench_fe_ops.py — Unified benchmark for all fe25519 ops on C64.

Measures fe25519_mul, fe25519_sqr, fe25519_inv, fe25519_add, fe25519_sub,
fe25519_reduce_final, fe25519_cswap, and fe25519_mul_a24 in jiffy ticks.

For sub-jiffy ops (everything except fe25519_inv), the single-call bench
suffers from ±1-jif quantization (a ~4.4 jif op rounds to 4 or 5). To get
sub-jiffy precision, this script builds a small 6502 subroutine that calls
the target N times back-to-back inside one bench window and divides by N.

fe25519_inv is ~1150 jif per call, so single-call timing is precise
enough; the default is 20 iterations for averaging over random inputs.

fe25519_cswap takes its mask in A on entry. Since the harness's `jsr`
helper does not let us set A before the call, we install a 6-byte
trampoline at $0340 (LDA #mask / JSR fe25519_cswap / RTS) and bench
that trampoline both single-call and batched.

Usage:
    python3 tools/bench_fe_ops.py [--iterations N] [--batch N]
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

P = (1 << 255) - 19

# Scratch subroutine addr for batch-bench thunks (unused cassette buffer region)
BATCH_SUB_ADDR = 0x03B0


def int_to_le32(val):
    return (val % P).to_bytes(32, "little")


def _read_ticks(transport, labels):
    ticks_data = read_bytes(transport, labels["bench_ticks"], 3)
    return (ticks_data[0] << 16) | (ticks_data[1] << 8) | ticks_data[2]


def _set_ptr(transport, labels, ptr_name, target_name):
    write_bytes(
        transport, labels[ptr_name],
        bytes([labels[target_name] & 0xFF, labels[target_name] >> 8]),
    )


def _prime_mul_operands(transport, labels, a, b):
    write_bytes(transport, labels["fe25519_tmp1"], int_to_le32(a))
    write_bytes(transport, labels["fe25519_tmp2"], int_to_le32(b))
    _set_ptr(transport, labels, "fe25519_src1", "fe25519_tmp1")
    _set_ptr(transport, labels, "fe25519_src2", "fe25519_tmp2")
    _set_ptr(transport, labels, "fe25519_dst",  "fe25519_tmp3")


def _prime_sqr_operand(transport, labels, a):
    write_bytes(transport, labels["fe25519_tmp1"], int_to_le32(a))
    _set_ptr(transport, labels, "fe25519_src1", "fe25519_tmp1")
    _set_ptr(transport, labels, "fe25519_dst",  "fe25519_tmp3")


def _prime_addsub_operands(transport, labels, a, b):
    """fe25519_add / fe25519_sub: src1 + src2 -> dst (32-byte LE ops)."""
    write_bytes(transport, labels["fe25519_tmp1"], int_to_le32(a))
    write_bytes(transport, labels["fe25519_tmp2"], int_to_le32(b))
    _set_ptr(transport, labels, "fe25519_src1", "fe25519_tmp1")
    _set_ptr(transport, labels, "fe25519_src2", "fe25519_tmp2")
    _set_ptr(transport, labels, "fe25519_dst",  "fe25519_tmp3")


def _prime_reduce_final_operand(transport, labels, a):
    """fe25519_reduce_final canonicalizes (fe25519_dst). Stage value at dst."""
    write_bytes(transport, labels["fe25519_tmp3"], int_to_le32(a))
    _set_ptr(transport, labels, "fe25519_dst", "fe25519_tmp3")


def _prime_a24_operand(transport, labels, a):
    """fe25519_mul_a24: dst <- 121665 * src1."""
    write_bytes(transport, labels["fe25519_tmp1"], int_to_le32(a))
    _set_ptr(transport, labels, "fe25519_src1", "fe25519_tmp1")
    _set_ptr(transport, labels, "fe25519_dst",  "fe25519_tmp3")


def _prime_cswap_operands(transport, labels, a, b):
    """fe25519_cswap: swap src1 and src2 if mask in fe_carry == $FF.
       The mask is also passed in A on entry; we set it in the trampoline."""
    write_bytes(transport, labels["fe25519_tmp1"], int_to_le32(a))
    write_bytes(transport, labels["fe25519_tmp2"], int_to_le32(b))
    _set_ptr(transport, labels, "fe25519_src1", "fe25519_tmp1")
    _set_ptr(transport, labels, "fe25519_src2", "fe25519_tmp2")


# -- single-call benches -----------------------------------------------------

def bench_fe_mul(transport, labels, a, b):
    _prime_mul_operands(transport, labels, a, b)
    jsr(transport, labels["bench_start"])
    jsr(transport, labels["fe25519_mul"], timeout=120.0)
    jsr(transport, labels["bench_stop"])
    return _read_ticks(transport, labels)


def bench_fe_sqr(transport, labels, a):
    _prime_sqr_operand(transport, labels, a)
    jsr(transport, labels["bench_start"])
    jsr(transport, labels["fe25519_sqr"], timeout=120.0)
    jsr(transport, labels["bench_stop"])
    return _read_ticks(transport, labels)


def bench_fe_inv(transport, labels, a):
    _prime_sqr_operand(transport, labels, a)
    jsr(transport, labels["bench_start"])
    jsr(transport, labels["fe25519_inv"], timeout=240.0)
    jsr(transport, labels["bench_stop"])
    return _read_ticks(transport, labels)


def bench_fe_add(transport, labels, a, b):
    _prime_addsub_operands(transport, labels, a, b)
    jsr(transport, labels["bench_start"])
    jsr(transport, labels["fe25519_add"], timeout=30.0)
    jsr(transport, labels["bench_stop"])
    return _read_ticks(transport, labels)


def bench_fe_sub(transport, labels, a, b):
    _prime_addsub_operands(transport, labels, a, b)
    jsr(transport, labels["bench_start"])
    jsr(transport, labels["fe25519_sub"], timeout=30.0)
    jsr(transport, labels["bench_stop"])
    return _read_ticks(transport, labels)


def bench_fe_reduce_final(transport, labels, a):
    _prime_reduce_final_operand(transport, labels, a)
    jsr(transport, labels["bench_start"])
    jsr(transport, labels["fe25519_reduce_final"], timeout=30.0)
    jsr(transport, labels["bench_stop"])
    return _read_ticks(transport, labels)


def bench_fe_mul_a24(transport, labels, a):
    _prime_a24_operand(transport, labels, a)
    jsr(transport, labels["bench_start"])
    jsr(transport, labels["fe25519_mul_a24"], timeout=60.0)
    jsr(transport, labels["bench_stop"])
    return _read_ticks(transport, labels)


# fe25519_cswap takes its mask in A on entry. The harness's `jsr` helper
# does not let us set A before the call, so we install a 6-byte trampoline
# at $0340 (cassette buffer region, also used by the safety loop at $0339):
#     LDA #mask    (2 bytes)
#     JSR cswap    (3 bytes)
#     RTS          (1 byte)
CSWAP_TRAMP_ADDR = 0x0340


def _build_cswap_trampoline(labels, mask):
    target = labels["fe25519_cswap"]
    code = bytearray()
    code += bytes([0xA9, mask & 0xFF])                  # LDA #mask
    code += bytes([0x20, target & 0xFF, target >> 8])   # JSR fe25519_cswap
    code += bytes([0x60])                               # RTS
    return bytes(code)


def bench_fe_cswap(transport, labels, a, b, mask):
    _prime_cswap_operands(transport, labels, a, b)
    write_bytes(transport, CSWAP_TRAMP_ADDR,
                _build_cswap_trampoline(labels, mask))
    jsr(transport, labels["bench_start"])
    jsr(transport, CSWAP_TRAMP_ADDR, timeout=30.0)
    jsr(transport, labels["bench_stop"])
    return _read_ticks(transport, labels)


# -- batched bench (sub-jiffy precision via amortization) --------------------

def _build_batch_thunk(labels, target, n):
    """Emit a 6502 subroutine that calls target N times inside bench_*.

    `target` may be a string (label name) or an int (raw address); the
    address form lets us batch-bench the cswap trampoline at $0340.

    Layout at BATCH_SUB_ADDR:
      jsr bench_start
      ldx #n ; stx $0200        (loop counter in page 2, BASIC input buf)
    loop:
      jsr target                (6502 JSR = 3 bytes)
      dec $0200                 (3 bytes)
      bne loop                  (2 bytes; branch offset -8 back to jsr)
      jsr bench_stop
      rts
    """
    if not (1 <= n <= 255):
        raise ValueError("n must fit in one byte (1..255)")
    if isinstance(target, str):
        target = labels[target]
    bs = labels["bench_start"]
    bp = labels["bench_stop"]
    code = bytearray()
    code += bytes([0x20, bs & 0xFF, bs >> 8])        # jsr bench_start
    code += bytes([0xA2, n])                          # ldx #n
    code += bytes([0x8E, 0x00, 0x02])                 # stx $0200
    code += bytes([0x20, target & 0xFF, target >> 8]) # jsr target    <- loop top
    code += bytes([0xCE, 0x00, 0x02])                 # dec $0200
    code += bytes([0xD0, 0xF8])                       # bne -8 -> jsr target
    code += bytes([0x20, bp & 0xFF, bp >> 8])         # jsr bench_stop
    code += bytes([0x60])                             # rts
    return bytes(code)


def bench_batch(transport, labels, target, n):
    thunk = _build_batch_thunk(labels, target, n)
    write_bytes(transport, BATCH_SUB_ADDR, thunk)
    jsr(transport, BATCH_SUB_ADDR, timeout=300.0)
    return _read_ticks(transport, labels)


# -- main --------------------------------------------------------------------

def main():
    os.chdir(PROJECT_ROOT)

    iterations = 20
    batch_n = 200
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--iterations" and i + 1 < len(args):
            iterations = int(args[i + 1]); i += 2
        elif args[i] == "--batch" and i + 1 < len(args):
            batch_n = int(args[i + 1]); i += 2
        else:
            i += 1

    rng = random.Random(25519)

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
        write_bytes(transport, 0x0339, bytes([0x4C, 0x39, 0x03]))

        # --- single-call spread (noisy but shows distribution) ---
        print(f"\n--- fe25519_mul single-call ({iterations} iters) ---")
        mul_ticks = []
        for _ in range(iterations):
            mul_ticks.append(bench_fe_mul(
                transport, labels, rng.randint(1, P-1), rng.randint(1, P-1)))
        print(f"  min={min(mul_ticks)} max={max(mul_ticks)} "
              f"avg={sum(mul_ticks)/len(mul_ticks):.2f} jif")

        print(f"\n--- fe25519_sqr single-call ({iterations} iters) ---")
        sqr_ticks = []
        for _ in range(iterations):
            sqr_ticks.append(bench_fe_sqr(transport, labels, rng.randint(1, P-1)))
        print(f"  min={min(sqr_ticks)} max={max(sqr_ticks)} "
              f"avg={sum(sqr_ticks)/len(sqr_ticks):.2f} jif")

        print(f"\n--- fe25519_inv single-call ({iterations} iters) ---")
        inv_ticks = []
        for _ in range(iterations):
            inv_ticks.append(bench_fe_inv(transport, labels, rng.randint(1, P-1)))
        avg_inv = sum(inv_ticks) / len(inv_ticks)
        print(f"  min={min(inv_ticks)} max={max(inv_ticks)} "
              f"avg={avg_inv:.2f} jif")

        # --- single-call benches for the other fe25519 ops (W1) ---
        # These ops are well under one jiffy each; the single-call form is
        # mostly noise. Real precision comes from the batch results below.
        print(f"\n--- fe25519_add single-call ({iterations} iters) ---")
        add_ticks = []
        for _ in range(iterations):
            add_ticks.append(bench_fe_add(
                transport, labels, rng.randint(1, P-1), rng.randint(1, P-1)))
        print(f"  min={min(add_ticks)} max={max(add_ticks)} "
              f"avg={sum(add_ticks)/len(add_ticks):.2f} jif")

        print(f"\n--- fe25519_sub single-call ({iterations} iters) ---")
        sub_ticks = []
        for _ in range(iterations):
            sub_ticks.append(bench_fe_sub(
                transport, labels, rng.randint(1, P-1), rng.randint(1, P-1)))
        print(f"  min={min(sub_ticks)} max={max(sub_ticks)} "
              f"avg={sum(sub_ticks)/len(sub_ticks):.2f} jif")

        print(f"\n--- fe25519_reduce_final single-call ({iterations} iters) ---")
        rf_ticks = []
        for _ in range(iterations):
            rf_ticks.append(bench_fe_reduce_final(
                transport, labels, rng.randint(1, P-1)))
        print(f"  min={min(rf_ticks)} max={max(rf_ticks)} "
              f"avg={sum(rf_ticks)/len(rf_ticks):.2f} jif")

        print(f"\n--- fe25519_mul_a24 single-call ({iterations} iters) ---")
        a24_ticks = []
        for _ in range(iterations):
            a24_ticks.append(bench_fe_mul_a24(
                transport, labels, rng.randint(1, P-1)))
        print(f"  min={min(a24_ticks)} max={max(a24_ticks)} "
              f"avg={sum(a24_ticks)/len(a24_ticks):.2f} jif")

        print(f"\n--- fe25519_cswap single-call ({iterations} iters, alternating mask) ---")
        cs_ticks = []
        for it in range(iterations):
            mask = 0xFF if (it & 1) else 0x00
            cs_ticks.append(bench_fe_cswap(
                transport, labels, rng.randint(1, P-1), rng.randint(1, P-1),
                mask))
        print(f"  min={min(cs_ticks)} max={max(cs_ticks)} "
              f"avg={sum(cs_ticks)/len(cs_ticks):.2f} jif")

        # --- batch (sub-jiffy precision for mul/sqr/add/sub/reduce/a24/cswap) ---
        # Prime operands once; batch thunk reuses src1/src2/dst pointers.
        _prime_mul_operands(transport, labels,
                            rng.randint(1, P-1), rng.randint(1, P-1))
        t_mul = bench_batch(transport, labels, "fe25519_mul", batch_n)
        _prime_sqr_operand(transport, labels, rng.randint(1, P-1))
        t_sqr = bench_batch(transport, labels, "fe25519_sqr", batch_n)

        _prime_addsub_operands(transport, labels,
                               rng.randint(1, P-1), rng.randint(1, P-1))
        t_add = bench_batch(transport, labels, "fe25519_add", batch_n)
        _prime_addsub_operands(transport, labels,
                               rng.randint(1, P-1), rng.randint(1, P-1))
        t_sub = bench_batch(transport, labels, "fe25519_sub", batch_n)

        _prime_reduce_final_operand(transport, labels, rng.randint(1, P-1))
        t_rf = bench_batch(transport, labels, "fe25519_reduce_final", batch_n)

        _prime_a24_operand(transport, labels, rng.randint(1, P-1))
        t_a24 = bench_batch(transport, labels, "fe25519_mul_a24", batch_n)

        # cswap: batch the trampoline at $0340 (mask=$FF -> always swap).
        # The trampoline does LDA #$FF / JSR fe25519_cswap / RTS each call.
        _prime_cswap_operands(transport, labels,
                              rng.randint(1, P-1), rng.randint(1, P-1))
        write_bytes(transport, CSWAP_TRAMP_ADDR,
                    _build_cswap_trampoline(labels, 0xFF))
        t_cs = bench_batch(transport, labels, CSWAP_TRAMP_ADDR, batch_n)

        precise_mul = t_mul / batch_n
        precise_sqr = t_sqr / batch_n
        precise_add = t_add / batch_n
        precise_sub = t_sub / batch_n
        precise_rf  = t_rf  / batch_n
        precise_a24 = t_a24 / batch_n
        precise_cs  = t_cs  / batch_n
        print(f"\n--- batch {batch_n}x (sub-jiffy precise) ---")
        print(f"  fe25519_mul:           {t_mul:5d} jif / {batch_n} = {precise_mul:.3f} jif/call")
        print(f"  fe25519_sqr:           {t_sqr:5d} jif / {batch_n} = {precise_sqr:.3f} jif/call")
        print(f"  fe25519_add:           {t_add:5d} jif / {batch_n} = {precise_add:.3f} jif/call")
        print(f"  fe25519_sub:           {t_sub:5d} jif / {batch_n} = {precise_sub:.3f} jif/call")
        print(f"  fe25519_reduce_final:  {t_rf:5d} jif / {batch_n} = {precise_rf:.3f} jif/call")
        print(f"  fe25519_mul_a24:       {t_a24:5d} jif / {batch_n} = {precise_a24:.3f} jif/call")
        print(f"  fe25519_cswap (mask=$FF):{t_cs:5d} jif / {batch_n} = {precise_cs:.3f} jif/call")

        # --- fe_inv overhead accounting ---
        # fe_inv does 254 sqr + 11 mul via an addition chain for 2^255-21.
        expected_raw = 254 * precise_sqr + 11 * precise_mul
        overhead = avg_inv - expected_raw
        print(f"\n--- fe25519_inv overhead accounting ---")
        print(f"  254 sqr x {precise_sqr:.3f} = {254 * precise_sqr:7.1f} jif")
        print(f"   11 mul x {precise_mul:.3f} = {11 * precise_mul:7.1f} jif")
        print(f"  raw mul+sqr total     = {expected_raw:7.1f} jif")
        print(f"  measured fe25519_inv  = {avg_inv:7.1f} jif")
        print(f"  overhead (inv - raw)  = {overhead:+7.1f} jif")

        mgr.release(inst)

    print("\nDone.")


if __name__ == "__main__":
    main()
