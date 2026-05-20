#!/usr/bin/env python3
"""bench_record.py — Run both benches and append a row to perf_history.csv.

Pipeline:
  1. Build (make) so labels.txt + .prg are current.
  2. Parse LIB_X25519_RESIDENT_BYTES / LIB_X25519_ZP_USAGE_BYTES /
     LIB_X25519_REU_BANKS_USED + LIB_VERSION_* from build/labels.txt.
  3. Run tools/bench_x25519.py --json <tmp>
  4. Run tools/bench_fe_ops.py  --json <tmp>
  5. Append a single row to docs/perf_history.csv.

The CSV is intentionally human-readable + commit-friendly. tools/perf_diff.py
consumes adjacent rows to print a markdown trade-off table.

Usage:
    python3 tools/bench_record.py [--skip-scalarmult] [--skip-fe-ops]
                                  [--csv path] [--note "free-form text"]

--skip-scalarmult lets you record an fe-ops-only row when the long
scalarmult bench isn't worth re-running (e.g. table-layout experiments
that don't touch the ladder). --skip-fe-ops is the inverse. Either way
the script refuses to skip BOTH benches.
"""

import argparse
import csv
import datetime as dt
import json
import os
import subprocess
import sys
import tempfile

PROJECT_ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
LABELS_PATH = os.path.join(PROJECT_ROOT, "build", "labels.txt")
DEFAULT_CSV = os.path.join(PROJECT_ROOT, "docs", "perf_history.csv")

CSV_FIELDS = [
    "date",
    "git_sha",
    "version",
    "resident_bytes",
    "zp_bytes",
    "reu_banks",
    "scalarmult_cycles",
    "scalarmult_jif",
    "fe25519_mul_jif",
    "fe25519_sqr_jif",
    "fe25519_mul_a24_jif",
    "fe25519_add_jif",
    "fe25519_sub_jif",
    "fe25519_reduce_final_jif",
    "fe25519_cswap_jif",
    "fe25519_inv_jif",
    "note",
]


def _read_labels(path):
    """Parse ld65 label file. Returns {name: int_value} for the symbols
    we care about; raises if any are missing."""
    wanted = {
        "LIB_VERSION_MAJOR", "LIB_VERSION_MINOR", "LIB_VERSION_PATCH",
        "LIB_X25519_RESIDENT_BYTES", "LIB_X25519_ZP_USAGE_BYTES",
        "LIB_X25519_REU_BANKS_USED",
    }
    found = {}
    with open(path) as f:
        for line in f:
            # Format: "al C:HHHHHH .symbolname"
            parts = line.split()
            if len(parts) != 3 or not parts[1].startswith("C:"):
                continue
            sym = parts[2].lstrip(".")
            if sym in wanted:
                found[sym] = int(parts[1][2:], 16)
    missing = wanted - found.keys()
    if missing:
        raise RuntimeError(
            f"missing manifest equates in {path}: {sorted(missing)}")
    return found


def _git_sha_with_dirty():
    sha = subprocess.run(
        ["git", "rev-parse", "--short=12", "HEAD"],
        cwd=PROJECT_ROOT, capture_output=True, text=True, check=True,
    ).stdout.strip()
    dirty = subprocess.run(
        ["git", "status", "--porcelain"],
        cwd=PROJECT_ROOT, capture_output=True, text=True, check=True,
    ).stdout.strip()
    return sha + ("-dirty" if dirty else "")


def _popcount(n):
    c = 0
    while n:
        c += n & 1
        n >>= 1
    return c


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", default=DEFAULT_CSV)
    ap.add_argument("--skip-scalarmult", action="store_true")
    ap.add_argument("--skip-fe-ops", action="store_true")
    ap.add_argument("--note", default="",
                    help="free-form text appended to the row")
    args = ap.parse_args()

    if args.skip_scalarmult and args.skip_fe_ops:
        print("FATAL: refusing to record an empty row "
              "(both benches skipped)", file=sys.stderr)
        sys.exit(2)

    # 1. Build.
    print("Building...")
    r = subprocess.run(["make"], cwd=PROJECT_ROOT,
                       capture_output=True, text=True)
    if r.returncode != 0:
        print(f"Build failed:\n{r.stderr}", file=sys.stderr)
        sys.exit(1)

    # 2. Manifest equates.
    eq = _read_labels(LABELS_PATH)
    sha = _git_sha_with_dirty()
    version = (f"v{eq['LIB_VERSION_MAJOR']}.{eq['LIB_VERSION_MINOR']}"
               f".{eq['LIB_VERSION_PATCH']}")

    row = {f: "" for f in CSV_FIELDS}
    row["date"] = dt.date.today().isoformat()
    row["git_sha"] = sha
    row["version"] = version
    row["resident_bytes"] = eq["LIB_X25519_RESIDENT_BYTES"]
    row["zp_bytes"] = eq["LIB_X25519_ZP_USAGE_BYTES"]
    row["reu_banks"] = _popcount(eq["LIB_X25519_REU_BANKS_USED"])
    row["note"] = args.note

    with tempfile.TemporaryDirectory() as td:
        # 3. scalarmult.
        if not args.skip_scalarmult:
            sm_json = os.path.join(td, "scalarmult.json")
            print("\nRunning bench_x25519.py (scalarmult)...")
            r = subprocess.run(
                ["python3", "tools/bench_x25519.py", "--json", sm_json],
                cwd=PROJECT_ROOT)
            if r.returncode != 0:
                print("scalarmult bench failed", file=sys.stderr)
                sys.exit(1)
            with open(sm_json) as f:
                sm = json.load(f)
            row["scalarmult_cycles"] = sm["scalarmult_cycles"]
            row["scalarmult_jif"] = f"{sm['scalarmult_jif']:.1f}"

        # 4. fe-ops.
        if not args.skip_fe_ops:
            fe_json = os.path.join(td, "fe_ops.json")
            print("\nRunning bench_fe_ops.py (per-op batch)...")
            r = subprocess.run(
                ["python3", "tools/bench_fe_ops.py", "--json", fe_json],
                cwd=PROJECT_ROOT)
            if r.returncode != 0:
                print("fe-ops bench failed", file=sys.stderr)
                sys.exit(1)
            with open(fe_json) as f:
                fo = json.load(f)
            for k in ("fe25519_mul_jif", "fe25519_sqr_jif",
                      "fe25519_mul_a24_jif", "fe25519_add_jif",
                      "fe25519_sub_jif", "fe25519_reduce_final_jif",
                      "fe25519_cswap_jif", "fe25519_inv_jif"):
                row[k] = f"{fo[k]:.3f}" if k != "fe25519_inv_jif" \
                    else f"{fo[k]:.1f}"

    # 5. Append.
    new_file = not os.path.exists(args.csv)
    os.makedirs(os.path.dirname(args.csv), exist_ok=True)
    with open(args.csv, "a", newline="") as f:
        w = csv.DictWriter(f, fieldnames=CSV_FIELDS)
        if new_file:
            w.writeheader()
        w.writerow(row)

    print(f"\nAppended row to {args.csv}:")
    print(f"  {version} ({sha})")
    print(f"  resident={row['resident_bytes']}B  zp={row['zp_bytes']}B  "
          f"reu_banks={row['reu_banks']}")
    if row["scalarmult_cycles"]:
        print(f"  scalarmult: {row['scalarmult_cycles']:,} cycles "
              f"/ {row['scalarmult_jif']} jif")


if __name__ == "__main__":
    main()
