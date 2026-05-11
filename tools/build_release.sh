#!/bin/bash
# tools/build_release.sh -- build a reproducible source tarball for a tagged release.
#
# Usage:
#   tools/build_release.sh <tag>
#   e.g. tools/build_release.sh v0.4.0
#
# Output: c64-x25519-<tag>.tar.gz in the repo root, plus the byte
# size and SHA256 printed to stdout. The script is location-aware
# and can be invoked from anywhere.
#
# Determinism: git archive is byte-deterministic for a given commit,
# and `gzip -n` drops the gzip timestamp/filename header. The same tag
# therefore always produces a byte-identical tarball. Re-running this
# script must reproduce the SHA256 recorded in the matching
# docs/RELEASE_NOTES_<tag>.md.
#
# File list: the canonical v0.4.0+ vendoring set per
# docs/RELEASE_NOTES_v0.4.0.md. For older tags (v0.1.0 / v0.2.0 /
# v0.3.0) the file list differed (no CT_ANALYSIS.md before v0.2.0,
# etc.) — historical tarball SHAs from those releases cannot be
# reproduced by this script. New releases (v0.4.0 and beyond) use
# this recipe.
#
# Make convenience target: `make dist VERSION=v0.4.0`.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

TAG="${1:-}"
if [[ -z "$TAG" ]]; then
  echo "usage: $0 <tag>" >&2
  exit 1
fi

if ! git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "tag '$TAG' not found (run 'git fetch --tags' to refresh)" >&2
  exit 1
fi

NOTES="docs/RELEASE_NOTES_${TAG}.md"
if ! git cat-file -e "${TAG}:${NOTES}" 2>/dev/null; then
  echo "release notes '${NOTES}' not present at tag '${TAG}'" >&2
  exit 1
fi

OUT="c64-x25519-${TAG}.tar.gz"

git archive \
  --prefix="c64-x25519-${TAG}/" \
  --format=tar \
  "$TAG" \
  src/constants.s src/data.s src/fe25519.s src/main.s src/mul_8x8.s \
  src/util.s src/x25519.s src/x25519_init.s src/x25519.inc \
  cfg/x25519-example.cfg \
  docs/LIBRARY.md docs/CT_ANALYSIS.md "$NOTES" \
  LICENSE ORIGIN.txt.template \
  | gzip -n -9 > "$OUT"

SIZE=$(wc -c < "$OUT" | tr -d ' ')
SHA=$(shasum -a 256 "$OUT" | cut -d' ' -f1)

echo "Built ${OUT}"
echo "  Size:   ${SIZE} bytes"
echo "  SHA256: ${SHA}"
