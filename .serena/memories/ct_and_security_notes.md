# Constant-Time and Security Notes

## Threat model
Network-observable timing attacker against the `fe25519_*` / `mul_8x8`
surface. The v0.2.0-candidate work (issue
[#20](https://github.com/JC-000/c64-x25519/issues/20)) is what makes
this threat model defensible; `docs/CT_ANALYSIS.md` is the
authoritative source of truth for the remediation argument.

## What's clean
All 22 catalogued leak sites (`L1`–`L22` in `docs/CT_ANALYSIS.md`) in
`mul_8x8`, `fe25519_mul`, and `fe25519_sqr` have been fixed. The
field-op hot path now has:
- No data-dependent branches (every branch depends on public loop
  indices only).
- No `(zp),y` indirect-indexed loads on secret operands.
- No zero-skip / early-exit shortcuts on secret data.
- An unconditional per-body pending-carry chain in `fe25519_sqr` plus
  a public-indexed end-of-inner ripple (the L19–L22 fix for the
  cross-term carry-cascade path).

## What's NOT yet audited
1. **`fe25519_sqr @diag_prop` diagonal-term path** — believed clean
   but not formally walked through. Tracked as nice-to-have.
2. **Outer `x25519_scalarmult` Montgomery ladder + `fe25519_cswap`.**
   A scalar-bit-dependent branch in the ladder would defeat all the
   field-op work. Current belief: `fe25519_cswap` is mask-time
   invariant and the ladder visits every scalar bit, but the audit is
   not yet written up. **This is the gating item** for any formal
   side-channel deployment claim.

## Non-goals for this repo
- **No RNG.** Callers generate / store / zero their own keys.
- **No power / EM / cache side channels.** The threat model is
  strictly timing-observable-over-network.
- **No Ed25519, X448, hashes, KDF, AEAD, or HKDF.** X25519 scalarmult
  only.

## Cost of CT
The v0.2.0 candidate is **~31.1% slower** than v0.1.0 on
`x25519_scalarmult` (9,520 → 12,485 jiffies on basepoint 9). This was
explicitly accepted — correctness and provable CT-cleanliness take
precedence over jiffy count. Performance recovery is planned for
v0.3.0 via `docs/CT_ANALYSIS.md` §Follow-ups Options 2/3/4, and those
passes are not allowed to touch correctness invariants. The library is
still ~31% faster than the original un-optimized baseline
(~18,000 jiffies) even after the full remediation.

## Testing posture
- Oracle = `pyca/cryptography`, never a repo-local reimpl.
- Random inputs with reproducible seeds, hard asserts.
- `tools/test_fe_reduce_wide_carry.py` is a permanent regression test
  for a latent `fe_reduce_wide` carry bug caught in v0.1.0 prep
  (`48092b5`) via differential testing on a `$FF`-boundary cascade.
- `tools/ct_mul_brute_check.py` brute-forces the CT property of
  `mul_8x8` across its input domain; re-run on any change to the
  quarter-square path.
