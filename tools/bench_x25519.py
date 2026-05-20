#!/usr/bin/env python3
"""bench_x25519.py — End-to-end X25519 scalarmult benchmark on C64.

Runs a full x25519_base (scalar * basepoint 9) natively on the C64 and
measures CPU cycles directly via a CIA1-driven 32-bit cycle counter
(bench_cycles_start / bench_cycles_stop, see src/util.s).

Why CIA timers, not the jiffy clock: since PR #35 (commit 35351c9),
x25519_scalarmult wraps its entire body in `php / sei … plp` as a CT
defence. The kernal jiffy clock at $A0-$A2 is incremented by the IRQ
handler, so it stops ticking while scalarmult is running and the
old jiffy-based bench reported ~0 jif. The CIA1 timer pair ticks
from the phi2 system clock directly and is unaffected by sei.

Uses jsr() with event-based binary monitor checkpoints for reliable
long-running computation in warp mode.

Usage:
    python3 tools/bench_x25519.py [--no-verify] [--no-blank] [--json out.json]

--json writes a machine-readable record (consumed by tools/perf_diff.py
and the make bench-record pipeline). Fields include cycles, derived jif,
wall-clock, and whether VIC-II blanking was applied.
"""

import json
import os
import subprocess
import sys
import time

from c64_test_harness import (
    Labels, ViceConfig, ViceInstanceManager,
    read_bytes, write_bytes, jsr, load_code, wait_for_text,
)

PROJECT_ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
PRG_PATH = os.path.join(PROJECT_ROOT, "build", "x25519.prg")
LABELS_PATH = os.path.join(PROJECT_ROOT, "build", "labels.txt")
VECTORS_PATH = os.path.join(PROJECT_ROOT, "test", "rfc7748_vectors.json")

NTSC_HZ = 60  # jiffy clock tick rate
NTSC_CYCLES_PER_SEC = 1_022_727
NTSC_CYCLES_PER_JIF = NTSC_CYCLES_PER_SEC / NTSC_HZ   # ≈ 17,045.45

# Benchmark subroutine address
BENCH_SUB_ADDR = 0x0360


def build_bench_subroutine(labels, blank=True):
    """Build 6502 subroutine that runs the full benchmark and returns via RTS.

    The subroutine:
      1. (optional) JSR vic_blank
      2. JSR bench_cycles_start  (sei + CIA1 TA/TB reconfigured)
      3. JSR x25519_base         (internally php/sei…plp)
      4. JSR bench_cycles_stop   (stops timers, writes 4-byte LE cycle count)
      5. (optional) JSR vic_unblank
      6. RTS
    """
    code = bytearray()

    # 1. Blank VIC (optional) — done before starting the timer so the
    # blank itself isn't counted toward scalarmult cycles.
    if blank:
        addr = labels["vic_blank"]
        code += bytes([0x20, addr & 0xFF, (addr >> 8) & 0xFF])  # JSR vic_blank

    # 2. Start CIA1 cycle counter (32-bit, survives sei)
    addr = labels["bench_cycles_start"]
    code += bytes([0x20, addr & 0xFF, (addr >> 8) & 0xFF])      # JSR bench_cycles_start

    # 3. JSR x25519_base (does the scalarmult under sei)
    addr = labels["x25519_base"]
    code += bytes([0x20, addr & 0xFF, (addr >> 8) & 0xFF])      # JSR x25519_base

    # 4. Stop CIA1 cycle counter (atomic snapshot into bench_cycles)
    addr = labels["bench_cycles_stop"]
    code += bytes([0x20, addr & 0xFF, (addr >> 8) & 0xFF])      # JSR bench_cycles_stop

    # 5. Unblank VIC (optional)
    if blank:
        addr = labels["vic_unblank"]
        code += bytes([0x20, addr & 0xFF, (addr >> 8) & 0xFF])  # JSR vic_unblank

    # 6. Return via RTS
    code += bytes([0x60])  # RTS

    return bytes(code)


def cycles_to_str(cycles):
    secs = cycles / NTSC_CYCLES_PER_SEC
    jif = cycles / NTSC_CYCLES_PER_JIF
    if secs < 60:
        return f"{cycles:,} cycles (~{jif:,.0f} jif, {secs:.1f}s)"
    mins = secs / 60
    return f"{cycles:,} cycles (~{jif:,.0f} jif, {mins:.1f} min / {secs:.0f}s)"


def main():
    os.chdir(PROJECT_ROOT)

    verify = True
    blank = True
    json_path = None

    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--no-verify":
            verify = False
            i += 1
        elif args[i] == "--no-blank":
            blank = False
            i += 1
        elif args[i] == "--json" and i + 1 < len(args):
            json_path = args[i + 1]
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
        "bench_cycles_start", "bench_cycles_stop", "bench_cycles",
        "vic_blank", "vic_unblank",
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
    config = ViceConfig(prg_path=PRG_PATH, warp=True, ntsc=True, sound=False,
                        extra_args=["-reu", "-reusize", "512"])

    with ViceInstanceManager(config=config) as mgr:
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
            print(f"  Method:          jsr (event-based binary monitor)")
            print(f"{'='*60}")
            print(f"\n  Starting...")

            # Execute via jsr — event-based binary monitor checkpoints
            wall_start = time.time()
            jsr(transport, BENCH_SUB_ADDR, timeout=7200.0)
            wall_elapsed = time.time() - wall_start

            # Read 4-byte little-endian u32 cycle count from bench_cycles
            cyc_data = read_bytes(transport, labels["bench_cycles"], 4)
            cycles = (cyc_data[0]
                      | (cyc_data[1] << 8)
                      | (cyc_data[2] << 16)
                      | (cyc_data[3] << 24))
            result_bytes = read_bytes(transport, labels["x25_result"], 32)

            c64_secs = cycles / NTSC_CYCLES_PER_SEC
            est_jif = cycles / NTSC_CYCLES_PER_JIF

            print(f"\n--- Results ---")
            print(f"  CIA1 cycles:   {cycles_to_str(cycles)}")
            print(f"  Jif (derived): {est_jif:,.1f}")
            print(f"  Wall clock:    {wall_elapsed:.1f}s ({wall_elapsed/60:.1f} min)")
            if wall_elapsed > 0:
                print(f"  Warp factor:   {c64_secs/wall_elapsed:.1f}x")
            print(f"  C64 real-time: {c64_secs:.1f}s ({c64_secs/60:.2f} min)")

            # Verify correctness
            correct = True
            if verify:
                if result_bytes == expected:
                    print(f"  Correctness:   PASS (matches RFC 7748)")
                else:
                    correct = False
                    print(f"  Correctness:   FAIL")
                    print(f"    expected: {expected.hex()}")
                    print(f"    got:      {result_bytes.hex()}")

            # Optional JSON sidecar for perf_diff.py / make bench-record.
            if json_path:
                record = {
                    "scalarmult_cycles":  cycles,
                    "scalarmult_jif":     est_jif,
                    "c64_seconds_ntsc":   c64_secs,
                    "wall_seconds":       wall_elapsed,
                    "vic_blanked":        blank,
                    "verified":           correct if verify else None,
                    "vector":             "rfc7748_basepoint_0",
                }
                with open(json_path, "w") as f:
                    json.dump(record, f, indent=2, sort_keys=True)
                    f.write("\n")
                print(f"\nJSON sidecar written: {json_path}")

    print("\nDone.")


if __name__ == "__main__":
    main()
