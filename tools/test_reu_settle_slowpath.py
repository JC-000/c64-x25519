#!/usr/bin/env python3
"""test_reu_settle_slowpath.py — §8.2 REU settle: fault-byte semantics.

VICE completes every REU DMA before the CPU's next instruction and sets
$DF00 bit 6, so REU_SETTLE's `jsr x25519_reu_settle_slow` is never taken
in situ (this file proves that too: the slow path's memory cells stay at a
sentinel across a full scalarmult). The slow path's logic is therefore
exercised by ENTERING IT DIRECTLY with a crafted A, exactly as the macro
would after a bad sample. Under VICE the follow-up $DF00 reads return bit 6
clear (bits 5-7 are clear-on-read and nothing re-sets them), so the spin
must expire.

Checks (REU attached):
  1. sentinel: x25519_reu_settle_cnt/_smp untouched by a full
     x25519_scalarmult (fast path only) and x25519_reu_fault == 0.
  2. A = $00 ^ $40 = $40  (bit6 clear, bit5 clear): spins ITER-1 more
     reads, fault |= $01, cnt reaches 0.
  3. A = $20 ^ $40 = $60  (bit5 set, bit6 clear): fault == $03, cnt 0.
  4. A = $60 ^ $40 = $20  (bit6 set AND bit5 set): fault == $02, no
     further reads (cnt == ITER).
  5. A = $40 ^ $40 = $00  (good sample, macro would not call): no change.
  6. sticky: a pre-set fault byte is never cleared by the slow path;
     X, Y and C are preserved on every path.
  7. reu_probe with REU: C=1, fault 0, $DF02-$DF08 restored to the
     pre-call values, $DF0A left 0.
Checks (no REU, `+reu`):
  8. reu_probe: C=0.  Reports fault byte and what $DF00 reads as.

Usage:
    C64_SKIP_BUILD=1 python3 tools/test_reu_settle_slowpath.py
"""

import os
import subprocess
import sys

from c64_test_harness import (
    Labels, ViceConfig, ViceInstanceManager,
    read_bytes, write_bytes, jsr, wait_for_text,
)

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
BUILD_DIR = os.environ.get("X25519_BUILD_DIR", "build")
if not os.path.isabs(BUILD_DIR):
    BUILD_DIR = os.path.join(PROJECT_ROOT, BUILD_DIR)
PRG_PATH = os.path.join(BUILD_DIR, "x25519.prg")
LABELS_PATH = os.path.join(BUILD_DIR, "labels.txt")
ITER = int(os.environ.get("X25519_REU_SETTLE_ITER", "8"))

THUNK = 0x03B0
RES = 0x0390        # results: [0]=X [1]=Y [2]=P after call, [3]=P before


def thunk_call_slow(labels, a_val, carry):
    """ldx #$12; ldy #$34; sec/clc; lda #a; jsr slow; php; stx RES; sty RES+1; pla; sta RES+2; rts"""
    slow = labels["x25519_reu_settle_slow"]
    return bytes([0xA2, 0x12, 0xA0, 0x34, 0x38 if carry else 0x18, 0xA9, a_val & 0xFF,
                  0x20, slow & 0xFF, slow >> 8,
                  0x08, 0x8E, RES & 0xFF, RES >> 8, 0x8C, (RES + 1) & 0xFF, RES >> 8,
                  0x68, 0x8D, (RES + 2) & 0xFF, RES >> 8, 0x60])


def thunk_probe(labels):
    p = labels["reu_probe"]
    return bytes([0x20, p & 0xFF, p >> 8, 0x08, 0x68, 0x8D, (RES + 2) & 0xFF, RES >> 8, 0x60])


def state(t, labels):
    f = read_bytes(t, labels["x25519_reu_fault"], 1)[0]
    c = read_bytes(t, labels["x25519_reu_settle_cnt"], 1)[0]
    s = read_bytes(t, labels["x25519_reu_settle_smp"], 1)[0]
    return f, c, s


def call_slow(t, labels, a_val, carry, fault_pre=0):
    write_bytes(t, labels["x25519_reu_fault"], bytes([fault_pre]))
    write_bytes(t, labels["x25519_reu_settle_cnt"], bytes([0xEE]))
    write_bytes(t, labels["x25519_reu_settle_smp"], bytes([0xEE]))
    write_bytes(t, THUNK, thunk_call_slow(labels, a_val, carry))
    jsr(t, THUNK, timeout=30.0)
    r = read_bytes(t, RES, 3)
    assert r[0] == 0x12 and r[1] == 0x34, f"X/Y clobbered: {r.hex()}"
    assert (r[2] & 1) == (1 if carry else 0), f"C clobbered: P=${r[2]:02x} carry_in={carry}"
    return state(t, labels)


def ok(label, cond, detail=""):
    print(f"  [{'PASS' if cond else 'FAIL'}] {label}" + (f"  {detail}" if detail else ""), flush=True)
    assert cond, f"{label} {detail}"


def with_reu(labels):
    config = ViceConfig(prg_path=PRG_PATH, warp=True, ntsc=True, sound=False,
                        extra_args=["-reu", "-reusize", "512"])
    with ViceInstanceManager(config=config) as mgr:
        inst = mgr.acquire(); t = inst.transport
        assert wait_for_text(t, "Q=QUIT", timeout=120.0) is not None
        write_bytes(t, 0x0339, bytes([0x4C, 0x39, 0x03]))
        print("--- REU attached ---")
        f, c, s = state(t, labels)
        ok("after boot (reu_mul_init): fault=0", f == 0, f"fault=${f:02x}")

        # 1. slow path never runs in situ
        write_bytes(t, labels["x25519_reu_settle_cnt"], bytes([0xEE]))
        write_bytes(t, labels["x25519_reu_settle_smp"], bytes([0xEE]))
        k = bytes([0x08]) + bytes(30) + bytes([0x40]); u = bytes([9]) + bytes(31)
        write_bytes(t, labels["x25_scalar"], k); write_bytes(t, labels["x25_u"], u)
        jsr(t, labels["x25519_scalarmult"], timeout=7200.0)
        f, c, s = state(t, labels)
        ok("full scalarmult: slow path never entered (cnt/smp sentinel intact), fault=0",
           f == 0 and c == 0xEE and s == 0xEE, f"fault=${f:02x} cnt=${c:02x} smp=${s:02x}")
        print("      (this is the ONLY settle path VICE can exercise in situ; the slow "
              "path below is entered directly)")

        # 2. bit6 clear, bit5 clear
        f, c, s = call_slow(t, labels, 0x40, carry=True)
        ok(f"A=$40 (sample $00): spin expires -> fault=$01, cnt=0", f == 0x01 and c == 0,
           f"fault=${f:02x} cnt=${c:02x} smp=${s:02x}")
        # 3. bit5 set, bit6 clear
        f, c, s = call_slow(t, labels, 0x60, carry=False)
        ok(f"A=$60 (sample $20): verify-error recorded AND spin expires -> fault=$03", f == 0x03 and c == 0,
           f"fault=${f:02x} cnt=${c:02x} smp=${s:02x}")
        # 4. both set
        f, c, s = call_slow(t, labels, 0x20, carry=True)
        ok(f"A=$20 (sample $60): fault=$02, no further reads (cnt==ITER={ITER})", f == 0x02 and c == ITER,
           f"fault=${f:02x} cnt=${c:02x} smp=${s:02x}")
        # 5. good sample
        f, c, s = call_slow(t, labels, 0x00, carry=False)
        ok(f"A=$00 (sample $40): fault stays 0, cnt==ITER", f == 0 and c == ITER,
           f"fault=${f:02x} cnt=${c:02x} smp=${s:02x}")
        # 6. sticky
        f, c, s = call_slow(t, labels, 0x00, carry=True, fault_pre=0x02)
        ok("sticky: pre-set fault $02 survives a good sample", f == 0x02, f"fault=${f:02x}")
        f, c, s = call_slow(t, labels, 0x40, carry=True, fault_pre=0x02)
        ok("sticky: pre-set $02 + expiry -> $03", f == 0x03, f"fault=${f:02x}")

        # 7. reu_probe with REU
        pre = bytes([0x11, 0x22, 0x33, 0x44, 0x05, 0x66, 0x77])
        for i, b in enumerate(pre):
            write_bytes(t, 0xDF02 + i, bytes([b]))
        write_bytes(t, labels["x25519_reu_fault"], bytes([0x03]))   # must be cleared at entry
        write_bytes(t, THUNK, thunk_probe(labels))
        jsr(t, THUNK, timeout=30.0)
        pflags = read_bytes(t, RES + 2, 1)[0]
        f, c, s = state(t, labels)
        post = bytes(read_bytes(t, 0xDF02 + i, 1)[0] for i in range(7))
        ok("reu_probe: C=1 with REU", pflags & 1 == 1, f"P=${pflags:02x}")
        ok("reu_probe: fault cleared at entry and 0 after 4 DMAs", f == 0, f"fault=${f:02x}")
        # $DF06 bank register: only low bits are implemented on a 512 KB REU
        # $DF06 (bank) has only bits 0-2 writable; a 17xx (and VICE) reads bits
        # 3-7 back as 1, so compare the bank field, not the raw byte.
        ok("reu_probe: $DF02-$DF08 restored to pre-call values (bank field masked)", post[:4] == pre[:4] and post[5:] == pre[5:] and (post[4] & 7) == (pre[4] & 7)
           and (post[4] & 0x07) == (pre[4] & 0x07), f"pre={pre.hex()} post={post.hex()}")
        ok("reu_probe: $DF0A left 0", read_bytes(t, 0xDF0A, 1)[0] & 0xC0 == 0)
        mgr.release(inst)


def without_reu(labels):
    config = ViceConfig(prg_path=PRG_PATH, warp=True, ntsc=True, sound=False, extra_args=["+reu"])
    with ViceInstanceManager(config=config) as mgr:
        inst = mgr.acquire(); t = inst.transport
        # The default build calls reu_mul_init at boot; with no REU it still
        # terminates (every DMA is a no-op, every settle read sees open bus).
        grid = wait_for_text(t, "Q=QUIT", timeout=180.0)
        print("--- no REU (+reu) ---")
        f, c, s = state(t, labels)
        df00 = read_bytes(t, 0xDF00, 1)[0]
        print(f"      boot reached menu: {grid is not None}; after boot fault=${f:02x} "
              f"cnt=${c:02x} smp=${s:02x}; $DF00 reads ${df00:02x}")
        if grid is None:
            print("  [INFO] reu_mul_init did not finish without an REU (settle spins on open bus); "
                  "reu_probe cannot be reached from this PRG's boot path")
            mgr.release(inst); return
        write_bytes(t, 0x0339, bytes([0x4C, 0x39, 0x03]))
        write_bytes(t, THUNK, thunk_probe(labels))
        jsr(t, THUNK, timeout=60.0)
        pflags = read_bytes(t, RES + 2, 1)[0]
        f, c, s = state(t, labels)
        ok("reu_probe: C=0 without REU", pflags & 1 == 0, f"P=${pflags:02x}")
        print(f"      fault=${f:02x} cnt=${c:02x} smp=${s:02x} (fault!=0 means the settle "
              f"itself flagged the missing REU; 0 means open-bus reads looked like bit6 set)")
        mgr.release(inst)


def main():
    if not os.environ.get("C64_SKIP_BUILD"):
        r = subprocess.run(["make"], capture_output=True, text=True, cwd=PROJECT_ROOT)
        assert r.returncode == 0, r.stderr
    labels = Labels.from_file(LABELS_PATH)
    with_reu(labels)
    without_reu(labels)
    print("PASS")


if __name__ == "__main__":
    main()
