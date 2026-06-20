#!/usr/bin/env python3
"""ct_mul_brute_check.py — Exhaustive correctness check for mul_8x8.

Runs the C64 `mul_8x8` quarter-square 8x8->16 multiply for all 65,536
(a, b) byte pairs and compares the 16-bit result against the Python
reference `a * b`.

Purpose
-------
This tool gates Phase 1 and Phase 2 landing of the constant-time
remediation tracked in `docs/CT_ANALYSIS.md` (issue #20). Any change to
`src/mul_8x8.s` — in particular a branch-free rewrite of the `|a-b|`
sign path or the sum-page select — must preserve full functional
correctness. Running this tool after each commit is cheap (~tens of
seconds in VICE warp) and catches regressions that stress tests with
targeted inputs can miss.

Usage
-----
    python3 tools/ct_mul_brute_check.py

Exits 0 on 0 mismatches, 1 otherwise (printing the first 5 failing
(a, b, got, expected) tuples).

Implementation notes
--------------------
A Python-driven 65,536-call loop is infeasible (each `jsr` round-trip
is ~10 ms, ~10 minutes total even in warp). Instead we upload a small
6502 kernel at $0360 that sweeps `b = 0..255` for a fixed `a`, writing
512 result bytes into two scratch pages at $C000/$C100. ct_mul_8x8 takes
`b` in Y and the multiplicand `a` SMC-baked into smc_sum_a_imm+1 /
smc_diff_a_imm+1; Python bakes `a` into those two sites for each outer
iteration and calls `jsr` once per `a` — 256 round-trips total.

Per project memory (`feedback_vice_instances.md`,
`feedback_no_direct_vice.md`):
 - Never spawn or kill VICE directly — always via ViceInstanceManager.
 - Never probe VICE ports directly — always via the harness.
"""

import os
import sys

from c64_test_harness import (
    Labels, ViceConfig, ViceInstanceManager,
    read_bytes, write_bytes, jsr, load_code, wait_for_text,
)

PROJECT_ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
PRG_PATH = os.path.join(PROJECT_ROOT, "build", "x25519.prg")
LABELS_PATH = os.path.join(PROJECT_ROOT, "build", "labels.txt")

# Kernel location (safe free RAM, same region used by bench_x25519.py).
KERNEL_ADDR = 0x0360

# Scratch buffers for the sweep results: 256 low bytes at $C000,
# 256 high bytes at $C100. $C000-$CFFF is free 4 KB RAM on the C64.
SCRATCH_LO = 0xC000
SCRATCH_HI = 0xC100

# Zero-page byte the kernel uses as its `b` counter. $FB-$FE are
# traditionally free scratch on the C64 KERNAL memory map.
ZP_B = 0xFB


def build_kernel(mul_8x8_addr, poly_prod_lo_addr, poly_prod_hi_addr):
    """Assemble the 6502 inner-sweep kernel for the SMC-baked
    ct_mul_8x8 calling convention (c64-lib-contract §8.3 adoption).

    The canonical ct_mul_8x8 takes its multiplier `b` in Y; the
    multiplicand `a` is SMC-baked by the *caller* into the two immediate
    operand sites smc_sum_a_imm+1 / smc_diff_a_imm+1 once per outer-a
    iteration. So Python patches `a` into those two addresses (not into
    the kernel), and the kernel only sweeps `b`::

            ldx #$00            ; b = 0
            stx $FB             ; save b
        loop:
            ldy $FB             ; Y = b  (ct_mul_8x8 multiplier operand)
            jsr ct_mul_8x8      ; -> poly_prod_lo/hi (a is SMC-baked)
            ldy $FB             ; Y = b again (ct_mul_8x8 clobbers Y)
            lda poly_prod_lo
            sta $C000,y
            lda poly_prod_hi
            sta $C100,y
            inc $FB
            bne loop            ; 256 iterations then $FB wraps to 0
            rts

    Returns the kernel bytes.
    """
    code = bytearray()

    # ldx #$00
    code += bytes([0xA2, 0x00])
    # stx $FB
    code += bytes([0x86, ZP_B])

    loop_offset = len(code)

    # ldy $FB  (Y = b — ct_mul_8x8 multiplier operand)
    code += bytes([0xA4, ZP_B])

    # jsr ct_mul_8x8  (a is SMC-baked into the body by Python, below)
    code += bytes([0x20, mul_8x8_addr & 0xFF, (mul_8x8_addr >> 8) & 0xFF])

    # ldy $FB  (reload b; ct_mul_8x8 exits with Y = |a-b|)
    code += bytes([0xA4, ZP_B])

    # lda poly_prod_lo (absolute)
    code += bytes([0xAD, poly_prod_lo_addr & 0xFF,
                   (poly_prod_lo_addr >> 8) & 0xFF])

    # sta $C000,y
    code += bytes([0x99, SCRATCH_LO & 0xFF, (SCRATCH_LO >> 8) & 0xFF])

    # lda poly_prod_hi (absolute)
    code += bytes([0xAD, poly_prod_hi_addr & 0xFF,
                   (poly_prod_hi_addr >> 8) & 0xFF])

    # sta $C100,y
    code += bytes([0x99, SCRATCH_HI & 0xFF, (SCRATCH_HI >> 8) & 0xFF])

    # inc $FB
    code += bytes([0xE6, ZP_B])

    # bne loop  (signed 8-bit displacement back to loop_offset)
    bne_off = len(code) + 2  # address of the byte after BNE
    disp = loop_offset - bne_off
    assert -128 <= disp <= 127, f"BNE displacement out of range: {disp}"
    code += bytes([0xD0, disp & 0xFF])

    # rts
    code += bytes([0x60])

    return bytes(code)


def main():
    os.chdir(PROJECT_ROOT)

    labels = Labels.from_file(LABELS_PATH)
    required = ["ct_mul_8x8", "smc_sum_a_imm", "smc_diff_a_imm",
                "poly_prod_lo", "poly_prod_hi"]
    for name in required:
        if labels.address(name) is None:
            print(f"FATAL: '{name}' label not found in {LABELS_PATH}")
            sys.exit(1)

    mul_addr = labels["ct_mul_8x8"]
    lo_addr = labels["poly_prod_lo"]
    hi_addr = labels["poly_prod_hi"]
    # `a` is SMC-baked into the two immediate operand sites (the byte
    # after each opcode, i.e. label+1) once per outer iteration.
    sum_a_addr = labels["smc_sum_a_imm"] + 1
    diff_a_addr = labels["smc_diff_a_imm"] + 1
    print(f"ct_mul_8x8     = ${mul_addr:04X}")
    print(f"poly_prod_lo   = ${lo_addr:04X}")
    print(f"poly_prod_hi   = ${hi_addr:04X}")
    print(f"smc_sum_a_imm+1  = ${sum_a_addr:04X}")
    print(f"smc_diff_a_imm+1 = ${diff_a_addr:04X}")

    kernel = build_kernel(mul_addr, lo_addr, hi_addr)
    print(f"Kernel: {len(kernel)} bytes at ${KERNEL_ADDR:04X} "
          f"(b-sweep; a SMC-baked per outer iter)")

    config = ViceConfig(prg_path=PRG_PATH, warp=True, ntsc=True, sound=False,
                        extra_args=["-reu", "-reusize", "512"])

    mismatches = 0
    first_failures = []

    with ViceInstanceManager(config=config) as mgr:
        inst = mgr.acquire()
        print(f"VICE PID={inst.pid}, port={inst.port}")
        transport = inst.transport

        grid = wait_for_text(transport, "Q=QUIT", timeout=60.0, verbose=False)
        if grid is None:
            print("FATAL: Main menu did not appear")
            sys.exit(1)
        print("VICE ready")

        # Safety trampoline: JMP to self at $0339
        write_bytes(transport, 0x0339, bytes([0x4C, 0x39, 0x03]))

        # Upload the sweep kernel once.
        load_code(transport, KERNEL_ADDR, kernel)

        print(f"Running brute-force sweep (65,536 products)...")

        for a in range(256):
            # SMC-bake the current `a` into ct_mul_8x8's two immediate
            # operand sites (the caller's job in this calling convention).
            write_bytes(transport, sum_a_addr, bytes([a]))
            write_bytes(transport, diff_a_addr, bytes([a]))

            # Execute the inner 256-iteration b-sweep kernel for this `a`.
            jsr(transport, KERNEL_ADDR, timeout=30.0)

            # Read back 256 low-bytes and 256 high-bytes of results.
            lo_buf = read_bytes(transport, SCRATCH_LO, 256)
            hi_buf = read_bytes(transport, SCRATCH_HI, 256)

            for b in range(256):
                got = lo_buf[b] | (hi_buf[b] << 8)
                expected = a * b
                if got != expected:
                    mismatches += 1
                    if len(first_failures) < 5:
                        first_failures.append((a, b, got, expected))

            if (a + 1) % 32 == 0:
                print(f"  a={a+1:3d}/256  mismatches so far: {mismatches}")

        mgr.release(inst)

    print()
    print("=" * 60)
    print(f"  {mismatches} mismatches out of 65536")
    print("=" * 60)

    if mismatches:
        print("\nFirst failing cases (a, b, got, expected):")
        for a, b, got, expected in first_failures:
            print(f"  a={a:3d} b={b:3d}  got=0x{got:04X} ({got})  "
                  f"expected=0x{expected:04X} ({expected})")
        sys.exit(1)

    sys.exit(0)


if __name__ == "__main__":
    main()
