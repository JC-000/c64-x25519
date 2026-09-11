#!/usr/bin/env python3
"""u64_preflight.py — shared front-of-run support for the three U64 tools.

Two things, neither of them a guard:

* :func:`print_grading` — print what the device reported and what the
  harness concluded from it, on every run.
* :func:`wait_device_ready` — settle-then-probe after ``client.reboot()``.

The tools construct :class:`Ultimate64Client` themselves. There is no
wrapper: see "Why there is no hygiene handling here at all" below.

The guard is the harness's, and it is not reimplemented here
==========================================================

``POST /v1/machine:writemem`` leaves a managed file in the device's
``/Temp`` on firmware without upstream fix GideonZ/1541ultimate#686.
``Ultimate64Client`` handles this itself, at the request choke point:

* :attr:`~Ultimate64Client.temp_hygiene_armed` arms when
  ``DeviceCapabilities.runner_wedge_possible is not False`` — so it arms
  on a C64 Ultimate at 1.1.0, and on the tri-state ``None`` too;
* ``_creates_temp_attachment`` is ``body is not None and method ==
  "POST"``, which counts ``POST machine:writemem`` — every 256-byte
  scrub write in ``test_reu_mul_u64`` included;
* every ``temp_gc_budget`` attachments it runs ``gc_temp_folder`` over
  FTP, enabling the device's FTP File Service itself if it must;
* when hygiene is armed and has been proven impossible it raises
  :class:`~c64_test_harness.backends.ultimate64_client.Ultimate64TempHygieneError`,
  with ``U64_TEMP_GC_REQUIRED=0`` as the named opt-out.

That is a refusal with a named opt-out, one layer below us and at the
request that creates the attachment rather than at a tool's front door.
This module used to carry its own version of it — two environment
variables, a refusal, a retry loop — which duplicated a facility we do
not own and, once that facility landed, printed sentences that were
false against it. It is deleted rather than reconciled.

So :func:`print_grading` is VISIBILITY, not a boundary. It refuses
nothing. It exists because a live device was once graded backwards from
a correctly-dated document, and what would have caught that is seeing
the device's own answer printed beside the conclusion drawn from it.

Why there is no hygiene handling here at all
============================================

Read this before adding any. Its absence is deliberate, and an absence
with no recorded reason is the thing someone re-adds.

This module briefly carried a ``make_client()`` that forced
``temp_hygiene=True`` when the client's construct-time capability probe
returned no firmware version — the "slow device is a distressed device"
residue the harness's own docstring names. At ``eb245a9`` that is
redundant and mildly wrong, and it was deleted:

* **Redundant.** ``60615b5`` added a post-evidence re-probe.
  ``_before_temp_attachment`` calls ``_maybe_reprobe_capabilities()``
  and only THEN consults ``temp_hygiene_armed`` — re-probe precedes
  arming. A client whose 0.5 s construct probe failed re-probes at the
  full timeout once it has seen one successful request, and arms itself.
  Every tool here issues GETs (``get_info``, ``snapshot_state``,
  ``probe_u64``) long before its first attachment-creating write, so the
  evidence precondition is already met.
* **Mildly wrong.** ``temp_hygiene=True`` sets ``_temp_hygiene_force``,
  which ``temp_hygiene_armed`` short-circuits on before anything else.
  A forced client therefore stays armed even after the re-probe
  establishes the device is a U64E 3.15 that collects its own
  attachments — FTP GC passes for the client's life on a device that
  needs none. Forcing does not suppress the re-probe (its guards never
  consult ``_temp_hygiene_force``), so the grade still settles; only the
  arming decision is pinned past the point the layer below could have
  made it correctly.

**The one surviving case is deliberately not ours.** If the re-probe
also fails, ``_maybe_reprobe_capabilities`` has already set
``_reprobed``, so it gives up permanently and logs a WARNING naming
``U64_AUTO_TEMP_GC=1`` and ``temp_hygiene=True``. The harness hands that
to the operator on purpose. Intercepting it here — in any form, however
small — would put back the duplicate guard this repo spent a day
removing.

Harness pin
===========

**Verified against c64-test-harness ``eb245a9`` (2026-09-10).**

This module's behaviour is reasoned from harness internals — the arming
rule, the attachment predicate, the re-probe path — and that dependency
moved four times in the session this was written (``f4074ab`` ->
``202c188`` -> ``d4b96bc`` -> ``eb245a9``), twice on ground this file
rests on. Note that ``d4b96bc`` is no longer reachable: PR #259 landed
as a squash, so a pin naming it resolves today only because the object
is still present and stops resolving after a gc. A
statement about a sibling repo ages; the installed tree is checkable at
any moment. If you are changing this module, re-read
``backends/ultimate64_client.py`` at the current HEAD before trusting
any sentence above, and move this pin when you do.

The deletion described above was made BECAUSE of behaviour at
``eb245a9``, not because hygiene stopped mattering. A reader who finds
no hygiene handling in this repo should read that as deliberate
deference to the layer below, and should check that the deference is
still earned at whatever HEAD they are on before relying on it.
"""

import os
import time

from c64_test_harness.backends.ultimate64_probe import probe_u64

#: Floor before probing after a reboot. This is the value HEAD slept
#: unconditionally, kept deliberately so this cannot regress against it.
#: NOT the harness's reboot_settle_seconds (12.0): that constant is
#: theirs, and copying it would put a second, drifting copy here.
REBOOT_SETTLE_FLOOR = 8.0


def _tri(v):
    # ``unknown`` is defensive: DeviceCapabilities._writemem_post_safe is
    # annotated -> bool and returns a bool on every path, so from_info
    # cannot currently produce None. The arm stays because the field is
    # declared tri-state and an ``overrides=`` caller may pin it.
    return {True: "yes", False: "no", None: "unknown"}[v]


def print_grading(client, *, what):
    """Print the device's own answer and the harness's conclusion.

    VISIBILITY, not a guard: this refuses nothing. The guard is
    ``Ultimate64TempHygieneError`` at the request choke point, opted out
    of with ``U64_TEMP_GC_REQUIRED=0``; see the module docstring.

    Sourced from ``client.capabilities``, NOT from a fresh
    ``get_info()``. The client pins ``write_mem_query_threshold`` from
    its construct-time probe, so every write in the run uses THAT read's
    answer; a second read could print a threshold the run does not
    actually use, which is the kind of divergence this printout exists to
    prevent rather than create.

    :param client: connected Ultimate64 client.
    :param what: tool name, for the log line.
    :returns: the :class:`DeviceCapabilities` the client is using.
    """
    caps = client.capabilities
    print(f"  device reported: product={caps.product!r} "
          f"firmware_version={caps.firmware_version!r}")
    print(f"  harness grading [{what}]: generation={caps.generation}, "
          f"PUT/POST threshold {client.write_mem_query_threshold} B, "
          f"collects its own /Temp attachments: "
          f"{_tri(caps.writemem_post_safe)}")
    print(f"  /Temp hygiene: "
          f"{'armed' if client.temp_hygiene_armed else 'disarmed'} "
          f"(budget {client.temp_gc_budget}). When armed and a pass "
          f"proves impossible the harness raises "
          f"Ultimate64TempHygieneError; U64_TEMP_GC_REQUIRED=0 opts out.")
    return caps


def wait_device_ready(host, timeout=90.0, poll=2.0,
                      settle=REBOOT_SETTLE_FLOOR):
    """Settle, THEN probe until reachable, after ``client.reboot()``.

    Shared by the tools that reboot, rather than copied into each: the
    body and the floor were duplicated verbatim in two files with nothing
    asserting the copies agreed, so a check looping over both modules
    would have passed on two different floors.

    The settle is not redundant with the probe, and removing it was a
    regression. ``probe_u64`` is ping -> TCP -> ``GET /v1/version``: it
    observes whether the REST API answers. But ``machine:reboot`` resets
    the C64, not the firmware serving REST — so the probe can come back
    reachable in ~100 ms with the C64 still in reset, and the caller then
    issues ``set_reu()`` against a machine that is not there yet.

    So: sleep the floor first (what HEAD did, so behaviour cannot
    regress), then probe, which adds the upper bound the bare sleep never
    had. Settle-then-probe is also the harness's own shape in
    ``ultimate64_helpers.recover()``.

    Returns the ProbeResult, or None if the device never came back.
    """
    time.sleep(settle)
    deadline = time.monotonic() + timeout
    pr = None
    while time.monotonic() < deadline:
        pr = probe_u64(host, password=os.environ.get("U64_PASSWORD"))
        if pr.reachable:
            return pr
        time.sleep(poll)
    return None
