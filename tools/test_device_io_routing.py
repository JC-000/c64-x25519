#!/usr/bin/env python3
"""test_device_io_routing.py — software-only guard on how the U64 tools
drive the device.

NO DEVICE AND NO EMULATOR ARE TOUCHED. A fake device stands in for the
Ultimate 64: it records every wire request the real
``Ultimate64Client.write_mem`` would issue — that classification code is
the harness's own, called unmodified — and the fake serves reads back
from a modelled 64 KB memory so the tools' own code paths run to
completion against it.

What is checked here:

* the ``check_rows`` scrub loop does not rewrite a buffer it has just
  written, and its coverage per leg has not shrunk;
* device turbo/REU state is restored on the FAILURE path, not only on
  the success path;
* post-reboot readiness is probed and bounded rather than slept through;
* the sentinel wait separates a read that RAISED from a run that never
  finished;
* a lock timeout carries its diagnosis to the operator;
* the single-call bench keeps ``bench_cycles_start``'s documented SEI in
  force over the measured routine;
* scratch blobs do not sit on declared harness scratch;
* the grading PRINTOUT reports the threshold the run will actually use,
  and no tool overrides the harness's own ``/Temp`` hygiene decision;
* the harness property that deletion rests on — re-probe before arming —
  still holds.

Bulk-write chunking is deliberately NOT checked. These tools call
``transport.write_memory``, which is harness API; the harness does not
chunk at that entry point yet, and adopting ``memory.write_bytes``
(hardcoded 84-byte chunks) to work around it would be unwound when the
harness fix lands. Nor is there a front-door refusal to check: the guard
is ``Ultimate64TempHygieneError`` at the harness's request choke point,
and this repo defers to it — see tools/u64_preflight.py, "Why there is
no hygiene handling here at all".

Each check below was driven to FAIL by reverting the defect it guards,
and its failure names the leg, the symbol or the address at fault. What
that perturbation was is RECORDED per check in ``RED_LEGS``; what is
machine-enforced is only that every check has an entry, not that the
entry is true — see the comment above ``RED_LEGS``.

Run:  python3 tools/test_device_io_routing.py
"""

import glob
import importlib
import logging
import os
import sys

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, PROJECT_ROOT)
sys.path.insert(0, os.path.join(PROJECT_ROOT, "tools"))

from c64_test_harness.backends.ultimate64_client import (
    Ultimate64Client, Ultimate64Error)
from c64_test_harness.memory_policy import MemoryPolicy, MemoryRegion


# --------------------------------------------------------------------------
# Red-leg roster
# --------------------------------------------------------------------------

#: What each check's red leg WAS, as recorded by the person who ran it.
#:
#: RECORDED, NOT VERIFIED — and the distinction is the point of this
#: comment. check_every_check_has_a_recorded_red_leg compares the roster's
#: KEYS against the checks main() registers, in both directions, so a
#: check with no entry fails the suite and a stale entry does too. Nothing
#: reads the VALUES. A value of "" or "TODO", or a sentence describing a
#: perturbation that actually reddens some other check, is equally green.
#: The enforced property is coverage: for every registered check, someone
#: once wrote a sentence here. Whether that sentence is true of the check
#: is not machine-checkable and is not claimed to be.
#:
#: Perturbations go in the SOURCE, reproducing the defect class, rather
#: than in the checker. Where an entry below names a FIXTURE or a runtime
#: monkeypatch instead of a source edit, that is the exception being
#: stated rather than hidden — the harness re-probe, because this repo
#: does not write to that checkout; the arming rule, whose input is the
#: fixture's firmware payload; and the roster's own leg, which is deleting
#: an entry. No count of those is given: it would be a hand-maintained
#: number inside the structure built to replace hand-maintained claims,
#: and it would be wrong the first time a check is added.
RED_LEGS = {
    "check_bench_x25519_u64_drives_clean":
        "run_once made to report no completed run",
    "check_reu_scrub_coverage":
        "drop rd_hi from check_rows' scrub set",
    "check_reu_no_duplicate_scrubs":
        "restore the four unconditional 256-byte scrubs",
    "check_reu_restores_state_on_failure":
        "remove restore_state from the finally block",
    "check_reboot_settle_floor":
        "lower the settle floor below the 8.0 s HEAD slept",
    "check_reboot_readiness_probed":
        "readiness back to sleep(8.0) plus a single probe",
    "check_sentinel_wait_reports_poll_error":
        "sentinel wait back to the original hand-rolled deadline loop",
    "check_sentinel_wait_is_actually_called":
        "inline the poll loop in call(), leaving the helper unused beside it",
    "check_issue33_uses_acquire_or_raise":
        "lock back to the bool-returning acquire(timeout=600)",
    "check_bench_fe_ops_single_call_is_one_thunk":
        "any one single-call bench back to three separate jsr() calls",
    "check_reprobe_precedes_arming":
        "Ultimate64Client._maybe_reprobe_capabilities monkeypatched to a "
        "no-op at runtime (the property is the harness's; this repo does "
        "not write to that checkout)",
    "check_harness_hygiene_arms_on_the_leaky_device":
        "fixture serves a self-collecting firmware in place of a leaky one",
    "check_grading_printout_matches_the_threshold_in_use":
        "grading printed from a fresh get_info() instead of "
        "client.capabilities; and the harness guard left unnamed",
    "check_no_front_door_refusal_survives":
        "reinstate a sys.exit refusal in u64_preflight; and bring back "
        "make_client",
    "check_no_tool_forces_temp_hygiene":
        "a tool passes temp_hygiene=True to Ultimate64Client",
    "check_harness_pin_names_a_real_commit":
        "pin left on a squashed (unreachable) commit; pin pointed at a "
        "nonexistent one; pin decayed to prose with no commit",
    "check_all_three_u64_tools_grade":
        "a reboot and a 1000-byte write injected ahead of the grading "
        "printout; and the printout's call site commented out",
    "check_reboot_is_followed_by_readiness_wait":
        "post-reboot readiness call site reverted to sleep(8.0)",
    "check_cited_spans_match_harness_span":
        "one cited harness span reverted to the exclusive-end form",
    "check_every_scratch_install_site_is_guarded":
        "an install site loses its assert_off_harness_scratch call, in the "
        "callable path and in the one inside main()",
    "check_scratch_off_harness_regions":
        "a scratch blob moved back onto a declared harness scratch region",
    "check_speeds_rejects_repeats_at_parse_time":
        "replace the refusal with a silent dedup; sort the parsed list so "
        "order is lost; drop the repeated value from the diagnosis clause; "
        "move parse_args below the device lock, including the comment-only "
        "form that defeated the previous string-search lint; name every "
        "given speed in the diagnosis instead of only the repeated one",
    "check_every_check_has_a_recorded_red_leg":
        "delete any entry from RED_LEGS",
}


def _registered_checks():
    """Names main() passes to check() AS A BARE IDENTIFIER, from the AST.

    Derived rather than listed: a roster compared against a second
    hand-maintained list would only prove the two lists agree.

    BOUND, deliberately and not fixed: only ``check("...", some_name)`` is
    seen. A check registered via a lambda, a ``functools.partial`` or a
    bound method is invisible here, so it would need no roster entry and
    the coverage guarantee would not cover it. Matching arbitrary callables
    in an AST walk buys a fragile checker against a hazard this file does
    not have — every registration below is the bare form. The two plausible
    refactors both fail loudly rather than silently: a module-level table
    of checks, and a helper that wraps check(), each leave zero bare
    identifiers and trip the "no check() registrations found" assertion. It
    is the lambda form alone that would slip through."""
    import ast
    tree = ast.parse(open(os.path.abspath(__file__)).read())
    main_fn = next(n for n in ast.walk(tree)
                   if isinstance(n, ast.FunctionDef) and n.name == "main")
    names = set()
    for node in ast.walk(main_fn):
        if (isinstance(node, ast.Call)
                and getattr(node.func, "id", None) == "check"
                and len(node.args) >= 2
                and isinstance(node.args[1], ast.Name)):
            names.add(node.args[1].id)
    return names


def check_every_check_has_a_recorded_red_leg():
    """The roster and the registered checks are the same set.

    This turns "every check here has a RECORDED red leg" into a checkable
    statement, where "every check here has been driven red" would remain a
    universal quantifier in prose with nothing comparing it to the code —
    the shape that failed repeatedly while this suite was being written.

    It checks COVERAGE, not truth: keys only, both directions. A roster
    value is prose and is never read, so this cannot tell a real
    perturbation from "TODO". Enforcing that would mean running each
    perturbation, which is what a person did once and what no check here
    repeats."""
    registered = _registered_checks()
    assert registered, (
        "no check() registrations found in main(); this check cannot see "
        "what it is meant to compare against")
    missing = sorted(registered - set(RED_LEGS))
    assert not missing, (
        "check(s) registered with no recorded red leg: "
        + ", ".join(missing)
        + ". Drive it red and record the perturbation in RED_LEGS. If you "
          "conclude it cannot be driven red, record THAT as its roster "
          "entry — the argument, in the roster, not in a docstring this "
          "check cannot read. An unfalsifiable check is an assertion, and "
          "the roster is the single place a reader looks to tell which is "
          "which")
    stale = sorted(set(RED_LEGS) - registered)
    assert not stale, (
        "RED_LEGS names check(s) that main() no longer registers: "
        + ", ".join(stale)
        + ". A roster entry for a deleted check is a claim about nothing")


# --------------------------------------------------------------------------
# Fake device
# --------------------------------------------------------------------------

#: The fake client needs SOME threshold because the real
#: Ultimate64Client.write_mem reads it to pick PUT vs POST. Nothing here
#: asserts which form a write takes — that property is no longer enforced
#: (chunking belongs at the harness's request choke point, filed there as
#: their #252). This is a fixture value, not a graded property.
FAKE_WRITE_THRESHOLD = 128


class FakeClient(Ultimate64Client):
    """Real ``write_mem`` (so the PUT/POST split is the harness's own
    code), fake transport underneath.

    ``Ultimate64Client.__init__`` probes the device for its capabilities,
    so it is deliberately not called; the two attributes ``write_mem``
    reads are set directly.
    """

    def __init__(self, dev):
        self.dev = dev
        self.host = "fake"
        self.write_mem_query_threshold = FAKE_WRITE_THRESHOLD

    def _request(self, method, path, *, query=None, body=None,
                 content_type=None, **kw):
        addr = int(query["address"], 16)
        n = len(body) if body is not None else len(query["data"]) // 2
        self.dev.requests.append((method, addr, n))
        data = body if body is not None else bytes.fromhex(query["data"])
        self.dev.mem[addr:addr + len(data)] = data
        self.dev.on_write(addr, data)
        return {}

    # --- device-control surface the tools call; all inert here ---
    def get_info(self):
        return {"product": "Ultimate 64 Elite", "firmware_version": "3.15",
                "fpga_version": "123", "core_version": "1.4E"}

    def reboot(self):
        self.dev.reboots += 1

    def reset(self):
        pass

    def pause(self):
        pass

    def resume(self):
        pass

    def run_prg(self, data):
        self.dev.on_run_prg()

    def close(self):
        pass


class FakeTransport:
    """Mirrors ``Ultimate64Transport.write_memory``'s tail: normalise,
    drop empties, hand the WHOLE payload to ``client.write_mem``. That
    no-chunking behaviour is the thing under test, so it is reproduced
    rather than stubbed away."""

    def __init__(self, dev):
        self.dev = dev
        self.client = dev.client

    def write_memory(self, addr, data, *, override=None):
        if isinstance(data, list):
            data = bytes(data)
        if not data:
            return
        self.client.write_mem(addr, data)

    def read_memory(self, addr, length):
        self.dev.reads += 1
        return bytes(self.dev.mem[addr:addr + length])

    def close(self):
        pass


class FakeDevice:
    def __init__(self):
        self.mem = bytearray(0x10000)
        self.requests = []      # (method, addr, nbytes)
        self.reads = 0
        self.reboots = 0
        self.client = FakeClient(self)
        self.transport = FakeTransport(self)
        self._hooks = []

    def on_write(self, addr, data):
        for h in self._hooks:
            h(addr, data)

    def add_hook(self, fn):
        self._hooks.append(fn)

    def on_run_prg(self):
        pass


def _fmt(pairs, names):
    out = []
    for a, n in pairs:
        out.append(f"${a:04X} ({names.get(a, 'unnamed site')}) {n} B")
    return "; ".join(out)


# --------------------------------------------------------------------------
# Assertion helpers
# --------------------------------------------------------------------------

FAILURES = []


def check(name, fn):
    try:
        fn()
    except AssertionError as e:
        FAILURES.append((name, str(e)))
        print(f"FAIL  {name}\n      {e}")
    except SystemExit as e:
        # assert_off_harness_scratch refuses with SystemExit, which derives
        # from BaseException and therefore escaped the Exception clause
        # below: a real collision aborted the WHOLE run at the first check
        # that tripped it, so every later check silently never ran and the
        # sweep reported "no check failed". Caught explicitly.
        FAILURES.append((name, f"SystemExit: {e}"))
        print(f"FAIL  {name}\n      SystemExit: {e}")
    except Exception as e:      # a check that errors out proves nothing
        FAILURES.append((name, f"{type(e).__name__}: {e}"))
        print(f"ERROR {name}\n      {type(e).__name__}: {e}")
    else:
        print(f"ok    {name}")


# --------------------------------------------------------------------------
# 1 + 3 — bench_x25519_u64: screen clear, shim, trampoline, scalar, sentinel
# --------------------------------------------------------------------------

def _bench_labels():
    return {
        "main_loop": 0x082D, "vic_blank": 0x1000, "bench_cycles_start": 0x1010,
        "x25519_base": 0x1020, "bench_cycles_stop": 0x1030,
        "vic_unblank": 0x1040, "x25_scalar": 0x19A0, "x25_result": 0x19E0,
        "bench_cycles": 0x17DC,
    }


def check_bench_x25519_u64_drives_clean():
    """Smoke test for the bench path: prepare_prg + run_once must run to
    completion against the modelled device.

    NOT a positive control for anything downstream — _drive_bench_x25519_u64
    has exactly one call site, this one, and nothing else consumes its
    result. It earns its place by catching a bench path that stops
    working against the fake at all, which is how the fake gets caught
    drifting from the code it stands in for.

    What it CANNOT catch is drift in READY_SCREEN_CODES itself. The fixture
    paints the modelled screen from m.READY_SCREEN_CODES and prepare_prg
    then searches for m.READY_SCREEN_CODES, so the comparison is defined in
    terms of the value under test and moves with it: setting the constant
    to arbitrary bytes leaves this check green. Not fixed here — hardcoding
    the expected bytes in the fixture trades a tautology for a brittle
    constant that has to be updated whenever the PRG's banner legitimately
    changes. A real banner mismatch shows up on hardware as the ready
    banner never appearing, which prepare_prg reports."""
    dev, names = _drive_bench_x25519_u64()
    assert dev.requests, "no writes recorded — the fake was never driven"


def _drive_bench_x25519_u64():
    """Run prepare_prg + run_once against the fake, return (dev, names)."""
    m = importlib.import_module("bench_x25519_u64")
    labels = _bench_labels()
    dev = FakeDevice()
    names = {
        0x0400: "clear_screen",
        m.SHIM_ADDR: "prepare_prg shim",
        m.TRAMPOLINE_ADDR: "prepare_prg trampoline",
        labels["x25_scalar"]: "prepare_prg scalar",
        labels["x25_result"]: "run_once result scrub",
        m.DONE_SENTINEL_ADDR: "run_once sentinel clear",
        labels["main_loop"] + 1: "run_once hijack",
    }
    expected = bytes(range(32))

    # The PRG's ready banner must be on screen before prepare_prg looks.
    dev.mem[0x0400:0x0400 + len(m.READY_SCREEN_CODES)] = m.READY_SCREEN_CODES

    def hook(addr, data):
        # run_prg re-paints the banner; the host's screen clear wipes it,
        # so put it back the way the booting PRG would.
        if addr <= 0x0400 < addr + len(data):
            dev.mem[0x0400:0x0400 + len(m.READY_SCREEN_CODES)] = \
                m.READY_SCREEN_CODES
        # The hijack write is what starts the trampoline; model the
        # trampoline finishing: result buffer filled, sentinel set.
        if addr == labels["main_loop"] + 1:
            dev.mem[labels["x25_result"]:labels["x25_result"] + 32] = expected
            dev.mem[m.DONE_SENTINEL_ADDR] = m.DONE_SENTINEL_VAL
    dev.add_hook(hook)

    orig_sleep, orig_turbo = m.time.sleep, m.set_turbo_mhz
    m.time.sleep = lambda s: None
    m.set_turbo_mhz = lambda c, mhz: None
    try:
        ok = m.prepare_prg(dev.client, dev.transport, __file__, labels,
                           bytes(32))
        assert ok, "prepare_prg returned False against the fake device"
        r = m.run_once(dev.client, dev.transport, labels, 48, expected, 30.0)
        assert r is not None, "run_once returned None against the fake device"
    finally:
        m.time.sleep, m.set_turbo_mhz = orig_sleep, orig_turbo
    return dev, names


# --------------------------------------------------------------------------
# 1 + 2 + 3 — test_reu_mul_u64: screen clear, trampoline, 256-byte scrubs
# --------------------------------------------------------------------------

def _reu_labels():
    return {
        "main_loop": 0x082D, "reu_mul_init": 0x1100,
        "reu_fetch_mul_row": 0x1120, "x25519_scalarmult": 0x1140,
        "mul_cached_a": 0x1A60, "mul_dma_lo": 0x2300, "mul_dma_hi": 0x2400,
        "x25_scalar": 0x19A0, "x25_u": 0x19C0, "x25_result": 0x19E0,
    }


class ReuFake(FakeDevice):
    """Models enough of the PRG for check_rows to run to completion, and
    records — per trampoline op — which of the four candidate buffers were
    carrying the SCRUB poison when the op fired. That is the scrub-coverage
    evidence: it is read off the modelled device, not off the source."""

    def __init__(self, m, labels):
        super().__init__()
        self.m, self.labels = m, labels
        self.op = None
        self.scrub_coverage = []        # one set per op fired
        self.add_hook(self._hook)

    def _poisoned(self, addr):
        return all(b == self.m.SCRUB
                   for b in self.mem[addr:addr + 256])

    def _hook(self, addr, data):
        m, L = self.m, self.labels
        if addr == m.OP_ADDR:
            self.op = data[0]
        elif addr == L["main_loop"] + 1:
            lo, hi = L["mul_dma_lo"], L["mul_dma_hi"]
            covered = {a for a in (lo, hi, m.SNAP_LO, m.SNAP_HI)
                       if self._poisoned(a)}
            self.scrub_coverage.append((self.op, covered))
            if self.op in (m.OP_FETCH, m.OP_FETCH_SNAP):
                a = self.mem[L["mul_cached_a"]]
                for b in range(256):
                    self.mem[lo + b] = (a * b) & 0xFF
                    self.mem[hi + b] = (a * b) >> 8
                if self.op == m.OP_FETCH_SNAP:
                    self.mem[m.SNAP_LO:m.SNAP_LO + 256] = \
                        self.mem[lo:lo + 256]
                    self.mem[m.SNAP_HI:m.SNAP_HI + 256] = \
                        self.mem[hi:hi + 256]
            self.mem[m.DONE_SENTINEL_ADDR] = m.DONE_SENTINEL_VAL


def _drive_reu_check_rows(rows=(0, 7, 255)):
    m = importlib.import_module("test_reu_mul_u64")
    labels = _reu_labels()
    dev = ReuFake(m, labels)
    names = {
        labels["mul_dma_lo"]: "check_rows scrub mul_dma_lo",
        labels["mul_dma_hi"]: "check_rows scrub mul_dma_hi",
        m.SNAP_LO: "check_rows scrub SNAP_LO",
        m.SNAP_HI: "check_rows scrub SNAP_HI",
        labels["mul_cached_a"]: "check_rows mul_cached_a",
        m.OP_ADDR: "call op byte",
        m.DONE_SENTINEL_ADDR: "call sentinel clear",
        labels["main_loop"] + 1: "call hijack",
    }
    orig = m.time.sleep
    m.time.sleep = lambda s: None
    try:
        checked, mism, bad, samples = m.check_rows(dev.transport, labels,
                                                   list(rows))
    finally:
        m.time.sleep = orig
    assert mism == {"host": 0, "cpu": 0}, (
        f"the modelled device returned wrong products ({mism}) — the "
        f"positive control does not pass, so a green negative proves "
        f"nothing (samples: {samples[:3]})")
    return m, dev, names


def check_reu_scrub_coverage():
    """Item 2's coverage half: dedup must not shrink what gets scrubbed.

    The 'cpu' leg reads back SNAP_LO/SNAP_HI, which are genuinely
    different addresses from the DMA target, so all four buffers must
    carry poison when OP_FETCH_SNAP fires. The 'host' leg reads back the
    DMA target itself, so two suffice."""
    m, dev, names = _drive_reu_check_rows(rows=(7,))
    lo, hi = _reu_labels()["mul_dma_lo"], _reu_labels()["mul_dma_hi"]
    by_op = dict(dev.scrub_coverage)
    assert m.OP_FETCH in by_op and m.OP_FETCH_SNAP in by_op, (
        f"expected both fetch legs to fire; saw ops {sorted(by_op)}")
    want_host = {lo, hi}
    want_cpu = {lo, hi, m.SNAP_LO, m.SNAP_HI}
    got_host, got_cpu = by_op[m.OP_FETCH], by_op[m.OP_FETCH_SNAP]
    missing_host = want_host - got_host
    missing_cpu = want_cpu - got_cpu
    assert not missing_host, (
        "'host' leg fired with un-poisoned read-back buffer(s): "
        + ", ".join(f"${a:04X} ({names.get(a, '?')})"
                    for a in sorted(missing_host)))
    assert not missing_cpu, (
        "'cpu' leg fired with un-poisoned read-back buffer(s): "
        + ", ".join(f"${a:04X} ({names.get(a, '?')})"
                    for a in sorted(missing_cpu))
        + " — SNAP_LO/SNAP_HI are distinct addresses from the DMA target "
          "and dropping their scrub would let a stale correct-looking row "
          "pass as a fresh one")


def check_reu_no_duplicate_scrubs():
    """Item 2's waste half: on the 'host' leg rd_lo/rd_hi ALIAS
    mul_dma_lo/mul_dma_hi, so the old four unconditional 256-byte writes
    scrubbed the same two pages twice — 128 of 512 writes per run were
    exact duplicates of the write immediately before them."""
    m, dev, names = _drive_reu_check_rows(rows=(7,))
    lo, hi = _reu_labels()["mul_dma_lo"], _reu_labels()["mul_dma_hi"]
    bufs = {lo: "mul_dma_lo", hi: "mul_dma_hi",
            m.SNAP_LO: "SNAP_LO", m.SNAP_HI: "SNAP_HI"}
    # Split the request log at each op-byte write: one segment per leg.
    segs, cur = [], []
    for meth, addr, n in dev.requests:
        if addr == m.OP_ADDR:
            segs.append(cur)
            cur = []
        else:
            cur.append((addr, n))
    segs.append(cur)

    def scrub_bytes(seg):
        """Bytes written into each 256-byte buffer span. Counted by span
        rather than by exact base address, so the check does not depend on
        whether a write arrives as one request or several."""
        tally = {b: 0 for b in bufs}
        for addr, n in seg:
            for b in bufs:
                if b <= addr < b + 256:
                    tally[b] += n
        return tally

    scrub_segs = [s for s in segs if any(scrub_bytes(s).values())]
    assert len(scrub_segs) == 2, (
        f"expected one scrub segment per leg, got {len(scrub_segs)}")
    host, cpu = scrub_bytes(scrub_segs[0]), scrub_bytes(scrub_segs[1])
    over_host = {bufs[b]: n for b, n in host.items() if n > 256}
    assert not over_host, (
        f"'host' leg wrote more than one 256-byte poison fill into "
        f"{over_host} — rd_lo/rd_hi alias mul_dma_lo/mul_dma_hi on this "
        f"leg, so the extra fill is an exact duplicate of the write "
        f"immediately before it")
    assert sum(host.values()) == 512, (
        f"'host' leg scrubbed {sum(host.values())} bytes; expected 512 "
        f"(mul_dma_lo + mul_dma_hi, once each). Per-buffer: "
        + ", ".join(f"{bufs[b]}={n}" for b, n in host.items() if n))
    over_cpu = {bufs[b]: n for b, n in cpu.items() if n > 256}
    assert not over_cpu, (
        f"'cpu' leg wrote more than one poison fill into {over_cpu}")
    assert sum(cpu.values()) == 1024, (
        f"'cpu' leg scrubbed {sum(cpu.values())} bytes; expected 1024 "
        f"(mul_dma_lo/hi plus the genuinely distinct SNAP_LO/SNAP_HI). "
        f"Per-buffer: "
        + ", ".join(f"{bufs[b]}={n}" for b, n in cpu.items() if n))


# --------------------------------------------------------------------------
# 4 — device state is restored on the FAILURE path
# --------------------------------------------------------------------------

def check_reu_restores_state_on_failure():
    """Every sys.exit(1) in main() sits inside the try; the old code only
    lowered turbo on the success path, so a failure exit left the device
    turbo'd. Drive main() to a failure exit and assert restore_state ran
    with the snapshot taken before the first mutation."""
    m = importlib.import_module("test_reu_mul_u64")
    dev = FakeDevice()
    calls = {"snap": None, "restored": []}
    sentinel = object()

    saved = {k: getattr(m, k) for k in
             ("DeviceLock", "probe_u64", "Ultimate64Transport",
              "Ultimate64Client", "print_grading",
              "snapshot_state", "restore_state", "set_reu", "set_turbo_mhz",
              "load_prg", "build_prg")}
    saved_sleep = m.time.sleep
    saved_argv = sys.argv[:]

    class L:
        def __init__(self, host):
            pass

        def acquire_or_raise(self, timeout):
            pass

        def release(self):
            pass

    class P:
        reachable = True

    def snap(client):
        calls["snap"] = sentinel
        return sentinel

    def restore(client, s):
        calls["restored"].append(s)

    m.DeviceLock = L
    m.probe_u64 = lambda *a, **k: P()
    m.Ultimate64Transport = lambda **kw: dev.transport
    # Without these two the real client is constructed against host
    # "fake" and the check dies on a DNS failure instead of exercising
    # the failure path it is named for.
    m.Ultimate64Client = lambda **kw: dev.client
    m.print_grading = lambda client, *, what: None
    m.snapshot_state = snap
    m.restore_state = restore
    m.set_reu = lambda *a, **k: None
    m.set_turbo_mhz = lambda *a, **k: None
    # The failure this models: the PRG never reaches its ready banner.
    m.load_prg = lambda *a, **k: False
    m.build_prg = lambda: None
    m.time.sleep = lambda s: None
    sys.argv = ["test_reu_mul_u64.py"]
    # Saved and restored, not popped: an operator with U64_HOST already
    # exported would have had it deleted by running the suite.
    saved_env = {k: os.environ.get(k) for k in ("U64_HOST", "C64_SKIP_BUILD")}
    os.environ["U64_HOST"] = "fake"
    os.environ["C64_SKIP_BUILD"] = "1"
    try:
        try:
            m.main()
        except SystemExit as e:
            code = e.code
        else:
            code = None
    finally:
        for k, v in saved.items():
            setattr(m, k, v)
        m.time.sleep = saved_sleep
        sys.argv = saved_argv
        for _k, _v in saved_env.items():
            if _v is None:
                os.environ.pop(_k, None)
            else:
                os.environ[_k] = _v

    assert code == 1, (
        f"expected the load_prg failure to exit 1, got {code!r} — the "
        f"failure path under test was not reached")
    assert calls["snap"] is sentinel, "snapshot_state was never called"
    assert calls["restored"] == [sentinel], (
        f"restore_state was NOT called with the pre-mutation snapshot on "
        f"the failure exit (calls: {calls['restored']!r}) — the device is "
        f"left turbo'd for the next lane")


# --------------------------------------------------------------------------
# 5 — reboot readiness is probed, not slept through
# --------------------------------------------------------------------------

def check_reboot_readiness_probed():
    """UNIT half: the probe retries until reachable, and gives up.

    This does NOT establish that anything calls it — that is
    check_reboot_is_followed_by_readiness_wait, and this check stayed
    green through a revert of the only real call site before that one
    existed. Patched on u64_preflight, where the function now lives:
    patching the tool modules stopped intercepting when it moved, and the
    real probe_u64 then went to the network."""
    pf = importlib.import_module("u64_preflight")
    tries = {"n": 0}

    class P:
        def __init__(self, ok):
            self.reachable = ok

    def probe(*a, **k):
        tries["n"] += 1
        return P(tries["n"] >= 3)

    saved_probe, saved_sleep = pf.probe_u64, pf.time.sleep
    pf.probe_u64 = probe
    pf.time.sleep = lambda s: None
    try:
        got = pf.wait_device_ready("fake", timeout=90.0, poll=0.0)
        assert got is not None and got.reachable, (
            "wait_device_ready gave up while the device was still coming "
            "back")
        assert tries["n"] == 3, (
            f"wait_device_ready probed {tries['n']} time(s); expected it "
            f"to retry until reachable")
        tries["n"] = 0
        pf.probe_u64 = lambda *a, **k: P(False)
        clock = {"t": 0.0}
        saved_mono = pf.time.monotonic
        pf.time.monotonic = lambda: clock["t"]
        pf.time.sleep = lambda s: clock.__setitem__("t", clock["t"] + 2.0)
        try:
            assert pf.wait_device_ready("fake", timeout=10.0) is None, (
                "wait_device_ready did not give up on a device that never "
                "returned")
        finally:
            pf.time.monotonic = saved_mono
    finally:
        pf.probe_u64, pf.time.sleep = saved_probe, saved_sleep


class RaisingTransport(FakeTransport):
    def read_memory(self, addr, length):
        raise ConnectionResetError("connection reset by peer")


def check_reboot_settle_floor():
    """wait_device_ready SETTLES before it probes, at the floor HEAD slept.

    probe_u64 is ping -> TCP -> GET /v1/version, so it observes the
    firmware's REST API. machine:reboot resets the C64, not the firmware,
    so the probe can answer in ~100 ms with the C64 still in reset and
    the caller then drives a machine that is not there.

    The threshold is the LITERAL 8.0, not m.REBOOT_SETTLE_FLOOR. Asserting
    the observed value against the module's own constant compares the
    module to itself: lowering the constant moves both sides and the
    check stays green, which is exactly what it must not do when its
    stated property is "what HEAD slept unconditionally".
    """
    HEAD_SLEPT = 8.0        # tools/*.py at HEAD: time.sleep(8.0) after reboot()
    pf = importlib.import_module("u64_preflight")
    events = []
    saved_sleep, saved_probe = pf.time.sleep, pf.probe_u64

    class P:
        reachable = True

    pf.time.sleep = lambda s: events.append(("sleep", s))
    pf.probe_u64 = lambda *a, **k: (events.append(("probe", None)), P())[1]
    try:
        pf.wait_device_ready("fake")
    finally:
        pf.time.sleep, pf.probe_u64 = saved_sleep, saved_probe

    assert events, "wait_device_ready did nothing at all"
    assert events[0][0] == "sleep", (
        f"wait_device_ready probed before settling (first event "
        f"{events[0][0]!r}). machine:reboot resets the C64, not the "
        f"firmware serving REST, so a probe can return reachable with the "
        f"machine still in reset. Events: {events}")
    assert events[0][1] >= HEAD_SLEPT, (
        f"wait_device_ready settled {events[0][1]}s, below the {HEAD_SLEPT}s "
        f"HEAD slept unconditionally. Going under it is a regression "
        f"against the behaviour this replaced. Events: {events}")
    assert pf.REBOOT_SETTLE_FLOOR >= HEAD_SLEPT, (
        f"REBOOT_SETTLE_FLOOR is {pf.REBOOT_SETTLE_FLOOR}, below the "
        f"{HEAD_SLEPT}s HEAD slept")
    assert any(e[0] == "probe" for e in events), (
        "wait_device_ready settled but never probed, so it has no upper "
        "bound — that is the bare sleep it replaced")

    # ONE definition, not two: the body and floor used to be duplicated
    # verbatim in both tools with nothing asserting the copies agreed, so
    # a check looping over both modules would pass on two different floors.
    import importlib as _il
    for modname in ("bench_x25519_u64", "test_reu_mul_u64"):
        m = _il.import_module(modname)
        assert m.wait_device_ready is pf.wait_device_ready, (
            f"{modname} has its own wait_device_ready rather than the "
            f"shared one; two copies can drift and nothing compares them")


def check_sentinel_wait_reports_poll_error():
    """The hand-rolled deadline loops these replaced had no except: a
    transport raising mid-poll propagated out and killed the run
    mid-measurement, with the tool's own diagnosis never printed.
    watch_progress yields PollError and keeps polling. Assert the reason
    survives to the caller, AND that a live-but-never-finishing device is
    still a plain TIMEOUT.

    Deliberately NOT asserted, because it is not true: an EMPTY read that
    does not raise still runs the wall budget out under watch_progress,
    exactly as it did under `if data and data[0] == VAL`."""
    for modname in ("test_reu_mul_u64", "bench_x25519_u64"):
        m = importlib.import_module(modname)
        assert hasattr(m, "wait_sentinel"), (
            f"{modname} has no wait_sentinel — the sentinel poll is still "
            f"hand-rolled against a time.monotonic() deadline")
        dev = FakeDevice()
        tr = RaisingTransport(dev)
        saved = m.time.sleep
        m.time.sleep = lambda s: None
        quiet = logging.getLogger("c64_test_harness.progress")
        quiet.setLevel(logging.ERROR)
        try:
            ok, why = m.wait_sentinel(tr, 0.2, 0.01)
        except Exception as e:
            raise AssertionError(
                f"{modname}.wait_sentinel let {type(e).__name__} propagate "
                f"out of the poll loop instead of reporting it. A "
                f"hand-rolled deadline loop has no except, so the first "
                f"transport hiccup kills the run mid-measurement; "
                f"watch_progress yields PollError and keeps polling"
            ) from None
        finally:
            m.time.sleep = saved
            quiet.setLevel(logging.NOTSET)
        assert not ok, f"{modname}.wait_sentinel claimed success on a dead " \
                       f"transport"
        assert "POLL ERROR" in why and "ConnectionResetError" in why, (
            f"{modname}.wait_sentinel reported {why!r} for a transport that "
            f"RAISED on every read; a dead transport must not be reported "
            f"as a plain timeout")

        # ... and a live-but-never-finishing device is still a timeout.
        dev2 = FakeDevice()
        saved = m.time.sleep
        m.time.sleep = lambda s: None
        try:
            ok2, why2 = m.wait_sentinel(dev2.transport, 0.2, 0.01)
        finally:
            m.time.sleep = saved
        assert not ok2 and why2 == "TIMEOUT", (
            f"{modname}.wait_sentinel reported {why2!r} for a device that "
            f"simply never set the sentinel; expected TIMEOUT")


def check_sentinel_wait_is_actually_called():
    """Same class as the readiness check: driving wait_sentinel as a unit
    says nothing about whether anything CALLS it.

    hasattr + a direct call would stay green if call() / run_once() went
    back to inlining a deadline loop while the helper sat unused beside
    them. So drive the real call path and record."""
    called = {"reu": 0, "bench": 0}

    reu = importlib.import_module("test_reu_mul_u64")
    real = reu.wait_sentinel

    def rec_reu(*a, **k):
        called["reu"] += 1
        return real(*a, **k)
    reu.wait_sentinel = rec_reu
    try:
        _drive_reu_check_rows(rows=(7,))
    finally:
        reu.wait_sentinel = real
    assert called["reu"], (
        "test_reu_mul_u64.call() completed a trampoline op without going "
        "through wait_sentinel — the sentinel poll is inlined again, and "
        "the helper beside it is dead code")

    bench = importlib.import_module("bench_x25519_u64")
    real_b = bench.wait_sentinel

    def rec_bench(*a, **k):
        called["bench"] += 1
        return real_b(*a, **k)
    bench.wait_sentinel = rec_bench
    try:
        _drive_bench_x25519_u64()
    finally:
        bench.wait_sentinel = real_b
    assert called["bench"], (
        "bench_x25519_u64.run_once() completed a measured run without "
        "going through wait_sentinel")


# --------------------------------------------------------------------------
# 7 — the lock failure carries diagnosis
# --------------------------------------------------------------------------

def check_issue33_uses_acquire_or_raise():
    """`lock.acquire(timeout=600)` returns a bare bool: no holder_pid, no
    pid_alive, no lockfile age, no device reachability. Drive main() into
    a lock timeout and assert the DeviceLockTimeout detail reaches the
    operator."""
    m = importlib.import_module("test_issue33_adversarial")
    from c64_test_harness.backends.device_lock import DeviceLockTimeout

    exc = DeviceLockTimeout(
        device_host="fake", holder_pid=4242, pid_alive=True,
        lockfile_age_seconds=903.0, device_reachable_rest=True,
        timeout=120.0)

    class L:
        def __init__(self, host):
            self.acquired = False

        def acquire(self, timeout=None):        # the OLD API
            raise AssertionError(
                "main() called the bool-returning lock.acquire(); "
                "acquire_or_raise is what carries holder_pid / pid_alive / "
                "lockfile_age_seconds / device_reachable_rest")

        def acquire_or_raise(self, timeout):
            assert timeout <= 120.0, (
                f"lock ceiling is {timeout}s; DeviceLock heartbeats already "
                f"extend a waiter behind a LIVE holder, so a longer hard "
                f"timeout only lengthens the wait behind a WEDGED one")
            raise exc

        def release(self):
            pass

    out = []
    saved_lock, saved_print = m.DeviceLock, print
    saved_argv = sys.argv[:]
    m.DeviceLock = L
    sys.argv = ["test_issue33_adversarial.py", "--target", "u64"]
    import builtins
    builtins.print = lambda *a, **k: out.append(" ".join(str(x) for x in a))
    try:
        rc = m.main()
    finally:
        builtins.print = saved_print
        m.DeviceLock = saved_lock
        sys.argv = saved_argv

    assert rc == 2, f"expected rc 2 on lock failure, got {rc!r}"
    text = "\n".join(out)
    assert "4242" in text and "903" in text, (
        "the lock-timeout diagnosis did not reach the operator; printed:\n"
        + text)


# --------------------------------------------------------------------------
# 8 — the single-call bench keeps bench_cycles_start's SEI in force
# --------------------------------------------------------------------------

def check_bench_fe_ops_single_call_is_one_thunk():
    """jsr()'s preserve_state=True default reads PC/SP/FL before the call
    and puts them back after. The old form

        jsr(bench_cycles_start); jsr(target); jsr(bench_cycles_stop)

    therefore reverted bench_cycles_start's `sei` the moment the first
    jsr returned, and the measured routine ran with the I flag as the
    monitor found it — while the batch path in the same file kept the
    sei. Assert the whole measurement is now ONE host-visible jsr into a
    thunk, so no FL restore can land between start and target.

    Not asserted here: that the I flag is actually set on the 6502 at the
    instant the routine runs. That needs an emulator and a 6502-side
    read of the flag; see the report."""
    m = importlib.import_module("bench_fe_ops")
    labels = {
        "bench_cycles_start": 0x1010, "bench_cycles_stop": 0x1030,
        "vic_blank": 0x1000, "vic_unblank": 0x1040,
        "fe25519_mul": 0x2000, "fe25519_tmp1": 0x1800, "fe25519_tmp2": 0x1820,
        "fe25519_tmp3": 0x1840, "fe25519_src1": 0x30, "fe25519_src2": 0x32,
        "fe25519_dst": 0x34, "bench_cycles": 0x17DC,
    }
    labels.update({
        "fe25519_sqr": 0x2010, "fe25519_inv": 0x2020, "fe25519_add": 0x2030,
        "fe25519_sub": 0x2040, "fe25519_reduce_final": 0x2050,
        "fe25519_mul_a24": 0x2060, "fe25519_cswap": 0x2070,
        "vic_blank": 0x1000, "vic_unblank": 0x1040,
    })
    # ALL EIGHT single-call benches, not just fe25519_mul: each was a
    # separate three-jsr site and any one of them could be reverted on its
    # own while a fe25519_mul-only check stayed green.
    calls = [
        ("bench_fe_mul", lambda: m.bench_fe_mul(None, labels, 3, 5),
         "fe25519_mul"),
        ("bench_fe_sqr", lambda: m.bench_fe_sqr(None, labels, 3),
         "fe25519_sqr"),
        ("bench_fe_inv", lambda: m.bench_fe_inv(None, labels, 3),
         "fe25519_inv"),
        ("bench_fe_add", lambda: m.bench_fe_add(None, labels, 3, 5),
         "fe25519_add"),
        ("bench_fe_sub", lambda: m.bench_fe_sub(None, labels, 3, 5),
         "fe25519_sub"),
        ("bench_fe_reduce_final",
         lambda: m.bench_fe_reduce_final(None, labels, 3),
         "fe25519_reduce_final"),
        ("bench_fe_mul_a24", lambda: m.bench_fe_mul_a24(None, labels, 3),
         "fe25519_mul_a24"),
        ("bench_fe_cswap",
         lambda: m.bench_fe_cswap(None, labels, 3, 5, 0xFF),
         None),   # target is the cswap trampoline address, not a label
    ]
    for fname, invoke, target_label in calls:
        blobs, jsrs = {}, []
        saved_w, saved_j, saved_r = m.write_bytes, m.jsr, m.read_bytes
        m.write_bytes = lambda tr, addr, data: blobs.__setitem__(
            addr, bytes(data))
        m.jsr = lambda tr, addr, timeout=5.0, **kw: jsrs.append((addr, kw))
        m.read_bytes = lambda tr, addr, n: bytes(n)
        try:
            invoke()
        finally:
            m.write_bytes, m.jsr, m.read_bytes = saved_w, saved_j, saved_r
        _assert_one_thunk(m, fname, labels, jsrs, blobs,
                          target_label and labels[target_label]
                          or m.CSWAP_TRAMP_ADDR)


def _assert_one_thunk(m, fname, labels, jsrs, blobs, target_addr):

    assert len(jsrs) == 1, (
        f"{fname} issued {len(jsrs)} host jsr() calls at "
        + ", ".join(f"${a:04X}" for a, _ in jsrs)
        + f"; expected exactly 1 (the thunk at ${m.BATCH_SUB_ADDR:04X}). "
        f"Each extra jsr() restores FL on return, so a "
        f"jsr(bench_cycles_start) of its own undoes the SEI that "
        f"src/util.s:129-130 documents as persisting to "
        f"bench_cycles_stop's plp")
    assert jsrs[0][0] == m.BATCH_SUB_ADDR, (
        f"{fname}'s single measured jsr went to ${jsrs[0][0]:04X}, not "
        f"the thunk at ${m.BATCH_SUB_ADDR:04X}")
    blob = blobs.get(m.BATCH_SUB_ADDR)
    assert blob, (f"{fname} wrote nothing to the thunk address "
                  f"${m.BATCH_SUB_ADDR:04X}")

    order = [blob[i + 1] | (blob[i + 2] << 8)
             for i in range(len(blob) - 2) if blob[i] == 0x20]
    assert order[:1] == [labels["bench_cycles_start"]], (
        f"{fname}: the thunk's first JSR is ${order[0]:04X}, not "
        f"bench_cycles_start (${labels['bench_cycles_start']:04X}) — the "
        f"SEI must be inside the measured window, not outside it")
    assert target_addr in order, (
        f"{fname}: the measured routine ${target_addr:04X} is not called "
        f"from the thunk at all; JSR targets present: "
        + ", ".join(f"${a:04X}" for a in order))
    assert order.index(target_addr) < order.index(
        labels["bench_cycles_stop"]), (
        f"{fname}: the measured routine is called AFTER bench_cycles_stop")
    assert labels["vic_blank"] not in order, (
        f"{fname}: the single-call thunk blanks the VIC; the single-call "
        f"spread has always been measured display-active (blank=False)")


# --------------------------------------------------------------------------
# /Temp hygiene: the guard is the harness's; ours is visibility + arming
# --------------------------------------------------------------------------

LEAKY_INFO = {"product": "C64 Ultimate", "firmware_version": "1.1.0"}
SAFE_INFO = {"product": "Ultimate 64 Elite", "firmware_version": "3.15"}
UNREADABLE_INFO = {"product": "Ultimate 64 Elite", "firmware_version": None}


class _ProbeClient(Ultimate64Client):
    """Real Ultimate64Client with only the NETWORK CALL stubbed.

    Subclassed rather than mocked so temp_hygiene_armed, capabilities and
    write_mem_query_threshold stay the harness's own logic over our
    fixture bytes. The arming rule is exactly what this change relies on
    instead of reimplementing, so a restatement of it here would grade
    the restatement."""

    #: Either a payload, or a LIST of payloads served one per probe so a
    #: construct-time failure can be followed by a successful re-probe.
    #: A ``None`` entry models a probe that did not answer.
    probe_payload = None

    def get_info(self):
        # `get_info`, NOT `_probe_info`. Stubbing _probe_info replaces the
        # harness's own bookkeeping — it is where `_probe_attempted` and
        # `_probing` are set, and the re-probe path refuses to run without
        # `_probe_attempted`. A fixture that stubs it therefore CANNOT
        # reach the re-probe, and a check that thought it was exercising
        # the ordering would have been exercising nothing. It also has to
        # match `_probe_info(timeout=self.timeout)` at
        # ultimate64_client.py:481 or TypeError the moment that path runs.
        # Stubbing the network call one layer down avoids both: everything
        # above it is the harness's real code.
        self.probe_calls += 1
        payload = type(self).probe_payload
        if isinstance(payload, list):
            i = min(self.probe_calls - 1, len(payload) - 1)
            payload = payload[i]
        if payload is None:
            # What a probe that did not answer looks like from here; the
            # real _probe_info catches it and grades unknown.
            raise Ultimate64Error("fixture: probe did not answer")
        return payload


def _client_for(payload, **kw):
    class C(_ProbeClient):
        probe_payload = payload
    c = C.__new__(C)
    c.probe_calls = 0
    C.__init__(c, host="fake", warn_unlocked=False, **kw)
    return c


def check_reprobe_precedes_arming():
    """THE load-bearing assumption of the whole deletion.

    make_client was deleted because ``_before_temp_attachment`` calls
    ``_maybe_reprobe_capabilities()`` and only THEN consults
    ``temp_hygiene_armed`` — so a client whose construct-time probe
    failed does not stay disarmed for life; it re-probes on evidence and
    arms itself. The arming RULE (check below) is not that property:
    neutering the re-probe entirely leaves the rule intact and every
    other check green, which is exactly what happened when the third
    reviewer tried it.

    So this drives the ORDERING: construct-probe returns nothing ->
    DISARMED; one successful request as evidence -> the next
    attachment-creating request re-probes and arms."""
    client = _client_for([None, LEAKY_INFO])
    assert client.probe_calls == 1, (
        f"expected one construct-time probe, saw {client.probe_calls}")
    assert not client.temp_hygiene_armed, (
        "a client whose construct-time probe returned nothing is already "
        "armed, so this check cannot observe the re-probe arming it")

    # `_saw_successful_request` is the flag Ultimate64Client._request sets
    # on any completed response. Setting it stands in for that request
    # rather than reimplementing the request path — the property under
    # test is what happens AFTER evidence exists, not how evidence is
    # recorded.
    client._saw_successful_request = True
    client._before_temp_attachment("POST /v1/machine:writemem")

    assert client.probe_calls == 2, (
        f"the first attachment-creating request did not re-probe "
        f"({client.probe_calls} probe call(s) total). Without the "
        f"re-probe a slow-probed C64U stays disarmed for the client's "
        f"life, and deleting make_client's forcing was wrong")
    assert client.temp_hygiene_armed, (
        "the re-probe ran but the client is still disarmed. The deletion "
        "rests on it arming itself here; if it does not, this repo has no "
        "hygiene handling and neither does the layer below")


def check_harness_hygiene_arms_on_the_leaky_device():
    """The arming RULE, on clients whose grade is already readable.

    Narrower than it used to claim: this says nothing about the ordering
    that the deletion actually rests on — see
    check_reprobe_precedes_arming, which is the one that would say so."""
    leaky = _client_for(LEAKY_INFO)
    assert leaky.temp_hygiene_armed, (
        "Ultimate64Client does NOT arm /Temp hygiene for a C64 Ultimate "
        "at 1.1.0 — the exact device this repo deleted its own refusal "
        "for. Either the harness changed or the deletion was wrong")
    safe = _client_for(SAFE_INFO)
    assert not safe.temp_hygiene_armed, (
        "hygiene armed on a U64E 3.15, which collects its own "
        "attachments; a GC pass over FTP every budget writes is pure cost "
        "there")
    assert Ultimate64Client._creates_temp_attachment("POST", b"x" * 256), (
        "POST-with-body is not counted as attachment-creating, so the "
        "256-byte scrub writes in test_reu_mul_u64 would not be budgeted")
    assert not Ultimate64Client._creates_temp_attachment("PUT", None), (
        "the PUT-with-hex path is being counted; it creates nothing")


def check_grading_printout_matches_the_threshold_in_use():
    """The printed threshold must be the one every write in the run
    actually uses.

    The client pins write_mem_query_threshold from its CONSTRUCT-TIME
    probe. Printing from a fresh get_info() could show a different number
    than the writes use — the divergence this printout exists to prevent
    rather than create."""
    import builtins
    pf = importlib.import_module("u64_preflight")
    for payload, label in ((SAFE_INFO, "safe"), (LEAKY_INFO, "leaky"),
                           (UNREADABLE_INFO, "unreadable")):
        client = _client_for(payload)
        out = []
        saved_print = builtins.print
        builtins.print = lambda *a, **k: out.append(
            " ".join(str(x) for x in a))
        try:
            pf.print_grading(client, what="fake_tool")
        finally:
            builtins.print = saved_print
        text = "\n".join(out)
        assert f"threshold {client.write_mem_query_threshold} B" in text, (
            f"[{label}] the printed threshold is not the client's own "
            f"({client.write_mem_query_threshold} B), so it does not "
            f"describe the writes this run will make. Printed:\n{text}")
        assert f"product={payload['product']!r}" in text, (
            f"[{label}] the device's raw product is not printed beside "
            f"the grading. Printed:\n{text}")
        assert f"firmware_version={payload['firmware_version']!r}" in text, (
            f"[{label}] the raw firmware_version is not printed. "
            f"Printed:\n{text}")
        assert "Ultimate64TempHygieneError" in text, (
            f"[{label}] the printout does not name the harness facility "
            f"that IS the guard, so a reader may take this visibility "
            f"line for one. Printed:\n{text}")


def check_no_front_door_refusal_survives():
    """The refusal axis and both override variables are gone.

    A code path that outlives its requirement is worse than none: two
    guards for one hazard is what the re-scope removed."""
    pf = importlib.import_module("u64_preflight")
    for gone in ("_env_set", "_validate_overrides", "UnrecognisedOverride",
                 "ALLOW_LEAKY_ENV", "ALLOW_UNGRADED_ENV", "grade_device",
                 "GRADE_ATTEMPTS", "_ungraded", "_unread", "_why_not_safe",
                 "_effect_verb",
                 # make_client went too: once its residue branch became
                 # redundant at harness eb245a9 it was a bare constructor
                 # wrapper, i.e. a layer existing to be mocked.
                 "make_client", "Ultimate64Client", "auto_gc_override"):
        assert not hasattr(pf, gone), (
            f"u64_preflight.{gone} survived the re-scope; the front-door "
            f"refusal duplicates Ultimate64TempHygieneError one layer down")
    src = open(os.path.join(PROJECT_ROOT, "tools",
                            "u64_preflight.py")).read()
    assert "sys.exit" not in src, (
        "u64_preflight still exits; it is visibility, not a boundary")
    for tool in ("bench_x25519_u64", "test_reu_mul_u64",
                 "test_issue33_adversarial"):
        t = open(os.path.join(PROJECT_ROOT, "tools", tool + ".py")).read()
        assert "X25519_ALLOW_LEAKY_WRITEMEM" not in t, (
            f"{tool} still references the deleted override variable")
        assert "X25519_PROCEED_WITHOUT_GRADING" not in t, (
            f"{tool} still references the deleted override variable")


def check_no_tool_forces_temp_hygiene():
    """No tool overrides the harness's own arming decision.

    Observed from the CONSTRUCTOR CALL, not grepped: the driver records
    the kwargs each tool passes to Ultimate64Client. A tool that passes
    temp_hygiene=True pins arming past the re-probe that would have
    settled it — so a U64E 3.15 which collects its own attachments gets
    FTP GC passes for the client's life, because we told it to. That is
    the defect the make_client deletion removed, and putting it back one
    call site over would be invisible to every other check here."""
    for modname in ("bench_x25519_u64", "test_reu_mul_u64",
                    "test_issue33_adversarial"):
        _, kwargs = _drive_main_recording_order(modname)
        assert kwargs, (
            f"{modname}.main() constructed no Ultimate64Client under the "
            f"driver, so this check examined nothing")
        for kw in kwargs:
            assert "temp_hygiene" not in kw, (
                f"{modname} passes temp_hygiene={kw['temp_hygiene']!r} to "
                f"Ultimate64Client. The harness re-probes before arming "
                f"(60615b5) and decides correctly on its own; forcing "
                f"pins that decision and cannot be undone by "
                f"U64_AUTO_TEMP_GC, which the operator owns. kwargs: {kw}")
            assert "write_mem_query_threshold" not in kw, (
                f"{modname} passes write_mem_query_threshold to "
                f"Ultimate64Client, which documents that construction "
                f"issues no HTTP — no capability probe, so /Temp hygiene "
                f"DISARMED for the client's life. kwargs: {kw}")


def check_harness_pin_names_a_real_commit():
    """The pin in u64_preflight names a harness commit, and that commit
    exists.

    The dependency moved three times in the session this was written, and
    a pin that decays to "verified against the harness" is how the next
    reader inherits the failure the pin exists to prevent.

    STALENESS IS A NOTICE, NOT A GATE: whether HEAD has moved past the
    pin is the sibling repo's business, not a reason to fail this repo's
    suite. Only an absent or non-existent pin fails."""
    import re
    import subprocess
    src = open(os.path.join(PROJECT_ROOT, "tools",
                            "u64_preflight.py")).read()
    m = re.search(r"Verified against c64-test-harness ``([0-9a-f]{7,40})``",
                  src)
    assert m, (
        "u64_preflight carries no 'Verified against c64-test-harness "
        "<commit>' pin. Its behaviour is reasoned from harness internals "
        "that moved repeatedly in a single afternoon; an unpinned claim "
        "about them is a dated record with no date")
    pinned = m.group(1)

    import c64_test_harness
    repo = os.path.dirname(os.path.dirname(os.path.dirname(
        os.path.abspath(c64_test_harness.__file__))))
    if not os.path.isdir(os.path.join(repo, ".git")):
        print(f"    (harness at {repo} is not a git checkout; pin "
              f"{pinned} not resolvable here)")
        return
    # merge-base --is-ancestor, not cat-file -e: cat-file succeeds on an
    # object that is present but UNREACHABLE, which is what a squashed PR
    # leaves behind. Such a pin passes today and starts failing after a
    # gc, with a message blaming the wrong thing. Reachability is the
    # property a pin needs.
    r = subprocess.run(["git", "merge-base", "--is-ancestor", pinned, "HEAD"],
                       cwd=repo, capture_output=True)
    present = subprocess.run(["git", "cat-file", "-e", pinned + "^{commit}"],
                             cwd=repo, capture_output=True).returncode == 0
    assert r.returncode == 0, (
        f"the pin names harness commit {pinned}, which is not an ancestor "
        f"of HEAD in {repo}"
        + (" — the object is still present but UNREACHABLE, which is what "
           "a squash-merged PR leaves behind. It resolves today and stops "
           "resolving after a gc. Re-pin to a reachable commit."
           if present else
           " and does not exist there at all. A pin that cannot be "
           "resolved is worse than none: it reads as verified."))
    head = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=repo,
                          capture_output=True, text=True).stdout.strip()
    if head and not head.startswith(pinned[:len(head)]):
        moved = subprocess.run(
            ["git", "log", "--oneline", f"{pinned}..HEAD", "--",
             "src/c64_test_harness/backends/ultimate64_client.py"],
            cwd=repo, capture_output=True, text=True).stdout.strip()
        print(f"    NOTE: harness HEAD is {head}, pin is {pinned}."
              + (f" {len(moved.splitlines())} commit(s) since, touching "
                 f"ultimate64_client.py — re-verify before relying on the "
                 f"hygiene reasoning." if moved else
                 " Nothing since touching ultimate64_client.py."))


class RecordingDevice(FakeDevice):
    """FakeDevice whose every device-facing call appends to a shared order
    list.

    Without this the driver saw only the calls it patched at module level,
    so a reboot and a 1000-byte write injected BEFORE the preflight were
    invisible and the ordering check stayed green while claiming to gate
    "the first device call after /v1/info"."""

    def __init__(self, order):
        self.order = order
        super().__init__()
        client, transport, order_ = self.client, self.transport, order

        def rec(name, fn):
            def wrapper(*a, **k):
                order_.append(name)
                return fn(*a, **k)
            return wrapper

        for name in ("reboot", "run_prg", "reset", "pause", "resume",
                     "get_info"):
            setattr(client, name, rec(name, getattr(client, name)))
        for name in ("write_memory", "read_memory"):
            setattr(transport, name, rec(name, getattr(transport, name)))


#: Calls that are the tool asking the device for its identity. The
#: grading printout must come after these and before everything else.
_IDENTITY_CALLS = frozenset({"get_info"})


def _drive_main_recording_order(modname, stop_at="snapshot"):
    """Drive a tool's real main(), recording the ORDER of every device
    call it makes.

    A source grep for a call site passes on a call site that is commented
    out or unreachable, which is how an earlier version of this check
    stayed green; this runs main().

    ``stop_at="snapshot"`` halts at snapshot_state, early enough to grade
    the printout's position. ``stop_at=None`` lets main() run to its own
    exit, which reaches the reboot / readiness sequence.
    """
    m = importlib.import_module(modname)
    order = []
    client_kwargs = []
    dev = RecordingDevice(order)
    stop = RuntimeError("stop")

    class L:
        def __init__(self, host):
            pass

        def acquire_or_raise(self, timeout):
            pass

        def acquire(self, timeout=None):
            return True

        def release(self):
            pass

    class P:
        reachable = True

    saved = {}

    def patch(name, value):
        if hasattr(m, name):
            saved[name] = getattr(m, name)
            setattr(m, name, value)

    def snap(c):
        order.append("snapshot")
        if stop_at == "snapshot":
            raise stop
        return object()

    patch("DeviceLock", L)
    patch("probe_u64", lambda *a, **k: P())
    patch("Ultimate64Transport", lambda **kw: dev.transport)
    # The tools construct Ultimate64Client directly again, so patching it
    # on the TOOL module intercepts. There is no wrapper to patch: a
    # wrapper whose only remaining purpose was to be the thing tests
    # patch is a layer that exists to be mocked.
    def make(**kw):
        client_kwargs.append(kw)
        return dev.client
    patch("Ultimate64Client", make)
    patch("print_grading", lambda client, *, what: order.append("grade"))
    patch("set_reu", lambda *a, **k: order.append("set_reu"))
    patch("set_turbo_mhz", lambda *a, **k: order.append("set_turbo_mhz"))
    patch("snapshot_state", snap)
    patch("restore_state", lambda c, s: None)
    patch("build_prg", lambda: None)
    patch("build_prgs", lambda: None)
    if hasattr(m, "wait_device_ready"):
        def ready(host, **kw):
            order.append("wait_device_ready")
            return P()
        patch("wait_device_ready", ready)
    patch("load_prg", lambda *a, **k: False)
    patch("prepare_prg", lambda *a, **k: False)
    prg = os.path.join(PROJECT_ROOT, "build", "x25519.prg")
    lbl = os.path.join(PROJECT_ROOT, "build", "labels.txt")
    for name, value in (("DEFAULT_PRG", prg), ("ONCHIP_PRG", prg),
                        ("DEFAULT_LABELS", lbl), ("ONCHIP_LABELS", lbl),
                        ("PRG_PATH", prg), ("LABELS_PATH", lbl)):
        patch(name, value)
    saved_sleep = m.time.sleep
    saved_argv = sys.argv[:]
    m.time.sleep = lambda s: None
    sys.argv = [modname + ".py"] + (
        ["--target", "u64"] if modname == "test_issue33_adversarial" else [])
    # Saved and restored, not popped: an operator with U64_HOST already
    # exported would have had it deleted by running the suite.
    saved_env = {k: os.environ.get(k) for k in ("U64_HOST", "C64_SKIP_BUILD")}
    os.environ["U64_HOST"] = "fake"
    os.environ["C64_SKIP_BUILD"] = "1"
    try:
        try:
            m.main()
        except (SystemExit, RuntimeError):
            pass
    finally:
        for k, v in saved.items():
            setattr(m, k, v)
        m.time.sleep = saved_sleep
        sys.argv = saved_argv
        for _k, _v in saved_env.items():
            if _v is None:
                os.environ.pop(_k, None)
            else:
                os.environ[_k] = _v
    return order, client_kwargs


def check_all_three_u64_tools_grade():
    """Every tool prints its grading before it touches the device for
    anything but its identity.

    This is an ORDERING property of a VISIBILITY line, not a gate — the
    guard is Ultimate64TempHygieneError one layer down. It still matters:
    a grading printed after the run has already rebooted and written is a
    grading the operator reads too late to act on.

    Driven through each tool's real main() with EVERY device call
    recorded — reboot, run_prg, write_memory and read_memory included,
    because an earlier version recorded only the functions it patched and
    stayed green with a reboot and a 1000-byte write injected ahead of
    the preflight."""
    for modname in ("bench_x25519_u64", "test_reu_mul_u64",
                    "test_issue33_adversarial"):
        order, _kw = _drive_main_recording_order(modname)
        assert "grade" in order, (
            f"{modname}.main() touched the device without printing its "
            f"grading. Either the printout is missing or it sits "
            f"after the calls below, where the operator reads it too "
            f"late to act on. Recorded order: {order}")
        before = [k for k in order[:order.index("grade")]
                  if k not in _IDENTITY_CALLS]
        assert not before, (
            f"{modname}.main() made {before} before printing its "
            f"grading. The printout must precede everything except "
            f"reading the device's identity. Recorded order: {order}")


def check_reboot_is_followed_by_readiness_wait():
    """F2's property, at the CALL SITE rather than on the helper.

    Checking hasattr(m, 'wait_device_ready') and driving the helper in
    isolation left this green when the only real post-reboot wait was
    reverted to sleep(8.0) — the helper still existed, nothing called it.
    So: drive main() and assert every reboot is followed by the readiness
    wait before any other device call."""
    for modname in ("bench_x25519_u64", "test_reu_mul_u64"):
        order, _kw = _drive_main_recording_order(modname,
                                                stop_at=None)
        assert "reboot" in order, (
            f"{modname}.main() never rebooted under the driver, so this "
            f"check examined nothing. Recorded order: {order}")
        for i, k in enumerate(order):
            if k != "reboot":
                continue
            rest = order[i + 1:]
            assert rest, (
                f"{modname}.main() rebooted and then did nothing; the "
                f"readiness wait is missing. Recorded order: {order}")
            assert rest[0] == "wait_device_ready", (
                f"{modname}.main() called {rest[0]!r} straight after "
                f"reboot instead of waiting for the device to come back. "
                f"machine:reboot resets the C64, so the next call lands on "
                f"a machine that may still be in reset. Recorded order: "
                f"{order}")


# --------------------------------------------------------------------------
# 9 — scratch blobs do not sit on declared harness scratch
# --------------------------------------------------------------------------

def check_every_scratch_install_site_is_guarded():
    """F6's property: every site that INSTALLS a blob calls the guard.

    check_scratch_off_harness_regions derives spans and calls each
    module's guard itself, so it verifies the ADDRESSES are clear and
    says nothing about whether the install sites consult the guard.
    Removing the guard from bench_fe_ops' batch-cswap install left it
    green — the defect F6 named was an unguarded SITE, not a bad address.

    Two halves, because one site is unreachable without VICE:

    * the three callable install paths are DRIVEN with the guard spied;
    * the fourth lives inside main() and is covered by a source scan.
      That half is a lint and is labelled one: it matches text, not
      behaviour."""
    import re
    fe = importlib.import_module("bench_fe_ops")
    labels = {
        "bench_cycles_start": 0x1010, "bench_cycles_stop": 0x1030,
        "vic_blank": 0x1000, "vic_unblank": 0x1040, "fe25519_mul": 0x2000,
        "fe25519_cswap": 0x2100, "fe25519_tmp1": 0x1800,
        "fe25519_tmp2": 0x1820, "fe25519_tmp3": 0x1840,
        "fe25519_src1": 0x30, "fe25519_src2": 0x32, "fe25519_dst": 0x34,
        "bench_cycles": 0x17DC,
    }
    scratch = {fe.BATCH_SUB_ADDR, fe.CSWAP_TRAMP_ADDR}

    for name, invoke in (
            ("_bench_single",
             lambda: fe._bench_single(None, labels, "fe25519_mul", 30.0)),
            ("bench_fe_cswap",
             lambda: fe.bench_fe_cswap(None, labels, 3, 5, 0xFF)),
            ("bench_batch",
             lambda: fe.bench_batch(None, labels, "fe25519_mul", 8))):
        guarded, written = [], []
        sw, sj, sr, sg = (fe.write_bytes, fe.jsr, fe.read_bytes,
                          fe.assert_off_harness_scratch)
        fe.write_bytes = lambda tr, addr, data: written.append(addr)
        fe.jsr = lambda *a, **k: None
        fe.read_bytes = lambda tr, addr, n: bytes(n)
        fe.assert_off_harness_scratch = lambda *spans: guarded.extend(
            sp[0] for sp in spans)
        try:
            invoke()
        finally:
            (fe.write_bytes, fe.jsr, fe.read_bytes,
             fe.assert_off_harness_scratch) = sw, sj, sr, sg
        for addr in written:
            if addr not in scratch:
                continue
            assert addr in guarded, (
                f"bench_fe_ops.{name} installs a blob at ${addr:04X} "
                f"without calling assert_off_harness_scratch for it. The "
                f"file states one standard for every blob it installs and "
                f"executes; an unguarded site is that standard applying "
                f"to some of them. Guarded this call: "
                + (", ".join(f"${a:04X}" for a in guarded) or "nothing"))

    # -- lint half: the install site inside main() --
    src = open(os.path.join(PROJECT_ROOT, "tools", "bench_fe_ops.py")).read()
    lines = src.split("\n")
    for i, line in enumerate(lines):
        m = re.search(r"write_bytes\(\s*transport,\s*(BATCH_SUB_ADDR|"
                      r"CSWAP_TRAMP_ADDR)\b", line)
        if not m:
            continue
        window = "\n".join(lines[max(0, i - 8):i])
        assert "assert_off_harness_scratch" in window, (
            f"bench_fe_ops.py:{i + 1} installs a blob at {m.group(1)} with "
            f"no assert_off_harness_scratch in the preceding 8 lines. "
            f"(Lint half: this matches text, not behaviour — it exists "
            f"because this site sits inside main() and needs VICE to "
            f"reach.)\n    {line.strip()}")


def check_speeds_rejects_repeats_at_parse_time():
    """`--speeds` refuses a repeated clock, by name, before any device.

    The list is bounded only by membership in KNOWN_SPEEDS[product],
    checked in main(), so without a dedup `--speeds 48,48,48,48` is
    accepted and the whole reu_fetch_mul_row loop plus the KAT runs once
    per entry — device traffic multiplied by a typo, for no added
    coverage.

    Refused rather than silently deduped: correcting an operator's
    argument without telling them is the quiet kind of erosion this repo
    has a rule about. Refused at PARSE time, verified by the call order in
    main(): parse_args returns before probe_u64 and before the device lock
    is taken, so a typo costs nothing.

    No maximum length is asserted here, because none should exist: with
    repeats refused, every entry is a distinct member of the product's own
    turbo-step set, which bounds the list without a literal."""
    m = importlib.import_module("test_reu_mul_u64")
    import builtins

    def parse(argv):
        out = []
        saved = builtins.print
        builtins.print = lambda *a, **k: out.append(
            " ".join(str(x) for x in a))
        try:
            return m.parse_args(argv), None, out
        except SystemExit as e:
            return None, e.code, out
        finally:
            builtins.print = saved

    # -- a repeat is refused, and the message names WHICH value --
    for argv, repeated in ((["--speeds", "48,48"], "48"),
                           (["--speeds", "1,48,1"], "1"),
                           (["--speeds", "48,1,48,1"], "48")):
        opts, code, out = parse(argv)
        text = "\n".join(out)
        assert code == 2, (
            f"{argv} was accepted (exit {code!r}); a repeated speed runs "
            f"the whole fetch loop again for no coverage. Printed:\n{text}")
        # Asserted against the DIAGNOSIS clause, not the whole message.
        # The message also echoes the raw argument, and that echo always
        # contains the repeated value — so "is it anywhere in the text"
        # cannot tell "names which value repeated" from "quotes the input
        # back". Same shape as the refusal-block problem earlier in this
        # file: a needle found in a neighbouring sentence.
        clause = text.split("(given")[0]
        assert repeated in clause, (
            f"the refusal for {argv} does not name the repeated value "
            f"{repeated!r} in its diagnosis — it appears only in the echo "
            f"of the argument, which would be there whatever repeated. "
            f"Diagnosis clause was: {clause!r}")

    # -- the discriminating fixture: the repeat is NOT the only value, so
    #    "names which value repeated" and "lists every given speed"
    #    produce different text. In 48,48 and 1,48,1 the repeated value is
    #    a substring of the full list either way, so those legs cannot
    #    tell the two apart — swapping `repeated` for `speeds` in the
    #    message left them green. Whenever an assertion checks that a
    #    message names a specific item, pick an input where naming the
    #    right one and naming all of them differ. --
    opts, code, out = parse(["--speeds", "1,16,48,16"])
    clause = "\n".join(out).split("(given")[0]
    assert code == 2, f"1,16,48,16 was accepted (exit {code!r})"
    assert "16" in clause, (
        f"the diagnosis does not name the repeated value 16: {clause!r}")
    for other in ("48", "1,"):
        assert other not in clause, (
            f"the diagnosis names {other!r}, which was NOT repeated — it is "
            f"listing every given speed rather than the repeat, so it does "
            f"not tell the operator which entry to fix: {clause!r}")

    # -- distinct lists pass, and ORDER survives: 48,1 and 1,48 are
    #    different tests, since the 48 MHz leg exposes the settle hazard --
    for given, want in (("48,1", [48, 1]), ("1,48", [1, 48]),
                        ("1,16,48", [1, 16, 48])):
        opts, code, out = parse(["--speeds", given])
        assert code is None, (
            f"--speeds {given} was refused (exit {code!r}); its entries are "
            f"distinct. Printed:\n" + "\n".join(out))
        assert opts["speeds"] == want, (
            f"--speeds {given} parsed to {opts['speeds']}, not {want}. "
            f"Order is significant and must not be sorted or reordered")

    # -- and the refusal precedes any device work.
    #
    #    Located with ast, NOT by string search. A `needle in line` scan
    #    matched COMMENTS and took the first hit, so moving the real
    #    parse_args call below the lock and adding one comment line
    #    mentioning "opts = parse_args(argv) runs first" satisfied it —
    #    a sentence discussing the order standing in for the order. THIS
    #    delta adds comments discussing parse order to that very file, so
    #    the needle was exactly the text the change introduces.
    #
    #    What this sees: Call nodes inside main()'s body, by callee name.
    #    Exactly one of each is required, so a second call site fails
    #    loudly instead of being silently resolved to the first.
    #    What it does NOT see: a device call inserted above parse_args
    #    under some other name. That remains out of reach.
    import ast
    tree = ast.parse(open(os.path.join(PROJECT_ROOT, "tools",
                                       "test_reu_mul_u64.py")).read())
    main_fn = next(n for n in ast.walk(tree)
                   if isinstance(n, ast.FunctionDef) and n.name == "main")

    def call_lines(pred):
        return [n.lineno for n in ast.walk(main_fn)
                if isinstance(n, ast.Call) and pred(n.func)]

    sites = {
        "parse_args": call_lines(
            lambda f: isinstance(f, ast.Name) and f.id == "parse_args"),
        "probe_u64": call_lines(
            lambda f: isinstance(f, ast.Name) and f.id == "probe_u64"),
        "acquire_or_raise": call_lines(
            lambda f: isinstance(f, ast.Attribute)
            and f.attr == "acquire_or_raise"),
    }
    for name, lines_found in sites.items():
        assert len(lines_found) == 1, (
            f"expected exactly one {name}() call in test_reu_mul_u64.main(), "
            f"found {len(lines_found)} at {lines_found}. With more than one, "
            f"'which comes first' is not a well-formed question and this "
            f"check would have silently graded the first")
    parse_at = sites["parse_args"][0]
    assert parse_at < sites["probe_u64"][0], (
        f"parse_args() is at line {parse_at}, after probe_u64() at "
        f"{sites['probe_u64'][0]}: a --speeds typo now costs a device round "
        f"trip before it is reported")
    assert parse_at < sites["acquire_or_raise"][0], (
        f"parse_args() is at line {parse_at}, after the device lock at "
        f"{sites['acquire_or_raise'][0]}: a --speeds typo now queues behind "
        f"or blocks another lane before it is reported")
    # NOTE: in the shipped order probe_u64 precedes the lock, so the lock
    # assertion cannot fail while the probe assertion passes. The two are
    # not independent in practice; both are kept because either call site
    # could move on its own.


def check_cited_spans_match_harness_span():
    """Any harness region cited in our prose must be spelled the way
    ScratchRegion.span spells it.

    ScratchRegion and MemoryRegion take an EXCLUSIVE end; .span renders
    INCLUSIVELY. So a raw `end` read off the constructor and copied into
    a comment is one byte too high, every time, and it reads as
    authoritative because it came from the harness. Spans in this change
    were wrong that way before anyone noticed, each off by exactly one in
    the same direction.

    No count is given, and the wrong values are deliberately not quoted.
    Quoting them would make this check fail on itself — which is how that
    point got settled — and counting them would be a claim nothing can
    check, since the things counted are absent by design.

    Scanned rather than restated. SCOPE, because this check deliberately
    does not police every span in the repo: it flags a $XXXX-$YYYY whose
    start matches a declared harness region AND whose end equals that
    region's EXCLUSIVE end — i.e. exactly the confusion above. A span at
    the same start with any other end is a different statement (the
    C64 memory map, a free band, a PRG image) and is left alone. Several
    starts carry more than one region ($0334 is jsr and liveness_probe;
    $C000 is three), so any matching region's span is accepted.

    OUT OF REACH BY CONSTRUCTION, so that nothing credits this check with
    more than it does: the regex is uppercase-only and matches
    two-endpoint spans only. A SINGLE-address citation in prose — a
    stale "$0340" after a move, say — is not seen by it at all. Those
    have to be found by reading."""
    import re
    from c64_test_harness.memory_policy import HARNESS_SCRATCH

    by_start = {}
    for sc in HARNESS_SCRATCH:
        by_start.setdefault(sc.start, []).append(sc)

    # Derived, not listed: a hand-maintained roster of filenames leaves a
    # tool added later silently unscanned, and nothing would say so.
    files = sorted(os.path.basename(f) for f in
                   glob.glob(os.path.join(PROJECT_ROOT, "tools", "*.py")))
    assert len(files) > 8, (
        f"the glob found only {len(files)} tools/*.py — it is not "
        f"scanning what it thinks it is")
    bad = []
    for fname in files:
        path = os.path.join(PROJECT_ROOT, "tools", fname)
        text = open(path).read()
        for m in re.finditer(r"\$([0-9A-F]{4})-\$([0-9A-F]{4})", text):
            start = int(m.group(1), 16)
            regions = by_start.get(start)
            if not regions:
                continue          # not a harness region; not ours to police
            cited = m.group(0)
            end = int(m.group(2), 16)
            spans = {sc.span for sc in regions}
            if cited in spans:
                continue
            # Flag ONLY the inclusive/exclusive confusion: a cited end
            # equal to some region's EXCLUSIVE end. Anything else at this
            # start address is a different statement — e.g.
            # "$C000-$CFFF is free 4 KB RAM on the C64" is true of the
            # machine and says nothing about a harness region, and a
            # checker that flagged it would be asserting more than it can
            # tell.
            if end not in {sc.end for sc in regions}:
                continue
            line = text[:m.start()].count("\n") + 1
            bad.append(
                f"{fname}:{line} cites {cited}, whose end ${end:04X} is "
                f"the EXCLUSIVE end of a harness region starting "
                f"${start:04X}; ScratchRegion.span renders it "
                f"{' or '.join(sorted(spans))} "
                f"({regions[0].owner.split(',')[0]})")
    assert not bad, (
        "prose cites a harness span in a form the harness does not use — "
        "almost always an EXCLUSIVE end copied into INCLUSIVE prose, "
        "which is off by one and reads as authoritative:\n  "
        + "\n  ".join(bad))


def check_scratch_off_harness_regions():
    """Every executable blob these tools install must be clear of the
    NON-transient spans the harness declares for itself.

    ONE standard across the enumerated set. Until 2026-09-10 two of the
    three files were guarded and bench_fe_ops was not, while its cswap
    trampoline at $0340 overlapped sid_player.play_sid_vice's song
    trampoline ($033C-$0341) — non-transient, the category the guard
    actually checks.

    Spans are DERIVED by building each blob at its largest configuration,
    not read from a declared length. bench_x25519 used to carry
    `BENCH_SUB_LEN = 19  # (blank=True: 6 JSRs + RTS)` against a blob
    that measures 16 bytes and 5 JSRs.
    """
    labels = {
        "vic_blank": 0x1000, "bench_cycles_start": 0x1010,
        "x25519_base": 0x1020, "bench_cycles_stop": 0x1030,
        "vic_unblank": 0x1040, "fe25519_mul": 0x2000,
        "fe25519_cswap": 0x2100,
    }
    bx = importlib.import_module("bench_x25519")
    ct = importlib.import_module("ct_mul_brute_check")
    fe = importlib.import_module("bench_fe_ops")

    blobs = [
        (bx, "BENCH_SUB_ADDR", bx.BENCH_SUB_ADDR,
         max(len(bx.build_bench_subroutine(labels, blank=b))
             for b in (True, False)), "bench_x25519 bench subroutine"),
        (ct, "KERNEL_ADDR", ct.KERNEL_ADDR,
         max(len(ct.build_kernel(0x2000, 0x30, 0x32, mutate=mut))
             for mut in (False, True)), "ct_mul_brute_check sweep kernel"),
        (fe, "CSWAP_TRAMP_ADDR", fe.CSWAP_TRAMP_ADDR,
         len(fe._build_cswap_trampoline(labels, 0xFF)),
         "bench_fe_ops cswap trampoline"),
        (fe, "BATCH_SUB_ADDR", fe.BATCH_SUB_ADDR,
         max(len(fe._build_batch_thunk(labels, "fe25519_mul", n, blank=b))
             for n in (1, 200) for b in (True, False)),
         "bench_fe_ops batch/single thunk"),
    ]
    for mod, attr, addr, length, note in blobs:
        region = MemoryRegion(addr, addr + length, f"{mod.__name__}.{attr}")
        overlaps = MemoryPolicy(
            reserved_regions=(region,)).harness_scratch_overlaps()
        assert not overlaps, (
            f"{mod.__name__}.{attr} = ${addr:04X}+{length} ({note}) sits "
            f"on harness scratch: " + "; ".join(
                f"{sc.span} ({sc.owner}; relocate via {sc.configurable})"
                for _, sc in overlaps))
        # ...and the tool's own guard, called from its own module, agrees
        mod.assert_off_harness_scratch((addr, length, note))


def main():
    check("bench_x25519_u64: bench path runs against the fake (smoke)",
          check_bench_x25519_u64_drives_clean)
    check("test_reu_mul_u64 check_rows: scrub coverage per leg",
          check_reu_scrub_coverage)
    check("test_reu_mul_u64 check_rows: no duplicate scrub of an aliased "
          "buffer", check_reu_no_duplicate_scrubs)
    check("test_reu_mul_u64: device state restored on a failure exit",
          check_reu_restores_state_on_failure)
    check("wait_device_ready settles BEFORE probing, at the floor",
          check_reboot_settle_floor)
    check("wait_device_ready probes to a bound, gives up (unit)",
          check_reboot_readiness_probed)
    check("sentinel wait separates PollError from Timeout (unit)",
          check_sentinel_wait_reports_poll_error)
    check("the sentinel wait is actually called by call()/run_once()",
          check_sentinel_wait_is_actually_called)
    check("test_issue33_adversarial: lock failure carries diagnosis",
          check_issue33_uses_acquire_or_raise)
    check("all 8 bench_fe_ops single-call benches are one thunk (SEI)",
          check_bench_fe_ops_single_call_is_one_thunk)
    check("harness re-probes BEFORE arming (the deletion's premise)",
          check_reprobe_precedes_arming)
    check("harness arming rule on a readable grade",
          check_harness_hygiene_arms_on_the_leaky_device)
    check("grading printout matches the threshold the run will use",
          check_grading_printout_matches_the_threshold_in_use)
    check("no front-door refusal survives the re-scope",
          check_no_front_door_refusal_survives)
    check("no tool forces temp_hygiene over the harness's decision",
          check_no_tool_forces_temp_hygiene)
    check("the harness pin names a commit that exists",
          check_harness_pin_names_a_real_commit)
    check("all three U64 tools print their grading before touching the "
          "device", check_all_three_u64_tools_grade)
    check("every reboot is followed by the readiness wait (call site)",
          check_reboot_is_followed_by_readiness_wait)
    check("--speeds refuses a repeated clock, by name, before any device",
          check_speeds_rejects_repeats_at_parse_time)
    check("cited harness spans match ScratchRegion.span (inclusive)",
          check_cited_spans_match_harness_span)
    check("every scratch install site calls the guard",
          check_every_scratch_install_site_is_guarded)
    check("scratch blobs clear of declared harness scratch",
          check_scratch_off_harness_regions)
    check("every check here has a recorded red leg",
          check_every_check_has_a_recorded_red_leg)
    print()
    if FAILURES:
        print(f"{len(FAILURES)} check(s) FAILED")
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
