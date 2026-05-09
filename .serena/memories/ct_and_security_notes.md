# Constant-Time and Security Notes

## Threat model
Network-observable timing attacker against the public `x25519_*` /
`fe25519_*` / `mul_8x8` surface. The library is consumed transitively
by network-facing downstream (c64-wireguard, c64-https), so the
network threat model applies even when this library runs locally.
`docs/CT_ANALYSIS.md` is the authoritative source of truth for the
remediation argument.

## Two distinct defence classes

### CT (timing-leak) defences — L1–L24
**All 24 catalogued timing leaks closed as of v0.3.0** in `mul_8x8`,
`fe25519_mul`, `fe25519_sqr` (cross-term + diagonal `@diag_prop`
paths), and the `x25519_scalarmult` Montgomery ladder bit loop. The
field-op hot path AND the outer ladder now have:
- No data-dependent branches (every branch depends on public loop
  indices only).
- No `(zp),y` indirect-indexed loads on secret operands.
- No zero-skip / early-exit shortcuts on secret data.
- Unconditional per-body pending-carry chain in `fe25519_sqr` +
  public-indexed end-of-inner ripple (Phase 6 / L19–L22).
- Phase-6-style unconditional ripple in the diagonal-term path
  (L23a/b/c, @diag_prop audit).
- Branchless `cmp/sbc/eor` bit-extract + mask-expand in the ladder
  bit loop (L24a/b).
- `fe25519_cswap` verified CT-clean by inspection (mask-time-invariant
  unrolled abs,Y inner loop; 32-byte page alignment hard-asserted in
  `data.s`).

CT-spread on `test_ct_square_cycles.py`: 0.045 jif across
structurally distinct inputs (3× tighter than the pre-audit 0.150).

### State-contract defences (correctness, not CT) — S1, S2
Separate class. These don't close timing leaks; they close
*correctness* defects that surface when the library is composed with
sibling REU consumers (other crypto libraries, NIC drivers) or with
ISR-installing hosts. Documented in `docs/CT_ANALYSIS.md` §State-
contract defences.

- **S1 (PR #35, landed v0.3.0+)**: `php / sei … plp` wrap of
  `x25519_scalarmult`. Library-enforced IRQ mask for the full call.
  Closes (a) IRQ interleaving partial REU multi-store register
  writes, (b) consumer ISR clobbering the 83 owned ZP bytes
  (`$1A-$2E`, `$40-$7F`). **NMI is not masked** by `sei` —
  custom-NMI-handler concerns remain caller responsibility.
- **S2 (PR #36, landed v0.3.0+, issue #33 fix)**: 4-instruction
  defensive REU register init at scalarmult entry — zero `reu_reu_lo`
  ($DF04) and `reu_addr_ctrl` ($DF0A). Closes the caller-REU-residue
  vector. `reu_clear_wide` and the inlined per-row DMA in
  `fe25519_mul` rely on those two registers being `$00`; without S2,
  caller residue caused garbage `fe_wide` accumulator → wrong shared
  secret (NOT a hang). Verified on VICE (8 adversarial cases) and
  hardware (U64E, 4 key cases). ~6 cycles cost.

## Non-goals
- **No RNG.** Callers generate / store / zero their own keys.
- **No power / EM / cache side channels.** Strictly
  timing-observable-over-network.
- **No Ed25519, X448, hashes, KDF, AEAD, or HKDF.**

## Cost of CT (post-v0.3.0)
- v0.1.0 baseline: 9,520 jif on basepoint 9
- v0.2.0 (full L1-L22 fix): 12,485 jif (+31.1%)
- v0.3.0 (perf recovery + L23/L24): **12,070 jif** (+26.8% vs v0.1.0,
  -3.3% vs v0.2.0)
- S1+S2 state-contract defences: <0.001% additional cost

The library remains ~33% faster than the original un-optimized
baseline (~18,000 jiffies) despite full CT certification + state-
contract hardening.

## Testing posture
- Oracle = `pyca/cryptography`, never a repo-local reimpl.
- Random inputs with reproducible seeds, hard asserts.
- `tools/test_fe_reduce_wide_carry.py` — permanent regression for the
  v0.1.0-prep `fe_reduce_wide` carry bug (`48092b5`) on a
  `$FF`-boundary cascade.
- `tools/ct_mul_brute_check.py` — brute-forces CT property of
  `mul_8x8` across its input domain; re-run on any change to the
  quarter-square path.
- `tools/test_ct_square_cycles.py` — `fe25519_sqr` cycle-count
  regression guard (≤1 jif spread). Treat as CT regression gate, not
  a perf bench.
- `tools/test_issue33_adversarial.py` — adversarial REU-state
  regression for S2; 8 cases (clean, h1_audit, reu_low_dirty,
  reu_addr_ctrl_dirty, reu_full_dirty, nmi_corrupts_zp40,
  irq_during_call, plus baseline). Supports `--target vice` (default,
  fast) and `--target u64` (real hardware via c64-test-harness).
