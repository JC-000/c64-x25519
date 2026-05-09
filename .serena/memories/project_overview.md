# c64-x25519 — Project Overview

## Purpose
X25519 Diffie-Hellman (RFC 7748) for the Commodore 64. Optimized
Curve25519 scalar multiplication in ca65 6502 assembly, targeting a
stock C64 + 1750 REU. Differentially validated against
pyca/cryptography through VICE.

Upstream: `JC-000/c64-x25519` (private GitHub repo).

## Status
- **v0.1.0** released 2026-04-13 (MIT). Public `fe25519_*` / `x25519_*`
  API is semver-locked for the 0.1.x line.
- **v0.2.0 candidate** (in progress as of 2026-04-14): constant-time
  remediation of issue #20 for `fe25519_*` / `mul_8x8`. Phases 0–6
  complete — all 22 catalogued secret-dependent branches / page-cross
  leaks (L1–L22) fixed. The field-op hot path has no data-dependent
  branches and no `(zp),y` loads on secret operands.
- CT work imposed a measured ~31% regression on `x25519_scalarmult`
  (9,520 → 12,485 jiffies on basepoint 9). Correctness prioritized over
  speed. Performance recovery options 2/3/4 queued for v0.3.0.
- Outstanding audit items (non-critical): `fe25519_sqr @diag_prop`
  diagonal path, and the outer `x25519_scalarmult` Montgomery ladder /
  `fe25519_cswap` audit. The ladder/cswap audit is the gating item for
  any formal side-channel deployment claim.

## Performance (stock C64, VIC-II blanked)
| Operation | Cost |
|---|---|
| `x25519_scalarmult` (basepoint, v0.2.0 cand.) | 12,485 jiffies / ~208.1s NTSC |
| `x25519_scalarmult` (basepoint, v0.1.0) | 9,520 jiffies / ~158.7s NTSC |
| `x25519_scalarmult` (dense u, v0.2.0 cand.) | ~13,700 jiffies |
| `fe25519_mul` | ~4.0 jiffies/call |
| `fe25519_sqr` | ~5.4 jiffies/call (post-CT) |

## Scope / non-goals
- X25519 only. No Ed25519, no X448, no hashes, no KDF/AEAD/HKDF.
- No RNG. Key generation is the caller's responsibility.
- Designed to be **vendored as source** into downstream C64 projects,
  not linked as a system library. `make lib` produces a reproducible
  library archive for in-tree verification.

## Key references
- `README.md` — top-level status and quickstart
- `docs/LIBRARY.md` — integration guide, memory map, public API
- `docs/CT_ANALYSIS.md` — full CT leak inventory, threat model, Phase 6
  correctness/CT argument
- `docs/RELEASE_NOTES_v0.1.0.md`
- `src/x25519.inc` — public header with full API documentation
