# Style and Conventions

## Assembly (`src/*.s`)
- **Assembler:** ca65 (cc65 suite). `.setcpu "6502"` at top of every
  compiled `.s` file. `constants.s` is `.include`'d, never assembled
  alone.
- **File header:** a long `;` comment block describing the module's
  purpose, key invariants, and any relevant design notes. Followed by
  `.setcpu`, `.include "constants.s"`, then `.export` / `.import`
  blocks, then `.segment "CODE"`.
- **Proc structure:** every public routine is wrapped in
  `.proc name ... .endproc`. A `;` banner comment above each `.proc`
  documents purpose, inputs, outputs, and clobbers (A / X / Y / ZP /
  wide).
- **Label convention:** local labels inside a `.proc` use the `@label`
  form (e.g. `@loop`, `@diag_prop`). This gives each `.proc` its own
  local-label namespace.
- **Naming:**
  - Library prefixes: `x25519_*` (public ECDH), `fe25519_*` (field
    arith), `mul_*` (8×8 multiply), `reu_*` (REU helpers),
    `sqtab_*` / `mul38_*` / `sqr_*` (lookup tables), `bench_*`
    (timing), `vic_*` (VIC-II helpers).
  - ZP scratch: `fe_*`, `x25_*`, `poly_*`, `lmul0/1`, `mul_dma_*`.
  - Fixed public buffers: `x25_scalar`, `x25_u`, `x25_result`,
    `x25_basepoint`.
- **Endianness:** little-endian throughout (matches 6502 carry
  propagation and X25519 wire format).
- **Loop idiom:** prefer `DEX`/`DEY` for carry-dependent loops because
  `CPX`/`CPY` clobber carry.
- **Buffer alignment:** 32-byte field buffers MUST start at one of
  `$00/$20/$40/$60/$80/$A0/$C0/$E0` within their page so that
  `,y`-indexed access over a full 32 bytes never crosses a page
  boundary. This is a CT invariant (not just a perf hint) — page
  crosses would leak timing.
- **ZP contract:** the library owns `$14–$7F` and `$FB–$FE` while
  running and does NOT preserve them across calls. Callers save/restore
  themselves.
- **REU contract:** library uses REU autoload and leaves
  `$DF00–$DF0A` in a ready-for-next-call state. Callers that also
  touch the REU must save/restore the register set.

## Constant-time discipline (v0.2.0+)
- **No secret-dependent branches** in the `fe25519_*` / `mul_8x8` hot
  path. All branches must depend only on **public** loop indices.
- **No `(zp),y` indirect loads on secret operands.** Use direct
  indexed loads from page-aligned buffers.
- **No zero-skip / early-exit optimizations** on secret data.
- Carries in `fe25519_sqr` use an unconditional per-body pending-carry
  chain plus a public-indexed end-of-inner ripple (the L19–L22 fix).
- All leak-fix rationale is tracked in `docs/CT_ANALYSIS.md` under
  catalogue ids L1–L22. When adding new code to the hot path, extend
  that catalogue — do not assume "probably fine."

## Public API stability
- `fe25519_*` and `x25519_*` surface is semver-locked for v0.1.x:
  additive → minor bump; breaking → major bump.
- `src/x25519.inc` is the canonical API header; it's copied into
  `build/lib/x25519.inc` by `make lib`. Keep the header's `.import`
  block in sync with library exports.

## Python (`tools/*.py`, `test/*.py`)
- **Python 3.** No type hints required; no mandatory formatter.
- External reference is **pyca/cryptography**, never a repo-local
  reimplementation — this avoids test/asm shared-bug failure modes.
- Differential tests use reproducible random seeds, hard assertions
  on every comparison. The v0.1.0 `fe_reduce_wide` carry bug was
  caught exactly this way (see `test_fe_reduce_wide_carry.py`).
- VICE-based tests launch the emulator, drop a `.prg`, and compare
  outputs byte-exact against the oracle.
- Bench scripts (`bench_*.py`) are separate from test scripts — they
  are not run by `make test-slow`.

## Comments / docs
- Long header comments in `.s` files are expected, especially around
  CT-critical routines. Per-line commentary is used sparingly and only
  where the WHY is not obvious.
- Design rationale and threat model live in `docs/CT_ANALYSIS.md`, not
  inline.
