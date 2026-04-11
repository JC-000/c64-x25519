"""pytest conftest for tools/ test suite.

The tests in this directory were originally written to be run as standalone
scripts via ``python tools/test_*.py``; they drive VICE via the
``c64-test-harness`` package. Several of them happen to define bare
``def test_*(transport, labels, ...)`` helpers that pytest's auto-discovery
would otherwise try to collect as test functions — but there are no
corresponding pytest fixtures, so collection fails.

This conftest provides two things:

1. ``transport`` and ``labels`` fixtures that raise a skip if VICE is not
   available. They are session-scoped so pytest can reuse a single VICE
   instance if we ever fully migrate the suite.

2. A ``collect_ignore_glob`` list that tells pytest to skip the test scripts
   whose ``test_*`` helpers are meant to be called from ``main()`` rather
   than collected as pytest test functions. These are still runnable via
   ``python tools/test_X.py`` and via the Makefile ``test`` target.

Per project memory (``feedback_vice_instances.md``) we never spawn or kill
VICE by PID directly — always via ``ViceInstanceManager``.
"""

from __future__ import annotations

import os

import pytest


# These scripts contain ``def test_*`` helpers that are positional-arg
# wrappers (not pytest tests), and ``main()`` that drives VICE. Collecting
# them under pytest would misinterpret the helpers as tests. They remain
# runnable as standalone scripts from the Makefile ``test`` / ``test-slow``
# targets.
collect_ignore_glob = [
    "test_fe25519.py",
    "test_opt_vic_reduce38.py",
    "test_fe_mul_stress.py",
    "test_fe_sqr_stress.py",
    "test_opt_fast_mul.py",
    "test_opt_karatsuba.py",
    "test_opt_sqr.py",
    "test_x25519.py",
    "test_ladder_checkpoint.py",
    "test_mul38_tables.py",
    "test_clamp_then_v2.py",
    "test_reproduce_failure.py",
    "test_state_leak.py",
    "test_vector2_debug.py",
]


def _vice_available() -> bool:
    """Best-effort check for a runnable VICE + built .prg.

    We never probe VICE processes directly (memory: feedback_no_direct_vice);
    this just checks that the build artifacts exist. If they are missing the
    fixture will skip rather than attempt to launch anything.
    """
    project_root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    prg = os.path.join(project_root, "build", "x25519.prg")
    labels_path = os.path.join(project_root, "build", "labels.txt")
    return os.path.isfile(prg) and os.path.isfile(labels_path)


@pytest.fixture(scope="session")
def labels():
    """Load assembly labels from the build artifact.

    Skipped if the build output is missing — pytest should not trigger
    ``make`` itself. Run ``make`` first, then ``pytest tools/``.
    """
    if not _vice_available():
        pytest.skip("build/x25519.prg or build/labels.txt missing — run 'make' first")
    try:
        from c64_test_harness import Labels
    except ImportError:
        pytest.skip("c64_test_harness not installed")
    project_root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    return Labels.from_file(os.path.join(project_root, "build", "labels.txt"))


@pytest.fixture(scope="session")
def transport():
    """Session-scoped VICE transport.

    The full VICE-dependent test scripts are excluded from pytest collection
    via ``collect_ignore_glob`` above; this fixture exists so that any future
    pytest-native test can request a transport without reimplementing the
    boilerplate. It always uses ``ViceInstanceManager`` — never raw
    subprocess — per project memory.
    """
    if not _vice_available():
        pytest.skip("build/x25519.prg or build/labels.txt missing — run 'make' first")
    try:
        from c64_test_harness import (
            ViceConfig, ViceInstanceManager, wait_for_text, write_bytes,
        )
    except ImportError:
        pytest.skip("c64_test_harness not installed")

    project_root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    prg = os.path.join(project_root, "build", "x25519.prg")

    config = ViceConfig(prg_path=prg, warp=True, ntsc=True, sound=False,
                        extra_args=["-reu", "-reusize", "512"])
    mgr = ViceInstanceManager(config=config)
    mgr.__enter__()
    try:
        inst = mgr.acquire()
        t = inst.transport
        if wait_for_text(t, "Q=QUIT", timeout=60.0, verbose=False) is None:
            pytest.skip("VICE main menu did not appear within 60s")
        # Safety trampoline: JMP $0339 at $0339 so stray returns loop harmlessly.
        write_bytes(t, 0x0339, bytes([0x4C, 0x39, 0x03]))
        yield t
        mgr.release(inst)
    finally:
        mgr.__exit__(None, None, None)
