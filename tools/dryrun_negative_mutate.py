#!/usr/bin/env python3
"""Sabotage one rule of the #167 knob guard in a COPY of the Makefile.

Driven by `make lib-verify-dry-run-negative`, one arm at a time:

    python3 tools/dryrun_negative_mutate.py ARM COPY_DIR

rewrites COPY_DIR/Makefile with ARM's mutation and writes the two strings the
arm must then see in `lib-verify-dry-run`'s output:

    COPY_DIR/expect.reached  an OK line from a leg BEFORE the one under test,
                             so the arm cannot pass on a run that died early
    COPY_DIR/expect.names    the FAIL line naming the leg built for this rule

Each mutation reproduces a defect in the Makefile under test, never in the
check. Every anchor must match exactly once, or this exits 1 before anything
runs: an anchor that silently stopped matching would leave the copy pristine,
and the arm would then fail with "the check passed", which a reader could
mistake for an inert check rather than a stale fixture.

The `pristine` arm mutates nothing and expects the check to PASS; it is the
positive control that the copy builds and reaches every leg at all.
"""
import os
import sys

FORCE = "override X25519_KNOB_FORCE := x25519-knob-force"
NQT = "$(foreach f,n q t,$(findstring $f,$(X25519_MF_FLAGS)))"
BOOL = "x25519_mf_flags = $(if $(call x25519_mf_strip,$1,$(X25519_MF_BOOL)),,$1)"
LONG = "$(foreach w,$(filter-out --%,$(filter -%,$(MFLAGS))),"
FLAGS = ("X25519_MF_FLAGS := \\\n"
         "  $(foreach w,$(filter-out --%,$(filter -%,$(MFLAGS))),"
         "$(call x25519_mf_flags,$(patsubst -%,%,$w)))\n")
FORCE_PREREQ = "$(wildcard $(X25519_KNOB_OUTPUTS)): $(X25519_KNOB_FORCE)\n"
CATCH = "$(foreach d,$(sort $(dir $(X25519_KNOB_OUTPUTS))),$(eval $(d)%: $(call x25519_knob_alias,$(d))% ; +$$(error No rule to make target"
CATCH_LINE = (CATCH + " `$$@' once the changed knobs invalidate it: a real build deletes it "
              "first and has no rule to rebuild it (#167))))\n")
ROUND3_CATCH = "$(foreach d,$(sort $(dir $(X25519_KNOB_OUTPUTS))),$(eval $(d)%: ; @:))\n"
CLEAR = "override X25519_KNOB_FORCE :=\n"
REFUSAL = ("ifneq ($(filter command override file,$(firstword $(origin MFLAGS))),)\n"
           "$(error knobs changed")

# The detector this file shipped in review round 2: a re-parse of MAKEFLAGS
# (a dash-less first word or `-x` words, before `--`). Correct for every
# MAKEFLAGS make generates itself, wrong for an -e environment MAKEFLAGS,
# which is why the guard reads MFLAGS now. FIRST is its first-word rule.
UPTO = ("x25519_mf_upto = $(if $1,$(if $(filter --,$(firstword $1)),,"
        "$(firstword $1) $(call x25519_mf_upto,$(wordlist 2,$(words $1),$1))))\n")
FIRST = "$(foreach w,$(filter-out -%,$(firstword $(X25519_MF_WORDS))),$(call x25519_mf_flags,$w))"
ROUND2 = (UPTO + "X25519_MF_WORDS := $(call x25519_mf_upto,$(MAKEFLAGS))\n"
          "X25519_MF_FLAGS := " + FIRST + " \\\n"
          "  $(foreach w,$(filter-out --%,$(filter -%,$(X25519_MF_WORDS))),"
          "$(call x25519_mf_flags,$(patsubst -%,%,$w)))\n")
EVERY = ROUND2.replace(FIRST, FIRST.replace("$(firstword $(X25519_MF_WORDS))", "$(X25519_MF_WORDS)"))
# MFLAGS and the round-2 MAKEFLAGS reading together ("belt and braces").
UNION = FLAGS + UPTO + ("X25519_MF_WORDS := $(call x25519_mf_upto,$(MAKEFLAGS))\n"
         "X25519_MF_FLAGS += " + FIRST + " \\\n"
         "  $(foreach w,$(filter-out --%,$(filter -%,$(X25519_MF_WORDS))),"
         "$(call x25519_mf_flags,$(patsubst -%,%,$w)))\n")

L = "FAIL: lib-verify-dry-run leg "
OK = "OK: lib-verify-dry-run leg "

ARMS = {
    "pristine": ([], OK + "(e) MFLAGS on the command line", None),
    # The dangerous half: skip the rm but still write the stamp. The next
    # real build would reuse the old objects under a stamp naming the new
    # knobs (#113/#114). Caught by the first dry leg, with only the stamp
    # lines of the snapshot differing.
    "stamp-no-rm": (
        [(FORCE, FORCE + "\n$(shell printf '%s' \"$(CURRENT_KNOBS)\" > $(CONTRACT_STAMP))")],
        OK + "baseline",
        L + "-n on an ABSENT x25519.a — the run changed build-dryrun",
    ),
    "drop-t": (
        [(NQT, NQT.replace("n q t", "n q"))],
        OK + "-n on an ABSENT x25519.a",
        L + "-t on an ABSENT x25519.a — the run changed build-dryrun",
    ),
    # Nothing forced: a changed-knob -q answers "up to date", and the
    # consumer `-q || make` idiom keeps the previous config's archive.
    "no-force": (
        [(FORCE_PREREQ, "")],
        OK + "-t on a nonexistent target (typo)",
        L + "-q on libx25519.a (consumer shape, a file with a rule) — sub-make exited 0, expected one of {1}",
    ),
    # Files with a recipe are forced, files without one are not: on 3.81 a
    # rule-less file with only a phony prerequisite still answers -q rc=0.
    # This is review round 2's shape, which missed the canonical x25519.a.
    "no-ruleless-recipe": (
        [(CATCH_LINE, "")],
        OK + "-q on libx25519.a",
        L + "-q on the canonical x25519.a (consumer shape, no rule) — sub-make exited 0, expected one of {2}",
    ),
    # Review round 3's catch-all, a do-nothing pattern on every output
    # directory: it matches ABSENT files too, so -n prints `:` for one and
    # -t creates it empty, where master says "No rule".
    "catch-all-restored": (
        [(CATCH_LINE, ROUND3_CATCH)],
        OK + "baseline",
        L + "-n on an ABSENT x25519.a — sub-make exited 0, expected one of {2}",
    ),
    # The error recipe without the self-alias prerequisite: it then fires for
    # an absent file as well, so a typo or a deleted archive gets this guard's
    # message instead of master's own "No rule ...  Stop.".
    "no-existence-scope": (
        [(CATCH, CATCH.replace(" $(call x25519_knob_alias,$(d))% ;", " ;"))],
        OK + "baseline",
        L + "-n on an ABSENT x25519.a — make did not say: No rule to make target `build-dryrun/lib/x25519.a'.  Stop.",
    ),
    # Existence-scoped, but a do-nothing recipe instead of the error: -q on an
    # existing rule-less file answers 1 (out of date) where master answered
    # rc 2 "No rule", and -t would touch it.
    "no-error-recipe": (
        [(CATCH_LINE, CATCH.split(" +$$(error")[0] + " @:))\n")],
        OK + "-q on libx25519.a",
        L + "-q on the canonical x25519.a (consumer shape, no rule) — sub-make exited 1, expected one of {2}",
    ),
    # The catch-all on the library directory only: an object in $(BUILD_DIR)
    # whose source is gone is then quietly passed over by -n.
    "lib-dir-only-catch-all": (
        [(CATCH, CATCH.replace("$(sort $(dir $(X25519_KNOB_OUTPUTS)))",
                               "$(filter $(LIB_DIR)/,$(sort $(dir $(X25519_KNOB_OUTPUTS))))"))],
        OK + "-n — previewed 13 ca65 lines",
        L + "-n with src/util.s missing (util.o present) — sub-make exited 0, expected one of {2}",
    ),
    # No clearing `override` before the guard: X25519_KNOB_FORCE from the
    # environment arms the force on a real build.
    "env-force-honoured": (
        [(CLEAR, "")],
        OK + "-q, UNCHANGED knobs — rc=0 on build-dryrun/labels.txt",
        L + "X25519_KNOB_FORCE from the environment — a real unchanged-knob build exited 0 and recompiled 13",
    ),
    "w-no-exec": (
        [(NQT, NQT.replace("n q t", "n q t w"))],
        OK + "(b) --no-print-directory",
        L + "(b) -w — a REAL build was taken",
    ),
    # The `--long` filter and the all-boolean rule each reject
    # --no-print-directory on their own, so only removing BOTH reaches (b).
    "long-and-bool": (
        [(LONG, "$(foreach w,$(filter -%,$(MFLAGS)),"),
         (BOOL, "x25519_mf_flags = $1")],
        OK + "(a) consumer -q x25519.a || make idiom — -q answered 2",
        L + "(b) --no-print-directory — a REAL build was taken",
    ),
    # Round 2's MAKEFLAGS re-parse with its first-word rule widened to every
    # dash-less word: `w n` (a real build) is then read as -n.
    "round2-every-word": (
        [(FLAGS, EVERY)],
        OK + "(c) lone t",
        L + "(d1) -e MAKEFLAGS='w n' (a real build) — a REAL build was taken",
    ),
    # Round 2's MAKEFLAGS re-parse as written: blind to `--touch` arriving
    # through -e, so the rm runs under a touch run.
    "round2-detector": (
        [(FLAGS, ROUND2)],
        OK + "(d1)",
        L + "-e MAKEFLAGS=--touch — the run changed build-dryrun",
    ),
    # MFLAGS plus the round-2 MAKEFLAGS reading: sees every dry run, but reads
    # (d2)'s `-I -n`, where -n is -I's argument, as -n.
    "union-with-makeflags": (
        [(FLAGS, UNION)],
        OK + "-e MAKEFLAGS=-ntx",
        L + "(d2) -e MAKEFLAGS='-Int -I -n --dry-runx --qu' (a real build) — a REAL build was taken",
    ),
    # No refusal: MFLAGS=-k on the command line is believed, the rm runs,
    # and nothing says why a dry run's MFLAGS could not be trusted.
    "no-mflags-refusal": (
        [(REFUSAL, "ifneq (,)\n$(error knobs changed")],
        OK + "(d2)",
        L + "(e) MFLAGS on the command line — exited 0 without the named refusal",
    ),
    # The catch-all moved above the real rules: on 3.81 the first matching
    # pattern rule wins, so the objects take the error recipe and even -q on
    # libx25519.a, which has a real rule, stops with "No rule" (rc 2).
    "force-before-patterns": (
        [(CATCH_LINE, ""),
         ("all: $(PRG)\n", "all: $(PRG)\nifneq ($(X25519_KNOB_FORCE),)\n"
          "x25519_knob_alias = $(if $(filter /%,$1),/$1,$(CURDIR)/$1)\n" + CATCH_LINE + "endif\n")],
        OK + "-t on a nonexistent target (typo)",
        L + "-q on libx25519.a (consumer shape, a file with a rule) — sub-make exited 2, expected one of {1}",
    ),
    # The archives forced but not the objects: -q on every archive still
    # answers as it should, and only -n shows that the build is not previewed.
    "objects-unforced": (
        [(FORCE_PREREQ, "$(filter-out %.o,$(wildcard $(X25519_KNOB_OUTPUTS))): $(X25519_KNOB_FORCE)\n")],
        OK + "-q on the canonical x25519.a",
        L + "-n — listed 0 ca65 line(s), expected 13",
    ),
}


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ARMS:
        sys.exit("usage: dryrun_negative_mutate.py {%s} COPY_DIR" % "|".join(ARMS))
    arm, d = sys.argv[1], sys.argv[2]
    path = os.path.join(d, "Makefile")
    with open(path) as f:
        text = f.read()
    edits, reached, names = ARMS[arm]
    for old, new in edits:
        n = text.count(old)
        if n != 1:
            sys.exit("FAIL: arm [%s] anchor matched %d time(s), expected 1; the "
                     "fixture is stale and the arm would prove nothing:\n  %s"
                     % (arm, n, old.strip()))
        text = text.replace(old, new)
    with open(path, "w") as f:
        f.write(text)
    with open(os.path.join(d, "expect.reached"), "w") as f:
        f.write(reached)
    with open(os.path.join(d, "expect.names"), "w") as f:
        f.write(names or "")
    print("OK: arm [%s] applied %d mutation(s) to %s" % (arm, len(edits), path))


if __name__ == "__main__":
    main()
