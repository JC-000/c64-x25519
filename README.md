# c64-x25519

X25519 Diffie-Hellman (RFC 7748) for the Commodore 64.

An optimized implementation of X25519 / Curve25519 scalar multiplication written in ca65 6502 assembly, targeting the stock C64 with a 1750 REU. Validated against pyca/cryptography via VICE emulator and hardware-compatible test harness.

## Status

**v0.5.0 in preparation — c64-lib-contract §1/§2/§3/§5 adoption.**
A library-ingestion release with no CT or correctness changes.
v0.5.0 ships the four sections of [c64-lib-contract](https://github.com/JC-000/c64-lib-contract)
that consumer projects (c64-https, c64-wireguard) need to compose
c64-x25519 alongside sibling crypto libraries without source
patching:

- **§1 Version identification** ([#45](https://github.com/JC-000/c64-x25519/issues/45) / [#47](https://github.com/JC-000/c64-x25519/pull/47)): new
  `src/lib_version.s` exports `LIB_VERSION_MAJOR/_MINOR/_PATCH`
  and `LIB_ABI_VERSION` for assemble-time consumer guards.
- **§2 Zero-page contract** ([#44](https://github.com/JC-000/c64-x25519/issues/44) / [#48](https://github.com/JC-000/c64-x25519/pull/48)): every consumer-
  overridable ZP slot moved to a dedicated `src/zp_config.s` with
  `.exportzp` declarations, so consumer modules can `.importzp`
  individual slots without dragging in BASIC/KERNAL hardware
  equates via `constants.s`.
- **§3 REU layout contract** ([#43](https://github.com/JC-000/c64-x25519/issues/43) / [#49](https://github.com/JC-000/c64-x25519/pull/49)): new `src/reu_config.s`
  exports `X25519_REU_BANK` (default `0`) and `X25519_REU_OFFSET`
  (default `$0000`), `.ifndef`-guarded for `ca65 -D` override.
  13 bank-immediate sites in `x25519_init.s` rewritten to
  `+X25519_REU_BANK` so consumers can relocate the six-bank mul-
  table claim without source patches.
- **§5 Aggregate manifest equates** ([#46](https://github.com/JC-000/c64-x25519/issues/46) / [#50](https://github.com/JC-000/c64-x25519/pull/50)): four exports for
  consumer-side cfg fit/collision checks: `LIB_X25519_ZP_USAGE_BYTES = 85`,
  `LIB_X25519_REU_BANKS_USED = $3F << X25519_REU_BANK`,
  `LIB_X25519_RESIDENT_BYTES = 9275`, `LIB_X25519_COLD_BYTES = 0`.

All changes are pure-additive: no symbol removals, no behaviour
change at default configuration. v0.4.0 consumers can adopt v0.5.0
without source edits. The §4 (segment naming) and §6 (build target
variants) sections of the contract are deferred (no current
consumer requires them). See
[`docs/RELEASE_NOTES_v0.5.0.md`](docs/RELEASE_NOTES_v0.5.0.md) for
the full adoption story.

**v0.4.0 released 2026-05-10** — Phase 7 LANDED: full L1-L29 CT
closure across the entire `fe25519_*` / `mul_8x8` /
`x25519_scalarmult` surface. v0.4.0 closed the v0.4.0-disclosed
27 secret-data-dependent branches across 5 leak families
(L25 / L26a-d / L27a-f / L28a-k / L29a-e) in `src/fe25519.s` —
`fe25519_mul`, `fe_reduce_wide`, `fe25519_mul_a24`,
`fe25519_add`, `fe25519_sub`, `fe_cmp_p`,
`fe25519_reduce_final`. The library is **L1-L29 CT-clean** for
network-facing deployments. Per-proc CT cycle-count guards
(`make test-vice`) report spreads of 0.000-0.01 jif across
structurally distinct inputs, well under the 1.0 jif threshold.
ZP claim grew to 85 bytes at `$14-$16, $1C, $1E-$2A, $2C-$2F,
$40-$7F`. See
[`docs/RELEASE_NOTES_v0.4.0.md`](docs/RELEASE_NOTES_v0.4.0.md)
for the full Phase 7 closure mechanism and migration guidance.

**v0.3.0 released 2026-04-19** — [GitHub release](https://github.com/JC-000/c64-x25519/releases/tag/v0.3.0),
MIT licensed. A perf-recovery + full-CT-certification minor release:
`x25519_scalarmult` (basepoint 9) lands at **12,070 jiffies
(~201.2 s NTSC / ~241.4 s PAL)**, which is **−415 jif (−3.3 %) vs
v0.2.0's 12,485 jif** and **+26.8 % vs v0.1.0's 9,520-jif baseline**.
Two independent bodies of work:

1. **Perf recovery (Phases 1–3).** Rewrites `fe25519_sqr`'s hot path
   without touching any CT invariant: SMC-literal hoist +
   register-threaded abs-math (Phase 1, −247 jif), `SQR_DMA_K` retune
   14→22 (Phase 2, −347 jif), and chain-step address-math +
   ripple-setup fold (Phase 3, −1,152 jif, overshooting its −425 jif
   plan estimate). Phase 3's PR includes an 8-invariant correctness
   walkthrough. Phase 0 ships a CT cycle-count regression guard
   (`tools/test_ct_square_cycles.py`) asserting `fe25519_sqr` stays
   data-independent to within 1 jif.

2. **Full CT certification (L23 + L24 audit closures).** v0.3.0 is
   the first release with **full field-op + outer-ladder side-channel
   posture**. PR [#31](https://github.com/JC-000/c64-x25519/pull/31)
   closes L23a/b/c in `fe25519_sqr`'s `@diag_prop` diagonal-term carry
   path (+1,330 jif) with a Phase-6-style unconditional ripple. PR
   [#30](https://github.com/JC-000/c64-x25519/pull/30) closes L24a/b
   in the Montgomery ladder — two scalar-bit-dependent branches in
   the bit loop — with a branchless `cmp/sbc/eor` bit-to-mask idiom
   (0 jif regression). `fe25519_cswap` is verified CT-clean by
   inspection (no source change). All 24 catalogued leaks (L1–L24)
   are now closed. The library's outermost primitive no longer leaks
   scalar-bit information through branch timing.

Post-release CT cycle-guard spread is **0.045 jif** across five
structurally distinct inputs (3× tighter than the pre-audit 0.150
spread; the `@diag_prop` fix tightened the per-call timing
distribution). **Public API unchanged** from v0.2.0. See
[`docs/RELEASE_NOTES_v0.3.0.md`](docs/RELEASE_NOTES_v0.3.0.md) for
the full release notes and [`docs/CT_ANALYSIS.md`](docs/CT_ANALYSIS.md)
for the underlying leak inventory.

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
| `x25519_scalarmult` (basepoint 9, v0.4.0 / Phase 7 landed) | **15,350 jiffies / ~256.4s NTSC / ~307.7s PAL** (261,640,265 cycles, CIA1-timer measurement) |
| `x25519_scalarmult` (basepoint 9, v0.3.0) | 12,070 jiffies / ~201.2s NTSC / ~241.4s PAL |
| `x25519_scalarmult` (basepoint 9, v0.2.0) | 12,485 jiffies / ~208.1s NTSC / ~249.7s PAL |
| `x25519_scalarmult` (basepoint 9, v0.1.0 baseline) | 9,520 jiffies / ~158.7s NTSC |
| `fe25519_mul` | 5.98 jiffies/call (v0.4.0, CT spread 0.000) |
| `fe25519_sqr` | 6.44 jiffies/call (v0.4.0, CT spread 0.005) |
| `fe25519_mul_a24` | 0.475-0.480 jiffies/call (v0.4.0, CT spread 0.005) |

All measurements on stock C64 with VIC-II blanked (`jsr vic_blank`),
median of 3 runs. v0.3.0 combines two independent bodies of work on
the v0.2.0 baseline: the Phases 1–3 `fe25519_sqr` hot-path rewrite
recovers **1,746 jif** from the v0.1.0→v0.2.0 regression without
touching any CT invariant, and the L23 + L24 audit closures cost back
**~1,330 jif** for full outer-ladder side-channel certification. Net
vs v0.2.0: **−415 jif (−3.3 %)** and fully CT-certified. The library
runs at **+26.8 % vs the v0.1.0 baseline** (vs +31.1 % at v0.2.0)
and **~32.9 % faster than the original un-optimized ~18,000-jiffy
baseline** (vs ~31 % at v0.2.0, ~47.1 % at v0.1.0). See
[`docs/RELEASE_NOTES_v0.3.0.md`](docs/RELEASE_NOTES_v0.3.0.md) for the
full perf and CT-posture story.

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

c64-x25519 is designed to be **vendored as source** into downstream C64 projects rather than linked as a system library. The current **v0.5.0** release hosts a downloadable tarball asset; new integrations should pin to it. Verify the SHA256 before extracting.

**v0.5.0 (current — recommended for new integrations):**

```
curl -LO https://github.com/JC-000/c64-x25519/releases/download/v0.5.0/c64-x25519-v0.5.0.tar.gz
echo "DRAFT_SHA_TBD  c64-x25519-v0.5.0.tar.gz" | sha256sum -c
mkdir -p vendor && tar -xzf c64-x25519-v0.5.0.tar.gz -C vendor/
```

**v0.4.0 (pinned — pre-c64-lib-contract, full L1-L29 CT):**

```
curl -LO https://github.com/JC-000/c64-x25519/releases/download/v0.4.0/c64-x25519-v0.4.0.tar.gz
echo "74e3d252760c15de34c35a2e3419bab4de999f2fb084182fe3b6c423047192fe  c64-x25519-v0.4.0.tar.gz" | sha256sum -c
mkdir -p vendor && tar -xzf c64-x25519-v0.4.0.tar.gz -C vendor/
```

> **Note on the legacy v0.1.0 / v0.2.0 / v0.3.0 download URLs below.** The release-page asset uploads for v0.1.0, v0.2.0, and v0.3.0 were lost in a remote-history reset and are not currently hosted (the `releases/download/v0.X.0/...` URLs return HTTP 404). The git tags themselves remain intact and the source can be reconstructed via `git archive` from the tag, but the resulting tarball will not byte-match the SHA256 values recorded below — those SHAs are kept as a record of the originally-published artifacts. For a current-recipe reproducible build of any v0.5.0+ release from its tag, see `tools/build_release.sh` (or `make dist VERSION=v0.5.0`). Note: v0.4.0's tarball used a smaller file list (no contract files); `make dist VERSION=v0.4.0` no longer reproduces its recorded SHA — the v0.4.0 entry above shows the SHA of the originally-published artifact, which remains downloadable.

**v0.3.0 (pinned — pre-Phase-7, L1-L24 closed):**

```
curl -LO https://github.com/JC-000/c64-x25519/releases/download/v0.3.0/c64-x25519-v0.3.0.tar.gz
echo "799d3998559001a102c2e5d4f782f69a7e03feaf31316b3d689176544d05c28d  c64-x25519-v0.3.0.tar.gz" | sha256sum -c
mkdir -p vendor && tar -xzf c64-x25519-v0.3.0.tar.gz -C vendor/
```

**v0.2.0 (pinned — full CT remediation, pre-perf-recovery):**

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

Per the [c64-lib-contract](https://github.com/JC-000/c64-lib-contract) ABI contract, consumers can additionally `.import LIB_VERSION_MAJOR, LIB_VERSION_MINOR, LIB_VERSION_PATCH, LIB_ABI_VERSION` and `.if`-guard at assemble time against an unsupported library version — a defense-in-depth assert on top of git-submodule SHA pinning. See `docs/LIBRARY.md` §4.3.

**REU bank base override.** Per [c64-lib-contract §3](https://github.com/JC-000/c64-lib-contract/blob/master/SPEC.md#3-reu-layout-contract), the six contiguous REU banks the library claims (mul tables + carry table + zero block) can be relocated at assemble time:

```sh
ca65 -D X25519_REU_BANK=3 -o build/x25519_init.o src/x25519_init.s
# ...rebuild every library .o with the same -D value, then re-archive.
```

`X25519_REU_BANK` defaults to `0` (banks 0–5). Setting it to `3` shifts the library's claim to banks 3–8, leaving banks 0–2 free for a sibling REU consumer. Every library translation unit must be assembled with the same value because the bank constant is baked in at assemble time. The library's standalone `make` / `make lib` build always uses the default; consumer projects rebuild from source with the override. See `docs/LIBRARY.md` §4.5 for the override walkthrough and §4.4 for the `LIB_X25519_REU_BANKS_USED` aggregate bitmask consumers can `.assert` against for compile-time collision detection.

Upstream maintainers can also reproduce the release tarball locally via `make lib` (which builds `build/lib/libx25519.a` and individual `.o` files for in-tree verification) — this is not what downstream projects consume.

## Testing and audit posture

Cryptographic results are differentially tested against [pyca/cryptography](https://github.com/pyca/cryptography) — not against a repo-local reimplementation. This avoids the class of failure where the test code and the assembly under test share a bug. Random inputs with reproducible seeds, hard assertions on every comparison.

The test suite caught a latent `fe_reduce_wide` carry-propagation bug in v0.1.0 prep (fixed in `48092b5`) via differential testing on a random u-coord that exercised a specific `$FF`-boundary cascade. A permanent regression test prevents recurrence, and an audit of all similar `adc #0` sites in `src/*.s` confirmed zero other instances of the bug pattern.

## Security notes

- **Full side-channel posture (v0.4.0, Phase 7 landed).** All 29
  catalogued leak families (L1-L29 in
  [`docs/CT_ANALYSIS.md`](docs/CT_ANALYSIS.md)) are now closed.
  L1-L22 (v0.2.0): branchless CT `mul_8x8` + `fe25519_sqr`
  rewrite + zero-skip removal + Phase-6 carry-chain.
  L23a/b/c (v0.3.0 PR #31): `fe25519_sqr` `@diag_prop`
  unconditional ripple. L24a/b (v0.3.0 PR #30): branchless
  `cmp/sbc/eor` bit-to-mask in the Montgomery ladder bit loop.
  **L25 / L26a-d / L27a-f / L28a-k / L29a-e (v0.4.0 Phase 7):**
  closes the field-op surface beyond `fe25519_sqr` — `fe25519_mul`,
  `fe_reduce_wide`, `fe25519_mul_a24`, `fe25519_add`,
  `fe25519_sub`, `fe_cmp_p`, `fe25519_reduce_final` all rewritten
  with the four Phase-7 closure templates (`lda#0/sbc#0/eor#$FF`
  mask + masked sub-p tail; Phase-6 Option F per-body pending
  chain; `dey/bne` cascades gated by `mul38_lo_tab[0]=0`;
  `fe_carry`-threaded reduction stages). `fe25519_cswap` remains
  CT-clean by inspection. **v0.4.0 is the first release with the
  entire `fe25519_*` / `mul_8x8` / `x25519_scalarmult` surface
  CT-clean** for network-facing deployments where the scalar is
  a long-lived ECDH private key. Per-proc CT cycle-count guards
  in `make test-vice` (`test_ct_square_cycles.py`,
  `test_ct_mul_cycles.py`, `test_ct_mul_a24_cycles.py`,
  `test_ct_reduce_wide_cycles.py`, plus the output-bound
  regression `test_fe_reduce_wide_bound.py`) report spreads of
  0.000-0.01 jif across structurally distinct inputs.
- **State-contract defences (post-v0.3.0, on master).** Two
  correctness-class fixes that complement the L1–L24 timing-leak
  posture by hardening the library against caller state pollution
  when composed with sibling REU consumers (see
  [`docs/CT_ANALYSIS.md`](docs/CT_ANALYSIS.md) §State-contract
  defences). **S1** ([PR #35](https://github.com/JC-000/c64-x25519/pull/35)):
  `x25519_scalarmult` is wrapped in `php / sei … plp` — IRQs are
  library-masked for the full call. **S2**
  ([PR #36](https://github.com/JC-000/c64-x25519/pull/36), closes
  [#33](https://github.com/JC-000/c64-x25519/issues/33)): defensive
  zero of `reu_reu_lo` ($DF04) and `reu_addr_ctrl` ($DF0A) at
  scalarmult entry. Closes a wrong-result-not-hang vector in TLS
  composition (caller residue caused `reu_clear_wide` to fill
  `fe_wide` with garbage). Hardware-confirmed on Ultimate 64 Elite
  via `tools/test_issue33_adversarial.py`. ~6 cycles total cost,
  CT-neutral.
- **No RNG.** Key generation is the caller's job.
- **X25519 only.** No Ed25519, no X448, no hash functions, no KDF/AEAD/HKDF.

## License

MIT — see [LICENSE](LICENSE).

## Acknowledgments

Phase 1–10 optimization work throughout 2026-03 and 2026-04. Test-hardening infrastructure from the 2026-04-11 audit pass is what enabled the Phase 10 correctness fix to be caught by differential testing before release.
