#!/usr/bin/env python3
"""bench_x25519.py — End-to-end X25519 scalarmult benchmark on C64.

Runs a full x25519_base (scalar * basepoint 9) natively on the C64 and
measures wall-clock time via the jiffy clock.

Uses jsr_poll() (flag-based completion detection) for reliable long-running
computation in warp mode — avoids the VICE monitor unresponsiveness that
occurs with breakpoint-based approaches during heavy computation.

Usage:
    python3 tools/bench_x25519.py [--no-verify] [--no-blank] [--poll N]

    --poll N    Poll interval in seconds (default: 30)
"""

import json
import os
import subprocess
import sys
import time

from c64_test_harness import (
    Labels, ViceConfig, ViceInstanceManager,
    read_bytes, write_bytes, jsr_poll, wait_for_text,
)
from c64_test_harness.execute import load_code

PROJECT_ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
PRG_PATH = os.path.join(PROJECT_ROOT, "build", "x25519.prg")
LABELS_PATH = os.path.join(PROJECT_ROOT, "build", "labels.txt")
VECTORS_PATH = os.path.join(PROJECT_ROOT, "test", "rfc7748_vectors.json")

NTSC_HZ = 60  # jiffy clock tick rate
NTSC_CYCLES_PER_SEC = 1_022_727

# Benchmark subroutine address — placed after jsr_poll's trampoline
# (jsr_poll uses $0334-$0344, 17 bytes; our code starts at $0360)
BENCH_SUB_ADDR = 0x0360


def build_bench_subroutine(labels, blank=True):
    """Build 6502 subroutine that runs the full benchmark and returns via RTS.

    The subroutine:
      1. SEI; zero jiffy clock; CLI
      2. (optional) JSR vic_blank
      3. JSR x25519_base
      4. SEI; copy jiffy clock to bench_ticks; CLI
      5. (optional) JSR vic_unblank
      6. RTS
    """
    code = bytearray()

    # 1. Zero jiffy clock (3 bytes at $A0-$A2, big-endian)
    code += bytes([0x78])         # SEI
    code += bytes([0xA9, 0x00])   # LDA #$00
    code += bytes([0x85, 0xA0])   # STA $A0
    code += bytes([0x85, 0xA1])   # STA $A1
    code += bytes([0x85, 0xA2])   # STA $A2
    code += bytes([0x58])         # CLI

    # 2. Blank VIC (optional)
    if blank:
        addr = labels["vic_blank"]
        code += bytes([0x20, addr & 0xFF, (addr >> 8) & 0xFF])  # JSR vic_blank

    # 3. JSR x25519_base
    addr = labels["x25519_base"]
    code += bytes([0x20, addr & 0xFF, (addr >> 8) & 0xFF])  # JSR x25519_base

    # 4. Copy jiffy clock to bench_ticks
    bt = labels["bench_ticks"]
    code += bytes([0x78])                                         # SEI
    code += bytes([0xA5, 0xA0])                                   # LDA $A0
    code += bytes([0x8D, bt & 0xFF, (bt >> 8) & 0xFF])           # STA bench_ticks
    code += bytes([0xA5, 0xA1])                                   # LDA $A1
    code += bytes([0x8D, (bt+1) & 0xFF, ((bt+1) >> 8) & 0xFF])  # STA bench_ticks+1
    code += bytes([0xA5, 0xA2])                                   # LDA $A2
    code += bytes([0x8D, (bt+2) & 0xFF, ((bt+2) >> 8) & 0xFF])  # STA bench_ticks+2
    code += bytes([0x58])                                         # CLI

    # 5. Unblank VIC (optional)
    if blank:
        addr = labels["vic_unblank"]
        code += bytes([0x20, addr & 0xFF, (addr >> 8) & 0xFF])  # JSR vic_unblank

    # 6. Return to jsr_poll's trampoline
    code += bytes([0x60])  # RTS

    return bytes(code)


def jiffies_to_str(ticks):
    secs = ticks / NTSC_HZ
    if secs < 60:
        return f"{ticks} jiffies ({secs:.1f}s)"
    mins = secs / 60
    return f"{ticks} jiffies ({mins:.1f} min / {secs:.0f}s)"


def main():
    os.chdir(PROJECT_ROOT)

    verify = True
    blank = True
    poll_interval = 30.0

    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--no-verify":
            verify = False
            i += 1
        elif args[i] == "--no-blank":
            blank = False
            i += 1
        elif args[i] == "--poll" and i + 1 < len(args):
            poll_interval = float(args[i + 1])
            i += 2
        else:
            i += 1

    # Build
    print("Building...")
    subprocess.run(["make", "clean"], capture_output=True, cwd=PROJECT_ROOT)
    result = subprocess.run(["make"], capture_output=True, text=True,
                            cwd=PROJECT_ROOT)
    if result.returncode != 0:
        print(f"Build failed:\n{result.stderr}")
        sys.exit(1)

    labels = Labels.from_file(LABELS_PATH)

    # Verify required labels
    required = [
        "x25519_base", "x25_scalar", "x25_result",
        "bench_ticks", "vic_blank", "vic_unblank",
    ]
    for name in required:
        if labels.address(name) is None:
            print(f"FATAL: '{name}' label not found")
            sys.exit(1)

    # Load RFC 7748 vector for verification
    with open(VECTORS_PATH) as f:
        vectors = json.load(f)
    vec = vectors["x25519_basepoint"][0]
    scalar = bytes.fromhex(vec["scalar"])
    expected = bytes.fromhex(vec["expected"])

    # Build benchmark subroutine
    bench_code = build_bench_subroutine(labels, blank=blank)
    print(f"Benchmark subroutine: {len(bench_code)} bytes at ${BENCH_SUB_ADDR:04X}")

    # Launch VICE via managed instance (PID/port tracked, file-locked)
    config = ViceConfig(prg_path=PRG_PATH, warp=True, ntsc=True, sound=False)

    with ViceInstanceManager(
        config=config,
        port_range_start=6510,
        port_range_end=6530,
    ) as mgr:
        with mgr.instance() as inst:
            print(f"VICE PID={inst.pid}, port={inst.port}")

            transport = inst.transport
            grid = wait_for_text(transport, "Q=QUIT", timeout=60.0, verbose=False)
            if grid is None:
                print("FATAL: Main menu did not appear")
                sys.exit(1)

            # Write scalar
            write_bytes(transport, labels["x25_scalar"], scalar)

            # Write benchmark subroutine
            load_code(transport, BENCH_SUB_ADDR, bench_code)

            print(f"\n{'='*60}")
            print(f"  Full X25519 scalarmult (scalar * basepoint 9)")
            print(f"  VIC-II blanking: {'ON' if blank else 'OFF'}")
            print(f"  Poll interval:   {poll_interval}s")
            print(f"  Method:          jsr_poll (flag-based)")
            print(f"{'='*60}")
            print(f"\n  Starting... (polling every {poll_interval}s)")

            # Execute via jsr_poll — flag-based completion, no breakpoints
            wall_start = time.time()
            jsr_poll(
                transport,
                BENCH_SUB_ADDR,
                timeout=7200.0,
                poll_interval=poll_interval,
            )
            wall_elapsed = time.time() - wall_start

            # Read results
            ticks_data = read_bytes(transport, labels["bench_ticks"], 3)
            ticks = (ticks_data[0] << 16) | (ticks_data[1] << 8) | ticks_data[2]
            result_bytes = read_bytes(transport, labels["x25_result"], 32)

            c64_secs = ticks / NTSC_HZ
            est_cycles = c64_secs * NTSC_CYCLES_PER_SEC

            print(f"\n--- Results ---")
            print(f"  Jiffy clock:   {jiffies_to_str(ticks)}")
            print(f"  Wall clock:    {wall_elapsed:.1f}s ({wall_elapsed/60:.1f} min)")
            if wall_elapsed > 0:
                print(f"  Warp factor:   {c64_secs/wall_elapsed:.1f}x")
            print(f"  Est. cycles:   {est_cycles:,.0f}")
            print(f"  C64 real-time: {c64_secs:.0f}s ({c64_secs/60:.1f} min)")

            # Verify correctness
            if verify:
                if result_bytes == expected:
                    print(f"  Correctness:   PASS (matches RFC 7748)")
                else:
                    print(f"  Correctness:   FAIL")
                    print(f"    expected: {expected.hex()}")
                    print(f"    got:      {result_bytes.hex()}")

    print("\nDone.")


if __name__ == "__main__":
    main()
