# c64-x25519

X25519 Diffie-Hellman (RFC 7748) for the Commodore 64.

An optimized implementation of X25519 / Curve25519 scalar multiplication written in ca65 6502 assembly, targeting the stock C64 with a 1750 REU. Validated against pyca/cryptography via VICE emulator and hardware-compatible test harness.

## Status

**v0.2.0-pre (in progress, 2026-04-14)** — constant-time remediation of
issue [#20](https://github.com/JC-000/c64-x25519/issues/20) is landing in
phases on `master`. Phases 0–5b have fixed 18 of 22 catalogued
secret-dependent branches and page-cross leaks (L1–L18) in `mul_8x8`,
`fe25519_mul`, and `fe25519_sqr`. L19–L22 carry-cascade short-circuits in
`fe25519_sqr` are tracked as **must-fix** follow-ups before the library can
be certified CT-clean for network-facing deployments. See
[`docs/CT_ANALYSIS.md`](docs/CT_ANALYSIS.md) for the full leak inventory,
landing history, and must-fix queue.

**v0.1.0 released 2026-04-13** — [GitHub release](https://github.com/JC-000/c64-x25519/releases/tag/v0.1.0), MIT licensed. The `fe25519_*` and `x25519_*` public API is locked for the v0.1.0 series and follows semver: additive changes bump the minor version, breaking API changes bump the major. `make test-slow` passes all assertions across 11 test suites against pyca/cryptography as the external reference.

## Performance

| Operation | Cost |
|---|---|
| `x25519_scalarmult` (basepoint 9, v0.2.0-pre) | 10,270 jiffies / ~171.2s NTSC / ~205.4s PAL |
| `x25519_scalarmult` (basepoint 9, v0.1.0 baseline) | 9,520 jiffies / ~158.7s NTSC |
| `x25519_scalarmult` (dense u-coord, v0.2.0-pre) | ~11,300 jiffies / ~188.3s NTSC |
| `fe25519_mul` | ~4.0 jiffies/call |
| `fe25519_sqr` | ~4.5 jiffies/call (post-CT) |

All measurements on stock C64 with VIC-II blanked (`jsr vic_blank`). The
v0.2.0-pre number reflects the +7.9 % regression from the branchless CT
rewrites of `mul_8x8` and `fe25519_sqr` and the zero-skip removals in
`fe25519_mul` / `fe25519_sqr`. Correctness is prioritized over performance
until L19–L22 land; Options 2/3/4 in `docs/CT_ANALYSIS.md` §Follow-ups
are queued for a v0.3.0 perf-recovery pass that should claw back most of
the regression. The library remains ~43 % faster than the original
un-optimized baseline (~18,000 jiffies) after v0.2.0-pre.

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

c64-x25519 is designed to be **vendored as source** into downstream C64 projects rather than linked as a system library. Download the v0.1.0 source tarball from the [GitHub release](https://github.com/JC-000/c64-x25519/releases/tag/v0.1.0) and verify its SHA256:

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

- **Partial constant-time (in progress).** v0.2.0-pre has eliminated
  18 of 22 catalogued secret-dependent branches and page-cross leaks
  (L1–L18) in the quarter-square multiply, the field multiply, and the
  field square. Four carry-cascade short-circuits (L19–L22) in
  `fe25519_sqr` remain and are tracked as **must-fix** before a CT-clean
  certification. Until those land, the library is suitable against
  network-observable attackers but **not yet** certified against
  adversaries with fine-grained timing or EM side-channel access. See
  [`docs/CT_ANALYSIS.md`](docs/CT_ANALYSIS.md) for the full inventory.
- **No RNG.** Key generation is the caller's job.
- **X25519 only.** No Ed25519, no X448, no hash functions, no KDF/AEAD/HKDF.

## License

MIT — see [LICENSE](LICENSE).

## Acknowledgments

Phase 1–10 optimization work throughout 2026-03 and 2026-04. Test-hardening infrastructure from the 2026-04-11 audit pass is what enabled the Phase 10 correctness fix to be caught by differential testing before release.
