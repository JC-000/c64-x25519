#!/usr/bin/env python3
"""Consumer-snippet hygiene check (c64-lib-contract SPEC §2 / §8.1).

Rejects two spellings that are broken as pasted:

  1. `-D NAME=$<value>` -- the $-hex define form.

     The defect is NOT the `$` sigil as such.  A *direct* ca65
     invocation with the value quoted is fine: `ca65 -D FOO='$40'`
     correctly defines FOO = 64.  The defect is a `$` value that is
     passed THROUGH MAKE (or through a shell) unprotected, which is
     exactly how every snippet in this repo is documented to be used:
     these defines ride CONTRACT_DEFINES / CONTRACT_ZP_DEFINES through
     make.

       - Through make, `$40` is a make expansion -- `$4` is an
         (undefined, empty) automatic variable -- so ca65 receives `0`.
         `$$40` collapses to a literal `$40` that the *shell* then eats,
         also yielding `0`; `$$$$40` yields the shell's PID.
       - Shell quotes in the snippet do NOT save it: make expands the
         recipe before the shell ever sees the quotes, so `-D FOO='$40'`
         written into a Makefile still reaches ca65 as `0`.  Quoted
         values are therefore flagged too.
       - Through a bare shell an unquoted `$40` is eaten as a positional
         parameter and also yields `0`.

     Nothing catches the resulting zero:

       - §8.1's page-alignment assert passes, because `0 & $00ff == 0`,
         so sqtab_init writes 1 KB over zero page; and
       - src/zp_config.s asserts nothing about a slot being non-zero, so
         an overridden slot silently lands on $00 -- the 6510 data
         direction register.

     No diagnostic from make, the shell, ca65 or ld65.  SPEC §2 is
     normative: "Make-mediated interfaces MUST therefore pass $-free
     values... Adopter docs that copied the previously-unquoted forms
     should re-check their own snippets."  Contract v0.14.2 amended
     §8.1's examples for exactly this reason.  The fix is always the
     `0x` form, which is `$`-free and survives make, the shell and ca65
     unchanged.

     A `$(...)` / `${...}` make-variable reference is NOT a violation:
     `-D LIB_SHARED_SQTAB_BASE=$(SQTAB_BASE)` is a legitimate,
     deliberately-expanded reference, and Makefile is in scope for this
     checker.  Those two forms are excluded.

  2. `--asm-define NAME=` -- cl65's spelling, rejected by a direct ca65
     invocation ("ca65: Unknown option: --asm-define").  Swept from the
     SPEC at v0.4.3.  Prose *about* the flag ("--asm-define is cl65's
     spelling") is fine and is not matched: the pattern requires an
     immediately following NAME=, i.e. an instructional use.

What counts as NAME
-------------------
Both rules accept either a real ca65 identifier (`LIB_SHARED_SQTAB_BASE`,
`N`) or a documentation metavariable in angle brackets (`<slot>`,
`<addr>`, `<bank>`).  Requiring an identifier was a false negative that
hid one of the four snippets this checker was written for:
src/constants.s documented the override as `-D <slot>=$<addr>`.

Both rules also accept the no-space `-DNAME=` / `-D=NAME=` spellings,
which ca65 accepts.

Why this joins lines instead of grepping them
---------------------------------------------
Comment wrapping splits these snippets across physical lines.  The
instance that shipped in cfg/x25519-example.cfg read:

    #      default); override by passing `ca65 -D
    #      LIB_SHARED_SQTAB_BASE=$<addr>` when rebuilding the library

A line-oriented grep cannot see that, which is why the defect survived.
This strips leading comment markers and folds each file to one line
before matching.

Usage:  python3 tools/check_doc_snippets.py <file> [<file> ...]
Exit:   0 clean, 1 violations found (listed on stdout), 2 usage error.
"""

import re
import sys

# A ca65 identifier, or a documentation metavariable such as `<slot>`.
NAME = r"(?:[A-Za-z_][A-Za-z0-9_]*|<[^<>\s]{1,32}>)"

# `-D` (optionally `-D=`, optionally with no separating space) then NAME
# then `=` then a `$` value.  \s* spans the folded newline.
#
# The value may be wrapped in shell quotes -- quoting does not protect it
# from make, so `-D FOO='$40'` in a snippet is just as broken.
#
# `$(...)` and `${...}` are excluded: those are make-variable references,
# not literal $-hex, and Makefile is in scope.
DOLLAR_DEFINE = re.compile(
    r"(?<![A-Za-z0-9_])-D=?\s*(" + NAME + r")\s*=\s*['\"]?\$(?![({])"
)

# cl65's spelling, but only where it is being *used* (a NAME= follows).
ASM_DEFINE = re.compile(r"--asm-define[\s=]+(" + NAME + r")\s*=")

# Leading comment markers to strip before folding: ca65 `;`, cfg/make `#`,
# and markdown blockquote `>`.
COMMENT_PREFIX = re.compile(r"^\s*[;#>]+\s?")


def fold(text):
    """Strip per-line comment markers and fold to a single line.

    Returns (folded_text, offsets) where offsets[i] is the 1-based source
    line number that folded character i came from, so a match can be
    reported at the line where the snippet *starts*.
    """
    parts, offsets = [], []
    for lineno, line in enumerate(text.splitlines(), start=1):
        stripped = COMMENT_PREFIX.sub("", line)
        chunk = stripped + " "
        parts.append(chunk)
        offsets.extend([lineno] * len(chunk))
    return "".join(parts), offsets


def check(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except (OSError, IOError) as exc:
        print("check_doc_snippets: cannot read %s: %s" % (path, exc))
        return [("?", "unreadable", str(exc))]

    folded, offsets = fold(text)
    hits = []
    for rx, kind, fix in (
        (DOLLAR_DEFINE, "$-hex define",
         "use the 0x form, e.g. -D %s=0xC000"),
        (ASM_DEFINE, "--asm-define",
         "use ca65's -D, e.g. -D %s=0xC000"),
    ):
        for m in rx.finditer(folded):
            line = offsets[m.start()] if m.start() < len(offsets) else "?"
            name = m.group(1)
            hits.append((line, kind, fix % name))
    return sorted(hits, key=lambda h: (h[0] if isinstance(h[0], int) else 0))


def main(argv):
    paths = argv[1:]
    if not paths:
        print(__doc__.strip())
        return 2

    total = 0
    kinds = set()
    for path in paths:
        for line, kind, fix in check(path):
            total += 1
            kinds.add(kind)
            print("%s:%s: FAIL [%s] -- %s" % (path, line, kind, fix))

    if total:
        print()
        print("%d broken consumer snippet(s)." % total)
        if "$-hex define" in kinds:
            print("  $-hex define: a $-value is silently wrong when it is "
                  "passed through make -- which is how these snippets are "
                  "documented to be used. Make expands `$40` to 0 before ca65 "
                  "ever sees it, and shell quotes in the snippet do not "
                  "prevent that. Neither the §8.1 page-alignment assert nor "
                  "zp_config.s catches the resulting zero. (A direct, quoted "
                  "`ca65 -D FOO='$40'` is fine; the 0x form is fine "
                  "everywhere.)")
        if "--asm-define" in kinds:
            print("  --asm-define: cl65's spelling; a direct ca65 invocation "
                  "rejects it (\"ca65: Unknown option: --asm-define\"). Use "
                  "ca65's -D.")
        print("See c64-lib-contract SPEC §2 and §8.1 (contract v0.14.2).")
        return 1

    print("check_doc_snippets: %d file(s) clean" % len(paths))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
