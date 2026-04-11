#!/usr/bin/env python3
import os, sys
from c64_test_harness import (
    Labels, ViceConfig, ViceInstanceManager,
    read_bytes, write_bytes, jsr, wait_for_text,
)

PROJECT_ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
PRG_PATH = os.path.join(PROJECT_ROOT, "build", "x25519.prg")
LABELS_PATH = os.path.join(PROJECT_ROOT, "build", "labels.txt")

def main():
    os.chdir(PROJECT_ROOT)
    labels = Labels.from_file(LABELS_PATH)
    config = ViceConfig(prg_path=PRG_PATH, warp=True, ntsc=True, sound=False,
                        extra_args=["-reu", "-reusize", "512"])

    with ViceInstanceManager(config=config) as mgr:
        inst = mgr.acquire()
        print(f"VICE PID={inst.pid}, port={inst.port}")
        transport = inst.transport
        grid = wait_for_text(transport, "Q=QUIT", timeout=60.0, verbose=False)
        if grid is None:
            print("FATAL: Main menu did not appear")
            sys.exit(1)
        print("VICE ready")

        # Read mul38_lo_tab and mul38_hi_tab from memory using labels
        lo_addr = labels["mul38_lo_tab"]
        hi_addr = labels["mul38_hi_tab"]
        lo_data = read_bytes(transport, lo_addr, 256)
        hi_data = read_bytes(transport, hi_addr, 256)

        passed = failed = 0
        for i in range(256):
            expected_lo = (i * 38) & 0xFF
            expected_hi = (i * 38) >> 8
            if lo_data[i] != expected_lo:
                print(f"FAIL mul38_lo_tab[{i}]: expected {expected_lo:#04x}, got {lo_data[i]:#04x}")
                failed += 1
            elif hi_data[i] != expected_hi:
                print(f"FAIL mul38_hi_tab[{i}]: expected {expected_hi:#04x}, got {hi_data[i]:#04x}")
                failed += 1
            else:
                passed += 1
            assert lo_data[i] == expected_lo, (
                f"mul38_lo_tab[{i}]: expected {expected_lo:#04x}, got {lo_data[i]:#04x}"
            )
            assert hi_data[i] == expected_hi, (
                f"mul38_hi_tab[{i}]: expected {expected_hi:#04x}, got {hi_data[i]:#04x}"
            )

        mgr.release(inst)

    print(f"\nResults: {passed}/256 passed, {failed} failed")
    sys.exit(0 if failed == 0 else 1)

if __name__ == "__main__":
    main()
