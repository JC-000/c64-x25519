# c64-x25519 — Project Overview

## Purpose
X25519 Diffie-Hellman (RFC 7748) for the Commodore 64. Optimized
Curve25519 scalar multiplication in ca65 6502 assembly, targeting a
stock C64 + 1750 REU. Differentially validated against
pyca/cryptography through VICE; hardware-confirmed on Ultimate 64
Elite.

Upstream: `JC-000/c64-x25519` (private GitHub repo).

## Status
- **v0.1.0** released 2026-04-13 (MIT). Baseline release; public
  `fe25519_*` / `x25519_*` API semver-locked.
- **v0.2.0** released 2026-04-19 — full CT remediation of the
  `fe25519_*` / `mul_8x8` field-op surface (L1–L22 closed), plus
  `.ifndef` host-overridable ZP layout for sibling-library composition.
  ~31% slower than v0.1.0 (9,520 → 12,485 jiffies on basepoint 9).
- **v0.3.0** released 2026-04-19 — perf recovery + full CT
  certification. Phases 1–3 of `fe25519_sqr` hot-path rewrite
  (-1,746 jif), L23a/b/c `@diag_prop` audit closure (+1,330 jif),
  L24a/b ladder bit-loop branchless rewrite (+0 jif). Net **12,070
  jiffies** on basepoint 9 (~201 s NTSC), -3.3% vs v0.2.0, +26.8% vs
  v0.1.0. **All L1–L24 timing leaks closed.**
- **Post-v0.3.0 (master, unreleased)** — two state-contract defences
  layered on top of the timing-leak posture (separate class — these are
  correctness fixes, not CT fixes):
  - **S1 (PR #35, 2026-05-06)**: `x25519_scalarmult` wrapped in
    `php / sei … plp`. Library-enforced IRQ mask for the full call.
  - **S2 (PR #36, 2026-05-08, issue #33 fix)**: defensive REU register
    init at scalarmult entry — zero `reu_reu_lo` ($DF04) and
    `reu_addr_ctrl` ($DF0A). Closes the caller-REU-residue vector
    that produced wrong-but-deterministic results in c64-https TLS
    composition. ~6 cycles, hardware-confirmed on U64E (4/4
    adversarial cases produce canonical RFC 7748 vec-1 hash).

## Performance (stock C64, VIC-II blanked)
| Operation | Cost |
|---|---|
| `x25519_scalarmult` (basepoint, v0.3.0) | 12,070 jiffies / ~201s NTSC |
| `x25519_scalarmult` (basepoint, v0.2.0) | 12,485 jiffies / ~208s NTSC |
| `x25519_scalarmult` (basepoint, v0.1.0) | 9,520 jiffies / ~159s NTSC |
| `fe25519_mul` | ~4.0 jiffies/call |
| `fe25519_sqr` | ~6.36 jiffies/call (v0.3.0) |

S1+S2 state-contract defences cost <0.001% of the budget — below
measurement noise.

## Scope / non-goals
- X25519 only. No Ed25519, no X448, no hashes, no KDF/AEAD/HKDF.
- No RNG. Key generation is the caller's responsibility.
- Designed to be **vendored as source** into downstream C64 projects
  (e.g. c64-https, c64-wireguard), not linked as a system library.
  `make lib` produces a reproducible library archive for in-tree
  verification.

## Key references
- `README.md` — top-level status and quickstart
- `CLAUDE.md` — onboarding for Claude Code agents (uncommitted by
  project convention)
- `docs/LIBRARY.md` — integration guide, memory map, public API,
  caller contracts
- `docs/CT_ANALYSIS.md` — leak inventory L1–L24, threat model, Phase 6
  correctness/CT argument, S1/S2 state-contract defences section
- `docs/RELEASE_NOTES_v{0.1.0,0.2.0,0.3.0}.md`
- `src/x25519.inc` — public header with full API documentation
- `tools/test_issue33_adversarial.py` — adversarial REU-state regression
  harness (8 cases, VICE + U64E backends)
