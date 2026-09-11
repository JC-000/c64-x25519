#!/usr/bin/env python3
"""bench_fe_ops.py — Unified benchmark for all fe25519 ops on C64.

Measures fe25519_mul, fe25519_sqr, fe25519_inv, fe25519_add, fe25519_sub,
fe25519_reduce_final, fe25519_cswap, and fe25519_mul_a24.

Uses the CIA1 32-bit cycle counter (bench_cycles_start / bench_cycles_stop,
see src/util.s) for cycle-exact measurement that survives sei. Why CIA1:
PR #39's refactor of the older jiffy-based bench_start / bench_stop pair
removed the matching `cli` at the end of bench_start, leaving the body
running under sei. The kernal jiffy clock at $A0-$A2 is incremented by
the IRQ handler, so it stops ticking while bench_start's body runs and
the old per-op bench reports 0 jif for everything. CIA1 ticks at phi2
directly and is unaffected by the I-flag.

For sub-cycle ops the single-call bench is mostly noise (call overhead
dominates). Real precision comes from the batch path: a small 6502
subroutine calls the target N times back-to-back inside one CIA1
window and divides by N.

fe25519_cswap takes its mask in A on entry. Since the harness's `jsr`
helper does not let us set A before the call, we install a 6-byte
trampoline at $0350 (LDA #mask / JSR fe25519_cswap / RTS) and bench
that trampoline both single-call and batched.

Usage:
    python3 tools/bench_fe_ops.py [--iterations N] [--batch N]
                                  [--json out.json] [--no-blank]

By default the batch thunk wraps the timed region in jsr vic_blank /
jsr vic_unblank so per-op numbers match the "VIC-II blanked" baseline
quoted in the README. Use --no-blank to measure under display-active
conditions instead. --json writes a machine-readable record (consumed
by tools/perf_diff.py and the make bench-record pipeline).
"""

import json
import os
import random
import subprocess
import sys

from c64_test_harness import (
    Labels, ViceConfig, ViceInstanceManager,
    read_bytes, write_bytes, jsr, wait_for_text,
)
from c64_test_harness.memory_policy import MemoryPolicy, MemoryRegion

PROJECT_ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
PRG_PATH = os.path.join(PROJECT_ROOT, "build", "x25519.prg")
LABELS_PATH = os.path.join(PROJECT_ROOT, "build", "labels.txt")

P = (1 << 255) - 19

# NTSC C64 derived constants (matches tools/bench_x25519.py).
NTSC_HZ = 60
NTSC_CYCLES_PER_SEC = 1_022_727
NTSC_CYCLES_PER_JIF = NTSC_CYCLES_PER_SEC / NTSC_HZ   # ≈ 17,045.45

# Scratch subroutine addr for batch-bench thunks (unused cassette buffer region)
BATCH_SUB_ADDR = 0x03B0


def int_to_le32(val):
    return (val % P).to_bytes(32, "little")


def _read_cycles(transport, labels):
    """Read the 4-byte little-endian u32 cycle count from bench_cycles."""
    b = read_bytes(transport, labels["bench_cycles"], 4)
    return b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24)


def _set_ptr(transport, labels, ptr_name, target_name):
    write_bytes(
        transport, labels[ptr_name],
        bytes([labels[target_name] & 0xFF, labels[target_name] >> 8]),
    )


def _prime_mul_operands(transport, labels, a, b):
    write_bytes(transport, labels["fe25519_tmp1"], int_to_le32(a))
    write_bytes(transport, labels["fe25519_tmp2"], int_to_le32(b))
    _set_ptr(transport, labels, "fe25519_src1", "fe25519_tmp1")
    _set_ptr(transport, labels, "fe25519_src2", "fe25519_tmp2")
    _set_ptr(transport, labels, "fe25519_dst",  "fe25519_tmp3")


def _prime_sqr_operand(transport, labels, a):
    write_bytes(transport, labels["fe25519_tmp1"], int_to_le32(a))
    _set_ptr(transport, labels, "fe25519_src1", "fe25519_tmp1")
    _set_ptr(transport, labels, "fe25519_dst",  "fe25519_tmp3")


def _prime_addsub_operands(transport, labels, a, b):
    """fe25519_add / fe25519_sub: src1 + src2 -> dst (32-byte LE ops)."""
    write_bytes(transport, labels["fe25519_tmp1"], int_to_le32(a))
    write_bytes(transport, labels["fe25519_tmp2"], int_to_le32(b))
    _set_ptr(transport, labels, "fe25519_src1", "fe25519_tmp1")
    _set_ptr(transport, labels, "fe25519_src2", "fe25519_tmp2")
    _set_ptr(transport, labels, "fe25519_dst",  "fe25519_tmp3")


def _prime_reduce_final_operand(transport, labels, a):
    """fe25519_reduce_final canonicalizes (fe25519_dst). Stage value at dst."""
    write_bytes(transport, labels["fe25519_tmp3"], int_to_le32(a))
    _set_ptr(transport, labels, "fe25519_dst", "fe25519_tmp3")


def _prime_a24_operand(transport, labels, a):
    """fe25519_mul_a24: dst <- 121665 * src1."""
    write_bytes(transport, labels["fe25519_tmp1"], int_to_le32(a))
    _set_ptr(transport, labels, "fe25519_src1", "fe25519_tmp1")
    _set_ptr(transport, labels, "fe25519_dst",  "fe25519_tmp3")


def _prime_cswap_operands(transport, labels, a, b):
    """fe25519_cswap: swap src1 and src2 if mask in fe_carry == $FF.
       The mask is also passed in A on entry; we set it in the trampoline."""
    write_bytes(transport, labels["fe25519_tmp1"], int_to_le32(a))
    write_bytes(transport, labels["fe25519_tmp2"], int_to_le32(b))
    _set_ptr(transport, labels, "fe25519_src1", "fe25519_tmp1")
    _set_ptr(transport, labels, "fe25519_src2", "fe25519_tmp2")


# -- single-call benches -----------------------------------------------------
#
# All of these go through _bench_single, which builds the SAME thunk the
# batch path builds (n=1). They used to issue three separate jsr() calls:
#     jsr(bench_cycles_start); jsr(target); jsr(bench_cycles_stop)
# and jsr()'s preserve_state=True default reads PC/SP/FL before the call
# and puts them back after, so bench_cycles_start's `sei` was reverted the
# moment that first jsr returned — the measured routine then ran with the
# I flag as the monitor found it, while the batch path at
# _build_batch_thunk() kept the sei. Two paths in one file measuring under
# different interrupt conditions.
#
# The mask is DOCUMENTED to outlive the reconfiguration. src/util.s:129-130,
# the banner over the pair: "Like bench_start/stop, this pair preserves the
# caller's I-flag via bench_cycles_saved_p"; and :134-136 over the proc:
# "Saves caller's P (incl. I flag); leaves IRQs masked while the counter
# runs (matched by bench_cycles_stop's plp)". The php-at-start /
# plp-at-stop pairing across two routines only makes sense if I persists
# between them. The `sei`'s own inline comment at :141 says merely "mask
# IRQs while we reconfigure CIA1", which reads as if the mask were
# scoped to the reconfiguration — it is not, and the banner four lines
# above says so.
#
# So this restores a documented invariant the single-call path silently
# broke; it is not a measurement fix. The measured effect is nil either
# way, because bench_cycles_start also writes $7F to cia1_icr, clearing
# every CIA1 interrupt source, so nothing was firing into the window.
#
# blank=False keeps the display-active condition the single-call spread
# has always been measured under (see _build_batch_thunk's docstring for
# why the batch path blanks and this one does not). The thunk adds its own
# ldx/stx/dec/bne scaffold inside the counted window, so single-call
# numbers move against pre-change runs.
#
# THE DELTA IS +14.5 CYCLES, and the delta is the quantity to trust. Two
# independent A/B runs under VICE on fe25519_mul (2026-09-10, both
# --iterations 2 --batch 5, seeded rng so every run saw the same
# operands):
#
#     run   old three-jsr form   this thunk form   delta
#     A          101,536.0          101,550.5      +14.5
#     B          101,535.5          101,550.0      +14.5
#
# The absolutes jitter by about a cycle between runs; the delta does not.
# The evidence for that is inside run A rather than asserted: at
# --iterations 2 the reported avg is (min+max)/2, and run A's old-form
# spread was min=101,530 max=101,541 — 11 cycles — so a half-cycle shift
# in an average of two samples is well inside its own noise. A third run
# will give a third pair of absolutes and the same delta.
#
# And the delta matches an opcode-level derivation of the scaffold the
# thunk adds inside the counted window (from the second adversarial
# review):
#
#     LDX #imm      2
#     STX abs       4
#     DEC abs       6
#     BNE not-taken 2
#                  --
#                  14 cycles
#
# So the number rests on a mechanism plus two measurements, not on one
# measurement. Nothing else in this file's reported figures was
# re-measured; the cross-check numbers quoted in _build_batch_thunk's
# docstring predate the change and are left as written rather than
# restated from a two-iteration run.


def _bench_single(transport, labels, target, timeout):
    """One measured call through the batch thunk builder with n=1."""
    thunk = _build_batch_thunk(labels, target, 1, blank=False)
    assert_off_harness_scratch(
        (BATCH_SUB_ADDR, len(thunk), "bench_fe_ops single-call thunk"))
    write_bytes(transport, BATCH_SUB_ADDR, thunk)
    jsr(transport, BATCH_SUB_ADDR, timeout=timeout)
    return _read_cycles(transport, labels)


def bench_fe_mul(transport, labels, a, b):
    _prime_mul_operands(transport, labels, a, b)
    return _bench_single(transport, labels, "fe25519_mul", 120.0)


def bench_fe_sqr(transport, labels, a):
    _prime_sqr_operand(transport, labels, a)
    return _bench_single(transport, labels, "fe25519_sqr", 120.0)


def bench_fe_inv(transport, labels, a):
    _prime_sqr_operand(transport, labels, a)
    return _bench_single(transport, labels, "fe25519_inv", 240.0)


def bench_fe_add(transport, labels, a, b):
    _prime_addsub_operands(transport, labels, a, b)
    return _bench_single(transport, labels, "fe25519_add", 30.0)


def bench_fe_sub(transport, labels, a, b):
    _prime_addsub_operands(transport, labels, a, b)
    return _bench_single(transport, labels, "fe25519_sub", 30.0)


def bench_fe_reduce_final(transport, labels, a):
    _prime_reduce_final_operand(transport, labels, a)
    return _bench_single(transport, labels, "fe25519_reduce_final", 30.0)


def bench_fe_mul_a24(transport, labels, a):
    _prime_a24_operand(transport, labels, a)
    return _bench_single(transport, labels, "fe25519_mul_a24", 60.0)


# fe25519_cswap takes its mask in A on entry. The harness's `jsr` helper
# does not let us set A before the call, so we install a 6-byte trampoline:
#     LDA #mask    (2 bytes)
#     JSR cswap    (3 bytes)
#     RTS          (1 byte)
#
# $0340 (used until 2026-09-10) overlaps sid_player.play_sid_vice's song
# trampoline at $033C-$0341 — a NON-transient declared harness span, the
# category assert_off_harness_scratch actually checks. Moved to $0350,
# inside $0342-$035F, which is free of every non-transient entry. Latent,
# like the $0360 case in bench_x25519.py: nothing here calls sid_player.
# The point is that one standard now covers every blob this file installs
# and executes, instead of two of three.
CSWAP_TRAMP_ADDR = 0x0350



def assert_off_harness_scratch(*spans):
    """Fail loudly if a scratch blob we install overlaps a NON-transient
    region the harness declares for itself.

    Same guard as bench_x25519.py and ct_mul_brute_check.py, and it is
    here because the standard has to be one standard: this file installs
    two executable blobs, and until 2026-09-10 one of them sat on
    sid_player.play_sid_vice's song trampoline ($033C-$0341) while the
    other was unchecked.

    Transient entries are excluded (the harness writes prior contents
    back), which is what keeps liveness_probe's $0334-$03B3 and the
    32 KiB $0800-$87FF REU staging window from matching everything.

    SCOPE, stated because it is not derivable from the call: pass every
    span this tool installs CODE into and then EXECUTES through a harness
    facility. The standard is "guard every declared NON-transient span",
    not "guard only what can collide today" — which facilities a tool
    invokes is exactly the kind of fact that changes without anyone
    noticing.

    ONE carve-out, and it is a derived constraint rather than a judgement
    call. The $0339 safety loop (JMP self) is NOT passed, because its
    address is not ours to choose: execute.jsr writes JSR/NOP/NOP at
    scratch_addr $0334-$0338, so $0339 is the first byte PAST that
    trampoline, and a safety loop anywhere else does not catch execution
    that runs off the end of it. sid_player.play_sid_vice parks at
    $0339-$033B for the same reason and by the same derivation — the
    collision is two facilities agreeing on an address the layout
    dictates, not two facilities picking one carelessly. Moving it would
    delete its function, and it is the same three bytes in 32 files here.
    So it is excluded, and the reason is written down where a reader
    meets it.

    Also not passed: the fe25519 buffers and bench_cycles, which live in
    the PRG image rather than in harness scratch.
    """
    regions = tuple(MemoryRegion(start, start + length, note)
                    for start, length, note in spans)
    overlaps = MemoryPolicy(reserved_regions=regions).harness_scratch_overlaps()
    if overlaps:
        detail = "; ".join(
            f"{r} collides with harness scratch {s.span} "
            f"({s.owner}; relocate via {s.configurable})"
            for r, s in overlaps)
        raise SystemExit(f"FATAL: scratch layout collides with the harness: "
                         f"{detail}")


def _build_cswap_trampoline(labels, mask):
    target = labels["fe25519_cswap"]
    code = bytearray()
    code += bytes([0xA9, mask & 0xFF])                  # LDA #mask
    code += bytes([0x20, target & 0xFF, target >> 8])   # JSR fe25519_cswap
    code += bytes([0x60])                               # RTS
    return bytes(code)


def bench_fe_cswap(transport, labels, a, b, mask):
    _prime_cswap_operands(transport, labels, a, b)
    tramp = _build_cswap_trampoline(labels, mask)
    assert_off_harness_scratch(
        (CSWAP_TRAMP_ADDR, len(tramp), "bench_fe_ops cswap trampoline"))
    write_bytes(transport, CSWAP_TRAMP_ADDR, tramp)
    # _build_batch_thunk takes an int target, which is what lets the cswap
    # trampoline go down the same path as the label-named ops.
    return _bench_single(transport, labels, CSWAP_TRAMP_ADDR, 30.0)


# -- batched bench (sub-jiffy precision via amortization) --------------------

def _build_batch_thunk(labels, target, n, blank=True):
    """Emit a 6502 subroutine that calls target N times inside the CIA1
    cycle counter.

    `target` may be a string (label name) or an int (raw address); the
    address form lets us batch-bench the cswap trampoline at $0350.

    With blank=True (the default), the thunk wraps the timed region in
    jsr vic_blank / jsr vic_unblank so that the measurement matches the
    "VIC-II blanked" baseline used by bench_x25519.py and quoted in the
    README. Without blanking, every measured op pays the badline penalty
    (~6.7% more cycles on the NTSC text screen the harness runs — one
    badline per character row, ~40-43 cycles each, against 17030 cycles
    per frame) and the per-op numbers don't compose with the scalarmult
    number for cross-checking. Use --no-blank to measure that delta
    directly: against a default run it comes out at 1.065-1.068x (mean
    1.0665) across all seven ops batch-benched below, which is the
    predicted text-screen band. Issue #103 measured 1.067-1.069x
    independently from the consumer side.

    Note the single-call spread above is NOT wrapped in vic_blank -- only
    this batch thunk is -- so those numbers run display-active and should
    track the --no-blank batch figures, which is a free cross-check on the
    A/B (measured 101,082.7 vs 101,054.8 cy/call for fe25519_mul).

    Layout at BATCH_SUB_ADDR (blank=True):
      jsr vic_blank
      jsr bench_cycles_start     (sei + reconfigure CIA1 TA+TB as down-counter)
      ldx #n ; stx $0200         (loop counter in page 2, BASIC input buf)
    loop:
      jsr target                 (6502 JSR = 3 bytes)
      dec $0200                  (3 bytes)
      bne loop                   (2 bytes; branch offset -8 back to jsr)
      jsr bench_cycles_stop      (atomic stop + snapshot to bench_cycles)
      jsr vic_unblank
      rts

    Per-iteration scaffold overhead (JSR + DEC + BNE) is ~14 cycles, so
    at batch_n=200 the noise floor is ~14 × 200 / batch_n = 14 cycles
    per call after dividing — well below any fe25519_* op cost. The
    bench_cycles range is 2^32 cycles (~4.2 s of C64 time), more than
    enough for batch_n × longest-op (e.g. 200 × ~110k cy fe25519_mul =
    22M cycles, ~200x headroom).
    """
    if not (1 <= n <= 255):
        raise ValueError("n must fit in one byte (1..255)")
    if isinstance(target, str):
        target = labels[target]
    bs = labels["bench_cycles_start"]
    bp = labels["bench_cycles_stop"]
    vb = labels["vic_blank"]
    vu = labels["vic_unblank"]
    code = bytearray()
    if blank:
        code += bytes([0x20, vb & 0xFF, vb >> 8])    # jsr vic_blank
    code += bytes([0x20, bs & 0xFF, bs >> 8])        # jsr bench_cycles_start
    code += bytes([0xA2, n])                          # ldx #n
    code += bytes([0x8E, 0x00, 0x02])                 # stx $0200
    code += bytes([0x20, target & 0xFF, target >> 8]) # jsr target    <- loop top
    code += bytes([0xCE, 0x00, 0x02])                 # dec $0200
    code += bytes([0xD0, 0xF8])                       # bne -8 -> jsr target
    code += bytes([0x20, bp & 0xFF, bp >> 8])         # jsr bench_cycles_stop
    if blank:
        code += bytes([0x20, vu & 0xFF, vu >> 8])    # jsr vic_unblank
    code += bytes([0x60])                             # rts
    return bytes(code)


def bench_batch(transport, labels, target, n, blank=True):
    thunk = _build_batch_thunk(labels, target, n, blank=blank)
    assert_off_harness_scratch(
        (BATCH_SUB_ADDR, len(thunk), "bench_fe_ops batch thunk"))
    write_bytes(transport, BATCH_SUB_ADDR, thunk)
    jsr(transport, BATCH_SUB_ADDR, timeout=300.0)
    return _read_cycles(transport, labels)


# -- main --------------------------------------------------------------------

def main():
    os.chdir(PROJECT_ROOT)

    iterations = 20
    batch_n = 200
    json_path = None       # --json <file>: also emit a machine-readable record
    blank = True           # --no-blank disables vic_blank in the batch thunk
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--iterations" and i + 1 < len(args):
            iterations = int(args[i + 1]); i += 2
        elif args[i] == "--batch" and i + 1 < len(args):
            batch_n = int(args[i + 1]); i += 2
        elif args[i] == "--json" and i + 1 < len(args):
            json_path = args[i + 1]; i += 2
        elif args[i] == "--no-blank":
            blank = False; i += 1
        else:
            i += 1

    rng = random.Random(25519)

    # make clean BEFORE make: ca65 doesn't track CA65FLAGS as a
    # dependency, so re-running this script after a different CA65FLAGS
    # invocation (e.g. the SQR_DMA_K=0 A/B in docs/REU_USAGE_ANALYSIS.md)
    # would otherwise reuse stale .o files and measure the wrong build.
    print("Building...")
    subprocess.run(["make", "clean"], capture_output=True, cwd=PROJECT_ROOT)
    subprocess.run(["make"], capture_output=True, cwd=PROJECT_ROOT)
    if not os.path.exists(PRG_PATH):
        print("Build failed"); sys.exit(1)

    labels = Labels.from_file(LABELS_PATH)

    # C64_NO_REU=1 launches VICE with no REU at all: runtime proof that a
    # no-REU build profile (e.g. X25519_ONCHIP_MUL) never polls $DFxx.
    # The default build reads REU mul tables and needs the REU attached.
    if os.environ.get("C64_NO_REU"):
        reu_args = ["+reu"]
    else:
        reu_args = ["-reu", "-reusize", "512"]
    config = ViceConfig(prg_path=PRG_PATH, warp=True, ntsc=True, sound=False,
                        extra_args=reu_args)

    with ViceInstanceManager(config=config) as mgr:
        inst = mgr.acquire()
        print(f"VICE PID={inst.pid}, port={inst.port}")

        transport = inst.transport
        grid = wait_for_text(transport, "Q=QUIT", timeout=60.0, verbose=False)
        if grid is None:
            print("FATAL: Main menu did not appear"); sys.exit(1)

        # Safety loop at $0339 so errant control flow lands somewhere defined
        write_bytes(transport, 0x0339, bytes([0x4C, 0x39, 0x03]))

        # --- single-call spread (cycle-exact via CIA1; shows the
        #     CT spread across random inputs) ---
        def _summary(label, samples):
            mn, mx = min(samples), max(samples)
            avg = sum(samples) / len(samples)
            jif = avg / NTSC_CYCLES_PER_JIF
            print(f"  cycles: min={mn:,} max={mx:,} avg={avg:,.1f} "
                  f"({jif:.3f} jif/call)")

        print(f"\n--- fe25519_mul single-call ({iterations} iters) ---")
        mul_ticks = []
        for _ in range(iterations):
            mul_ticks.append(bench_fe_mul(
                transport, labels, rng.randint(1, P-1), rng.randint(1, P-1)))
        _summary("mul", mul_ticks)

        print(f"\n--- fe25519_sqr single-call ({iterations} iters) ---")
        sqr_ticks = []
        for _ in range(iterations):
            sqr_ticks.append(bench_fe_sqr(transport, labels, rng.randint(1, P-1)))
        _summary("sqr", sqr_ticks)

        print(f"\n--- fe25519_inv single-call ({iterations} iters) ---")
        inv_ticks = []
        for _ in range(iterations):
            inv_ticks.append(bench_fe_inv(transport, labels, rng.randint(1, P-1)))
        avg_inv_cy = sum(inv_ticks) / len(inv_ticks)
        avg_inv = avg_inv_cy / NTSC_CYCLES_PER_JIF
        _summary("inv", inv_ticks)

        print(f"\n--- fe25519_add single-call ({iterations} iters) ---")
        add_ticks = []
        for _ in range(iterations):
            add_ticks.append(bench_fe_add(
                transport, labels, rng.randint(1, P-1), rng.randint(1, P-1)))
        _summary("add", add_ticks)

        print(f"\n--- fe25519_sub single-call ({iterations} iters) ---")
        sub_ticks = []
        for _ in range(iterations):
            sub_ticks.append(bench_fe_sub(
                transport, labels, rng.randint(1, P-1), rng.randint(1, P-1)))
        _summary("sub", sub_ticks)

        print(f"\n--- fe25519_reduce_final single-call ({iterations} iters) ---")
        rf_ticks = []
        for _ in range(iterations):
            rf_ticks.append(bench_fe_reduce_final(
                transport, labels, rng.randint(1, P-1)))
        _summary("reduce_final", rf_ticks)

        print(f"\n--- fe25519_mul_a24 single-call ({iterations} iters) ---")
        a24_ticks = []
        for _ in range(iterations):
            a24_ticks.append(bench_fe_mul_a24(
                transport, labels, rng.randint(1, P-1)))
        _summary("mul_a24", a24_ticks)

        print(f"\n--- fe25519_cswap single-call ({iterations} iters, alternating mask) ---")
        cs_ticks = []
        for it in range(iterations):
            mask = 0xFF if (it & 1) else 0x00
            cs_ticks.append(bench_fe_cswap(
                transport, labels, rng.randint(1, P-1), rng.randint(1, P-1),
                mask))
        _summary("cswap", cs_ticks)

        # --- batch (sub-jiffy precision for mul/sqr/add/sub/reduce/a24/cswap) ---
        # Prime operands once; batch thunk reuses src1/src2/dst pointers.
        _prime_mul_operands(transport, labels,
                            rng.randint(1, P-1), rng.randint(1, P-1))
        t_mul = bench_batch(transport, labels, "fe25519_mul", batch_n,
                            blank=blank)
        _prime_sqr_operand(transport, labels, rng.randint(1, P-1))
        t_sqr = bench_batch(transport, labels, "fe25519_sqr", batch_n,
                            blank=blank)

        _prime_addsub_operands(transport, labels,
                               rng.randint(1, P-1), rng.randint(1, P-1))
        t_add = bench_batch(transport, labels, "fe25519_add", batch_n,
                            blank=blank)
        _prime_addsub_operands(transport, labels,
                               rng.randint(1, P-1), rng.randint(1, P-1))
        t_sub = bench_batch(transport, labels, "fe25519_sub", batch_n,
                            blank=blank)

        _prime_reduce_final_operand(transport, labels, rng.randint(1, P-1))
        t_rf = bench_batch(transport, labels, "fe25519_reduce_final",
                           batch_n, blank=blank)

        _prime_a24_operand(transport, labels, rng.randint(1, P-1))
        t_a24 = bench_batch(transport, labels, "fe25519_mul_a24", batch_n,
                            blank=blank)

        # cswap: batch the trampoline at $0350 (mask=$FF -> always swap).
        # The trampoline does LDA #$FF / JSR fe25519_cswap / RTS each call.
        _prime_cswap_operands(transport, labels,
                              rng.randint(1, P-1), rng.randint(1, P-1))
        cs_tramp = _build_cswap_trampoline(labels, 0xFF)
        assert_off_harness_scratch(
            (CSWAP_TRAMP_ADDR, len(cs_tramp),
             "bench_fe_ops cswap trampoline (batch)"))
        write_bytes(transport, CSWAP_TRAMP_ADDR, cs_tramp)
        t_cs = bench_batch(transport, labels, CSWAP_TRAMP_ADDR, batch_n,
                           blank=blank)

        # `t_*` are CIA1 cycle counts for `batch_n` back-to-back calls
        # (plus a fixed per-batch scaffold: 2-3 jsr/rts + ldx + stx +
        # bench_cycles_start/stop overhead, totaling well under 200 cy
        # and amortised away by batch_n).
        precise_mul_cy = t_mul / batch_n
        precise_sqr_cy = t_sqr / batch_n
        precise_add_cy = t_add / batch_n
        precise_sub_cy = t_sub / batch_n
        precise_rf_cy  = t_rf  / batch_n
        precise_a24_cy = t_a24 / batch_n
        precise_cs_cy  = t_cs  / batch_n

        def _j(cy):  # cycles -> jif/call for human-readable parity
            return cy / NTSC_CYCLES_PER_JIF

        precise_mul = _j(precise_mul_cy)
        precise_sqr = _j(precise_sqr_cy)
        precise_add = _j(precise_add_cy)
        precise_sub = _j(precise_sub_cy)
        precise_rf  = _j(precise_rf_cy)
        precise_a24 = _j(precise_a24_cy)
        precise_cs  = _j(precise_cs_cy)

        print(f"\n--- batch {batch_n}x (cycle-exact via CIA1) ---")
        print(f"  fe25519_mul:            {t_mul:>11,} cy / {batch_n} "
              f"= {precise_mul_cy:>10,.1f} cy/call  ({precise_mul:.3f} jif)")
        print(f"  fe25519_sqr:            {t_sqr:>11,} cy / {batch_n} "
              f"= {precise_sqr_cy:>10,.1f} cy/call  ({precise_sqr:.3f} jif)")
        print(f"  fe25519_add:            {t_add:>11,} cy / {batch_n} "
              f"= {precise_add_cy:>10,.1f} cy/call  ({precise_add:.3f} jif)")
        print(f"  fe25519_sub:            {t_sub:>11,} cy / {batch_n} "
              f"= {precise_sub_cy:>10,.1f} cy/call  ({precise_sub:.3f} jif)")
        print(f"  fe25519_reduce_final:   {t_rf:>11,} cy / {batch_n} "
              f"= {precise_rf_cy:>10,.1f} cy/call  ({precise_rf:.3f} jif)")
        print(f"  fe25519_mul_a24:        {t_a24:>11,} cy / {batch_n} "
              f"= {precise_a24_cy:>10,.1f} cy/call  ({precise_a24:.3f} jif)")
        print(f"  fe25519_cswap (mask=$FF):{t_cs:>10,} cy / {batch_n} "
              f"= {precise_cs_cy:>10,.1f} cy/call  ({precise_cs:.3f} jif)")

        # --- fe_inv overhead accounting ---
        # fe_inv does 254 sqr + 11 mul via an addition chain for 2^255-21.
        expected_raw = 254 * precise_sqr + 11 * precise_mul
        overhead = avg_inv - expected_raw
        print(f"\n--- fe25519_inv overhead accounting ---")
        print(f"  254 sqr x {precise_sqr:.3f} = {254 * precise_sqr:7.1f} jif")
        print(f"   11 mul x {precise_mul:.3f} = {11 * precise_mul:7.1f} jif")
        print(f"  raw mul+sqr total     = {expected_raw:7.1f} jif")
        print(f"  measured fe25519_inv  = {avg_inv:7.1f} jif")
        print(f"  overhead (inv - raw)  = {overhead:+7.1f} jif")

        # --- JSON sidecar for machine-readable consumption by
        #     tools/perf_diff.py and the docs/perf_history.csv pipeline ---
        if json_path:
            record = {
                "batch_n": batch_n,
                "iterations": iterations,
                "vic_blanked": blank,
                "measurement": "CIA1_cycles",
                # Cycle-exact (raw CIA1 counts / batch_n).
                "fe25519_mul_cy":          precise_mul_cy,
                "fe25519_sqr_cy":          precise_sqr_cy,
                "fe25519_add_cy":          precise_add_cy,
                "fe25519_sub_cy":          precise_sub_cy,
                "fe25519_reduce_final_cy": precise_rf_cy,
                "fe25519_mul_a24_cy":      precise_a24_cy,
                "fe25519_cswap_cy":        precise_cs_cy,
                "fe25519_inv_cy":          avg_inv_cy,
                # Derived jif (cycles / NTSC_CYCLES_PER_JIF) for human-
                # readable parity with the historical README numbers.
                "fe25519_mul_jif":          precise_mul,
                "fe25519_sqr_jif":          precise_sqr,
                "fe25519_add_jif":          precise_add,
                "fe25519_sub_jif":          precise_sub,
                "fe25519_reduce_final_jif": precise_rf,
                "fe25519_mul_a24_jif":      precise_a24,
                "fe25519_cswap_jif":        precise_cs,
                "fe25519_inv_jif":          avg_inv,
                "fe25519_inv_overhead_jif": overhead,
            }
            with open(json_path, "w") as f:
                json.dump(record, f, indent=2, sort_keys=True)
                f.write("\n")
            print(f"\nJSON sidecar written: {json_path}")

        mgr.release(inst)

    print("\nDone.")


if __name__ == "__main__":
    main()
