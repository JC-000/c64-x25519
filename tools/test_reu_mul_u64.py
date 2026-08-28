#!/usr/bin/env python3
"""test_reu_mul_u64.py — Ultimate 64 hardware unit test for the §8.2
`reu_mul` primitive (c64-x25519 #115 / c64-lib-contract#144).

Per clock (default 48 and 1 MHz):

  1. load build/x25519.prg with the REU enabled (512 KB), set the clock;
  2. `jsr reu_mul_init` at that clock (rebuilds the 256-row a*b tables
     through the REU C64->REU stash path);
  3. for a deterministic sample of rows `a`, poke `mul_cached_a`, jsr
     `reu_fetch_mul_row` (the §8.2 fetch primitive, latch registers
     established exactly as the caller contract in src/x25519_init.s
     demands), read back mul_dma_lo/hi and hard-compare against CPU a*b —
     twice per row: once host-read with the CPU idle, once with the 6502
     copying the row itself immediately after the DMA (the read-after-DMA
     shape the ladder actually executes);
  4. full X25519 KAT through `x25519_scalarmult` — this walks
     fe25519_mul's *inlined* fetch (src/fe25519.s), a different execute
     site than step 3, deliberately — oracle is pyca/cryptography;
  5. one verdict line per clock; exit 1 on any failure.

Symbol addresses come from build/labels.txt, the ld65 `-Ln` label file
the Makefile already emits for the PRG (Makefile: `$(PRG)` rule).

Calls are driven by a done-sentinel trampoline at $C000 (free RAM above
the PRG, same scheme as tools/bench_x25519_u64.py): main_loop's JMP
operand is retargeted to a shim at $0800, the trampoline dispatches on an
op byte, restores main_loop and sets the sentinel. Nothing in $14-$7F or
the library's buffers is touched by the host except the documented
inputs (mul_cached_a, x25_scalar, x25_u) and the scrubbed outputs.

Discrimination note: on U64E fw 3.15 at 48 MHz the UNFIXED primitive is
expected to return wrong products (contract#144); at 1 MHz it must pass.
Measured on master 232bb11 (fw 3.15, fpga 123, core 1.4E): host-read rows
are clean at every clock, but the cpu-read variant at 48 MHz sees the
first bytes of mul_dma_lo[0..1] / mul_dma_hi[0] still holding the scrub
poison — the 6502 reads past `sta reu_command; rts` before the DMA has
landed — 2 wrong products per row, 64 over 32 rows, and the KAT fails.
At 1 MHz all of it passes. That is the settle hazard, and the cpu-read
leg is the one that must go red for this test to be doing its job.
If every clock passes, the script says so loudly — that is either a
non-3.15 firmware or a test that misses the hazard, not a green light.

Usage:
    U64_HOST=10.43.23.81 python3 tools/test_reu_mul_u64.py
    U64_HOST=... python3 tools/test_reu_mul_u64.py --speeds 48,1 --seed 7
    U64_HOST=... python3 tools/test_reu_mul_u64.py --init-mhz 1   # init at
        1 MHz, fetch/KAT at each --speeds clock (splits init vs fetch)
    U64_HOST=... python3 tools/test_reu_mul_u64.py --no-kat
    C64_SKIP_BUILD=1 U64_HOST=... python3 tools/test_reu_mul_u64.py
"""

import hashlib
import json
import os
import random
import subprocess
import sys
import time

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, PROJECT_ROOT)

from c64_test_harness import DeviceLock, DeviceLockTimeout, Labels
from c64_test_harness.backends.ultimate64 import Ultimate64Transport
from c64_test_harness.backends.ultimate64_helpers import set_reu, set_turbo_mhz
from c64_test_harness.backends.ultimate64_probe import probe_u64

from cryptography.hazmat.primitives.asymmetric.x25519 import (
    X25519PrivateKey, X25519PublicKey)

PRG_PATH = os.path.join(PROJECT_ROOT, "build", "x25519.prg")
LABELS_PATH = os.path.join(PROJECT_ROOT, "build", "labels.txt")
VECTORS_PATH = os.path.join(PROJECT_ROOT, "test", "rfc7748_vectors.json")

TRAMPOLINE_ADDR = 0xC000
OP_ADDR = 0xC0FE              # op byte read by the trampoline
SHIM_ADDR = 0x0800            # dead BASIC-stub bytes; JMP $C000 goes here
DONE_SENTINEL_ADDR = 0x02A8   # free OS area, cleared before each call
DONE_SENTINEL_VAL = 0x42

OP_INIT, OP_FETCH, OP_SCALARMULT, OP_FETCH_SNAP = 0, 1, 2, 3
SNAP_LO, SNAP_HI = 0xC100, 0xC200   # 6502-side copy of a fetched row

REU_C64_LO, REU_C64_HI = 0xDF02, 0xDF03
REU_REU_LO, REU_LEN_LO, REU_LEN_HI, REU_ADDR_CTRL = 0xDF04, 0xDF07, 0xDF08, 0xDF0A

FIXED_ROWS = [0, 1, 127, 128, 254, 255]
RANDOM_ROWS = 26
SCRUB = 0xEE                  # poison for mul_dma_lo/hi before each fetch

READY_SCREEN_CODES = bytes([0x11, 0x3D, 0x11, 0x15, 0x09, 0x14])  # "q=quit"

KNOWN_SPEEDS = {
    "Ultimate 64 Elite": {1, 2, 3, 4, 5, 6, 8, 10, 12, 14, 16, 20, 24, 32, 40, 48},
    "C64 Ultimate": {1, 2, 3, 4, 6, 8, 10, 12, 14, 16, 20, 24, 32, 40, 48, 64},
}

REQUIRED_LABELS = ["main_loop", "reu_mul_init", "reu_fetch_mul_row",
                   "mul_cached_a", "mul_dma_lo", "mul_dma_hi",
                   "x25_scalar", "x25_u", "x25_result", "x25519_scalarmult"]


def build_prg():
    env = dict(os.environ)
    env.pop("CA65FLAGS", None)   # a stray export silently flips the profile
    print("Building default profile...")
    subprocess.run(["make", "clean"], capture_output=True, cwd=PROJECT_ROOT)
    r = subprocess.run(["make"], capture_output=True, text=True,
                       cwd=PROJECT_ROOT, env=env)
    if r.returncode != 0:
        print(f"build failed:\n{r.stderr}")
        sys.exit(1)


def sha256_of(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def build_trampoline(labels):
    """Op dispatcher. Ops: 0 = jsr reu_mul_init; 1 = latch + jsr
    reu_fetch_mul_row (host reads mul_dma_lo/hi afterwards, CPU idle);
    3 = same fetch, then the 6502 itself immediately copies mul_dma_lo/hi
    into SNAP_LO/SNAP_HI (the consumer-shaped read-after-DMA the ladder
    does: fetch, then `lda mul_dma_lo,y`); 2 = jsr x25519_scalarmult."""
    main_loop = labels["main_loop"]
    assert (main_loop >> 8) == (SHIM_ADDR >> 8), \
        f"main_loop ${main_loop:04X} not in shim page ${SHIM_ADDR >> 8:02X}xx"
    mdl, mdh = labels["mul_dma_lo"], labels["mul_dma_hi"]
    code = bytearray()
    fix = []          # (offset_of_operand, label_name) for forward refs
    lab = {}

    def emit(*b):
        code.extend(b)

    def abs_op(opc, a):
        emit(opc, a & 0xFF, a >> 8)

    def abs_lbl(opc, name):
        fix.append((len(code) + 1, name)); emit(opc, 0, 0)

    def beq_lbl(name):
        fix.append((len(code) + 1, ("rel", name))); emit(0xF0, 0)

    def latch():
        emit(0x78)                                 # SEI
        emit(0xA9, mdl & 0xFF); abs_op(0x8D, REU_C64_LO)
        emit(0xA9, mdl >> 8);   abs_op(0x8D, REU_C64_HI)
        emit(0xA9, 0x00)
        abs_op(0x8D, REU_REU_LO); abs_op(0x8D, REU_LEN_LO)
        abs_op(0x8D, REU_ADDR_CTRL)
        emit(0xA9, 0x02); abs_op(0x8D, REU_LEN_HI)
        abs_op(0x20, labels["reu_fetch_mul_row"])  # JSR

    abs_op(0xAD, OP_ADDR)                          # LDA OP
    emit(0xC9, OP_FETCH); beq_lbl("fetch")
    emit(0xC9, OP_FETCH_SNAP); beq_lbl("snap")
    emit(0xC9, OP_SCALARMULT); beq_lbl("sm")
    abs_op(0x20, labels["reu_mul_init"])
    abs_lbl(0x4C, "done")
    lab["fetch"] = len(code)
    latch(); emit(0x58); abs_lbl(0x4C, "done")     # CLI; JMP done
    lab["snap"] = len(code)
    latch()
    emit(0xA0, 0x00)                               # LDY #0
    lab["cp"] = len(code)
    abs_op(0xB9, mdl); abs_op(0x99, SNAP_LO)       # LDA mul_dma_lo,y / STA
    abs_op(0xB9, mdh); abs_op(0x99, SNAP_HI)
    emit(0xC8)                                     # INY
    emit(0xD0, (lab["cp"] - (len(code) + 2)) & 0xFF)  # BNE cp
    emit(0x58); abs_lbl(0x4C, "done")
    lab["sm"] = len(code)
    abs_op(0x20, labels["x25519_scalarmult"])
    lab["done"] = len(code)
    emit(0x58)                                     # CLI
    emit(0xA9, main_loop & 0xFF); abs_op(0x8D, main_loop + 1)  # restore
    emit(0xA9, DONE_SENTINEL_VAL); abs_op(0x8D, DONE_SENTINEL_ADDR)
    abs_op(0x4C, main_loop)
    for off, name in fix:
        if isinstance(name, tuple):
            code[off] = (lab[name[1]] - (off + 1)) & 0xFF
        else:
            a = TRAMPOLINE_ADDR + lab[name]
            code[off], code[off + 1] = a & 0xFF, a >> 8
    assert len(code) < (OP_ADDR - TRAMPOLINE_ADDR), len(code)
    return bytes(code)


def wait_ready_screen(transport, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        screen = transport.read_memory(0x0400, 1000)
        if screen and READY_SCREEN_CODES in bytes(screen):
            return True
        time.sleep(1.0)
    return False


def load_prg(client, transport, labels, boot_mhz):
    set_turbo_mhz(client, boot_mhz)
    time.sleep(0.5)
    transport.write_memory(0x0400, bytes([0x20] * 1000))
    with open(PRG_PATH, "rb") as f:
        prg = f.read()
    print(f"    [run_prg {len(prg)}B @ {boot_mhz} MHz boot]", flush=True)
    client.run_prg(prg)
    if not wait_ready_screen(transport, timeout=300.0):
        print("    FATAL: ready banner never appeared")
        return False
    transport.write_memory(SHIM_ADDR, bytes(
        [0x4C, TRAMPOLINE_ADDR & 0xFF, TRAMPOLINE_ADDR >> 8]))
    transport.write_memory(TRAMPOLINE_ADDR, build_trampoline(labels))
    return True


def call(transport, labels, op, timeout, poll=0.02):
    """Run one trampoline op; return wall seconds or None on timeout."""
    transport.write_memory(OP_ADDR, bytes([op]))
    transport.write_memory(DONE_SENTINEL_ADDR, b"\x00")
    main_loop = labels["main_loop"]
    t0 = time.monotonic()
    transport.write_memory(main_loop + 1, bytes([SHIM_ADDR & 0xFF]))
    deadline = t0 + timeout
    while time.monotonic() < deadline:
        d = transport.read_memory(DONE_SENTINEL_ADDR, 1)
        if d and d[0] == DONE_SENTINEL_VAL:
            return time.monotonic() - t0
        time.sleep(poll)
    return None


def check_rows(transport, labels, rows, max_report=6):
    """For each row a: (host) jsr reu_fetch_mul_row, host reads mul_dma_lo/hi
    with the CPU idle; (cpu) jsr reu_fetch_mul_row and the 6502 copies the
    row itself right after the DMA (consumer-shaped read-after-DMA), host
    reads the copy. Both compared with CPU a*b.
    Returns (rows_checked, {"host": n, "cpu": n}, bad_rows, samples)."""
    lo_addr, hi_addr = labels["mul_dma_lo"], labels["mul_dma_hi"]
    mism = {"host": 0, "cpu": 0}
    bad_rows = []
    samples = []
    for a in rows:
        for kind, op, rd_lo, rd_hi in (("host", OP_FETCH, lo_addr, hi_addr),
                                       ("cpu", OP_FETCH_SNAP, SNAP_LO, SNAP_HI)):
            transport.write_memory(lo_addr, bytes([SCRUB] * 256))
            transport.write_memory(hi_addr, bytes([SCRUB] * 256))
            transport.write_memory(rd_lo, bytes([SCRUB] * 256))
            transport.write_memory(rd_hi, bytes([SCRUB] * 256))
            transport.write_memory(labels["mul_cached_a"], bytes([a]))
            if call(transport, labels, op, timeout=10.0) is None:
                print(f"      TIMEOUT: reu_fetch_mul_row a={a} ({kind})")
                mism[kind] += 512
                bad_rows.append((a, kind, 512))
                return len(rows), mism, bad_rows, samples
            lo = bytes(transport.read_memory(rd_lo, 256))
            hi = bytes(transport.read_memory(rd_hi, 256))
            n = 0
            for b in range(256):
                want = a * b
                if lo[b] != (want & 0xFF) or hi[b] != (want >> 8):
                    n += 1
                    if len(samples) < max_report:
                        samples.append((kind, a, b, lo[b], hi[b], want))
            if n:
                bad_rows.append((a, kind, n))
            mism[kind] += n
    return len(rows), mism, bad_rows, samples


def run_kat(transport, labels, scalar, u, mhz):
    priv = X25519PrivateKey.from_private_bytes(scalar)
    expected = priv.exchange(X25519PublicKey.from_public_bytes(u))
    # x25519_scalarmult expects a clamped scalar (pyca clamps internally)
    clamped = bytearray(scalar)
    clamped[0] &= 0xF8
    clamped[31] = (clamped[31] & 0x7F) | 0x40
    transport.write_memory(labels["x25_scalar"], bytes(clamped))
    transport.write_memory(labels["x25_u"], u)
    transport.write_memory(labels["x25_result"], bytes([SCRUB] * 32))
    timeout = 900.0 if mhz == 1 else 300.0
    wall = call(transport, labels, OP_SCALARMULT, timeout=timeout, poll=0.05)
    if wall is None:
        print(f"      KAT TIMEOUT after {timeout:.0f}s")
        return False, None
    got = bytes(transport.read_memory(labels["x25_result"], 32))
    ok = got == expected
    if not ok:
        print(f"      KAT MISMATCH @ {mhz} MHz")
        print(f"        got      {got.hex()}")
        print(f"        expected {expected.hex()}  (pyca)")
    return ok, wall


def parse_args(argv):
    opts = {"speeds": [48, 1], "seed": 20260828, "init_mhz": None,
            "kat": True, "expect_unfixed": False}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--speeds":
            opts["speeds"] = [int(s) for s in argv[i + 1].split(",")]
            i += 2
        elif a == "--seed":
            opts["seed"] = int(argv[i + 1]); i += 2
        elif a == "--init-mhz":
            opts["init_mhz"] = int(argv[i + 1]); i += 2
        elif a == "--no-kat":
            opts["kat"] = False; i += 1
        elif a == "--expect-unfixed":
            # baseline mode: PRG is the UNFIXED primitive; all-green -> exit 2
            opts["expect_unfixed"] = True; i += 1
        else:
            print(f"unknown arg {a}"); sys.exit(2)
    return opts


def main():
    opts = parse_args(sys.argv[1:])
    host = os.environ.get("U64_HOST")
    if not host:
        print("U64_HOST not set — refusing to guess a device address.")
        sys.exit(1)

    if not os.environ.get("C64_SKIP_BUILD"):
        build_prg()
    for p in (PRG_PATH, LABELS_PATH):
        if not os.path.exists(p):
            print(f"missing {p}"); sys.exit(1)
    print(f"  build/x25519.prg sha256 {sha256_of(PRG_PATH)[:16]}…")
    labels = Labels.from_file(LABELS_PATH)
    for name in REQUIRED_LABELS:
        if labels.address(name) is None:
            print(f"FATAL: label '{name}' missing from {LABELS_PATH}")
            sys.exit(1)

    rng = random.Random(opts["seed"])
    rows = list(FIXED_ROWS)
    while len(rows) < len(FIXED_ROWS) + RANDOM_ROWS:
        a = rng.randrange(256)
        if a not in rows:
            rows.append(a)
    print(f"  rows ({len(rows)}, seed {opts['seed']}): {rows}")

    with open(VECTORS_PATH) as f:
        vec = json.load(f)["x25519_scalarmult"][0]
    scalar = bytes.fromhex(vec["scalar"])
    u = bytes.fromhex(vec["u_coordinate"])

    probe = probe_u64(host)
    if not probe.reachable:
        print(f"U64 at {host} not reachable: {probe}"); sys.exit(1)

    lock = DeviceLock(host)
    try:
        lock.acquire_or_raise(timeout=120.0)
    except DeviceLockTimeout as e:
        print(f"device busy: {e}"); sys.exit(1)

    verdicts = []
    failed = False
    transport = None
    try:
        transport = Ultimate64Transport(
            host=host, password=os.environ.get("U64_PASSWORD"), timeout=8.0)
        client = transport.client
        info = client.get_info()
        product = info.get("product", "?")
        fw = info.get("firmware_version", "?")
        dev = f"{product} fw {fw}"
        print(f"Device: {dev} at {host}  (fpga {info.get('fpga_version', '?')}, "
              f"core {info.get('core_version', '?')})")
        if product not in KNOWN_SPEEDS:
            print(f"REFUSING: unknown device product '{product}'"); sys.exit(1)
        bad = [s for s in opts["speeds"] if s not in KNOWN_SPEEDS[product]]
        if bad:
            print(f"REFUSING: {product} has no turbo step for {bad}"); sys.exit(1)

        print("\n[session boot] reboot + REU on (512 KB)")
        client.reboot()
        time.sleep(8.0)
        set_reu(client, enabled=True, size="512 KB")

        for mhz in opts["speeds"]:
            init_mhz = opts["init_mhz"] or mhz
            print(f"\n=== {mhz} MHz (reu_mul_init @ {init_mhz} MHz) ===")
            # fresh PRG per clock: boot at the init clock, so the boot-time
            # reu_mul_init and our explicit one run at the same speed
            if not load_prg(client, transport, labels, boot_mhz=init_mhz):
                sys.exit(1)
            w = call(transport, labels, OP_INIT, timeout=120.0, poll=0.05)
            if w is None:
                print("      TIMEOUT: reu_mul_init"); sys.exit(1)
            print(f"  reu_mul_init: {w:.2f} s wall", flush=True)

            set_turbo_mhz(client, mhz)
            time.sleep(0.5)
            checked, mism, bad_rows, samples = check_rows(transport, labels, rows)
            print(f"  reu_fetch_mul_row: {checked} rows x 2 reads; mismatched "
                  f"products host-read={mism['host']} cpu-read={mism['cpu']}; "
                  f"{len(bad_rows)} bad (row, read) pairs")
            if bad_rows:
                print(f"    bad (a, read, n): {bad_rows[:12]}"
                      f"{' …' if len(bad_rows) > 12 else ''}")
                for kind, a, b, lo, hi, want in samples:
                    print(f"    [{kind}] a={a:3d} b={b:3d} got lo/hi={lo:02x}/{hi:02x} "
                          f"want {want & 0xFF:02x}/{want >> 8:02x} ({want})")
            kat = "SKIP"
            if opts["kat"]:
                ok, wall = run_kat(transport, labels, scalar, u, mhz)
                kat = "PASS" if ok else "FAIL"
                if wall is not None:
                    print(f"  x25519_scalarmult KAT: {kat} ({wall:.2f} s wall)")
            line = (f"VERDICT {dev} | {mhz} MHz | rows_checked={checked} "
                    f"mismatches=host:{mism['host']}/cpu:{mism['cpu']} KAT={kat}")
            verdicts.append(line)
            print(line, flush=True)
            if mism["host"] or mism["cpu"] or kat == "FAIL":
                failed = True

        set_turbo_mhz(client, 1)
    finally:
        if transport is not None:
            transport.close()
        lock.release()

    print("\n" + "=" * 66)
    for v in verdicts:
        print(v)
    if not failed and opts["expect_unfixed"]:
        # Baseline mode: the caller asserts the PRG carries the UNFIXED
        # §8.2 primitive, so an all-green 48 MHz run on U64E fw 3.15 means
        # the test is not reaching the hazard (contract#144), not that the
        # hazard is absent. Observed failing on master 232bb11 (2026-08-28):
        # cpu-read=64 mismatches + KAT=FAIL at 48 MHz, all green at 1 MHz.
        print("NOTE: --expect-unfixed was given and every clock passed. On "
              "U64E fw 3.15 the unfixed §8.2 primitive is expected to FAIL at "
              "48 MHz (contract#144); either the firmware is not 3.15 or this "
              "test is not reaching the hazard — do not read it as a fix.")
        sys.exit(2)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
