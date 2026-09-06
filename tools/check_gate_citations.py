#!/usr/bin/env python3
"""Verify the Makefile guard table's file:line citations still name real gates.

The `_NEEDS_DEF_*` / `_NEEDS_VAL_*` block in the Makefile documents a
deliberate spelling asymmetry: definedness-gated switches (`.ifdef` /
`.ifndef`) are matched on the bare name, because definedness IS the axis and
every spelling that defines the symbol selects it; value-gated switches
(`.if ::NAME`) are matched on an explicit `=<value>`, because ca65's bare
`-D NAME` defines the symbol as **0** and would name the axis while selecting
the default path.

That rule is only as good as the citations a reader follows to re-derive it.
At v0.13.0 nine of twelve pointed at blank lines, prose comments or ordinary
instructions (issue #122); the `src/fe25519.s` pair was off by one and off by
nine, i.e. correct when written and drifted as lines were inserted above.
Nothing read them, so nothing caught it.

This checks two things per citation, not one:

  1. the cited line is a gate directive at all, and
  2. its STYLE matches the family the guard table files the switch under --
     a `_NEEDS_DEF_` switch must be cited at `.ifdef`/`.ifndef`, a
     `_NEEDS_VAL_` switch at `.if ::NAME`.

(2) is the load-bearing half. A citation that merely points at *some* gate
would still let a value-gated switch be documented by a definedness gate,
which is precisely the confusion the guard table exists to prevent.

Run via `make lib-verify-citations`, which `lib-verify` depends on.
Negative leg: `make lib-verify-citations-negative`.
"""

import argparse
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# (switch, family, file, line) -- one REPRESENTATIVE gate per switch.
#
# Deliberately not exhaustive. Issue #122's post-mortem is that exhaustive
# lists are what drift: every one of the nine wrong citations was in a
# multi-site list, and the two that had ever been right were the two nobody
# had to keep re-finding. One site per switch is what a reader needs to see
# the shape, and one site per switch is what stays true.
CITATIONS = [
    ("SHARED_SQTAB_INIT",    "DEF", "src/mul_8x8.s",     37),
    ("SHARED_CT_MUL_8X8",    "DEF", "src/mul_8x8.s",     55),
    ("SHARED_REU_MUL_INIT",  "DEF", "src/x25519_init.s", 107),
    ("SHARED_REU_MUL_FETCH", "DEF", "src/x25519_init.s", 24),
    ("X25519_ONCHIP_MUL",    "VAL", "src/x25519_init.s", 20),
    ("SQR_DMA_K",            "VAL", "src/x25519_init.s", 35),
]

# `.ifdef FOO` / `.ifndef FOO` -- definedness is the axis.
DEF_RE = r"^\s*\.if(n)?def\s+{sw}\s*(;.*)?$"
# `.if ::FOO` / `.if ::FOO = 0` / `.if .defined(X) .and (::FOO = 0)` -- the
# scoped `::` reference is what makes it a VALUE gate rather than a
# definedness one.
VAL_RE = r"^\s*\.if\b.*::{sw}\b"


def check(citations=CITATIONS):
    """Return a list of human-readable failure strings (empty == all good)."""
    failures = []
    for sw, family, relpath, lineno in citations:
        path = REPO / relpath
        if not path.exists():
            failures.append(f"{relpath}:{lineno} [{sw}] cited file does not exist")
            continue
        lines = path.read_text().splitlines()
        if lineno < 1 or lineno > len(lines):
            failures.append(
                f"{relpath}:{lineno} [{sw}] cited line is past end of file "
                f"({len(lines)} lines)"
            )
            continue
        text = lines[lineno - 1]
        pattern = (DEF_RE if family == "DEF" else VAL_RE).format(sw=re.escape(sw))
        if re.match(pattern, text):
            style = ".ifdef/.ifndef" if family == "DEF" else ".if ::NAME"
            print(f"  OK: {relpath}:{lineno:<5} {sw:<22} {style:<15} | {text.strip()}")
            continue
        want = (
            f".ifdef {sw}` or `.ifndef {sw}"
            if family == "DEF"
            else f".if ::{sw} ..."
        )
        failures.append(
            f"{relpath}:{lineno} [{sw}] is cited by the Makefile guard table as a "
            f"_NEEDS_{family}_ gate, but that line is not one.\n"
            f"      expected: `{want}`\n"
            f"      found:    {text.strip()!r}"
        )
    return failures


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--mutate",
        metavar="SWITCH",
        help="negative leg: perturb this switch's cited line number by +1 "
        "before checking, so the check must fail and must name that switch",
    )
    args = ap.parse_args()

    citations = list(CITATIONS)
    if args.mutate:
        names = [c[0] for c in citations]
        if args.mutate not in names:
            print(
                f"check_gate_citations: --mutate {args.mutate!r} is not a cited "
                f"switch. Known: {' '.join(names)}",
                file=sys.stderr,
            )
            return 2
        i = names.index(args.mutate)
        sw, family, relpath, lineno = citations[i]
        citations[i] = (sw, family, relpath, lineno + 1)
        print(
            f"check_gate_citations: MUTATED {sw} citation "
            f"{relpath}:{lineno} -> {relpath}:{lineno + 1}"
        )

    print(f"=== gate citations: {len(citations)} representative sites ===")
    failures = check(citations)
    if failures:
        print()
        for f in failures:
            print(f"FAIL: {f}")
        print(
            f"\ncheck_gate_citations: {len(failures)}/{len(citations)} citation(s) "
            f"no longer name a gate of the documented style.\n"
            f"Correct the line numbers in tools/check_gate_citations.py and the "
            f"Makefile guard table (issue #122)."
        )
        return 1
    print(
        f"OK: all {len(citations)} guard-table citations name a gate of the "
        f"documented style"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
