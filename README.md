# c64-x25519

X25519 Diffie-Hellman (RFC 7748) for the Commodore 64.

An optimized implementation of X25519 / Curve25519 scalar multiplication written in ca65 6502 assembly, targeting the stock C64 with a 1750 REU. Validated against pyca/cryptography via VICE emulator and hardware-compatible test harness.

## Status

**v0.2.0 released 2026-04-19** — [GitHub release](https://github.com/JC-000/c64-x25519/releases/tag/v0.2.0),
MIT licensed. Constant-time remediation of issue
[#20](https://github.com/JC-000/c64-x25519/issues/20) is **complete**
for the `fe25519_*` / `mul_8x8` surface. Phases 0–6 have fixed all
22 catalogued secret-dependent branches and page-cross leaks (L1–L22)
across `mul_8x8`, `fe25519_mul`, and `fe25519_sqr` (including
`fe25519_sqr`'s cross-term carry-cascade path, which now uses an
unconditional per-body pending-carry chain plus a public-indexed
end-of-inner ripple). Every branch in the field-op hot path now
depends only on public loop indices. Hosts can now override the
library's zero-page layout via `.ifndef` guards in `src/constants.s`
to compose with sibling c64 crypto libraries — see
[`docs/LIBRARY.md`](docs/LIBRARY.md) §4.2. Public API is unchanged
from v0.1.0. See [`docs/CT_ANALYSIS.md`](docs/CT_ANALYSIS.md) for
the full leak inventory, threat model, landing history, Phase 6
correctness/CT argument, and remaining non-critical audit items
(the `@diag_prop` diagonal path and the outer `x25519_scalarmult`
ladder/cswap audit).

**v0.1.0 released 2026-04-13** — [GitHub release](https://github.com/JC-000/c64-x25519/releases/tag/v0.1.0), MIT licensed. The `fe25519_*` and `x25519_*` public API is locked for the v0.1.0 series and follows semver: additive changes bump the minor version, breaking API changes bump the major. `make test-slow` passes all assertions across 11 test suites against pyca/cryptography as the external reference.

## Performance

| Operation | Cost |
|---|---|
| `x25519_scalarmult` (basepoint 9, v0.2.0) | 12,485 jiffies / ~208.1s NTSC / ~249.7s PAL |
| `x25519_scalarmult` (basepoint 9, v0.1.0 baseline) | 9,520 jiffies / ~158.7s NTSC |
| `x25519_scalarmult` (dense u-coord, v0.2.0) | ~13,700 jiffies / ~228.3s NTSC |
| `fe25519_mul` | ~4.0 jiffies/call |
| `fe25519_sqr` | ~5.4 jiffies/call (post-CT) |

All measurements on stock C64 with VIC-II blanked (`jsr vic_blank`). The
v0.2.0 figure reflects a +31.1 % regression from the full CT
remediation (Phases 1–6): branchless CT quarter-square in `mul_8x8`,
inline branchless CT mult66 in `fe25519_sqr`, zero-skip removal across
`fe25519_mul` / `fe25519_sqr`, and the unconditional pending-carry
chain that eliminated L19–L22. Correctness was prioritized over
performance throughout: the budget breach is the price of provable
CT-cleanliness. Performance-recovery Options 2/3/4 in
`docs/CT_ANALYSIS.md` §Follow-ups are queued for a v0.3.0 pass that
does not touch correctness invariants. The library remains ~31 %
faster than the original un-optimized baseline (~18,000 jiffies)
after the full v0.2.0 CT remediation.

## Requirements

- **CPU:** 6502 (stock C64)
- **Assembler:** ca65/ld65 (cc65 suite)
- **REU:** 1750 REU or equivalent (6 banks of 64 KB = 384 KB required for mul tables)
- **RAM:** BASIC ROM banked out at startup; library owns specific ZP + RAM regions
- **Test harness:** VICE emulator + `c64-test-harness` Python package

See [`docs/LIBRARY.md`](docs/LIBRARY.md) for the full integration guide, memory map, and public API reference.

## Quick start (upstream test harness)

```
make              # builds build/x25519.prg (standalone test harness)
make test-slow    # full RFC 7748 + differential tests via VICE
```

## Integrating into your own project

c64-x25519 is designed to be **vendored as source** into downstream C64 projects rather than linked as a system library. Both the current v0.2.0 and the previous v0.1.0 tarballs are published; downstream projects can pin to either. Verify the SHA256 before extracting.

**v0.2.0 (current — recommended for new integrations):**

```
curl -LO https://github.com/JC-000/c64-x25519/releases/download/v0.2.0/c64-x25519-v0.2.0.tar.gz
echo "18e573e9c86e81b17f27a0c51becb782a0d0f79f67d30247e0242789c11f22e8  c64-x25519-v0.2.0.tar.gz" | sha256sum -c
mkdir -p vendor && tar -xzf c64-x25519-v0.2.0.tar.gz -C vendor/
```

**v0.1.0 (pinned — for historical or API-identical builds):**

```
curl -LO https://github.com/JC-000/c64-x25519/releases/download/v0.1.0/c64-x25519-v0.1.0.tar.gz
echo "901dd7ebb59e686ae15f7fd9d0b5df82c7cbc8f4516408e1ffaf38ba6bf4c971  c64-x25519-v0.1.0.tar.gz" | sha256sum -c
mkdir -p vendor && tar -xzf c64-x25519-v0.1.0.tar.gz -C vendor/
```

The tarball contains:

- Library source (`src/*.s`) — the 8 `.s` files you assemble with `ca65`
- Public header (`src/x25519.inc`)
- Starter linker config (`cfg/x25519-example.cfg`)
- Integration guide (`docs/LIBRARY.md`) + release notes
- `LICENSE` and `ORIGIN.txt.template` for provenance tracking

Copy `ORIGIN.txt.template` → `ORIGIN.txt` in your vendored copy, fill in the `date_imported` / `local_modifications` fields, then assemble the source with `ca65` from your own build system.

See [`docs/LIBRARY.md`](docs/LIBRARY.md) §4 and §4.1 for the full integration walkthrough.

Upstream maintainers can also reproduce the release tarball locally via `make lib` (which builds `build/lib/libx25519.a` and individual `.o` files for in-tree verification) — this is not what downstream projects consume.

## Testing and audit posture

Cryptographic results are differentially tested against [pyca/cryptography](https://github.com/pyca/cryptography) — not against a repo-local reimplementation. This avoids the class of failure where the test code and the assembly under test share a bug. Random inputs with reproducible seeds, hard assertions on every comparison.

The test suite caught a latent `fe_reduce_wide` carry-propagation bug in v0.1.0 prep (fixed in `48092b5`) via differential testing on a random u-coord that exercised a specific `$FF`-boundary cascade. A permanent regression test prevents recurrence, and an audit of all similar `adc #0` sites in `src/*.s` confirmed zero other instances of the bug pattern.

## Security notes

- **Constant-time field operations (v0.2.0).** All 22
  catalogued secret-dependent branches and page-cross leaks in
  `mul_8x8`, `fe25519_mul`, and `fe25519_sqr` (L1–L22 in
  [`docs/CT_ANALYSIS.md`](docs/CT_ANALYSIS.md)) have been fixed. The
  field-op hot path now contains no data-dependent branches and no
  `(zp),y` indirect-indexed loads on secret operands. Remaining audit
  items are non-critical: the `@diag_prop` diagonal-term path in
  `fe25519_sqr` (tracked as a nice-to-have), and the outer
  `x25519_scalarmult` Montgomery ladder / `fe25519_cswap` audit
  (scalar-bit-dependent branches in the ladder would defeat the
  field-op fixes; currently believed clean — `fe25519_cswap` is
  mask-time-invariant and the ladder visits every scalar bit — but
  not yet formally audited). Suitable against network-observable
  timing attackers through the field-op surface; the ladder/cswap
  audit is the gating item for side-channel deployment certification.
- **No RNG.** Key generation is the caller's job.
- **X25519 only.** No Ed25519, no X448, no hash functions, no KDF/AEAD/HKDF.

## License

MIT — see [LICENSE](LICENSE).

## Acknowledgments

Phase 1–10 optimization work throughout 2026-03 and 2026-04. Test-hardening infrastructure from the 2026-04-11 audit pass is what enabled the Phase 10 correctness fix to be caught by differential testing before release.
