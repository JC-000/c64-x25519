#!/bin/sh
# =============================================================================
# Counting sabotage shim for `make lib-verify-guards-legc-negative` (issue #133)
# =============================================================================
#
# The three zero-count legs of the leg C family (C1, C2, C1b) pass when a count
# comes back 0. A step that produced NO OUTPUT AT ALL also counts 0, so each
# leg's negative demonstration has to reproduce exactly that: a tool that works
# for the earlier steps and then, from one nominated invocation on, misbehaves
# in a specific, named way.
#
# This script is COPIED into a throwaway bin/ directory under the basename of
# the tool it stands in for (`od65` or `make`) and is selected either by a PATH
# prefix (od65, which the Makefile calls bare) or by overriding `MAKE=` on the
# sub-make command line (make, which the Makefile calls through $(MAKE)).
#
# Environment:
#   SHIM_REAL        absolute path to the real tool (required)
#   SHIM_FAIL_AT     first invocation number to sabotage (required, >= 1)
#   SHIM_COUNT_FILE  invocation counter, created on first use (required)
#   SHIM_TRACE_FILE  REQUIRED. Append-only log: one "<tool> invocation <n>:
#                    <argv>" line per invocation, with the sabotaged one marked.
#                    The arm asserts this file holds exactly SHIM_FAIL_AT lines
#                    and that the last names this tool, so that "the leg failed"
#                    cannot be confused with "the leg failed for some unrelated
#                    reason and the shim never ran". It was once documented as
#                    optional; since the arm asserts on it, an unset value could
#                    only ever produce an arm failure, so it is enforced below
#                    rather than described as a choice.
#   SHIM_MODE        what to do from SHIM_FAIL_AT on (default silent-fail):
#
#     silent-fail      write NOTHING to stdout or stderr, exit 1. The
#                      "examined nothing" shape from the issue.
#     silent-ok        write NOTHING, exit 0. A tool that appears to succeed
#                      and reports nothing -- the shape a `2>/dev/null | grep
#                      -c` pipeline cannot distinguish from a real zero.
#     substitute-last  exec the real tool with its LAST argument replaced by
#                      $SHIM_SUBSTITUTE. Used to hand od65 a path that exists
#                      and is NOT an xo65 object: measured, od65 prints
#                      "<path>: (no xo65 object file)" and exits 0, so rc and
#                      a filename grep both pass and only a record-count check
#                      catches it.
#     touch-then-exec  touch $SHIM_TOUCH, then exec the real tool unchanged.
#                      Used to make one source file newer than the objects
#                      between a build and the no-rebuild count that follows
#                      it, so something really does recompile -- leg C1/C1b's
#                      own property, reproduced rather than simulated. It only
#                      ever touches a COPY of src/ that the arm made.
#     strip-arg        exec the real tool with every occurrence of $SHIM_STRIP
#                      removed from every argument. Used to drop a -D knob out
#                      of a sub-make's CONTRACT_DEFINES so the knob change
#                      never reaches the artifact -- the #113/#114 defect leg
#                      C2 exists to catch, reproduced rather than simulated.
#
# In every mode the shim perturbs the STEP a leg draws its evidence from, never
# the assertion itself.

tool=$(basename "$0")

for v in SHIM_REAL SHIM_FAIL_AT SHIM_COUNT_FILE SHIM_TRACE_FILE; do
    eval "val=\$$v"
    if [ -z "$val" ]; then
        echo "legc_negative_shim ($tool): $v is unset" >&2
        exit 2
    fi
done

n=0
if [ -f "$SHIM_COUNT_FILE" ]; then
    n=$(cat "$SHIM_COUNT_FILE")
fi
n=$((n + 1))
echo "$n" > "$SHIM_COUNT_FILE"

# The trace records the argv AS REQUESTED plus whether this invocation is the
# sabotaged one, so a transcript cannot be misread: under strip-arg, invocation
# N still shows the -D the recipe asked for, and the marker says it was taken
# away. Exactly one line per invocation -- the arm counts them.
sab=""
if [ "$n" -ge "$SHIM_FAIL_AT" ]; then
    sab="   <== SABOTAGED (${SHIM_MODE:-silent-fail})"
fi
echo "$tool invocation $n: $*$sab" >> "$SHIM_TRACE_FILE"

if [ "$n" -lt "$SHIM_FAIL_AT" ]; then
    exec "$SHIM_REAL" "$@"
fi

case "${SHIM_MODE:-silent-fail}" in
    silent-fail)
        exit 1
        ;;
    silent-ok)
        exit 0
        ;;
    substitute-last)
        if [ -z "$SHIM_SUBSTITUTE" ]; then
            echo "legc_negative_shim ($tool): SHIM_SUBSTITUTE is unset" >&2
            exit 2
        fi
        # Rotate argv, dropping the final element and appending the decoy.
        last_i=$(($# - 1))
        i=0
        while [ "$i" -lt "$last_i" ]; do
            a=$1
            shift
            set -- "$@" "$a"
            i=$((i + 1))
        done
        shift                       # discard the original last argument
        exec "$SHIM_REAL" "$@" "$SHIM_SUBSTITUTE"
        ;;
    touch-then-exec)
        if [ -z "$SHIM_TOUCH" ]; then
            echo "legc_negative_shim ($tool): SHIM_TOUCH is unset" >&2
            exit 2
        fi
        if [ ! -f "$SHIM_TOUCH" ]; then
            echo "legc_negative_shim ($tool): SHIM_TOUCH '$SHIM_TOUCH' does not exist" >&2
            exit 2
        fi
        # A FUTURE stamp, not a bare `touch`. GNU Make 3.81 -- which is what
        # runs here -- compares mtimes at WHOLE-SECOND granularity, so a source
        # touched in the same second as the object built from it is not
        # "newer" and nothing rebuilds. Measured: a bare touch left the leg
        # counting 0 ca65 invocations and the arm correctly reported that its
        # sabotage had not landed. This is the same granularity trap the repo
        # hit with CONTRACT_STAMP and a stale PRG.
        touch -t 203001010000 "$SHIM_TOUCH"
        exec "$SHIM_REAL" "$@"
        ;;
    strip-arg)
        if [ -z "$SHIM_STRIP" ]; then
            echo "legc_negative_shim ($tool): SHIM_STRIP is unset" >&2
            exit 2
        fi
        # Rotate argv once, rewriting each element in place. Preserves element
        # boundaries, which a `set -- $(...)` respelling would not.
        n_args=$#
        i=0
        while [ "$i" -lt "$n_args" ]; do
            a=$1
            shift
            case "$a" in
                *"$SHIM_STRIP"*)
                    a=$(printf '%s' "$a" | sed "s| *$SHIM_STRIP||g")
                    ;;
            esac
            set -- "$@" "$a"
            i=$((i + 1))
        done
        exec "$SHIM_REAL" "$@"
        ;;
    *)
        echo "legc_negative_shim ($tool): unknown SHIM_MODE '$SHIM_MODE'" >&2
        exit 2
        ;;
esac
