#!/usr/bin/env python3
"""perf_diff.py — Compare the last two rows of docs/perf_history.csv.

Prints a markdown table of the deltas (cycle count, jif, RAM, REU) so a
release reviewer can eyeball whether a change traded perf for memory or
vice versa.

Usage:
    python3 tools/perf_diff.py [--csv path] [--rows old new]

Default --csv is docs/perf_history.csv at the repo root. With no
--rows, compares the last two rows. Pass --rows <old_idx> <new_idx>
(0-based, excluding the header) to compare arbitrary historical pairs.
"""

import argparse
import csv
import os
import sys

PROJECT_ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
DEFAULT_CSV = os.path.join(PROJECT_ROOT, "docs", "perf_history.csv")

# Columns to surface in the diff. Anything else (date, sha) is shown as
# header context only.
NUMERIC_FIELDS = [
    ("scalarmult_cycles",     "scalarmult cycles",      "{:>14,}"),
    ("scalarmult_jif",        "scalarmult jif",         "{:>14}"),
    ("fe25519_mul_jif",       "fe25519_mul jif/call",   "{:>14}"),
    ("fe25519_sqr_jif",       "fe25519_sqr jif/call",   "{:>14}"),
    ("fe25519_mul_a24_jif",   "fe25519_mul_a24 jif",    "{:>14}"),
    ("resident_bytes",        "resident bytes",         "{:>14,}"),
    ("zp_bytes",              "zp bytes",               "{:>14}"),
    ("reu_banks",             "reu banks",              "{:>14}"),
]


def _parse_num(s):
    if s in ("", None):
        return None
    try:
        if "." in s:
            return float(s)
        return int(s)
    except ValueError:
        return s


def _fmt(v, spec):
    if v is None:
        return spec.format("-")
    if isinstance(v, float):
        return spec.format(f"{v:.3f}")
    return spec.format(v)


def _delta(old, new):
    if old is None or new is None:
        return ""
    if not (isinstance(old, (int, float)) and isinstance(new, (int, float))):
        return ""
    d = new - old
    if old == 0:
        pct = ""
    else:
        pct = f" ({d / old * 100:+.1f}%)"
    sign = "+" if d >= 0 else ""
    if isinstance(d, float):
        return f"{sign}{d:.3f}{pct}"
    return f"{sign}{d:,}{pct}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", default=DEFAULT_CSV)
    ap.add_argument("--rows", nargs=2, type=int, metavar=("OLD", "NEW"),
                    help="0-based row indices to compare (default: last two)")
    args = ap.parse_args()

    if not os.path.exists(args.csv):
        print(f"FATAL: {args.csv} not found", file=sys.stderr)
        sys.exit(1)

    with open(args.csv, newline="") as f:
        rows = list(csv.DictReader(f))

    if len(rows) < 2:
        print(f"Need at least 2 rows in {args.csv}; have {len(rows)}.",
              file=sys.stderr)
        sys.exit(1)

    if args.rows is None:
        old_row = rows[-2]
        new_row = rows[-1]
    else:
        oi, ni = args.rows
        old_row = rows[oi]
        new_row = rows[ni]

    old_label = f"{old_row.get('version','?')} ({old_row.get('git_sha','?')[:7]})"
    new_label = f"{new_row.get('version','?')} ({new_row.get('git_sha','?')[:7]})"

    print(f"## perf_diff: {old_label} -> {new_label}")
    print()
    print(f"| metric                | {old_label:<22} | {new_label:<22} | delta |")
    print(f"|-----------------------|{'-'*24}|{'-'*24}|-------|")

    for key, label, spec in NUMERIC_FIELDS:
        old_v = _parse_num(old_row.get(key, ""))
        new_v = _parse_num(new_row.get(key, ""))
        d = _delta(old_v, new_v)
        print(f"| {label:<21} | {_fmt(old_v, spec):>22} | "
              f"{_fmt(new_v, spec):>22} | {d:>5} |")
    print()


if __name__ == "__main__":
    main()
