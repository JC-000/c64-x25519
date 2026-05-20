#!/usr/bin/env python3
"""bench_fe_ops.py — Unified benchmark for all fe25519 ops on C64.

Measures fe25519_mul, fe25519_sqr, fe25519_inv, fe25519_add, fe25519_sub,
fe25519_reduce_final, fe25519_cswap, and fe25519_mul_a24.

Uses the CIA1 32-bit cycle counter (bench_cycles_start / bench_cycles_stop,
see src/util.s) for cycle-exact measurement that survives sei. Why CIA1:
PR #39's refactor of the older jiffy-based bench_start / bench_stop pair
removed the matching `cli` at the end of bench_start, leaving the body
running under sei. The kernal jiffy clock at $A0-$A2 is incremented by
the IRQ handler, so it stops ticking while bench_start's body runs and
the old per-op bench reports 0 jif for everything. CIA1 ticks at phi2
directly and is unaffected by the I-flag.

For sub-cycle ops the single-call bench is mostly noise (call overhead
dominates). Real precision comes from the batch path: a small 6502
subroutine calls the target N times back-to-back inside one CIA1
window and divides by N.

fe25519_cswap takes its mask in A on entry. Since the harness's `jsr`
helper does not let us set A before the call, we install a 6-byte
trampoline at $0340 (LDA #mask / JSR fe25519_cswap / RTS) and bench
that trampoline both single-call and batched.

Usage:
    python3 tools/bench_fe_ops.py [--iterations N] [--batch N]
                                  [--json out.json] [--no-blank]

By default the batch thunk wraps the timed region in jsr vic_blank /
jsr vic_unblank so per-op numbers match the "VIC-II blanked" baseline
quoted in the README. Use --no-blank to measure under display-active
conditions instead. --json writes a machine-readable record (consumed
by tools/perf_diff.py and the make bench-record pipeline).
"""

import json
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

# NTSC C64 derived constants (matches tools/bench_x25519.py).
NTSC_HZ = 60
NTSC_CYCLES_PER_SEC = 1_022_727
NTSC_CYCLES_PER_JIF = NTSC_CYCLES_PER_SEC / NTSC_HZ   # ≈ 17,045.45

# Scratch subroutine addr for batch-bench thunks (unused cassette buffer region)
BATCH_SUB_ADDR = 0x03B0


def int_to_le32(val):
    return (val % P).to_bytes(32, "little")


def _read_cycles(transport, labels):
    """Read the 4-byte little-endian u32 cycle count from bench_cycles."""
    b = read_bytes(transport, labels["bench_cycles"], 4)
    return b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24)


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
    jsr(transport, labels["bench_cycles_start"])
    jsr(transport, labels["fe25519_mul"], timeout=120.0)
    jsr(transport, labels["bench_cycles_stop"])
    return _read_cycles(transport, labels)


def bench_fe_sqr(transport, labels, a):
    _prime_sqr_operand(transport, labels, a)
    jsr(transport, labels["bench_cycles_start"])
    jsr(transport, labels["fe25519_sqr"], timeout=120.0)
    jsr(transport, labels["bench_cycles_stop"])
    return _read_cycles(transport, labels)


def bench_fe_inv(transport, labels, a):
    _prime_sqr_operand(transport, labels, a)
    jsr(transport, labels["bench_cycles_start"])
    jsr(transport, labels["fe25519_inv"], timeout=240.0)
    jsr(transport, labels["bench_cycles_stop"])
    return _read_cycles(transport, labels)


def bench_fe_add(transport, labels, a, b):
    _prime_addsub_operands(transport, labels, a, b)
    jsr(transport, labels["bench_cycles_start"])
    jsr(transport, labels["fe25519_add"], timeout=30.0)
    jsr(transport, labels["bench_cycles_stop"])
    return _read_cycles(transport, labels)


def bench_fe_sub(transport, labels, a, b):
    _prime_addsub_operands(transport, labels, a, b)
    jsr(transport, labels["bench_cycles_start"])
    jsr(transport, labels["fe25519_sub"], timeout=30.0)
    jsr(transport, labels["bench_cycles_stop"])
    return _read_cycles(transport, labels)


def bench_fe_reduce_final(transport, labels, a):
    _prime_reduce_final_operand(transport, labels, a)
    jsr(transport, labels["bench_cycles_start"])
    jsr(transport, labels["fe25519_reduce_final"], timeout=30.0)
    jsr(transport, labels["bench_cycles_stop"])
    return _read_cycles(transport, labels)


def bench_fe_mul_a24(transport, labels, a):
    _prime_a24_operand(transport, labels, a)
    jsr(transport, labels["bench_cycles_start"])
    jsr(transport, labels["fe25519_mul_a24"], timeout=60.0)
    jsr(transport, labels["bench_cycles_stop"])
    return _read_cycles(transport, labels)


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
    jsr(transport, labels["bench_cycles_start"])
    jsr(transport, CSWAP_TRAMP_ADDR, timeout=30.0)
    jsr(transport, labels["bench_cycles_stop"])
    return _read_cycles(transport, labels)


# -- batched bench (sub-jiffy precision via amortization) --------------------

def _build_batch_thunk(labels, target, n, blank=True):
    """Emit a 6502 subroutine that calls target N times inside the CIA1
    cycle counter.

    `target` may be a string (label name) or an int (raw address); the
    address form lets us batch-bench the cswap trampoline at $0340.

    With blank=True (the default), the thunk wraps the timed region in
    jsr vic_blank / jsr vic_unblank so that the measurement matches the
    "VIC-II blanked" baseline used by bench_x25519.py and quoted in the
    README. Without blanking, every measured op pays the ~20-25% badline
    penalty and the per-op numbers don't compose with the scalarmult
    number for cross-checking.

    Layout at BATCH_SUB_ADDR (blank=True):
      jsr vic_blank
      jsr bench_cycles_start     (sei + reconfigure CIA1 TA+TB as down-counter)
      ldx #n ; stx $0200         (loop counter in page 2, BASIC input buf)
    loop:
      jsr target                 (6502 JSR = 3 bytes)
      dec $0200                  (3 bytes)
      bne loop                   (2 bytes; branch offset -8 back to jsr)
      jsr bench_cycles_stop      (atomic stop + snapshot to bench_cycles)
      jsr vic_unblank
      rts

    Per-iteration scaffold overhead (JSR + DEC + BNE) is ~14 cycles, so
    at batch_n=200 the noise floor is ~14 × 200 / batch_n = 14 cycles
    per call after dividing — well below any fe25519_* op cost. The
    bench_cycles range is 2^32 cycles (~4.2 s of C64 time), more than
    enough for batch_n × longest-op (e.g. 200 × ~110k cy fe25519_mul =
    22M cycles, ~200x headroom).
    """
    if not (1 <= n <= 255):
        raise ValueError("n must fit in one byte (1..255)")
    if isinstance(target, str):
        target = labels[target]
    bs = labels["bench_cycles_start"]
    bp = labels["bench_cycles_stop"]
    vb = labels["vic_blank"]
    vu = labels["vic_unblank"]
    code = bytearray()
    if blank:
        code += bytes([0x20, vb & 0xFF, vb >> 8])    # jsr vic_blank
    code += bytes([0x20, bs & 0xFF, bs >> 8])        # jsr bench_cycles_start
    code += bytes([0xA2, n])                          # ldx #n
    code += bytes([0x8E, 0x00, 0x02])                 # stx $0200
    code += bytes([0x20, target & 0xFF, target >> 8]) # jsr target    <- loop top
    code += bytes([0xCE, 0x00, 0x02])                 # dec $0200
    code += bytes([0xD0, 0xF8])                       # bne -8 -> jsr target
    code += bytes([0x20, bp & 0xFF, bp >> 8])         # jsr bench_cycles_stop
    if blank:
        code += bytes([0x20, vu & 0xFF, vu >> 8])    # jsr vic_unblank
    code += bytes([0x60])                             # rts
    return bytes(code)


def bench_batch(transport, labels, target, n, blank=True):
    thunk = _build_batch_thunk(labels, target, n, blank=blank)
    write_bytes(transport, BATCH_SUB_ADDR, thunk)
    jsr(transport, BATCH_SUB_ADDR, timeout=300.0)
    return _read_cycles(transport, labels)


# -- main --------------------------------------------------------------------

def main():
    os.chdir(PROJECT_ROOT)

    iterations = 20
    batch_n = 200
    json_path = None       # --json <file>: also emit a machine-readable record
    blank = True           # --no-blank disables vic_blank in the batch thunk
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--iterations" and i + 1 < len(args):
            iterations = int(args[i + 1]); i += 2
        elif args[i] == "--batch" and i + 1 < len(args):
            batch_n = int(args[i + 1]); i += 2
        elif args[i] == "--json" and i + 1 < len(args):
            json_path = args[i + 1]; i += 2
        elif args[i] == "--no-blank":
            blank = False; i += 1
        else:
            i += 1

    rng = random.Random(25519)

    # make clean BEFORE make: ca65 doesn't track CA65FLAGS as a
    # dependency, so re-running this script after a different CA65FLAGS
    # invocation (e.g. the SQR_DMA_K=0 A/B in docs/REU_USAGE_ANALYSIS.md)
    # would otherwise reuse stale .o files and measure the wrong build.
    print("Building...")
    subprocess.run(["make", "clean"], capture_output=True, cwd=PROJECT_ROOT)
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

        # --- single-call spread (cycle-exact via CIA1; shows the
        #     CT spread across random inputs) ---
        def _summary(label, samples):
            mn, mx = min(samples), max(samples)
            avg = sum(samples) / len(samples)
            jif = avg / NTSC_CYCLES_PER_JIF
            print(f"  cycles: min={mn:,} max={mx:,} avg={avg:,.1f} "
                  f"({jif:.3f} jif/call)")

        print(f"\n--- fe25519_mul single-call ({iterations} iters) ---")
        mul_ticks = []
        for _ in range(iterations):
            mul_ticks.append(bench_fe_mul(
                transport, labels, rng.randint(1, P-1), rng.randint(1, P-1)))
        _summary("mul", mul_ticks)

        print(f"\n--- fe25519_sqr single-call ({iterations} iters) ---")
        sqr_ticks = []
        for _ in range(iterations):
            sqr_ticks.append(bench_fe_sqr(transport, labels, rng.randint(1, P-1)))
        _summary("sqr", sqr_ticks)

        print(f"\n--- fe25519_inv single-call ({iterations} iters) ---")
        inv_ticks = []
        for _ in range(iterations):
            inv_ticks.append(bench_fe_inv(transport, labels, rng.randint(1, P-1)))
        avg_inv_cy = sum(inv_ticks) / len(inv_ticks)
        avg_inv = avg_inv_cy / NTSC_CYCLES_PER_JIF
        _summary("inv", inv_ticks)

        print(f"\n--- fe25519_add single-call ({iterations} iters) ---")
        add_ticks = []
        for _ in range(iterations):
            add_ticks.append(bench_fe_add(
                transport, labels, rng.randint(1, P-1), rng.randint(1, P-1)))
        _summary("add", add_ticks)

        print(f"\n--- fe25519_sub single-call ({iterations} iters) ---")
        sub_ticks = []
        for _ in range(iterations):
            sub_ticks.append(bench_fe_sub(
                transport, labels, rng.randint(1, P-1), rng.randint(1, P-1)))
        _summary("sub", sub_ticks)

        print(f"\n--- fe25519_reduce_final single-call ({iterations} iters) ---")
        rf_ticks = []
        for _ in range(iterations):
            rf_ticks.append(bench_fe_reduce_final(
                transport, labels, rng.randint(1, P-1)))
        _summary("reduce_final", rf_ticks)

        print(f"\n--- fe25519_mul_a24 single-call ({iterations} iters) ---")
        a24_ticks = []
        for _ in range(iterations):
            a24_ticks.append(bench_fe_mul_a24(
                transport, labels, rng.randint(1, P-1)))
        _summary("mul_a24", a24_ticks)

        print(f"\n--- fe25519_cswap single-call ({iterations} iters, alternating mask) ---")
        cs_ticks = []
        for it in range(iterations):
            mask = 0xFF if (it & 1) else 0x00
            cs_ticks.append(bench_fe_cswap(
                transport, labels, rng.randint(1, P-1), rng.randint(1, P-1),
                mask))
        _summary("cswap", cs_ticks)

        # --- batch (sub-jiffy precision for mul/sqr/add/sub/reduce/a24/cswap) ---
        # Prime operands once; batch thunk reuses src1/src2/dst pointers.
        _prime_mul_operands(transport, labels,
                            rng.randint(1, P-1), rng.randint(1, P-1))
        t_mul = bench_batch(transport, labels, "fe25519_mul", batch_n,
                            blank=blank)
        _prime_sqr_operand(transport, labels, rng.randint(1, P-1))
        t_sqr = bench_batch(transport, labels, "fe25519_sqr", batch_n,
                            blank=blank)

        _prime_addsub_operands(transport, labels,
                               rng.randint(1, P-1), rng.randint(1, P-1))
        t_add = bench_batch(transport, labels, "fe25519_add", batch_n,
                            blank=blank)
        _prime_addsub_operands(transport, labels,
                               rng.randint(1, P-1), rng.randint(1, P-1))
        t_sub = bench_batch(transport, labels, "fe25519_sub", batch_n,
                            blank=blank)

        _prime_reduce_final_operand(transport, labels, rng.randint(1, P-1))
        t_rf = bench_batch(transport, labels, "fe25519_reduce_final",
                           batch_n, blank=blank)

        _prime_a24_operand(transport, labels, rng.randint(1, P-1))
        t_a24 = bench_batch(transport, labels, "fe25519_mul_a24", batch_n,
                            blank=blank)

        # cswap: batch the trampoline at $0340 (mask=$FF -> always swap).
        # The trampoline does LDA #$FF / JSR fe25519_cswap / RTS each call.
        _prime_cswap_operands(transport, labels,
                              rng.randint(1, P-1), rng.randint(1, P-1))
        write_bytes(transport, CSWAP_TRAMP_ADDR,
                    _build_cswap_trampoline(labels, 0xFF))
        t_cs = bench_batch(transport, labels, CSWAP_TRAMP_ADDR, batch_n,
                           blank=blank)

        # `t_*` are CIA1 cycle counts for `batch_n` back-to-back calls
        # (plus a fixed per-batch scaffold: 2-3 jsr/rts + ldx + stx +
        # bench_cycles_start/stop overhead, totaling well under 200 cy
        # and amortised away by batch_n).
        precise_mul_cy = t_mul / batch_n
        precise_sqr_cy = t_sqr / batch_n
        precise_add_cy = t_add / batch_n
        precise_sub_cy = t_sub / batch_n
        precise_rf_cy  = t_rf  / batch_n
        precise_a24_cy = t_a24 / batch_n
        precise_cs_cy  = t_cs  / batch_n

        def _j(cy):  # cycles -> jif/call for human-readable parity
            return cy / NTSC_CYCLES_PER_JIF

        precise_mul = _j(precise_mul_cy)
        precise_sqr = _j(precise_sqr_cy)
        precise_add = _j(precise_add_cy)
        precise_sub = _j(precise_sub_cy)
        precise_rf  = _j(precise_rf_cy)
        precise_a24 = _j(precise_a24_cy)
        precise_cs  = _j(precise_cs_cy)

        print(f"\n--- batch {batch_n}x (cycle-exact via CIA1) ---")
        print(f"  fe25519_mul:            {t_mul:>11,} cy / {batch_n} "
              f"= {precise_mul_cy:>10,.1f} cy/call  ({precise_mul:.3f} jif)")
        print(f"  fe25519_sqr:            {t_sqr:>11,} cy / {batch_n} "
              f"= {precise_sqr_cy:>10,.1f} cy/call  ({precise_sqr:.3f} jif)")
        print(f"  fe25519_add:            {t_add:>11,} cy / {batch_n} "
              f"= {precise_add_cy:>10,.1f} cy/call  ({precise_add:.3f} jif)")
        print(f"  fe25519_sub:            {t_sub:>11,} cy / {batch_n} "
              f"= {precise_sub_cy:>10,.1f} cy/call  ({precise_sub:.3f} jif)")
        print(f"  fe25519_reduce_final:   {t_rf:>11,} cy / {batch_n} "
              f"= {precise_rf_cy:>10,.1f} cy/call  ({precise_rf:.3f} jif)")
        print(f"  fe25519_mul_a24:        {t_a24:>11,} cy / {batch_n} "
              f"= {precise_a24_cy:>10,.1f} cy/call  ({precise_a24:.3f} jif)")
        print(f"  fe25519_cswap (mask=$FF):{t_cs:>10,} cy / {batch_n} "
              f"= {precise_cs_cy:>10,.1f} cy/call  ({precise_cs:.3f} jif)")

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

        # --- JSON sidecar for machine-readable consumption by
        #     tools/perf_diff.py and the docs/perf_history.csv pipeline ---
        if json_path:
            record = {
                "batch_n": batch_n,
                "iterations": iterations,
                "vic_blanked": blank,
                "measurement": "CIA1_cycles",
                # Cycle-exact (raw CIA1 counts / batch_n).
                "fe25519_mul_cy":          precise_mul_cy,
                "fe25519_sqr_cy":          precise_sqr_cy,
                "fe25519_add_cy":          precise_add_cy,
                "fe25519_sub_cy":          precise_sub_cy,
                "fe25519_reduce_final_cy": precise_rf_cy,
                "fe25519_mul_a24_cy":      precise_a24_cy,
                "fe25519_cswap_cy":        precise_cs_cy,
                "fe25519_inv_cy":          avg_inv_cy,
                # Derived jif (cycles / NTSC_CYCLES_PER_JIF) for human-
                # readable parity with the historical README numbers.
                "fe25519_mul_jif":          precise_mul,
                "fe25519_sqr_jif":          precise_sqr,
                "fe25519_add_jif":          precise_add,
                "fe25519_sub_jif":          precise_sub,
                "fe25519_reduce_final_jif": precise_rf,
                "fe25519_mul_a24_jif":      precise_a24,
                "fe25519_cswap_jif":        precise_cs,
                "fe25519_inv_jif":          avg_inv,
                "fe25519_inv_overhead_jif": overhead,
            }
            with open(json_path, "w") as f:
                json.dump(record, f, indent=2, sort_keys=True)
                f.write("\n")
            print(f"\nJSON sidecar written: {json_path}")

        mgr.release(inst)

    print("\nDone.")


if __name__ == "__main__":
    main()
