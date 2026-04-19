# c64-x25519 v0.2.0 — constant-time field operations + host ZP override

**Status:** released 2026-04-19.

## What this is

A security-hardening and composition-oriented minor release of `c64-x25519`. See [`RELEASE_NOTES_v0.1.0.md`](RELEASE_NOTES_v0.1.0.md) for the baseline description of the library, its RFC 7748 correctness posture, the vendoring model, and the v0.1.0 performance envelope. v0.2.0 does **not** change the public API or the on-the-wire results of any routine: it reshapes the timing characteristics of the field-op surface and widens the library's zero-page contract so it can coexist with sibling c64 crypto libraries in a composed host. Per semver this is a minor bump.

## Highlights

- **Constant-time remediation of the field-op surface (issue [#20](https://github.com/JC-000/c64-x25519/issues/20), PR [#21](https://github.com/JC-000/c64-x25519/pull/21)).** All 22 catalogued secret-dependent branches and page-cross leaks (L1–L22) in `mul_8x8`, `fe25519_mul`, and `fe25519_sqr` are fixed. Phase 6 specifically eliminated L19–L22 in `fe25519_sqr`'s cross-term carry-cascade path by replacing opportunistic short-circuits with an unconditional per-body pending-carry chain and a public-indexed end-of-inner ripple. See [`docs/CT_ANALYSIS.md`](CT_ANALYSIS.md) for the full leak inventory, threat model, landing history, and remaining audit items.
- **Host zero-page override capability (PR [#22](https://github.com/JC-000/c64-x25519/pull/22)).** Every library-owned ZP equate in `src/constants.s` is now wrapped in `.ifndef <name>` / `.endif`, matching the convention used by the sibling `c64-ChaCha20-Poly1305` library's `src/lib/constants_lib.s`. Hosts composing multiple c64 crypto libraries can now pre-define their own ZP layout at the link unit and the library will defer to it. See [`docs/LIBRARY.md`](LIBRARY.md) §4.2.
- **Public API unchanged from v0.1.0.** Every `fe25519_*` and `x25519_*` entry point retains its v0.1.0 signature and contract. Only timing characteristics shift.
- **Deliberate +31.1 % scalarmult regression.** Provable CT-cleanliness of the field-op surface was prioritized over raw speed. Performance-recovery work that does not touch correctness invariants is queued for v0.3.0 (see `docs/CT_ANALYSIS.md` §Follow-ups).

## Performance

| Operation | v0.2.0 | v0.1.0 | Δ |
|---|---:|---:|---:|
| `x25519_scalarmult` (basepoint 9) | 12,485 jiffies (~208.1 s NTSC / ~249.7 s PAL) | 9,520 jiffies (~158.7 s NTSC) | +31.1 % |
| `x25519_scalarmult` (dense u-coord) | ~13,700 jiffies (~228.3 s NTSC) | ~10,600 jiffies (~176.7 s NTSC) | +29 % |
| `fe25519_mul` | ~4.0 jiffies/call | ~4.0 jiffies/call | ~flat |
| `fe25519_sqr` | ~5.4 jiffies/call (post-CT) | ~4.1 jiffies/call | +32 % |

All measurements on stock C64 with VIC-II blanked (`jsr vic_blank`). `fe25519_mul` per-call cost is essentially preserved; the scalarmult regression is dominated by the inline branchless CT mult66 rewrite in `fe25519_sqr`, the zero-skip removal across both mul and sqr, and the unconditional per-body pending-carry chain that replaced the L19–L22 short-circuits. The library remains ~31 % faster than the original un-optimized ~18,000-jiffy baseline after the full v0.2.0 CT remediation.

## Public API

**UNCHANGED from v0.1.0.** See the v0.1.0 release notes "Public API" section for the authoritative symbol list; `src/x25519.inc` remains the machine-readable header. No symbols were added, removed, renamed, or reordered. No entry-point contract (ZP inputs/outputs, preserved-register sets, carry/flag invariants) was modified.

## Constant-time posture

v0.1.0 documented that the field-op surface was **not** constant-time. v0.2.0 closes that gap for the 22 catalogued leaks. The leak classes eliminated by Phases 0–6 can be summarized as:

- **Branch on secret zero** (zero-skip fast paths in `fe25519_mul` / `fe25519_sqr` outer and inner, DMA-hybrid paths). Removed: every body now executes unconditionally on every iteration, and `mul_8x8` uses a branchless CT quarter-square.
- **Branch on secret sign / carry shape** (opportunistic carry-cascade short-circuits in `fe25519_sqr`'s cross-term mult66 bodies, L19–L22). Replaced by an unconditional per-body 1-bit pending-carry chain plus a public-indexed end-of-inner ripple (Phase 6, Option F; Option A's full-width ripple was rejected at 31,386 jiffies as unaffordable).
- **Page-cross on secret index** (`(zp),y` indirect-indexed loads where `y` derived from a secret byte). Eliminated via inlining the branchless CT mult66 in `fe25519_sqr` and by restructuring `mul_8x8`'s lookup path to index only on public loop counters.
- **Data-dependent length / trip-count** (early-exit loops in the sqr cross-term). Every inner loop now runs a fixed number of iterations determined by public loop indices alone.

Every branch in the field-op hot path now depends only on public loop indices; no `(zp),y` load in that path uses a secret operand as its index.

**Remaining audit items (not certified as CT for v0.2.0):**

- The `@diag_prop` diagonal-term path in `fe25519_sqr`. Not in the L1–L22 scope. Tracked as a nice-to-have.
- The outer `x25519_scalarmult` Montgomery ladder and `fe25519_cswap`. `fe25519_cswap` is mask-time-invariant and the ladder visits every scalar bit regardless of its value, so the scalar-bit side is not currently believed to leak — but it has not yet been formally audited end-to-end. **This is the gating item for side-channel deployment certification.** Network-facing deployments should treat the ladder audit as pending before claiming full CT certification.

See `docs/CT_ANALYSIS.md` for the full Phase 6 correctness/CT argument and the complete leak catalog.

## Host zero-page override

Every library-owned ZP equate in `src/constants.s` is now wrapped:

```asm
.ifndef ZP_FOO
ZP_FOO = $xx
.endif
```

A composed host that links c64-x25519 alongside (e.g.) c64-ChaCha20-Poly1305, a WireGuard stack, or a TLS record layer can now pre-define a unified ZP map at the link unit. If the host leaves a name undefined, the library keeps its historical v0.1.0 address — so existing downstream vendors are unaffected. The pattern matches the sibling `c64-ChaCha20-Poly1305`'s `src/lib/constants_lib.s`.

This is the ZP-side parallel to the REU-manifest convention already in flight for cross-library composition (see `project_reu_convention` in the upstream memory index): ZP for short-lived scratch and REU banks for long-lived tables are the two shared resources that need negotiation when c64-wireguard or c64-https imports multiple crypto primitives at once.

See [`docs/LIBRARY.md`](LIBRARY.md) §4.2 for the override protocol, naming contract, and example.

## Memory and ZP footprint

Unchanged from v0.1.0 when the host does not override:

- **Zero page:** `$14-$2E`, `$40-$7F`, `$FB-$FE` owned while running
- **RAM:** code from `$0900` upward; page-aligned data pages for field buffers; `$7800-$7BFF` for the quarter-square table
- **REU:** banks 0–5 of 1750 REU (384 KB)

Full memory map in `docs/LIBRARY.md` §7.

## Security notes

- **Field-op surface is CT-clean for L1–L22.** See "Constant-time posture" above. This is the headline posture change vs v0.1.0.
- **Ladder / cswap audit is the gating item** for side-channel deployment certification. Currently believed clean but not formally audited end-to-end.
- **No RNG.** Key generation remains the caller's responsibility.
- **No KDF / HKDF / AEAD.** Raw scalar multiplication only.
- **X25519 only.** No Ed25519, no X448, no hash functions.

## Testing and audit

The test suite posture is unchanged from v0.1.0 — pyca/cryptography remains the external differential reference.

- `make test` — fast Python-only reference self-test (no VICE)
- `make test-slow` — full VICE-driven suite
- `make test-vice` — quick VICE sanity check

At v0.1.0 release time `make test-slow` produced 847 assertions across 11 test files, 0 failures (see v0.1.0 release notes for the per-file breakdown). v0.2.0's `test-slow` counts are unchanged against that baseline for the cryptographic suites themselves; the CT-side addition for this release is the bruteforce tool `tools/ct_mul_brute_check.py`, which exhaustively checks `mul_8x8` for zero-body timing divergence and is invoked out-of-band from `make test-slow` (it is not a VICE test).

## Known limitations

- **REU still mandatory.** No pure-6502 fallback yet. Still planned for a later release.
- **Ladder / cswap audit pending** (see Security notes).
- **`@diag_prop` audit pending** (see Constant-time posture).
- **Interrupts.** Run with `sei` for consistent timing.
- **REU register state.** The library leaves REU registers in a non-default state.

## Migration notes from v0.1.0

**No source change is required for downstream callers.** The public API is identical byte-for-byte. To move a vendored copy from v0.1.0 to v0.2.0:

1. Bump `version:` / `tag:` / `release_notes:` / `tarball_sha256:` in your `ORIGIN.txt`.
2. Re-vendor `src/*.s`, `src/x25519.inc`, `cfg/x25519-example.cfg`, `docs/LIBRARY.md`, `docs/RELEASE_NOTES_v0.2.0.md`, `LICENSE`, and `ORIGIN.txt.template` from the v0.2.0 tarball.
3. Re-assemble with your existing `ca65` invocation.

The only observable behavioural change is the scalarmult timing regression documented in "Performance". If your host pre-defines its own ZP map, you can now use the `.ifndef` override described in `docs/LIBRARY.md` §4.2; otherwise the library keeps its v0.1.0 ZP layout.

## Full commit list (v0.1.0..master)

Reproduce with `git log --format="%h %s" v0.1.0..master`:

- `abcfa7a` Merge pull request #22 from JC-000/feat/zp-ifndef-guards
- `05f2588` feat(lib): wrap ZP equates in .ifndef for host override
- `131d14a` Merge pull request #21 from JC-000/feat/ct-remediation-issue-20
- `acbf2bd` feat(ct): Phase 6 — eliminate L19-L22 carry-cascade leaks in fe25519_sqr
- `8b50f2a` feat(ct): constant-time remediation Phases 0-5b (L1-L18)
- `89d41f9` Merge pull request #19 from JC-000/docs/readme-v010-status
- `ec8f599` docs: README status reflects v0.1.0 released + correct vendoring flow
- `8b98f03` Merge pull request #18 from JC-000/docs/v0.1.0-commit-list
- `bfd563e` docs: fill in v0.1.0 release notes commit list and tarball info

## Tarball

**c64-x25519-v0.2.0.tar.gz** — source distribution (ca65/ld65-compatible assembly + docs + linker config example + LICENSE + ORIGIN.txt.template)

- Size: **49,415 bytes**
- SHA256: `18e573e9c86e81b17f27a0c51becb782a0d0f79f67d30247e0242789c11f22e8`
- Download: https://github.com/JC-000/c64-x25519/releases/download/v0.2.0/c64-x25519-v0.2.0.tar.gz

Downstream vendoring: extract into your project, fill in `ORIGIN.txt` from the template, and run `ca65` against `src/*.s`. See `docs/LIBRARY.md` §4 and §4.1 for the full integration guide, and §4.2 for the new host ZP override protocol.
