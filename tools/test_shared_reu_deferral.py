#!/usr/bin/env python3
"""test_shared_reu_deferral.py - runtime test of a §8.2 deferral build (#159).

Builds build-defer/x25519.prg (`make test-defer-prg`): every x25519 TU
assembled with -D SHARED_REU_MUL_INIT -D SHARED_REU_MUL_FETCH at the
default SQR_DMA_K, linked with tests/deferral/reu_mul_provider.s as the
§8.2 provider. The PRG boots sqtab_init -> provider reu_mul_tables_init ->
x25519_sqr_tables_init, the sequence a deferring consumer uses.

Checks, in VICE with a 512 KB REU:
  * x25519_reu_fault is 0 after boot;
  * fe25519_mul(a, a) and fe25519_sqr(a) against Python integers. mul reads
    only the provider's pair (base, base+1); sqr also reads x25519's private
    doubled/carry banks (base+3..+5). The failure message says which one is
    wrong, so "sqr wrong, mul right" names the private banks;
  * (not --quick) the RFC 7748 §5.2 vectors through x25519_scalarmult,
    against pyca/cryptography and the published outputs.

The PRG is always rebuilt through make first, so this never grades a
stale artifact.

Usage:
    python3 tools/test_shared_reu_deferral.py [--quick] [--seed S]
"""

import os
import random
import subprocess
import sys

from c64_test_harness import (
    Labels, ViceConfig, ViceInstanceManager,
    read_bytes, write_bytes, jsr, wait_for_text,
)

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ref_x25519  # noqa: E402  (pyca/cryptography-backed oracle)

PROJECT_ROOT = os.path.normpath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
DEFER_DIR = os.path.join(PROJECT_ROOT, "build-defer")
PRG_PATH = os.path.join(DEFER_DIR, "x25519.prg")
LABELS_PATH = os.path.join(DEFER_DIR, "labels.txt")

P = (1 << 255) - 19


def write_fe(t, addr, val):
    write_bytes(t, addr, (val % P).to_bytes(32, "little"))


def read_fe(t, addr):
    return int.from_bytes(read_bytes(t, addr, 32), "little")


def set_ptr(t, labels, name, addr):
    write_bytes(t, labels[name], bytes([addr & 0xFF, addr >> 8]))


def c64_mul(t, labels, a, b):
    write_fe(t, labels["fe25519_tmp1"], a)
    write_fe(t, labels["fe25519_tmp2"], b)
    set_ptr(t, labels, "fe25519_src1", labels["fe25519_tmp1"])
    set_ptr(t, labels, "fe25519_src2", labels["fe25519_tmp2"])
    set_ptr(t, labels, "fe25519_dst", labels["fe25519_tmp3"])
    jsr(t, labels["fe25519_mul"], timeout=120.0)
    jsr(t, labels["fe25519_reduce_final"], timeout=5.0)
    return read_fe(t, labels["fe25519_tmp3"])


def c64_sqr(t, labels, a):
    write_fe(t, labels["fe25519_tmp1"], a)
    set_ptr(t, labels, "fe25519_src1", labels["fe25519_tmp1"])
    set_ptr(t, labels, "fe25519_dst", labels["fe25519_tmp3"])
    jsr(t, labels["fe25519_sqr"], timeout=120.0)
    jsr(t, labels["fe25519_reduce_final"], timeout=5.0)
    return read_fe(t, labels["fe25519_tmp3"])


def sqr_cases(rng, n_random):
    cases = [("one", 1), ("two", 2), ("P-1", P - 1),
             ("all-0xFF", int.from_bytes(b"\xff" * 32, "little") % P),
             ("all-0x80", int.from_bytes(b"\x80" * 32, "little") % P),
             ("0xFF@byte0", 0xFF), ("0xFF@byte31", 0xFF << 248)]
    cases += [(f"random#{i:02d}", rng.randint(0, P - 1)) for i in range(n_random)]
    return cases


def main():
    quick = "--quick" in sys.argv
    seed = random.randint(0, 2**32 - 1)
    if "--seed" in sys.argv:
        seed = int(sys.argv[sys.argv.index("--seed") + 1])
    print(f"Random seed: {seed} (reproduce with --seed {seed})")
    rng = random.Random(seed)

    print("=== building build-defer/x25519.prg (make test-defer-prg) ===")
    subprocess.run(["make", "-s", "test-defer-prg"], cwd=PROJECT_ROOT,
                   check=True, stdout=subprocess.DEVNULL)
    labels = Labels.from_file(LABELS_PATH)
    for need in ("x25519_sqr_tables_init", "reu_mul_tables_init"):
        if labels.get(need) is None:
            print(f"FAIL: {need} not in {LABELS_PATH}; not a deferral build")
            sys.exit(1)

    config = ViceConfig(prg_path=PRG_PATH, warp=True, ntsc=True, sound=False,
                        extra_args=["-reu", "-reusize", "512"])
    failures = []
    with ViceInstanceManager(config=config) as mgr:
        inst = mgr.acquire()
        t = inst.transport
        if wait_for_text(t, "Q=QUIT", timeout=120.0, verbose=False) is None:
            print("FATAL: deferral PRG did not reach its ready prompt")
            sys.exit(1)
        write_bytes(t, 0x0339, bytes([0x4C, 0x39, 0x03]))

        fault = read_bytes(t, labels["x25519_reu_fault"], 1)[0]
        if fault != 0:
            failures.append(f"x25519_reu_fault = ${fault:02X} after boot")

        cases = sqr_cases(rng, 4 if quick else 16)
        print(f"--- fe25519_mul(a,a) / fe25519_sqr(a): {len(cases)} cases ---")
        for name, a in cases:
            exp = a * a % P
            m = c64_mul(t, labels, a, a)
            s = c64_sqr(t, labels, a)
            if m == exp and s == exp:
                print(f"  OK   {name}")
                continue
            if m == exp:
                why = ("fe25519_sqr WRONG, fe25519_mul right: the private "
                       "doubled/carry banks (base+3..+5) do not hold "
                       "2*a*b -- x25519_sqr_tables_init did not build them")
            elif s == exp:
                why = "fe25519_mul WRONG, fe25519_sqr right: provider pair (base, base+1)"
            else:
                why = "fe25519_mul AND fe25519_sqr WRONG"
            print(f"  FAIL {name}: {why}")
            print(f"       a   = 0x{a:064x}\n       exp = 0x{exp:064x}\n"
                  f"       mul = 0x{m:064x}\n       sqr = 0x{s:064x}")
            failures.append(f"{name}: {why}")

        if not quick:
            print("--- RFC 7748 §5.2 vectors via x25519_scalarmult vs pyca ---")
            for v in ref_x25519.RFC7748_VECTORS:
                oracle = ref_x25519.x25519_scalarmult(v["scalar"], v["u"])
                assert oracle == v["out"], "pyca disagrees with RFC 7748"
                write_bytes(t, labels["x25_scalar"], bytes.fromhex(v["scalar"]))
                jsr(t, labels["x25519_clamp"], timeout=5.0)
                write_bytes(t, labels["x25_u"], bytes.fromhex(v["u"]))
                jsr(t, labels["x25519_scalarmult"], timeout=7200.0)
                got = read_bytes(t, labels["x25_result"], 32).hex()
                if got == oracle:
                    print(f"  OK   {v['desc']}")
                else:
                    print(f"  FAIL {v['desc']}: got {got}, pyca {oracle}")
                    failures.append(f"{v['desc']}: scalarmult != pyca")

            fault = read_bytes(t, labels["x25519_reu_fault"], 1)[0]
            if fault != 0:
                failures.append(f"x25519_reu_fault = ${fault:02X} after the ladders")
        mgr.release(inst)

    if failures:
        print(f"\nFAIL: §8.2 deferral build (SHARED_REU_MUL_INIT, SQR_DMA_K > 0): "
              f"{len(failures)} failure(s)")
        for f in failures:
            print(f"  - {f}")
        sys.exit(1)
    print("\nOK: §8.2 deferral build computes correct squares"
          + ("" if quick else " and RFC 7748 vectors"))


if __name__ == "__main__":
    main()
