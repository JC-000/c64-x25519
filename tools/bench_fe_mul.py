#!/usr/bin/env python3
"""bench_fe_mul.py — Benchmark fe_mul timing on C64.

Measures the jiffy clock ticks for fe_mul with random field elements.
Use this to measure the impact of performance optimizations.

Usage:
    python3 tools/bench_fe_mul.py [--iterations N]
"""

import os
import random
import subprocess
import sys
import time

from c64_test_harness import (
    Labels, ViceConfig, ViceInstanceManager,
    read_bytes, write_bytes, jsr, wait_for_text,
)

PROJECT_ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
PRG_PATH = os.path.join(PROJECT_ROOT, "build", "x25519.prg")
LABELS_PATH = os.path.join(PROJECT_ROOT, "build", "labels.txt")

P = (1 << 255) - 19


def robust_jsr(transport, addr, timeout=10.0, retries=3, poll_interval=0.2):
    """jsr() with retry for transient VICE connection failures."""
    for attempt in range(retries):
        try:
            return jsr(transport, addr, timeout=timeout, poll_interval=poll_interval)
        except Exception as e:
            if attempt < retries - 1:
                time.sleep(0.5)
                continue
            raise


def int_to_le32(val):
    return (val % P).to_bytes(32, "little")


def le32_to_int(data):
    return int.from_bytes(data, "little")


def bench_fe_mul(transport, labels, a, b):
    """Time a single fe_mul call in jiffy ticks."""
    write_bytes(transport, labels["fe_tmp1"], int_to_le32(a))
    write_bytes(transport, labels["fe_tmp2"], int_to_le32(b))
    write_bytes(transport, labels["fe_src1"],
                bytes([labels["fe_tmp1"] & 0xFF, labels["fe_tmp1"] >> 8]))
    write_bytes(transport, labels["fe_src2"],
                bytes([labels["fe_tmp2"] & 0xFF, labels["fe_tmp2"] >> 8]))
    write_bytes(transport, labels["fe_dst"],
                bytes([labels["fe_tmp3"] & 0xFF, labels["fe_tmp3"] >> 8]))

    # Start timer, call fe_mul, stop timer
    robust_jsr(transport, labels["bench_start"])
    robust_jsr(transport, labels["fe_mul"], timeout=120.0, poll_interval=2.0)
    robust_jsr(transport, labels["bench_stop"])

    # Read jiffy ticks (3 bytes, big-endian in memory: MSB at jiffy_clock)
    ticks_data = read_bytes(transport, labels["bench_ticks"], 3)
    ticks = (ticks_data[0] << 16) | (ticks_data[1] << 8) | ticks_data[2]
    return ticks


def bench_fe_sqr(transport, labels, a):
    """Time a single fe_sqr call in jiffy ticks."""
    write_bytes(transport, labels["fe_tmp1"], int_to_le32(a))
    write_bytes(transport, labels["fe_src1"],
                bytes([labels["fe_tmp1"] & 0xFF, labels["fe_tmp1"] >> 8]))
    write_bytes(transport, labels["fe_dst"],
                bytes([labels["fe_tmp3"] & 0xFF, labels["fe_tmp3"] >> 8]))

    robust_jsr(transport, labels["bench_start"])
    robust_jsr(transport, labels["fe_sqr"], timeout=120.0, poll_interval=2.0)
    robust_jsr(transport, labels["bench_stop"])

    ticks_data = read_bytes(transport, labels["bench_ticks"], 3)
    ticks = (ticks_data[0] << 16) | (ticks_data[1] << 8) | ticks_data[2]
    return ticks


def main():
    os.chdir(PROJECT_ROOT)

    iterations = 5
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--iterations" and i + 1 < len(args):
            iterations = int(args[i + 1])
            i += 2
        else:
            i += 1

    seed = 25519
    rng = random.Random(seed)

    # Build
    print("Building...")
    subprocess.run(["make", "clean"], capture_output=True, cwd=PROJECT_ROOT)
    result = subprocess.run(["make"], capture_output=True, text=True,
                            cwd=PROJECT_ROOT)
    if result.returncode != 0:
        print(f"Build failed:\n{result.stderr}")
        sys.exit(1)
    print(f"Built: {PRG_PATH}")

    labels = Labels.from_file(LABELS_PATH)

    # Launch VICE
    config = ViceConfig(prg_path=PRG_PATH, warp=True, ntsc=True, sound=False)

    with ViceInstanceManager(
        config=config,
        port_range_start=6510,
        port_range_end=6530,
    ) as mgr:
        inst = mgr.acquire()
        print(f"VICE PID={inst.pid}, port={inst.port}")

        transport = inst.transport
        grid = wait_for_text(transport, "Q=QUIT", timeout=60.0, verbose=False)
        if grid is None:
            print("FATAL: Main menu did not appear")
            sys.exit(1)

        # Safety loop
        write_bytes(transport, 0x0339, bytes([0x4C, 0x39, 0x03]))

        print(f"\n--- fe_mul benchmark ({iterations} iterations) ---")
        mul_ticks = []
        for i in range(iterations):
            a = rng.randint(1, P - 1)
            b = rng.randint(1, P - 1)
            ticks = bench_fe_mul(transport, labels, a, b)
            mul_ticks.append(ticks)
            ms = ticks * 1000 / 60  # NTSC: 60 Hz jiffy clock
            print(f"  fe_mul #{i}: {ticks} jiffies ({ms:.0f} ms)")

        avg_mul = sum(mul_ticks) / len(mul_ticks)
        print(f"  Average: {avg_mul:.1f} jiffies ({avg_mul * 1000 / 60:.0f} ms)")

        print(f"\n--- fe_sqr benchmark ({iterations} iterations) ---")
        sqr_ticks = []
        for i in range(iterations):
            a = rng.randint(1, P - 1)
            ticks = bench_fe_sqr(transport, labels, a)
            sqr_ticks.append(ticks)
            ms = ticks * 1000 / 60
            print(f"  fe_sqr #{i}: {ticks} jiffies ({ms:.0f} ms)")

        avg_sqr = sum(sqr_ticks) / len(sqr_ticks)
        print(f"  Average: {avg_sqr:.1f} jiffies ({avg_sqr * 1000 / 60:.0f} ms)")

        # Estimate full X25519 time
        # 255 ladder steps × (4 mul + 1 mul_a24 + 2 sqr + 4 add/sub) per step
        # + 1 inversion (~253 sqr + 11 mul)
        # Total: ~255*4 + 11 = 1031 muls, 255*2 + 253 = 763 sqrs
        est_muls = 1031
        est_sqrs = 763
        est_total = est_muls * avg_mul + est_sqrs * avg_sqr
        est_sec = est_total / 60  # NTSC
        print(f"\n--- Estimated full X25519 time ---")
        print(f"  {est_muls} muls × {avg_mul:.1f} + {est_sqrs} sqrs × {avg_sqr:.1f}")
        print(f"  = {est_total:.0f} jiffies = {est_sec:.0f}s = {est_sec/60:.1f} min")

        mgr.release(inst)

    print("\nDone.")


if __name__ == "__main__":
    main()
