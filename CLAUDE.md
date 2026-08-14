# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

X25519 (RFC 7748) for the Commodore 64 in ca65 6502 assembly, targeting a stock C64 + 1750 REU. Differentially validated against `pyca/cryptography` driven through VICE. Designed to be **vendored as source** into downstream C64 projects, not linked as a system library.

Current release: **v0.3.0** (full CT certification, L1–L24 closed). Public `fe25519_*` / `x25519_*` API is semver-locked.

## Build / test commands

```
make                 # build build/x25519.prg (standalone test harness)
make clean
make lib             # build build/lib/libx25519.a + .o + x25519.inc + cfg
make lib-verify      # smoke-test libx25519.a via tests/lib_linkage stub
make lib-verify-shared  # linkage matrix for the four SHARED_* deferral builds (R6)

make test            # python3 tools/ref_x25519.py (no VICE, fastest)
make test-vice       # subset: mul38, fe25519, fe_mul/sqr stress, ct_square_cycles, reduce_wide_carry
make test-slow       # full suite (requires VICE + built .prg)
```

Single test run: `python3 tools/<name>.py [--slow]`. Benches live in `tools/bench_*.py` and are NOT run by `make test-slow`.

## Toolchain

- `ca65` / `ld65` / `ar65` (cc65 suite) — `brew install cc65`
- VICE emulator for `make test-vice` / `make test-slow` — `brew install vice`
- Python 3 + `pyca/cryptography` + `c64-test-harness` package
- macOS: zsh, BSD `sed`/`grep`. `sha256sum` is not installed — use `shasum -a 256`.

## Architecture (big picture)

The library is 6 ca65 `.o` modules (no `main.o`, which is the BASIC stub / test harness — downstream supplies its own entry point). Module layout in `src/`:

```
x25519.s       Montgomery ladder, x25519_clamp / _scalarmult / _base
fe25519.s     Field arithmetic mod p = 2^255 - 19
mul_8x8.s     8x8→16 multiply via quarter-square table (CT)
x25519_init.s sqtab_init, reu_mul_init, REU helpers
data.s        Page-aligned static buffers (CT-critical alignment)
util.s        vic_blank/unblank, bench_start/stop (jiffy clock)
constants.s   .include'd by every .s; never assembled alone
x25519.inc    Public header (imports list + full API docs) — canonical API surface
```

Dep sketch: `x25519.s → fe25519.s → mul_8x8.s` and `x25519.s → x25519_init.s (REU)` and `→ data.s (buffers)`. `util.s` is standalone.

### Hardware contract

- **REU:** 1750 or equivalent, ≥512 KB (library uses 6 banks = 384 KB for mul tables). Library uses REU autoload; leaves `$DF00–$DF0A` ready-for-next-call. Callers that also touch the REU must save/restore.
- **Zero page:** library owns `$14–$7F` while running and does NOT preserve it across calls. (`$FB-$FE` is test-harness-only scratch, local to `main.s` since contract #83 — not part of the library claim.) Hosts can override the ZP layout via `.ifndef` guards in `src/constants.s` (see `docs/LIBRARY.md` §4.2) to compose with sibling crypto libs.
- **No RNG.** Caller generates / stores / zeros keys.

### Constant-time discipline (NON-NEGOTIABLE)

The threat model is network-observable timing against `fe25519_*` and the outer ladder. (`mul_8x8` is boot-only — sole caller `reu_mul_init`'s public table enumeration, no secret inputs — so it has no network-observable exposure; it retains constant-time discipline as the canonical c64-lib-contract §8.3 shared-primitive shape, byte-identical to the chacha owner.) All 24 catalogued leak sites L1–L24 are closed. When touching the hot path:

- **No secret-dependent branches.** Every branch must depend only on **public** loop indices.
- **No `(zp),y` indirect loads on secret operands.** Use direct indexed loads from page-aligned buffers.
- **No zero-skip / early-exit shortcuts** on secret data.
- **32-byte buffer alignment is a CT invariant**, not a perf hint. Field buffers MUST start at `$00/$20/.../$E0` within their page so `,y`-indexed access over 32 bytes never crosses a page boundary. This is hard-asserted in `src/data.s`.
- `fe25519_sqr` carries use an unconditional per-body pending-carry chain + public-indexed end-of-inner ripple (Phase 6 / L19–L22 fix). The diagonal `@diag_prop` path uses the same Phase-6-style unconditional ripple (L23 fix).
- Ladder bit-loop branches use the branchless `cmp/sbc/eor` bit-to-mask idiom (L24 fix).

When you add or change anything CT-relevant, **extend the leak catalogue in `docs/CT_ANALYSIS.md`** — do not assume "probably fine." Re-run `tools/ct_mul_brute_check.py` if the change touches `mul_8x8` / quarter-square. CT regressions are not allowed to be "fixed later" — correctness and CT-cleanliness take precedence over jiffy count.

### Testing posture

- Oracle is `pyca/cryptography`, **never** a repo-local reimplementation — avoids shared-bug failure modes between test code and asm under test.
- Differential tests use reproducible random seeds, hard asserts on every comparison.
- `tools/test_fe_reduce_wide_carry.py` is a permanent regression for a real `$FF`-cascade carry bug caught in v0.1.0 prep (`48092b5`). Don't delete it.
- `tools/test_ct_square_cycles.py` is the CT cycle-count guard for `fe25519_sqr` (≤1 jif spread across structurally distinct inputs). Treat as a CT regression gate, not a perf bench.

## Conventions

### Assembly (`src/*.s`)
- Long `;` header block per file (purpose, invariants, design notes), then `.setcpu "6502"`, `.include "constants.s"`, `.export`/`.import`, `.segment "CODE"`.
- Every public routine wrapped in `.proc name … .endproc` with banner comment for inputs / outputs / clobbers (A / X / Y / ZP / wide).
- Local labels inside `.proc` use `@label` form for per-proc namespacing.
- Naming prefixes: `x25519_*` (public ECDH), `fe25519_*` (field), `mul_*` (multiply), `reu_*` (REU), `sqtab_*` / `mul38_*` / `sqr_*` (tables), `bench_*`, `vic_*`. ZP scratch: `fe_*`, `x25_*`, `poly_*`, `lmul0/1`, `mul_dma_*`. Public buffers: `x25_scalar`, `x25_u`, `x25_result`, `x25_basepoint`.
- Little-endian throughout. Prefer `DEX`/`DEY` for carry-dependent loops (CPX/CPY clobber carry).

### Python (`tools/*.py`)
- Python 3, no required formatter or type hints. No `pytest`/`ruff`/`black` config — tools are run directly via `python3 tools/...`.

### API stability
- `src/x25519.inc` is the canonical API header — copied to `build/lib/x25519.inc` by `make lib`. Keep its `.import` block in sync with library exports. Additive → minor bump; breaking → major bump. `make lib-verify` asserts the expected public symbols are still present.

## Reference docs in repo

- `docs/LIBRARY.md` — integration guide, memory map, public API
- `docs/CT_ANALYSIS.md` — leak catalogue L1–L24, threat model, Phase 6 correctness/CT argument. **Authoritative for any CT discussion.**
- `docs/RELEASE_NOTES_v*.md` — per-release perf + CT posture story

## Workflow notes

- `build/` and `build/lib/` are `.gitignore`d. Don't commit generated artifacts.
- Don't "fix" a failing differential test by editing the test — pyca is the oracle; the asm is wrong until proven otherwise.
- After CT-relevant changes: update `docs/CT_ANALYSIS.md`, re-run `ct_mul_brute_check.py` if `mul_8x8`/quarter-square changed, and run `make test-slow`.
- After perf changes: re-measure via `tools/bench_x25519.py` / `bench_fe_mul.py` / `bench_fe_ops.py` with `jsr vic_blank`, then update jiffy counts in `README.md` and the relevant release notes — don't leave stale numbers.

## Serena MCP

This repo is a Serena-onboarded project (`.serena/` present, memories under `.serena/memories/`). Activation is **not automatic** — call `mcp__serena__activate_project` with this path at the start of a session, then `mcp__serena__initial_instructions` if not already read. Existing memories: `project_overview`, `code_structure`, `tech_stack`, `suggested_commands`, `style_and_conventions`, `ct_and_security_notes`, `task_completion_checklist`.
