#!/usr/bin/env python3
"""bench_x25519_u64.py — X25519 scalarmult wall-clock A/B on Ultimate 64
hardware (issue #72 hardware gate: default REU build vs X25519_ONCHIP_MUL).

Why this does NOT use the nist-curves jiffy-clock pattern: x25519_scalarmult
runs under SEI for its whole duration, so the kernal jiffy clock is frozen
while the routine executes (the exact reason src/util.s grew the CIA1
bench_cycles counter). Timing here is therefore:

  * Primary: host-side wall clock around a done-sentinel poll. Immune to
    the "48 MHz jiffy clock drifts ~3.8% across reboots" problem entirely.
    Poll cadence 50 ms → worst-case quantization ±0.05 s, <1% at the
    shortest measured run (~9 s).
  * Secondary: the 32-bit CIA1 bench_cycles counter (sei-safe), read back
    after each run. Its tick domain at turbo (wall-anchored ~1.02 MHz vs
    CPU-scaled) is itself unknown until measured — the printed
    ticks-per-wall-second ratio disambiguates, and whichever domain it
    turns out to be, it is reported, not assumed.

A/B discipline: ONE boot per session. Default PRG measured at every speed,
then run_prg() switches to the onchip PRG (no reboot) for the same speeds.
All CIA-domain numbers in a session are therefore same-run comparable.

The REU stays attached for both PRGs (the onchip build provably ignores it:
VICE cycle counts are bit-identical with/without REU). An optional final
phase reboots with the REU DISABLED and re-runs the onchip PRG once — the
hardware analogue of the VICE C64_NO_REU proof.

Device guard: refuses to run unless the device self-reports as
"Ultimate 64 Elite" (the C64U is out of bounds for now; also the U64E
turbo enum tops out at 48 MHz — there is no 64 MHz step on this device,
so the 64 MHz gate point remains pending on the C64U).

Usage:
    U64_HOST=10.43.23.81 python3 tools/bench_x25519_u64.py
    U64_HOST=10.43.23.81 python3 tools/bench_x25519_u64.py --speeds 1,16,48
    U64_HOST=10.43.23.81 python3 tools/bench_x25519_u64.py --no-stock-proof
    C64_SKIP_BUILD=1 U64_HOST=... python3 tools/bench_x25519_u64.py
"""

import json
import os
import subprocess
import sys
import time

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, PROJECT_ROOT)

from c64_test_harness import DeviceLock, DeviceLockTimeout, Labels
from c64_test_harness.backends.ultimate64 import Ultimate64Transport
from c64_test_harness.backends.ultimate64_helpers import set_reu, set_turbo_mhz
from c64_test_harness.backends.ultimate64_probe import probe_u64

DEFAULT_PRG = os.path.join(PROJECT_ROOT, "build", "x25519.prg")
DEFAULT_LABELS = os.path.join(PROJECT_ROOT, "build", "labels.txt")
ONCHIP_PRG = os.path.join(PROJECT_ROOT, "build-onchip", "x25519.prg")
ONCHIP_LABELS = os.path.join(PROJECT_ROOT, "build-onchip", "labels.txt")
VECTORS_PATH = os.path.join(PROJECT_ROOT, "test", "rfc7748_vectors.json")

TRAMPOLINE_ADDR = 0xC000
SHIM_ADDR = 0x0800            # dead BASIC-stub bytes; JMP $C000 goes here
DONE_SENTINEL_ADDR = 0x02A8   # free OS area, cleared before each run
DONE_SENTINEL_VAL = 0x42

NTSC_CPU_HZ = 1_022_727

READY_SCREEN_CODES = bytes([0x11, 0x3D, 0x11, 0x15, 0x09, 0x14])  # "q=quit"


def build_prgs():
    """Build both profiles fresh. Default with CA65FLAGS scrubbed from the
    env (ten tools' lesson: a stray exported value silently flips the
    profile), onchip with the explicit define."""
    env_default = dict(os.environ)
    env_default.pop("CA65FLAGS", None)
    print("Building default profile...")
    subprocess.run(["make", "clean"], capture_output=True, cwd=PROJECT_ROOT)
    r = subprocess.run(["make"], capture_output=True, text=True,
                       cwd=PROJECT_ROOT, env=env_default)
    if r.returncode != 0:
        print(f"default build failed:\n{r.stderr}")
        sys.exit(1)
    print("Building onchip profile...")
    subprocess.run(["rm", "-rf", "build-onchip"], cwd=PROJECT_ROOT)
    r = subprocess.run(
        ["make", "BUILD_DIR=build-onchip",
         "CA65FLAGS=-D X25519_ONCHIP_MUL=1"],
        capture_output=True, text=True, cwd=PROJECT_ROOT, env=env_default)
    if r.returncode != 0:
        print(f"onchip build failed:\n{r.stderr}")
        sys.exit(1)


def sha256_of(path):
    import hashlib
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def build_trampoline(labels):
    """JSR vic_blank / bench_cycles_start / x25519_base /
    bench_cycles_stop / vic_unblank, then atomically restore main_loop's
    JMP operand, set the done sentinel, and jump back to the idle loop."""
    main_loop = labels["main_loop"]
    assert (main_loop >> 8) == (SHIM_ADDR >> 8), \
        f"main_loop ${main_loop:04X} not in shim page ${SHIM_ADDR >> 8:02X}xx"
    code = bytearray()

    def jsr(a):
        code.extend([0x20, a & 0xFF, (a >> 8) & 0xFF])

    jsr(labels["vic_blank"])
    jsr(labels["bench_cycles_start"])
    jsr(labels["x25519_base"])
    jsr(labels["bench_cycles_stop"])
    jsr(labels["vic_unblank"])
    # restore idle loop: JMP $0800 -> JMP $08xx (single-byte, atomic)
    code.extend([0xA9, main_loop & 0xFF])                    # LDA #<main_loop
    code.extend([0x8D, (main_loop + 1) & 0xFF, (main_loop + 1) >> 8])
    code.extend([0xA9, DONE_SENTINEL_VAL])                   # LDA #$42
    code.extend([0x8D, DONE_SENTINEL_ADDR & 0xFF, DONE_SENTINEL_ADDR >> 8])
    code.extend([0x4C, main_loop & 0xFF, (main_loop >> 8) & 0xFF])
    return bytes(code)


def wait_ready_screen(transport, timeout):
    """Poll screen RAM for the harness ready banner ("Q=QUIT")."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        screen = transport.read_memory(0x0400, 1000)
        if screen and READY_SCREEN_CODES in bytes(screen):
            return True
        time.sleep(1.0)
    return False


def clear_screen(transport):
    transport.write_memory(0x0400, bytes([0x20] * 1000))


def prepare_prg(client, transport, prg_path, labels, scalar, init_mhz=48):
    """Load a PRG (no reboot), wait for its init to finish, install shim +
    trampoline + scalar. Turbo is raised for init, caller sets the
    measurement speed afterwards."""
    set_turbo_mhz(client, init_mhz)
    time.sleep(0.5)
    clear_screen(transport)
    with open(prg_path, "rb") as f:
        prg_data = f.read()
    print(f"    [run_prg {len(prg_data)}B]", flush=True)
    client.run_prg(prg_data)
    if not wait_ready_screen(transport, timeout=300.0):
        print("    FATAL: ready banner never appeared")
        return False
    # shim: JMP TRAMPOLINE at $0800
    transport.write_memory(SHIM_ADDR, bytes(
        [0x4C, TRAMPOLINE_ADDR & 0xFF, TRAMPOLINE_ADDR >> 8]))
    transport.write_memory(TRAMPOLINE_ADDR, build_trampoline(labels))
    transport.write_memory(labels["x25_scalar"], scalar)
    return True


def run_once(client, transport, labels, mhz, expected, timeout):
    """One measured scalarmult at `mhz`. Returns (wall_s, cia_ticks) or
    None on failure."""
    set_turbo_mhz(client, mhz)
    time.sleep(0.5)
    transport.write_memory(DONE_SENTINEL_ADDR, b"\x00")
    transport.write_memory(labels["x25_result"], bytes(32))  # scrub
    main_loop = labels["main_loop"]
    # hijack: JMP main_loop -> JMP $0800 (single low-byte write, atomic)
    t0 = time.monotonic()
    transport.write_memory(main_loop + 1, bytes([SHIM_ADDR & 0xFF]))
    deadline = t0 + timeout
    wall = None
    while time.monotonic() < deadline:
        data = transport.read_memory(DONE_SENTINEL_ADDR, 1)
        if data and data[0] == DONE_SENTINEL_VAL:
            wall = time.monotonic() - t0
            break
        time.sleep(0.05)
    if wall is None:
        print(f"      TIMEOUT after {timeout:.0f}s at {mhz} MHz")
        return None
    result = bytes(transport.read_memory(labels["x25_result"], 32))
    if result != expected:
        print(f"      ORACLE FAIL at {mhz} MHz:")
        print(f"        got      {result.hex()}")
        print(f"        expected {expected.hex()}")
        return None
    cyc = bytes(transport.read_memory(labels["bench_cycles"], 4))
    ticks = cyc[0] | (cyc[1] << 8) | (cyc[2] << 16) | (cyc[3] << 24)
    return wall, ticks


def main():
    speeds = [1, 16, 48]
    stock_proof = True
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--speeds" and i + 1 < len(args):
            speeds = [int(s) for s in args[i + 1].split(",")]
            i += 2
        elif args[i] == "--no-stock-proof":
            stock_proof = False
            i += 1
        else:
            i += 1

    host = os.environ.get("U64_HOST")
    if not host:
        print("U64_HOST not set — refusing to guess a device address.")
        sys.exit(1)

    if not os.environ.get("C64_SKIP_BUILD"):
        build_prgs()
    for p in (DEFAULT_PRG, ONCHIP_PRG):
        if not os.path.exists(p):
            print(f"missing {p}")
            sys.exit(1)
        print(f"  {os.path.relpath(p, PROJECT_ROOT)}  sha256 {sha256_of(p)[:16]}…")

    with open(VECTORS_PATH) as f:
        vec = json.load(f)["x25519_basepoint"][0]
    scalar = bytes.fromhex(vec["scalar"])
    expected = bytes.fromhex(vec["expected"])

    probe = probe_u64(host)
    if not probe.reachable:
        print(f"U64 at {host} not reachable: {probe}")
        sys.exit(1)

    lock = DeviceLock(host)
    try:
        lock.acquire_or_raise(timeout=120.0)
    except DeviceLockTimeout as e:
        print(f"device busy: {e}")
        sys.exit(1)

    transport = None
    try:
        transport = Ultimate64Transport(
            host=host, password=os.environ.get("U64_PASSWORD"), timeout=8.0)
        client = transport.client
        info = client.get_info()
        product = info.get("product", "?")
        print(f"Device: {product} fw {info.get('firmware_version', '?')} at {host}")
        if product != "Ultimate 64 Elite":
            print(f"REFUSING: device is '{product}', not the U64E "
                  "(C64U is out of bounds for this run)")
            sys.exit(1)
        if any(s > 48 for s in speeds):
            print("REFUSING: U64E turbo tops out at 48 MHz (no 64 MHz step)")
            sys.exit(1)

        results = {}  # (profile, mhz) -> (wall, ticks)

        print("\n[session boot] reboot + REU on (512 KB)")
        client.reboot()
        time.sleep(8.0)
        set_reu(client, enabled=True, size="512 KB")

        for profile, prg, labels_path in (
                ("default", DEFAULT_PRG, DEFAULT_LABELS),
                ("onchip", ONCHIP_PRG, ONCHIP_LABELS)):
            print(f"\n=== {profile} profile ===")
            labels = Labels.from_file(labels_path)
            if not prepare_prg(client, transport, prg, labels, scalar):
                sys.exit(1)
            for mhz in speeds:
                # generous timeout: stock onchip ~440 s
                timeout = 900.0 if mhz == 1 else 300.0
                print(f"  [{profile} @ {mhz} MHz] running...", flush=True)
                r = run_once(client, transport, labels, mhz, expected, timeout)
                if r is None:
                    sys.exit(1)
                wall, ticks = r
                rate = ticks / wall if wall else 0
                results[(profile, mhz)] = (wall, ticks)
                print(f"      wall {wall:9.2f} s   CIA ticks {ticks:>13,} "
                      f"({rate / 1e6:.3f} M/s)")

        if stock_proof:
            print("\n=== onchip stock-config proof (REU DISABLED) ===")
            client.reboot()
            time.sleep(8.0)
            set_reu(client, enabled=False)
            labels = Labels.from_file(ONCHIP_LABELS)
            if not prepare_prg(client, transport, ONCHIP_PRG, labels, scalar):
                sys.exit(1)
            r = run_once(client, transport, labels, 48, expected, 300.0)
            if r is None:
                sys.exit(1)
            wall, ticks = r
            results[("onchip-noreu", 48)] = (wall, ticks)
            print(f"      wall {wall:9.2f} s   CIA ticks {ticks:>13,}")

        print(f"\n{'=' * 66}")
        print(f"{'profile':<14} {'MHz':>4} {'wall s':>10} {'CIA ticks':>15} "
              f"{'ticks/s':>12}")
        for (profile, mhz), (wall, ticks) in sorted(results.items()):
            print(f"{profile:<14} {mhz:>4} {wall:>10.2f} {ticks:>15,} "
                  f"{ticks / wall:>12,.0f}")
        for mhz in speeds:
            d = results.get(("default", mhz))
            o = results.get(("onchip", mhz))
            if d and o:
                print(f"A/B @ {mhz:>2} MHz: default {d[0]:.2f} s vs onchip "
                      f"{o[0]:.2f} s -> onchip is {d[0] / o[0]:.2f}x"
                      f"{' FASTER' if o[0] < d[0] else ' (slower)'}")

        set_turbo_mhz(client, 1)
        print("\n(device left at 1 MHz; REU state = last phase's setting)")
    finally:
        if transport is not None:
            transport.close()
        lock.release()


if __name__ == "__main__":
    main()
