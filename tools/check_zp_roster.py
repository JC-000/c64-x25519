#!/usr/bin/env python3
"""Reconcile src/zp_config.s's slot roster against what the build emits.

The pairwise-disjointness and zero-page-fit asserts in src/zp_config.s run
over the roster only (the `x25519_zp_roster` macro). A slot declared in
src/zp_config.s outside it would be exported yet unchecked, and uncounted
in LIB_X25519_ZP_USAGE_BYTES. This tool makes that fail by name.

Scope: it reads src/zp_config.s only. A slot defined in any other file
(constants.s, another TU) is not seen.

It re-assembles src/zp_config.s with `-g` and the build's own defines,
reads the debug symbols (roster slots carry an `x25519_zp_size_<slot>`
marker), and checks:

  1. the roster is non-empty and every roster slot is defined;
  2. zp_config.s defines no other symbol (control symbols and names the
     build passed with -D excepted) -- i.e. no slot outside the roster;
  3. the shipped zp_config.o exports exactly the roster slots, at the
     same addresses (or nothing, in a ZP_CONFIG_NO_EXPORTS build);
  4. LIB_X25519_ZP_USAGE_BYTES in the shipped lib_manifest.o equals the
     sum of the roster sizes.

Usage:
  check_zp_roster.py --defines "<ca65 -D flags>" --zp-obj <zp_config.o>
                     --manifest-obj <lib_manifest.o> [--src src/zp_config.s]
"""
import argparse
import os
import re
import shlex
import subprocess
import sys
import tempfile

MARKER = "x25519_zp_size_"
# Symbols zp_config.s defines that are not slots.
CONTROL = {"ZP_CONFIG_S_INCLUDED", "x25519_zp_bytes", "x25519_zp_i", "x25519_zp_j"}


def od65_records(flag, obj):
    out = subprocess.run(["od65", flag, obj], check=True,
                         capture_output=True, text=True).stdout
    recs = []
    for block in re.split(r"^\s*Index:", out, flags=re.M)[1:]:
        name = re.search(r'Name:\s*"([^"]*)"', block)
        value = re.search(r"Value:\s*0x([0-9A-Fa-f]+)", block)
        if name:
            recs.append((name.group(1), int(value.group(1), 16) if value else None))
    return recs


def define_names(defines):
    names = set()
    toks = shlex.split(defines)
    i = 0
    while i < len(toks):
        t = toks[i]
        arg = None
        if t == "-D" and i + 1 < len(toks):
            arg = toks[i + 1]
            i += 1
        elif t.startswith("-D"):
            arg = t[2:]
        if arg:
            names.add(arg.split("=", 1)[0])
        i += 1
    return names


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--defines", default="")
    ap.add_argument("--zp-obj", required=True)
    ap.add_argument("--manifest-obj", required=True)
    ap.add_argument("--src", default="src/zp_config.s")
    a = ap.parse_args()

    fails = []
    with tempfile.TemporaryDirectory() as td:
        obj = os.path.join(td, "zp_config_g.o")
        cmd = ["ca65", "-g"] + shlex.split(a.defines) + ["-o", obj, a.src]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            print("FAIL: check_zp_roster: re-assembling %s failed:\n%s"
                  % (a.src, r.stderr.strip()))
            return 1
        syms = dict(od65_records("--dump-dbgsyms", obj))

    roster = {n[len(MARKER):]: v for n, v in syms.items() if n.startswith(MARKER)}
    if not roster:
        print("FAIL: check_zp_roster: no x25519_zp_size_* markers in %s -- "
              "the roster is empty or unreadable, so nothing below would be checked" % a.src)
        return 1

    for slot in sorted(roster):
        if syms.get(slot) is None:
            fails.append("roster slot %s has no definition in %s" % (slot, a.src))

    passed = define_names(a.defines)
    for name, val in sorted(syms.items()):
        if (name.startswith(MARKER) or name in roster or name in CONTROL
                or name in passed):
            continue
        fails.append(
            "%s defines '%s' (= $%02X) outside the x25519_zp_roster: it is "
            "exported or used without the pairwise-disjointness check and "
            "without counting in LIB_X25519_ZP_USAGE_BYTES -- declare it as "
            "a roster line" % (a.src, name, val if val is not None else 0))

    exports = dict(od65_records("--dump-exports", a.zp_obj))
    no_exports = "ZP_CONFIG_NO_EXPORTS" in passed
    if no_exports:
        if exports:
            fails.append("ZP_CONFIG_NO_EXPORTS build, yet %s exports %s"
                         % (a.zp_obj, ", ".join(sorted(exports))))
    else:
        for name in sorted(set(exports) - set(roster)):
            fails.append("%s exports ZP slot '%s' ($%02X), which is not in the "
                         "x25519_zp_roster" % (a.zp_obj, name, exports[name]))
        for name in sorted(set(roster) - set(exports)):
            fails.append("roster slot '%s' is not exported by %s (SPEC §2)"
                         % (name, a.zp_obj))
        for name in sorted(set(roster) & set(exports)):
            if exports[name] != syms.get(name):
                fails.append("%s exports %s = $%02X but the same defines give $%02X"
                             % (a.zp_obj, name, exports[name], syms.get(name)))

    man = dict(od65_records("--dump-exports", a.manifest_obj))
    total = sum(roster.values())
    usage = man.get("LIB_X25519_ZP_USAGE_BYTES")
    if usage != total:
        fails.append("LIB_X25519_ZP_USAGE_BYTES = %s in %s, but the roster sums to %d"
                     % (usage, a.manifest_obj, total))

    if fails:
        for f in fails:
            print("FAIL: check_zp_roster: " + f)
        return 1
    print("OK: ZP roster: %d slots, %d bytes = LIB_X25519_ZP_USAGE_BYTES; %s"
          % (len(roster), total,
             "exports suppressed (ZP_CONFIG_NO_EXPORTS), so the export "
             "reconciliation is not applicable" if no_exports
             else "zp_config.o exports exactly the roster"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
