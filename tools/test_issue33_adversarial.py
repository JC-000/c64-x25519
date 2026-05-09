#!/usr/bin/env python3
"""Issue #33 root-cause repro: adversarial pre-state harness.

Drives the c64-x25519 standalone PRG on either VICE (-target vice) or
Ultimate 64 hardware (-target u64), injects a specific adversarial
pre-state into REU registers / ZP / NMI vector before invoking
`x25519_scalarmult` with RFC 7748 §6.1 vector-1 inputs, and reports
either the 32-byte result, a wrong-result, or a hang (timeout).

Hypotheses, mapped to --case values:

  - clean:                baseline -- no dirty state. Must pass.
  - h1_audit:             Static-audit H1 exact recipe -- leaves
                          reu_c64_lo/hi, reu_len_lo/hi pre-set to
                          mimic crypto_swap.s do_swap residue.
  - reu_low_dirty:        reu_reu_lo=$5A. The library's reu_clear_wide
                          (src/x25519_init.s:314-339) writes 6 of 8
                          REU regs but NOT reu_reu_lo. Caller-residue
                          on reu_reu_lo silently routes the
                          fe_wide-zero DMA to the wrong REU offset.
  - reu_addr_ctrl_dirty:  reu_addr_ctrl=$80 (hold C64 addr). Same
                          contract violation; reu_clear_wide assumes
                          $00 and never resets it. Result: only
                          fe_wide[0] gets zeroed, [1..63] retain junk.
  - reu_full_dirty:       Combination matching c64-https crypto_swap
                          do_swap post-DMA residue exactly.
  - zp40_dirty:           Pre-fill $40-$7F (fe_wide) with $A5. PR #35's
                          sei does NOT defend against pre-existing
                          dirty state at entry, only against ISRs.
  - zp40_dirty_plus_reu:  Combined ZP+REU dirty state.
  - nmi_corrupts_zp40:    H3: install NMI ISR that bumps $40 mid-call.
                          PR #35's sei does NOT mask NMI.
  - irq_during_call:      Sanity: PR #35's sei should mask CIA1 IRQ.
                          If this hangs, the sei wrap is broken.

Examples:
    venv/bin/python tools/test_issue33_adversarial.py --target vice --case clean
    venv/bin/python tools/test_issue33_adversarial.py --target vice --case h1_audit
    venv/bin/python tools/test_issue33_adversarial.py --target u64  --case h1_audit
"""
from __future__ import annotations

import argparse
import os
import socket
import sys
import time

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, PROJECT_ROOT)

from c64_test_harness.backends.ultimate64_client import Ultimate64Client
from c64_test_harness.backends.ultimate64 import Ultimate64Transport
from c64_test_harness.backends.device_lock import DeviceLock
from c64_test_harness.backends.ultimate64_probe import probe_u64
from c64_test_harness.backends.ultimate64_helpers import (
    set_turbo_mhz, set_reu, snapshot_state, restore_state,
)
from c64_test_harness.labels import Labels

PRG_PATH = os.path.join(PROJECT_ROOT, "build", "x25519.prg")
LABELS_PATH = os.path.join(PROJECT_ROOT, "build", "labels.txt")

DEFAULT_HOST = os.environ.get("U64_HOST", "10.43.23.81")
PASSWORD = os.environ.get("U64_PASSWORD")

# Trampoline location: $C000 page is dead RAM under the standalone PRG
# (PRG occupies $0801-$7FFF; sqtab at $7800; mul tables in REU; main_loop
# at $0810-ish).
TRAMPOLINE_ADDR = 0xC000
DONE_SENTINEL_ADDR = 0xC0F0    # $42 = OK, $99 = pre-trampoline marker
PRE_MARKER_ADDR    = 0xC0F1    # bumped before jsr scalarmult ($55)
POST_MARKER_ADDR   = 0xC0F2    # bumped after  jsr scalarmult ($AA)

# RFC 7748 §6.1 test vector 1 (scalar / u / expected after clamp + scalarmult).
SCALAR_HEX = "a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4"
U_HEX      = "e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c"
EXPECTED_HEX = "c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552"


def _local_ip(host: str) -> str:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect((host, 80))
        return s.getsockname()[0]
    finally:
        s.close()


def clamp(scalar: bytes) -> bytes:
    s = bytearray(scalar)
    s[0] &= 0xF8
    s[31] = (s[31] & 0x7F) | 0x40
    return bytes(s)


def build_trampoline(scalarmult_addr: int, x25_scalar_addr: int,
                     x25_u_addr: int,
                     dirty_setup: bytes = b"") -> bytes:
    """Build a small 6502 program at $C000 that:
       1. (optional) does dirty_setup -- raw 6502 bytes inlined here
       2. writes $55 to PRE_MARKER ($C0F1)
       3. jsr x25519_scalarmult
       4. writes $AA to POST_MARKER ($C0F2)
       5. writes $42 to DONE_SENTINEL ($C0F0)
       6. JMP * (park)

    Caller is responsible for separately writing x25_scalar / x25_u.
    """
    code = bytearray()

    def emit(*bs):
        code.extend(bs)

    def lda_imm(v): emit(0xA9, v & 0xFF)
    def sta_abs(a): emit(0x8D, a & 0xFF, (a >> 8) & 0xFF)
    def jsr(a):     emit(0x20, a & 0xFF, (a >> 8) & 0xFF)

    # Pre-marker = $55 (so we can tell if dirty_setup itself crashed)
    lda_imm(0x55)
    sta_abs(PRE_MARKER_ADDR)

    # Inline dirty_setup raw bytes (caller assembled).
    code.extend(dirty_setup)

    # JSR x25519_scalarmult
    jsr(scalarmult_addr)

    # Post-marker = $AA (set immediately after return)
    lda_imm(0xAA)
    sta_abs(POST_MARKER_ADDR)

    # Done sentinel = $42
    lda_imm(0x42)
    sta_abs(DONE_SENTINEL_ADDR)

    # Park forever (JMP $C0FE / loop)
    park_pc = TRAMPOLINE_ADDR + len(code)
    emit(0x4C, park_pc & 0xFF, (park_pc >> 8) & 0xFF)

    return bytes(code)


# Each "case" returns raw 6502 bytes that get inlined into the trampoline
# BEFORE the jsr to x25519_scalarmult. The library expects a clean state;
# these injectors create the c64-https-like residual state.
def case_clean() -> bytes:
    return b""


def case_reu_low_dirty() -> bytes:
    # Set reu_reu_lo ($DF04) = $5A. Mimics post-do_swap residue:
    # non-autoload DMA leaves reu_reu_lo at the post-increment value.
    return bytes([
        0xA9, 0x5A,             # lda #$5A
        0x8D, 0x04, 0xDF,       # sta $DF04 (reu_reu_lo)
    ])


def case_h1_audit() -> bytes:
    # Static-audit H1 exact recipe.
    #   lda #$00 / sta $df02   ; reu_c64_lo  = 0
    #   lda #$42 / sta $df03   ; reu_c64_hi  = $42 (crypto_swap target)
    #   lda #$00 / sta $df07   ; reu_len_lo  = 0
    #   lda #$20 / sta $df08   ; reu_len_hi  = $20 (8KB)
    return bytes([
        0xA9, 0x00, 0x8D, 0x02, 0xDF,
        0xA9, 0x42, 0x8D, 0x03, 0xDF,
        0xA9, 0x00, 0x8D, 0x07, 0xDF,
        0xA9, 0x20, 0x8D, 0x08, 0xDF,
    ])


def case_reu_addr_ctrl_dirty() -> bytes:
    # Set reu_addr_ctrl ($DF0A) = $80 (fix C64 address; both inc disabled).
    # reu_clear_wide does not reset addr_ctrl.
    return bytes([
        0xA9, 0x80,
        0x8D, 0x0A, 0xDF,
    ])


def case_reu_full_dirty() -> bytes:
    # reu_reu_lo=$5A, reu_reu_hi=$03, reu_reu_bank=$05, reu_len_lo=$00,
    # reu_len_hi=$20, reu_addr_ctrl=$00 (kept inc-both because
    # do_swap explicitly clears it). This mirrors the exact post-DMA
    # state of the c64-https crypto_swap_to_p256 path:
    #   c64_addr=overlay_end, reu_addr=overlay_p256+$2000,
    #   len=$0000 (decremented), addr_ctrl=$00.
    # We don't write c64_addr because the library re-writes it; we
    # do write reu_reu_lo because the library does NOT.
    return bytes([
        0xA9, 0x5A, 0x8D, 0x04, 0xDF,    # reu_reu_lo  = $5A
        0xA9, 0x03, 0x8D, 0x05, 0xDF,    # reu_reu_hi  = $03
        0xA9, 0x05, 0x8D, 0x06, 0xDF,    # reu_reu_bank= $05
        0xA9, 0x00, 0x8D, 0x07, 0xDF,    # reu_len_lo  = $00
        0xA9, 0x20, 0x8D, 0x08, 0xDF,    # reu_len_hi  = $20
        0xA9, 0x00, 0x8D, 0x0A, 0xDF,    # reu_addr_ctrl=$00
    ])


def case_zp40_dirty() -> bytes:
    # Fill $40-$7F (fe_wide accumulator) with $A5. The library's
    # reu_clear_wide is supposed to zero this. If reu state is also
    # dirty so that reu_clear_wide silently fetches from the wrong
    # offset, the $A5 pattern survives and corrupts the first
    # fe25519_mul.
    code = bytearray()
    code.extend([0xA9, 0xA5])         # lda #$A5
    code.extend([0xA2, 0x40])         # ldx #$40
    # @loop:
    loop_pc = 4
    code.extend([0x95, 0x00])         # sta $00,x  (zp,X store at $00+X = $40..$7F)
    code.extend([0xE8])               # inx
    code.extend([0xE0, 0x80])         # cpx #$80
    code.extend([0xD0, 0xFA])         # bne @loop  (-6)
    return bytes(code)


def case_zp40_dirty_plus_reu() -> bytes:
    # Combined: dirty $40-$7F AND dirty REU regs. This is the closest
    # synthetic match to the c64-https TLS-context state at the moment
    # tls_ecdh_generate_keypair is invoked.
    return case_zp40_dirty() + case_reu_full_dirty()


def case_nmi_corrupts_zp40() -> bytes:
    # H3: install a custom NMI vector ($0318/$0319) pointing at $C100.
    # At $C100 we install a tiny ISR: `inc $40 ; rti`. Then arm CIA2
    # timer A to fire NMI ~3000 cycles in.
    #
    # NOTE: PR #35's `sei` does NOT mask NMI. If the ZP $40 byte
    # gets corrupted mid-ladder, fe_wide accumulator gets bumped and
    # downstream multiplies poison the ladder.
    code = bytearray()
    # 1. Install ISR at $C100: $E6 $40 (inc $40), $40 (rti)
    code.extend([0xA9, 0xE6, 0x8D, 0x00, 0xC1])  # sta isr+0 = $E6
    code.extend([0xA9, 0x40, 0x8D, 0x01, 0xC1])  # sta isr+1 = $40
    code.extend([0xA9, 0x40, 0x8D, 0x02, 0xC1])  # sta isr+2 = $40 (rti)
    # 2. Patch NMI user-vector $0318/$0319 -> $C100
    code.extend([0xA9, 0x00, 0x8D, 0x18, 0x03])  # sta $0318 lo
    code.extend([0xA9, 0xC1, 0x8D, 0x19, 0x03])  # sta $0319 hi
    # 3. Stop CIA2 timer A first
    code.extend([0xA9, 0x00, 0x8D, 0x0E, 0xDD])
    # 4. Latch low/high ~3000 cycles
    code.extend([0xA9, 0xB8, 0x8D, 0x04, 0xDD])
    code.extend([0xA9, 0x0B, 0x8D, 0x05, 0xDD])
    # 5. Enable CIA2 timer A NMI ($DD0D bit7=1 + bit0=1)
    code.extend([0xA9, 0x81, 0x8D, 0x0D, 0xDD])
    # 6. Start CIA2 timer A: $DD0E control = $11 (start + force-load)
    code.extend([0xA9, 0x11, 0x8D, 0x0E, 0xDD])
    return bytes(code)


def case_irq_during_call() -> bytes:
    # Arm CIA timer A to fire ~3000 cycles into the call.
    # CIA #1 timer A: $DC04/$DC05 = latch, $DC0E = control reg.
    # Bit 0 = start, Bit 3 = oneshot, Bit 4 = force-load.
    # KERNAL IRQ vector at $0314/$0315 still points at $EA31 — fine.
    # We DON'T disable the existing IRQ; we just pile on a faster one.
    #
    # NOTE: PR #35 added sei at scalarmult entry, so this should NOT
    # cause a hang. If it does, the wrap is broken.
    return bytes([
        # Stop CIA timer A first
        0xA9, 0x00, 0x8D, 0x0E, 0xDC,
        # Latch low/high  ~3000 cycles
        0xA9, 0xB8, 0x8D, 0x04, 0xDC,    # $0BB8 = 3000
        0xA9, 0x0B, 0x8D, 0x05, 0xDC,
        # Enable CIA1 timer A IRQ in $DC0D
        0xA9, 0x81, 0x8D, 0x0D, 0xDC,
        # Start CIA timer A: control = $11 (start + force-load)
        0xA9, 0x11, 0x8D, 0x0E, 0xDC,
    ])


CASES = {
    "clean":                  case_clean,
    "h1_audit":               case_h1_audit,
    "reu_low_dirty":          case_reu_low_dirty,
    "reu_addr_ctrl_dirty":    case_reu_addr_ctrl_dirty,
    "reu_full_dirty":         case_reu_full_dirty,
    "zp40_dirty":             case_zp40_dirty,
    "zp40_dirty_plus_reu":    case_zp40_dirty_plus_reu,
    "nmi_corrupts_zp40":      case_nmi_corrupts_zp40,
    "irq_during_call":        case_irq_during_call,
}


def _run_on_vice(args, prg_data, labels, scalarmult_addr,
                 x25_scalar_addr, x25_u_addr, x25_result_addr,
                 main_loop_addr, dirty_bytes):
    """Drive the test under VICE warp mode.

    VICE's REU emulation honours the autoload bit and the `addr_ctrl`
    bit, so H1/H2 hypotheses can be validated in the emulator.

    Uses the harness's ``jsr()`` primitive: pauses CPU at main_loop,
    writes a dirty-state-injector trampoline at $C000 that jumps
    through to $C100 (where x25519_scalarmult lives), then sets PC
    to the trampoline and waits for return.
    """
    from c64_test_harness import (
        ViceConfig, ViceInstanceManager, wait_for_text, write_bytes,
        read_bytes, jsr,
    )

    config = ViceConfig(prg_path=PRG_PATH, warp=True, ntsc=True,
                        sound=False,
                        extra_args=["-reu", "-reusize", "512"])
    with ViceInstanceManager(config=config) as mgr:
        inst = mgr.acquire()
        try:
            tr = inst.transport
            print(f"  VICE PID={inst.pid}, port={inst.port}")
            grid = wait_for_text(tr, "Q=QUIT", timeout=120.0,
                                 verbose=False)
            if grid is None:
                print("FATAL: VICE main menu did not appear")
                return 2
            print("  VICE READY")

            # Safety trampoline at $0339 (cassette buffer): JMP $0339
            # so any stray RTS that overflows past our trampoline loops
            # harmlessly there.
            write_bytes(tr, 0x0339, bytes([0x4C, 0x39, 0x03]))

            # Set inputs
            scalar = clamp(bytes.fromhex(SCALAR_HEX))
            u_bytes = bytes.fromhex(U_HEX)
            write_bytes(tr, x25_scalar_addr, scalar)
            write_bytes(tr, x25_u_addr, u_bytes)
            write_bytes(tr, x25_result_addr, bytes(32))

            # Build a "dirty-injector" trampoline: dirty_setup, then
            # jsr scalarmult, then rts. The harness's `jsr()` primitive
            # treats the target like a 6502 subroutine: it pushes a
            # return sentinel onto the stack, sets PC, and waits for
            # that sentinel to return. So our trampoline must end in
            # rts ($60), NOT in a parking loop.
            tramp = bytearray()
            tramp.extend(dirty_bytes)
            tramp.extend([0x20, scalarmult_addr & 0xFF,
                          (scalarmult_addr >> 8) & 0xFF])  # jsr
            tramp.append(0x60)                              # rts
            write_bytes(tr, TRAMPOLINE_ADDR, bytes(tramp))
            print(f"  trampoline @ ${TRAMPOLINE_ADDR:04x}, "
                  f"{len(tramp)} bytes; dirty_setup: {len(dirty_bytes)}B")

            print(f"  jsr ${TRAMPOLINE_ADDR:04x} (timeout "
                  f"{args.timeout:.0f}s, warp)...")
            t0 = time.monotonic()
            try:
                jsr(tr, TRAMPOLINE_ADDR, timeout=args.timeout)
                outcome = "OK"
            except Exception as e:
                outcome = f"HANG/EXC ({type(e).__name__}: {e})"
            elapsed = time.monotonic() - t0
            print(f"  outcome:  {outcome} after {elapsed:.1f}s")

            if outcome == "OK":
                got = read_bytes(tr, x25_result_addr, 32)
                print(f"  result:   {got.hex()}")
                print(f"  expected: {EXPECTED_HEX}")
                if got.hex() == EXPECTED_HEX:
                    print("  RESULT_MATCH=yes")
                    return 0
                else:
                    print("  RESULT_MATCH=no  (returned, but wrong output)")
                    return 1
            else:
                print("  HANG -- jsr never returned within timeout")
                return 3
        finally:
            mgr.release(inst)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--case", default="clean", choices=sorted(CASES.keys()))
    ap.add_argument("--target", default="u64", choices=("u64", "vice"))
    ap.add_argument("--host", default=DEFAULT_HOST)
    ap.add_argument("--mhz", type=int, default=1,
                    help="CPU speed; 1 = stock NTSC (default)")
    ap.add_argument("--timeout", type=float, default=180.0,
                    help="Max seconds to wait for the scalarmult to return")
    ap.add_argument("--init-timeout", type=float, default=120.0)
    ap.add_argument("--skip-reboot", action="store_true",
                    help="Assume PRG already loaded; reuse current state")
    args = ap.parse_args()

    if not os.path.isfile(PRG_PATH) or not os.path.isfile(LABELS_PATH):
        print(f"FATAL: missing {PRG_PATH} or {LABELS_PATH}; run 'make' first")
        return 2
    with open(PRG_PATH, "rb") as f:
        prg_data = f.read()
    labels = Labels.from_file(LABELS_PATH)

    needed = ["x25519_scalarmult", "x25519_clamp",
              "x25_scalar", "x25_u", "x25_result"]
    for sym in needed:
        if labels.address(sym) is None:
            print(f"FATAL: label '{sym}' not in {LABELS_PATH}")
            return 2
    scalarmult_addr = labels["x25519_scalarmult"]
    x25_scalar_addr = labels["x25_scalar"]
    x25_u_addr      = labels["x25_u"]
    x25_result_addr = labels["x25_result"]

    if labels.address("main_loop") is None:
        print("FATAL: 'main_loop' label not exported. Add `.export main_loop`"
              " to src/main.s and rebuild.")
        return 2
    main_loop_addr = labels["main_loop"]

    print(f"  PRG:        {PRG_PATH} ({len(prg_data)} bytes)")
    print(f"  scalarmult: ${scalarmult_addr:04x}")
    print(f"  main_loop:  ${main_loop_addr:04x}")
    print(f"  x25_scalar: ${x25_scalar_addr:04x}")
    print(f"  x25_u:      ${x25_u_addr:04x}")
    print(f"  x25_result: ${x25_result_addr:04x}")
    print(f"  case:       {args.case}")
    print(f"  target:     {args.target}")

    dirty_bytes = CASES[args.case]()
    print(f"  dirty_setup: {len(dirty_bytes)} bytes")

    if args.target == "vice":
        return _run_on_vice(args, prg_data, labels, scalarmult_addr,
                            x25_scalar_addr, x25_u_addr, x25_result_addr,
                            main_loop_addr, dirty_bytes)

    print(f"  host:       {args.host}, mhz={args.mhz}")

    lock = DeviceLock(args.host)
    print("  acquiring device lock (cross-process queue)...", flush=True)
    if not lock.acquire(timeout=600.0):
        print("FATAL: could not acquire device lock within 10min")
        return 2
    print("  device lock acquired")

    # After lock acquisition, probe with retries: the previous holder
    # may have just released and the U64 firmware can take a few
    # seconds before the REST API responds again.
    print("  probing U64E REST API (retry up to 30s)...", flush=True)
    deadline = time.monotonic() + 30.0
    pr = None
    while time.monotonic() < deadline:
        pr = probe_u64(args.host, password=PASSWORD)
        if pr.reachable:
            break
        time.sleep(2.0)
    if pr is None or not pr.reachable:
        lock.release()
        print(f"FATAL: U64E unreachable after lock: {pr}")
        return 2
    print(f"  probe ok: {pr}")
    try:
        client = Ultimate64Client(host=args.host, password=PASSWORD,
                                  timeout=60.0)
        transport = Ultimate64Transport(host=args.host, password=PASSWORD,
                                        client=client)
        orig = snapshot_state(client)
        try:
            if not args.skip_reboot:
                print("  reset (KERNAL warm)...", end="", flush=True)
                # Pause first: if a previous run left CPU in mid-PRG
                # state, run_prg will return 404. Pause+resume around
                # reset is the harness's idiom.
                try:
                    client.pause()
                except Exception:
                    pass
                client.reset()
                time.sleep(2.5)
                try:
                    client.resume()
                except Exception:
                    pass
                time.sleep(2.5)
                print(" ok")
                print("  enable REU 512KB...", end="", flush=True)
                set_reu(client, enabled=True, size="512 KB")
                print(" ok")
                print(f"  set turbo {args.mhz} MHz...", end="", flush=True)
                set_turbo_mhz(client, args.mhz)
                time.sleep(0.5)
                print(" ok")
                print(f"  run_prg {len(prg_data)}B...", end="", flush=True)
                client.run_prg(prg_data)
                print(" sent")
                # PRG init takes a while at 1 MHz: sqtab + reu_mul_init.
                # reu_mul_init does 256 * (2 stash autoloads + doubled
                # tables stash + carry stash) DMAs == ~1300 DMAs at
                # ~1 ms each plus ~256 inner-loop multiplies. Eyeball
                # 60-90s at 1 MHz. We poll the screen for "READY. Q="
                # via screen RAM ($0400+).
                print(f"  wait for READY (up to {args.init_timeout:.0f}s):",
                      end="", flush=True)
                deadline = time.monotonic() + args.init_timeout
                ready = False
                while time.monotonic() < deadline:
                    s = transport.read_memory(0x0400, 200)
                    # PETSCII screencode: 'R'=$12, 'E'=$05, 'A'=$01,
                    # 'D'=$04, 'Y'=$19, '.'=$2E.
                    if bytes([0x12, 0x05, 0x01, 0x04, 0x19, 0x2E]) in s:
                        ready = True
                        break
                    print(".", end="", flush=True)
                    time.sleep(2.0)
                if not ready:
                    print(f"\nFATAL: READY never appeared in {args.init_timeout:.0f}s")
                    return 2
                print(f" READY ({time.monotonic() - deadline + args.init_timeout:.0f}s)")

            # Set up the test inputs in x25_scalar / x25_u.
            scalar = bytes.fromhex(SCALAR_HEX)
            scalar = clamp(scalar)
            u_bytes = bytes.fromhex(U_HEX)
            transport.write_memory(x25_scalar_addr, scalar)
            transport.write_memory(x25_u_addr, u_bytes)
            # Zero the result region so we can detect "wrote zeros" vs
            # "didn't run".
            transport.write_memory(x25_result_addr, bytes(32))

            # Build trampoline.
            tramp = build_trampoline(scalarmult_addr,
                                     x25_scalar_addr, x25_u_addr,
                                     dirty_setup=dirty_bytes)
            # Clear sentinels first so we can distinguish "never ran"
            # vs "ran and finished".
            transport.write_memory(DONE_SENTINEL_ADDR, bytes([0x00]))
            transport.write_memory(PRE_MARKER_ADDR,    bytes([0x00]))
            transport.write_memory(POST_MARKER_ADDR,   bytes([0x00]))
            transport.write_memory(TRAMPOLINE_ADDR, tramp)
            print(f"  trampoline @ ${TRAMPOLINE_ADDR:04x}, {len(tramp)} bytes")

            # Hijack main_loop. main.s:
            #   main_loop:
            #     jmp main_loop      ; bytes: 4C lo hi @ main_loop
            # We rewrite the operand to point at TRAMPOLINE_ADDR.
            # Atomic-ish: write low byte first, high byte second.
            # Read current bytes for sanity.
            cur = transport.read_memory(main_loop_addr, 3)
            assert cur[0] == 0x4C, (
                f"main_loop @ ${main_loop_addr:04x} not 'JMP abs' "
                f"(got {cur.hex()})")
            transport.write_memory(main_loop_addr + 1,
                bytes([TRAMPOLINE_ADDR & 0xFF,
                       (TRAMPOLINE_ADDR >> 8) & 0xFF]))

            print(f"  hijacked main_loop -> ${TRAMPOLINE_ADDR:04x}, "
                  f"polling sentinel (timeout {args.timeout:.0f}s)...")

            t0 = time.monotonic()
            outcome = "TIMEOUT"
            while time.monotonic() - t0 < args.timeout:
                done = transport.read_memory(DONE_SENTINEL_ADDR, 1)[0]
                if done == 0x42:
                    outcome = "OK"
                    break
                time.sleep(0.5)

            elapsed = time.monotonic() - t0
            pre = transport.read_memory(PRE_MARKER_ADDR, 1)[0]
            post = transport.read_memory(POST_MARKER_ADDR, 1)[0]
            done = transport.read_memory(DONE_SENTINEL_ADDR, 1)[0]
            print(f"  outcome:  {outcome} after {elapsed:.1f}s")
            print(f"  pre=${pre:02x}  post=${post:02x}  done=${done:02x}")

            # Restore main_loop so the device doesn't keep retriggering.
            transport.write_memory(main_loop_addr + 1,
                bytes([main_loop_addr & 0xFF,
                       (main_loop_addr >> 8) & 0xFF]))

            if outcome == "OK":
                got = transport.read_memory(x25_result_addr, 32)
                print(f"  result:   {got.hex()}")
                print(f"  expected: {EXPECTED_HEX}")
                if got.hex() == EXPECTED_HEX:
                    print("  RESULT_MATCH=yes")
                    return 0
                else:
                    print("  RESULT_MATCH=no  (returned, but wrong output)")
                    return 1
            else:
                if pre == 0x55 and post == 0x00:
                    print("  HANG INSIDE x25519_scalarmult "
                          "(pre-marker set, post-marker not)")
                elif pre == 0x00:
                    print("  HANG/FAULT BEFORE pre-marker; trampoline "
                          "didn't run or dirty_setup faulted")
                return 3
        finally:
            try:
                restore_state(client, orig)
            except Exception:
                pass
            try:
                transport.close()
            except Exception:
                pass
    finally:
        lock.release()


if __name__ == "__main__":
    sys.exit(main())
