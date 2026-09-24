"""vice_build.py — select which build a VICE test runs, and on what REU.

Environment:
  X25519_BUILD_DIR        build tree holding x25519.prg + labels.txt
                          (default "build"; relative to the repo root)
  X25519_REUSIZE          VICE -reusize in KB (default 512)
  C64_NO_REU              launch VICE with no REU at all
  X25519_EXPECT_REU_BANK  if set, the linked labels must report this base
                          bank for BOTH X25519_REU_BANK and the exported
                          LIB_X25519_SHARED_REU_MUL_BANK, else the test
                          exits before VICE starts. This is what stops a
                          relocated-bank run from silently grading a
                          default-bank PRG.

This module never builds anything: the caller (the Makefile) does.
"""

import os
import sys

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))


def build_dir():
    d = os.environ.get("X25519_BUILD_DIR", "build")
    return d if os.path.isabs(d) else os.path.join(PROJECT_ROOT, d)


def prg_path():
    return os.path.join(build_dir(), "x25519.prg")


def labels_path():
    return os.path.join(build_dir(), "labels.txt")


def reu_args():
    if os.environ.get("C64_NO_REU"):
        return ["+reu"]
    return ["-reu", "-reusize", os.environ.get("X25519_REUSIZE", "512")]


def check_expected_bank(labels):
    """Exit non-zero unless the build's bank matches X25519_EXPECT_REU_BANK."""
    want = os.environ.get("X25519_EXPECT_REU_BANK")
    if want is None:
        return
    want = int(want, 0)
    for name in ("X25519_REU_BANK", "LIB_X25519_SHARED_REU_MUL_BANK"):
        got = labels.address(name)
        if got != want:
            print(f"FATAL: {labels_path()}: {name} = {got}, expected {want} "
                  f"(X25519_EXPECT_REU_BANK) - wrong build selected")
            sys.exit(1)
    # Window is base+0..base+5; the REU must hold it or VICE wraps banks.
    need_kb = (want + 6) * 64
    have_kb = int(os.environ.get("X25519_REUSIZE", "512"))
    if have_kb < need_kb:
        print(f"FATAL: X25519_REUSIZE={have_kb} KB cannot hold banks "
              f"{want}..{want + 5} (needs {need_kb} KB)")
        sys.exit(1)
    print(f"Build {build_dir()}: X25519_REU_BANK = "
          f"LIB_X25519_SHARED_REU_MUL_BANK = {want}, REU {have_kb} KB")
