#!/usr/bin/env python3
"""test_reu_fetch_mul_row.py — the §8.2 per-row fetch, called directly.

reu_fetch_mul_row (A = a on entry) must DMA row a of the shared mul table
into the staging buffers: mul_dma_lo[b] = lo(a*b), mul_dma_hi[b] = hi(a*b).
No in-tree hot path calls it, so the field stress tests never exercise it.
Rows include a >= 128, which selects the table's second bank.

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


def thunk(labels, a):
    """Restore the fetch's autoload state, then lda #a; jsr reu_fetch_mul_row."""
    def jsr_(addr):
        return bytes([0x20, addr & 0xFF, addr >> 8])
    return (bytes([0xA9, 0x00,              # lda #0
                   0x8D, 0x04, 0xDF,        # sta $DF04 (REU addr lo)
                   0x8D, 0x0A, 0xDF])       # sta $DF0A (addr control)
            + jsr_(labels["reu_clear_wide"])  # c64 addr = mul_dma_lo, len 512
            + bytes([0xA9, a])              # lda #a
            + jsr_(labels["reu_fetch_mul_row"])
            + bytes([0x60]))                # rts


def main():
    labels = Labels.from_file(vice_build.labels_path())
    for name in ("reu_fetch_mul_row", "reu_clear_wide", "mul_dma_lo", "mul_dma_hi"):
        if labels.address(name) is None:
            print(f"FATAL: '{name}' not in {vice_build.labels_path()}")
            sys.exit(1)
    vice_build.check_expected_bank(labels)
    lo_addr, hi_addr = labels["mul_dma_lo"], labels["mul_dma_hi"]
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
        for a in ROWS:
            # Poison the staging buffers so a fetch that moves nothing fails.
            write_bytes(t, lo_addr, bytes([0x5A]) * 256)
            write_bytes(t, hi_addr, bytes([0x5A]) * 256)
            write_bytes(t, THUNK, thunk(labels, a))
            jsr(t, THUNK, timeout=10.0)
            lo = read_bytes(t, lo_addr, 256)
            hi = read_bytes(t, hi_addr, 256)
            bad = [b for b in range(256)
                   if lo[b] != (a * b) & 0xFF or hi[b] != (a * b) >> 8]
            if bad:
                b = bad[0]
                print(f"  FAIL reu_fetch_mul_row a=0x{a:02X}: {len(bad)}/256 entries wrong; "
                      f"b=0x{b:02X} expected 0x{a * b:04X} got 0x{hi[b]:02X}{lo[b]:02X}")
                failed += 1
            else:
                print(f"  PASS reu_fetch_mul_row a=0x{a:02X}")
        mgr.release(inst)
    print(f"Results: {len(ROWS) - failed}/{len(ROWS)} rows passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
