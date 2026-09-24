#!/usr/bin/env python3
"""test_reu_fetch_mul_row.py — the §8.2 per-row fetch, called directly.

reu_fetch_mul_row (A = a on entry) must DMA row a of the shared mul table
into the staging buffers: mul_dma_lo[b] = lo(a*b), mul_dma_hi[b] = hi(a*b).
No in-tree hot path calls it, so the field stress tests never exercise it.
Rows include a >= 128, which selects the table's second bank.

§8.2 puts no precondition on REU register state, so each row is fetched
under three preceding states:
  clean          fe25519_mul's own setup (reu_lo/addr_ctrl = 0,
                 reu_clear_wide's c64 addr + length) runs first;
  after-doubled  reu_fetch_doubled_row (a=3) runs first, leaving the
                 autoload latch at mul_dma_carry / 256 bytes;
  after-sqr      a real fe25519_sqr runs first (its last REU op is that
                 same DMA).
The last two need the SQR_DMA_K > 0 build and are skipped, by name, in
the 1764 build. After every fetch the C64 address, REU address low byte,
length and address control must read back as mul_dma_lo / $00 / 512 / $00
(address control: bits 7-6; the unused bits read as 1 under VICE).

Build / REU selection: see vice_build.py (X25519_BUILD_DIR, X25519_REUSIZE,
X25519_EXPECT_REU_BANK). This script never builds.

Usage:
    python3 tools/test_reu_fetch_mul_row.py
"""

import os
import sys

from c64_test_harness import (
    Labels, ViceConfig, ViceInstanceManager,
    read_bytes, write_bytes, jsr, wait_for_text,
)

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vice_build  # noqa: E402

THUNK = 0x03B0   # cassette-buffer scratch, as the CT guards use
ROWS = [0x00, 0x01, 0x02, 0x7F, 0x80, 0x81, 0xA5, 0xFF]
SQR_IN = 0x11    # fe25519_sqr input: all 32 limbs 0x11 (doubled row 0x22 is not in ROWS)


def jsr_(addr):
    return bytes([0x20, addr & 0xFF, addr >> 8])


def prelude(labels, case):
    """6502 code that runs before the fetch, leaving the REU in `case`'s state."""
    if case == "clean":
        return (bytes([0xA9, 0x00,              # lda #0
                       0x8D, 0x04, 0xDF,        # sta $DF04 (REU addr lo)
                       0x8D, 0x0A, 0xDF])       # sta $DF0A (addr control)
                + jsr_(labels["reu_clear_wide"]))  # c64 addr = mul_dma_lo, len 512
    if case == "after-doubled":
        m = labels["mul_cached_a"]
        return (bytes([0xA9, 0x03,              # lda #3
                       0x8D, m & 0xFF, m >> 8])  # sta mul_cached_a
                + jsr_(labels["reu_fetch_doubled_row"]))
    if case == "after-sqr":
        return jsr_(labels["fe25519_sqr"])
    raise ValueError(case)


def thunk(labels, case, a):
    """<prelude>; lda #a; jsr reu_fetch_mul_row; rts"""
    return (prelude(labels, case)
            + bytes([0xA9, a])                  # lda #a
            + jsr_(labels["reu_fetch_mul_row"])
            + bytes([0x60]))                    # rts


def main():
    labels = Labels.from_file(vice_build.labels_path())
    for name in ("reu_fetch_mul_row", "reu_clear_wide", "mul_dma_lo", "mul_dma_hi"):
        if labels.address(name) is None:
            print(f"FATAL: '{name}' not in {vice_build.labels_path()}")
            sys.exit(1)
    vice_build.check_expected_bank(labels)
    lo_addr, hi_addr = labels["mul_dma_lo"], labels["mul_dma_hi"]
    cases = ["clean"]
    if labels.address("reu_fetch_doubled_row") is None:
        print("  SKIP after-doubled, after-sqr: no reu_fetch_doubled_row "
              "in this build (SQR_DMA_K = 0)")
    else:
        for name in ("mul_cached_a", "fe25519_sqr", "fe25519_src1",
                     "fe25519_dst", "fe25519_tmp1", "fe25519_tmp3"):
            if labels.address(name) is None:
                print(f"FATAL: '{name}' not in {vice_build.labels_path()}")
                sys.exit(1)
        cases += ["after-doubled", "after-sqr"]
    config = ViceConfig(prg_path=vice_build.prg_path(), warp=True, ntsc=True,
                        sound=False, extra_args=vice_build.reu_args())
    failed = 0
    with ViceInstanceManager(config=config) as mgr:
        inst = mgr.acquire()
        t = inst.transport
        if wait_for_text(t, "Q=QUIT", timeout=60.0, verbose=False) is None:
            print("FATAL: Main menu did not appear")
            sys.exit(1)
        write_bytes(t, 0x0339, bytes([0x4C, 0x39, 0x03]))
        for case in cases:
            if case == "after-sqr":
                tmp1, tmp3 = labels["fe25519_tmp1"], labels["fe25519_tmp3"]
                write_bytes(t, tmp1, bytes([SQR_IN]) * 32)
                write_bytes(t, labels["fe25519_src1"], bytes([tmp1 & 0xFF, tmp1 >> 8]))
                write_bytes(t, labels["fe25519_dst"], bytes([tmp3 & 0xFF, tmp3 >> 8]))
            for a in ROWS:
                if case == "after-sqr":   # sqr writes dst only; reset its input
                    write_bytes(t, labels["fe25519_tmp1"], bytes([SQR_IN]) * 32)
                # Poison the staging buffers so a fetch that moves nothing fails.
                write_bytes(t, lo_addr, bytes([0x5A]) * 256)
                write_bytes(t, hi_addr, bytes([0x5A]) * 256)
                write_bytes(t, THUNK, thunk(labels, case, a))
                jsr(t, THUNK, timeout=60.0)
                lo = read_bytes(t, lo_addr, 256)
                hi = read_bytes(t, hi_addr, 256)
                # c64 lo/hi, reu lo/hi/bank, len lo/hi, irq mask, addr ctrl
                regs = read_bytes(t, 0xDF02, 9)
                tag = f"reu_fetch_mul_row [{case}] a=0x{a:02X}"
                bad = [b for b in range(256)
                       if lo[b] != (a * b) & 0xFF or hi[b] != (a * b) >> 8]
                reg_err = []
                if regs[0] | (regs[1] << 8) != lo_addr:
                    reg_err.append(f"c64 addr ${regs[1]:02X}{regs[0]:02X} != mul_dma_lo ${lo_addr:04X}")
                if regs[2] != 0:
                    reg_err.append(f"reu addr lo ${regs[2]:02X} != $00")
                if regs[5] | (regs[6] << 8) != 512:
                    reg_err.append(f"length {regs[5] | (regs[6] << 8)} != 512")
                if regs[8] & 0xC0:   # $DF0A: only bits 7-6 are implemented
                    reg_err.append(f"addr ctrl ${regs[8]:02X}: bits 7-6 != 00")
                if bad:
                    b = bad[0]
                    print(f"  FAIL {tag}: {len(bad)}/256 entries wrong; "
                          f"b=0x{b:02X} expected 0x{a * b:04X} got 0x{hi[b]:02X}{lo[b]:02X}")
                    failed += 1
                elif reg_err:
                    print(f"  FAIL {tag}: row correct but on return " + "; ".join(reg_err))
                    failed += 1
                else:
                    print(f"  PASS {tag}")
        mgr.release(inst)
    total = len(cases) * len(ROWS)
    print(f"Results: {total - failed}/{total} fetches passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
