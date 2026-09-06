#!/usr/bin/env python3
"""Assert c64-lib-contract SPEC v1.2.2 §6.1 member isolation over a shipped archive.

The clause, quoted from the TAG this conforms to. SS6.1 was corrected twice
on 2026-09-06; the v1.2.0 wording lacked the prefixed-counterparts exception,
under which precalc_manifest.o -- 9 bare plus 9 prefixed -- would itself have
been non-conformant. Quote the tag, not main:

    ld65 links whole archive members. A symbol a consumer may displace --
    suppress under LIB_NO_BARE_EXPORTS, or define itself under APP_OWNED
    (SS8.0) -- MUST live in a translation unit that exports nothing else a
    consumer may import -- other displaceable names included, THEIR OWN
    PREFIXED COUNTERPARTS EXCEPTED -- and defines nothing else the library's
    own code references. Otherwise the member arrives uninvited and its
    displaceable names collide -- with the consumer's own definitions, or
    with the identical bare name a sibling library exports -- and the
    consumer can repair neither: member surgery is banned above.

That exception is why this tool tests bare-vs-aggregate and bare-vs-bare
co-occurrence but NOT bare-vs-its-own-prefixed-counterpart: the latter is
expressly permitted, and a check forbidding it would reject the conformant
arrangement.

Two displaceable families are exported by this library, both suppressed by
`-D LIB_NO_BARE_EXPORTS=1` and both identical in every adopter, so both
collide in a composed link:

    bare version quadruple   LIB_VERSION_{MAJOR,MINOR,PATCH}, LIB_ABI_VERSION
    bare precalc triples     LIB_PRECALC_<name>_{SIZE,REGION,SHARED}

Neither may share a member with the other, nor with anything a consumer
imports for its own reasons -- the SS5 aggregates most of all, since SS5
*requires* a consumer to import those.

Measured before the v0.14.0 split, consumer importing only two prefixed SS5
equates from two libraries and referencing no bare name:

    ld65: Error: Duplicate external identifier: 'LIB_PRECALC_sqtab_SHARED'

WHY THIS IS A TOOL AND NOT THREE GREPS
--------------------------------------
An isolation check is an ABSENCE assertion, and absence assertions fail
open: if the export extraction returns nothing, every "must not co-occur"
test passes and the check goes quiet rather than red. Three separate ways
that happens here, all observed in this fleet rather than imagined:

  1. `od65`'s padding before the quoted name is `abs(24 - len(name))` --
     measured across 20 distinct lengths (4..23) on this library's own
     objects, every one matching. It is `printf("Name:%*s\"%s\"", 24-len,
     "", name)`, where a NEGATIVE `%*s` width left-justifies rather than
     truncating. So the padding is ZERO at name length EXACTLY 24, and od65
     emits `Name:"LIB_PRECALC_sqtab_REGION"` with no space at all.
     `awk '/Name:/{print $2}'` then yields a token that is not the name,
     and a `Name:\s+"` regex fails to match. This library exports three
     such names (LIB_PRECALC_sqtab_REGION, LIB_PRECALC_sqtab_SHARED,
     LIB_PRECALC_reu_mul_SIZE) and ALL THREE ARE BARE -- precisely the
     class this check counts. An unsafe extraction reports "0 bare names"
     on a member holding three.

     Two false inferences to avoid, each licensing a WORSE extractor:
       * NOT a fixed column. The quote's offset moves with every name, so
         `cut -c` or any fixed-offset slice is wrong on both sides of 24.
       * NOT a long-name problem. The hazard is the single length where
         the padding expression is zero. LIB_PRECALC_sqtab_REGION (24)
         breaks; LIB_PRECALC_reu_mul_doubled_SHARED (34) is fine.

  2. A member that fails to dump at all (renamed, od65 missing, archive
     stale) contributes an empty name set and passes everything.
  3. After a split, the member a leg was written about may no longer be
     pulled into the artifact the leg inspects at all.

DO NOT REPLACE THE DERIVED POPULATION WITH A ROSTER
---------------------------------------------------
The next maintainer's instinct will be to add a readable list of "the bare
names we expect" and intersect against it. That is the regression, not the
improvement. c64-nist-curves had exactly that shape: a hand-written
BARE_GATED roster that listed none of the 18 bare LIB_PRECALC_* names the
SS8.4 macro generates, so the leg computed an empty intersection and
reported "0 bare names" for a TU it had never actually examined -- since
their issue #113.

The population here is DERIVED (a regex over what od65 reports, reconciled
against od65's own record count), never enumerated. A name nobody thought
to list still counts, and a name the macro starts emitting tomorrow counts
on the day it appears. The per-profile sentinel is a total, deliberately,
not a roster: it constrains the count without claiming to know the names.

A DIFF IS BLIND TO ANY ERROR ITS TWO SIDES SHARE
------------------------------------------------
Reconciliation catches an extractor dropping names from ONE side. It cannot
catch one dropping the same names from BOTH -- that case agrees rather than
erroring. Export-set equality between two builds, run through a
field-splitting extractor, silently excludes every length-24 name from both
sides and reports "identical".

The two defences are complementary, not redundant: reconciliation for
asymmetric drops, a known-hard-input check for symmetric ones --

    od65 --dump-exports build/lib/precalc_manifest.o | grep -c 'Name:"'

non-zero means that object holds a length-24 name; then confirm the
extractor actually returns LIB_PRECALC_sqtab_REGION.

And keep one piece of evidence that is not comparison-shaped at all. Two
comparison checks sharing an extractor are not independent evidence. Here
that is the VICE suite and tools/test_ct_ladder_cycles.py, neither of which
parses a symbol name -- which is why the cycle test was the only thing that
caught the count-2 CT regression when every parsed-name and functional
check passed.


So this tool never merely asserts absence. It RECONCILES: for every member,
bare + prefixed + other must equal that member's total export count, and the
totals must match known non-zero sentinels. A dropped name breaks the
reconciliation even when it does not break a co-occurrence test.

Extraction is quote-anchored (`Name: *"..."`, zero-or-more spaces), which is
correct at every name length. Do not "simplify" it to awk or `\\s+`.
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# Quote-anchored, zero-or-more spaces. Correct at name length 24, where od65
# emits no space at all. See the module docstring.
NAME_RE = re.compile(r'Name: *"([^"]*)"')

BARE_VERSION_RE = re.compile(r"^LIB_(VERSION_(MAJOR|MINOR|PATCH)|ABI_VERSION)$")
BARE_PRECALC_RE = re.compile(r"^LIB_PRECALC_")
AGGREGATE_RE = re.compile(
    r"^LIB_X25519_(ZP_USAGE_BYTES|REU_BANKS_USED|RESIDENT_BYTES|COLD_BYTES"
    r"|SHARED_PRIMITIVES|SHARED_CONSUMES)$"
)


def members(archive):
    out = subprocess.run(["ar65", "t", str(archive)], capture_output=True, text=True)
    if out.returncode != 0:
        raise SystemExit(f"check_member_isolation: ar65 t {archive} failed:\n{out.stderr}")
    return [m for m in out.stdout.split() if m.endswith(".o")]


def exports(obj_path):
    out = subprocess.run(
        ["od65", "--dump-exports", str(obj_path)], capture_output=True, text=True
    )
    if out.returncode != 0:
        raise SystemExit(f"check_member_isolation: od65 failed on {obj_path}:\n{out.stderr}")
    names = NAME_RE.findall(out.stdout)
    # Reconciliation input: how many export records od65 claims to have
    # emitted, independent of how many names we managed to parse out. If
    # these disagree, the extraction dropped something and every absence
    # test below is untrustworthy.
    declared = out.stdout.count("Name:")
    return names, declared


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--archive", required=True)
    ap.add_argument("--lib-dir", required=True)
    ap.add_argument(
        "--expect-bare-precalc",
        type=int,
        default=None,
        help="non-empty sentinel: how many bare LIB_PRECALC_* names the archive "
        "must export in total. An isolation check that never sees one is not "
        "evidence of isolation, it is evidence of an empty dump.",
    )
    ap.add_argument(
        "--unsafe-extract",
        action="store_true",
        help="negative leg: re-run using the awk-equivalent extraction that "
        "drops length-24 names, to demonstrate this check can tell the "
        "difference",
    )
    args = ap.parse_args()

    archive = Path(args.archive)
    lib_dir = Path(args.lib_dir)

    failures = []
    total_bare_precalc = 0
    total_bare_version = 0

    print(f"=== member isolation (SPEC v1.2.2 §6.1) over {archive} ===")
    for m in members(archive):
        names, declared = exports(lib_dir / m)

        if args.unsafe_extract:
            # The awk '{print $2}' behaviour, reproduced exactly: split the
            # line on whitespace and take field 2. At name length 24 od65
            # emits no space, so field 2 is the quoted name glued to
            # `Name:` and the token does not match -- the name vanishes.
            raw, _ = exports(lib_dir / m)
            del raw
            out = subprocess.run(
                ["od65", "--dump-exports", str(lib_dir / m)],
                capture_output=True,
                text=True,
            ).stdout
            names = []
            for line in out.splitlines():
                if "Name:" in line:
                    parts = line.split()
                    if len(parts) >= 2:
                        names.append(parts[1].strip('"'))

        bare_v = [n for n in names if BARE_VERSION_RE.match(n)]
        bare_p = [n for n in names if BARE_PRECALC_RE.match(n)]
        aggs = [n for n in names if AGGREGATE_RE.match(n)]
        total_bare_precalc += len(bare_p)
        total_bare_version += len(bare_v)

        # RECONCILIATION. This is the half that does not fail open: a name
        # the extraction dropped makes parsed < declared, regardless of
        # which co-occurrence tests happen to pass.
        if len(names) != declared:
            failures.append(
                f"{m}: extraction dropped {declared - len(names)} of {declared} "
                f"export name(s) -- every absence test on this member is "
                f"untrustworthy. This is the od65 length-24 padding bug; the "
                f"extraction must be quote-anchored."
            )
            continue

        # The isolation tests themselves.
        if bare_p and aggs:
            failures.append(
                f"{m}: exports {len(bare_p)} bare LIB_PRECALC_* name(s) AND "
                f"{len(aggs)} §5 aggregate(s) a consumer MUST import "
                f"({', '.join(sorted(aggs))}) -- importing a footprint equate "
                f"drags the displaceable names into the link"
            )
        if bare_p and bare_v:
            failures.append(
                f"{m}: exports {len(bare_p)} bare LIB_PRECALC_* name(s) AND "
                f"{len(bare_v)} bare version export(s) -- two displaceable "
                f"families in one member"
            )
        if bare_v and aggs:
            failures.append(
                f"{m}: exports {len(bare_v)} bare version export(s) AND "
                f"{len(aggs)} §5 aggregate(s)"
            )

        tag = []
        if bare_v:
            tag.append(f"{len(bare_v)} bare-version")
        if bare_p:
            tag.append(f"{len(bare_p)} bare-precalc")
        if aggs:
            tag.append(f"{len(aggs)} §5-aggregate")
        print(f"  {m:<22} {declared:>3} exports" + (f"  [{', '.join(tag)}]" if tag else ""))

    # NON-EMPTY SENTINEL. Without this the whole check passes on an archive
    # that exports nothing at all -- the classic way an absence assertion
    # goes quiet instead of red.
    if args.expect_bare_precalc is not None:
        if total_bare_precalc != args.expect_bare_precalc:
            failures.append(
                f"sentinel: expected {args.expect_bare_precalc} bare LIB_PRECALC_* "
                f"exports across the archive, found {total_bare_precalc}. Either "
                f"the enumeration changed (update the sentinel deliberately) or "
                f"the extraction is dropping names, in which case the isolation "
                f"result above means nothing."
            )
    if total_bare_version != 4:
        failures.append(
            f"sentinel: expected the 4 bare version exports "
            f"(LIB_VERSION_MAJOR/MINOR/PATCH, LIB_ABI_VERSION), found "
            f"{total_bare_version}. §1 requires them until a future MAJOR."
        )

    if failures:
        print()
        for f in failures:
            print(f"FAIL: {f}")
        print("\nSee SPEC v1.2.2 §6.1, src/precalc_manifest.s and src/mul_stage.s.")
        return 1

    print(
        f"OK: no member mixes displaceable names with names a consumer imports "
        f"for another reason ({total_bare_precalc} bare precalc + "
        f"{total_bare_version} bare version exports accounted for, all "
        f"reconciled against od65's own record count)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
