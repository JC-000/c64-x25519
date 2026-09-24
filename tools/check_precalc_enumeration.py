#!/usr/bin/env python3
"""Every page-aligned >=256 B table in the linked output must be §8.4-enumerated.

SPEC v1.2.2 §8.4 requires one LIB_PRECALC_TABLE invocation per table of
256 B or more that is page-aligned (among other triggers). This derives both
sides and compares them, so a table added to the library without an entry
fails the build that added it.

  linked side      in each non-code LIB_X25519_* segment of the lib-verify
                   stub link (map), the names exported by the archive
                   members the map places in that segment (od65), at their
                   linked addresses (labels file). A page-aligned address
                   whose extent -- up to the next such address in the same
                   member, or that member's end (so link fill is never
                   counted) -- is >= 256 B is a table; names sharing an
                   address are one table.
  enumerated side  LIB_X25519_PRECALC_<name>_{SIZE,REGION} exported by any
                   member of the archive, with their values (od65). The
                   prefixed form is present with or without
                   LIB_NO_BARE_EXPORTS.

Each table must have an entry named exactly `x25519_<symbol>`: these are
private tables, and the bare LIB_PRECALC_<name>_* triple is one namespace
across every adopter, so an unprefixed private name collides in a composed
link. The entry's SIZE must equal the linked extent, and its REGION must be
RODATA (assemble-time constants nothing writes).

Scope: only EXPORTED names are seen (od65 lists exports), so a non-exported
page-aligned table would be missed. Every such table in src/ is exported
today (defined in data.s, read from fe25519.s). The map's own export list
is not used: it omits exports nothing references.
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

# Page-aligned >=256 B buffers that are not precalculated tables. Name -> why.
EXEMPT = {
    "mul_dma_lo": "§8.2 staging buffer, rewritten by every row fetch",
    "mul_dma_hi": "§8.2 staging buffer, rewritten by every row fetch",
    "mul_dma_carry": "staging buffer for the doubled-row carry fetch",
}
PREFIX = "x25519_"
REGION_RODATA = 0x03  # PRECALC_REGION_RODATA, src/precalc_table.inc

NAME_RE = re.compile(r'Name: *"([^"]*)"')  # quote-anchored: safe at name length 24
VALUE_RE = re.compile(r'Name: *"([^"]*)"\s*\n\s*Value:\s*0x([0-9A-Fa-f]+)')
SEG_RE = re.compile(r"^(LIB_X25519_\w+)\s+([0-9A-F]{6})\s+([0-9A-F]{6})\s+[0-9A-F]{6}\s+[0-9A-F]{5}$")
MOD_RE = re.compile(r"^\S+\((\S+\.o)\):$")
MODSEG_RE = re.compile(r"^\s+(LIB_X25519_\w+)\s+Offs=([0-9A-F]+)\s+Size=([0-9A-F]+)")


def od65(obj):
    return subprocess.run(["od65", "--dump-exports", str(obj)], capture_output=True, text=True, check=True).stdout


def linked_tables(map_path, labels_path, lib_dir):
    lines = Path(map_path).read_text().splitlines()
    segs = [(n, int(s, 16), int(e, 16)) for n, s, e in
            (m.groups() for m in map(SEG_RE.match, lines) if m) if not n.endswith("CODE")]
    contrib, member = {}, None  # segment -> [(member, offset, size)]
    for line in lines[:lines.index("Segment list:")]:
        m = MOD_RE.match(line)
        if m:
            member = m.group(1)
        elif member and MODSEG_RE.match(line):
            seg, offs, size = MODSEG_RE.match(line).groups()
            contrib.setdefault(seg, []).append((member, int(offs, 16), int(size, 16)))
    addr = {}
    for line in Path(labels_path).read_text().splitlines():
        parts = line.split()
        if len(parts) == 3:
            addr[parts[2].lstrip(".")] = int(parts[1], 16)
    tables = []
    for seg, start, _ in segs:
        for mem, offs, size in contrib.get(seg, ()):
            lo, hi = start + offs, start + offs + size  # this member's bytes
            at = {}
            for n in NAME_RE.findall(od65(Path(lib_dir) / mem)):
                if n in addr and lo <= addr[n] < hi:
                    at.setdefault(addr[n], set()).add(n)
            addrs = sorted(at)
            for i, a in enumerate(addrs):
                extent = (addrs[i + 1] if i + 1 < len(addrs) else hi) - a
                if a & 0xFF == 0 and extent >= 256:
                    tables.append((seg, a, extent, at[a]))
    return segs, tables


def enumerated(archive, lib_dir):
    members = subprocess.run(["ar65", "t", archive], capture_output=True, text=True, check=True).stdout.split()
    entries = {}  # name -> {"SIZE": v, "REGION": v}
    for m in members:
        for n, v in VALUE_RE.findall(od65(Path(lib_dir) / m)):
            mm = re.fullmatch(r"LIB_X25519_PRECALC_(.+)_(SIZE|REGION)", n)
            if mm:
                entries.setdefault(mm.group(1), {})[mm.group(2)] = int(v, 16)
    return entries


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--map", required=True)
    ap.add_argument("--labels", required=True)
    ap.add_argument("--archive", required=True)
    ap.add_argument("--lib-dir", required=True)
    ap.add_argument("--profile", default="?")
    a = ap.parse_args()

    segs, tables = linked_tables(a.map, a.labels, a.lib_dir)
    entries = enumerated(a.archive, a.lib_dir)
    print(f"=== §8.4 enumeration vs linked tables: {a.profile} profile ===")
    # Positive control: an absence check over nothing passes vacuously.
    if not segs or not tables or not entries:
        print(f"FAIL: examined nothing -- {len(segs)} non-code LIB_X25519_* segment(s), "
              f"{len(tables)} candidate table(s), {len(entries)} enumerated entr(ies) "
              f"from {a.map} / {a.labels} / {a.archive}")
        return 1
    fails = []
    for seg, addr, extent, names in tables:
        tag = ", ".join(sorted(names))
        where = f"${addr:04X} {extent:>5} B {seg:<16} {tag}"
        hit = sorted(n for n in names if PREFIX + n in entries)
        if hit:
            e = entries[PREFIX + hit[0]]
            if e.get("SIZE") != extent:
                fails.append(f"{tag}: entry {PREFIX}{hit[0]} declares SIZE {e.get('SIZE')} "
                             f"but the linked table is {extent} B")
            if e.get("REGION") != REGION_RODATA:
                fails.append(f"{tag}: entry {PREFIX}{hit[0]} declares REGION {e.get('REGION')}, "
                             f"expected {REGION_RODATA} (PRECALC_REGION_RODATA)")
            print(f"  ok      {where}")
        elif names & EXEMPT.keys():
            print(f"  exempt  {where} ({EXEMPT[min(names & EXEMPT.keys())]})")
        else:
            bare = sorted(names & entries.keys())
            hint = (f" (entry '{bare[0]}' is unprefixed: private table names must be "
                    f"'{PREFIX}<symbol>', the bare triple is a cross-library namespace)"
                    if bare else "")
            fails.append(f"{tag}: page-aligned table of >=256 B in the {a.profile} link has "
                         f"no LIB_PRECALC_TABLE entry '{PREFIX}{min(names)}' in "
                         f"src/precalc_manifest.s (SPEC v1.2.2 §8.4){hint}")
            print(f"  MISSING {where}")
    for f in fails:
        print(f"FAIL: {f}")
    if fails:
        return 1
    print(f"OK: all {len(tables)} page-aligned >=256 B table(s) in the {a.profile} link are "
          f"enumerated (name, SIZE, REGION) or exempt ({len(entries)} §8.4 entries in the archive)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
