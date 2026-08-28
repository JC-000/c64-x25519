# c64-x25519 v0.12.0 — DRAFT

A contract-conformance release. c64-lib-contract SPEC **v0.13.0 §8.2**
(tag `c771935`; contract#144 / contract#146; tracked here as #115) made REU completion
checking normative: after **every** REU execute and **before the next
access to any REU register**, an implementation MUST (a) read `$DF00`
and confirm bit 6 (END OF BLOCK) is set, spinning bounded if not, and
(b) leave a post-execute settle meeting the bracketed floor. All twelve
execute sites in this library now do both. Runtime code changed, so
`build/x25519.prg` is **not** byte-identical to the v0.11.0–v0.11.3
PRG (`905bb969…`); the VICE suite, the CT cycle gate and the bench were
rerun.

**Version 0/12/0. `LIB_X25519_ABI_VERSION` stays 3.** MINOR because the
change is additive: one new export (`x25519_reu_fault`) and one new
§6.2 knob (`X25519_REU_SETTLE_ITER`). No symbol was removed or renamed.
One documented register contract tightened — `reu_fetch_mul_row` and
`reu_fetch_doubled_row` now clobber A **and X** (see §3) — which is
why consumers that JSR the fetch helper directly should read this
before taking the release.

Contract-aligned through c64-lib-contract SPEC **v0.14.0** (tag
`e76bcff`): v0.12.0 (`a6bb30a`), v0.12.1 (`42c84bd`) and v0.14.0 are
§13.x networking and do not apply to x25519; v0.13.0 (`c771935`) §8.2
is this change. v0.11.1 is now tagged too (`cc3f8a6`).

---

## 1. What §8.2 v0.13.0 requires, and what we claim

The clause has two halves. **(a)** is a completion check: read
`reu_status` ($DF00), test bit 6, spin bounded. Reading $DF00 clears
bits 5–7, so the read happens once per spin iteration into A and the
tests run on that copy; bit 5 set is a VERIFY ERROR. **(b)** is a
timing floor: the bracketed hardware measurement is **≥ 49 cycles at
48 MHz on Ultimate 64 Elite firmware 3.15**, and one `lda reu_status`
— an I/O-mapped read — is what costs ~49 cycles at that turbo on the
U64E, which is why read-once meets the floor whenever bit 6 is already
set on the first read. The 64 MHz turbo is **unbracketed** by the
contract. **c64-x25519 claims conformance at ≤ 48 MHz only** and says
nothing about 64 MHz.

Reporter's hardware reference (U64E fw 3.15 @ 48 MHz, 9/9 pass): bit 6
was already set on the first read in all 19,416 calls. Under VICE's REU
it always is.

## 2. The change

`REU_SETTLE`, a macro in `src/constants.s` (which every TU includes),
expanded immediately after each of the twelve `sta reu_command`:

| site | file | count | path |
|---|---|---:|---|
| `reu_mul_init` stashes (lo, hi, doubled-lo, doubled-hi, carry) | `src/x25519_init.s` | 5 | boot (cold) |
| `reu_fetch_mul_row` | `src/x25519_init.s` | 1 | **hot** — every `fe25519_sqr` DMA row via DMA #1 |
| `reu_fetch_doubled_row` inline DMA #2 | `src/x25519_init.s` | 1 | **hot** — 22 per `fe25519_sqr` |
| `reu_probe` (read-orig, stash sentinel, fetch back, restore) | `src/x25519_init.s` | 4 | boot (cold) |
| `fe25519_mul` inlined row fetch | `src/fe25519.s` | 1 | **hot** — 32 per call |

In `reu_probe` the settle sits between the execute and the `lda
@scratch` that reads the transferred byte — the byte must have landed
before it is read, not merely before the next register write.

It is a macro, not a `jsr` target, because two sites are inside the
per-row loops. Fast path: `lda abs / and / eor #$40 / beq` = **11 cycles**, 9 bytes
per expansion, taken **only** when the single `$DF00` sample shows bit 6
set and bit 5 clear. Every other sample takes one shared
`jsr x25519_reu_settle_slow` (`src/x25519_init.s`), which keeps
spinning on **bit 6 alone** until it is set or the bound expires and
records bit 5 separately — a verify-fault sample never ends the spin
early (review point on #116). Both paths clobber A only; the slow
path keeps its sample and counter in two cross-TU internal bytes in
`src/data.s` (`x25519_reu_settle_smp` / `_cnt` — exported for linkage,
not API), so X, Y and C survive every expansion. The
macro uses only unnamed `:` labels so that expanding it inside a
`.proc` does not open a new cheap-local scope and orphan the
surrounding `@labels` (it did, on the first attempt).

**Clock claim.** `X25519_MAX_CLOCK_MHZ` (default 48, `.ifndef`) — the
clock the settle is claimed for. SPEC v0.13.0 concedes a read-once
implementation meets floor (b) at 48 MHz "by accident" (one I/O read
costs ~49 cycles there); an `.assert` makes any build claiming more
than the bracketed 48 MHz fail loudly instead of silently shipping an
unmeasured settle. Verified: `make lib CONTRACT_DEFINES="-D
X25519_MAX_CLOCK_MHZ=64"` fails on the named assert. Raise it only
with a measured bracket at the new clock (contract#144's open 64 MHz
cell).

**Knob.** `X25519_REU_SETTLE_ITER` — the spin bound, default 8,
`.ifndef`-guarded, `.assert`ed to 1..255. A §6.2 knob:
`make lib CONTRACT_DEFINES="-D X25519_REU_SETTLE_ITER=16"`.
`CONTRACT_STAMP` reads `ALL_DEFINES`, so §6.3 invalidation is automatic
— measured, not assumed: warm `make lib` with unchanged knobs
recompiled 0 TUs; changing the value recompiled 10; unchanged again 0;
back to default 10. The listing under `=16` shows `A2 10` at all eleven
`x25519_init.s` sites.

**Fault channel.** The fetch primitive has no error return. The
contract says an adopter SHOULD surface a bounded-spin failure the way
it surfaces a missing REU at init. New sticky byte `x25519_reu_fault`
(`src/data.s`, exported, documented in `src/x25519.inc`):
`$01` ORed in on bound expiry, `$02` if bit 5 was seen; cleared at
`reu_mul_init` and `reu_probe` entry, never otherwise. `reu_probe`
returns C = 0 if the byte is non-zero after its four DMAs. The library
never branches on the byte on the hot path.

**Autoload latch.** Reading $DF00 does not disturb the latched address
/ length / control registers — the status register's only read
side-effect is clearing its own bits 5–7, and the autoload reload is
keyed on the command register at execute completion. The S3 invariant
(`reu_fetch_doubled_row` banner; CT_ANALYSIS S3) is untouched, and
`tools/test_fe_sqr_stress.py` / the sqr-then-mul regressions are green.

## 3. Register-clobber analysis, per site

The reporter's reference implementation clobbers X (an `ldx`/`dex` spin
counter). x25519's macro does **not**: it counts in memory, so every
site — including the §8.2 provider-surface `reu_fetch_mul_row`, whose
documented convention is "clobbers A" — keeps its pre-v0.12.0 register
contract. C is never written by the macro (`lda`/`and`/`ora`/`dec`/
branches), and the two hot callers (`fe25519_sqr` after
`jsr reu_fetch_doubled_row`, `fe25519_mul`'s inline fetch) `clc` before
their next carry use anyway. A consumer that JSRs `reu_fetch_mul_row`
directly needs no migration beyond what §8.2 v0.13.0 itself demands.

## 4. CT posture

Catalogued as **L31a-c** in `docs/CT_ANALYSIS.md`. The settle's
branches are on `$DF00` bits 6/5 — hardware completion state for a
transfer whose length (512 or 256 bytes), direction and target are
fixed; only the REU page varies with the secret row index, and REU DMA
cost is address-independent. Spin count is a function of (hardware,
length), never of (scalar, point). `tools/test_ct_square_cycles.py`:
0.000–0.010 jif spread across structurally distinct inputs, unchanged
from v0.11.x. CT rule kept: no branch on secret data was added.

## 5. Cost

Bench (`tools/bench_x25519.py`, VICE, VIC blanked, same tree before /
after the change):

| | cycles | jif |
|---|---:|---:|
| before | 262,318,045 | 15,389.3 |
| after | 263,424,237 | 15,454.2 |
| delta | **+1,106,192 (+0.42 %)** | +64.9 |

Expected from construction: ~11 cycles × (32 fetches per `fe25519_mul`
+ 44 per `fe25519_sqr`) over the ladder's ~1,300 mul + ~1,300 sqr
calls ≈ 1.6 M cycles. Correctness: PASS (RFC 7748 vector).

## 6. §6.6 footprint pairs

**Consumer impact — read this before bumping.** The RESIDENT / COLD
growth below **will trip a consumer's §6.6 footprint asserts at link
time** if it pins the v0.11.x pair. `c64-wireguard` (RAM-constrained;
pins v0.10.1 with v0.11.1 as its next target) and `c64-https` (pins
v0.11.2) both do. That link failure is §6.6 working as designed:
update the pinned pair to the values below when taking v0.12.0.

Re-measured with `od65 --dump-segsize` (the `make lib-x25519-*`
dumps, plus assembling `x25519_init.s` under the deferral defines for
the `_D_*` deltas):

| profile | RESIDENT | COLD | note |
|---|---:|---:|---|
| default | 8383 → **8476** | 826 → **947** | 3 resident + 9 cold sites at 9 B each plus the shared `x25519_reu_settle_slow` proc (resident); the two `data.s` bytes are absorbed by the existing page pad, DATA stays 3584 |
| `lib-x25519-1764` | 8247 → **8328** | 648 → **733** | 2 resident + 6 cold sites survive at K=0 |
| `lib-x25519-onchip` | 8207 | 160 | unchanged — no REU access, no `$DF00` read anywhere (listing-verified: zero settle expansions in `x25519_init.o` / `fe25519.o`) |
| §8.2 deferral deltas | `_D_RES_REU` 20 → **32** | `_D_COLD_REU` 364 → **427** (K>0), 186 → **213** (K=0) | the slow proc is not deferrable (serves `reu_probe` and DMA #2) |

The seven per-profile `LIB_VERIFY_RESIDENT_EXPECT` /
`LIB_VERIFY_COLD_EXPECT` locks in the Makefile (contract #62 audit
lock) were re-derived from the same dumps; `lib-verify` failed on the
stale default lock before they were updated, which is the lock doing
its job.

`make lib-verify-guards` leg A moved its diverged-base probe from
`0x2A00` to `0x2C00`: the standalone image end is now `$2A82`, so the
old value tripped the *overrun* assert first and the leg could no
longer distinguish region-disagreement (its job) from overrun (leg
A2's job). Both legs still fail on their own named error.

## Verification

- `make clean && make && make test-vice` — all green (mul38, fe25519
  ops, fe_mul/sqr stress, ct_square_cycles ×4, reduce_wide_carry,
  sqr-then-mul; 64/64, 128/128, 49/49, 50/50, 3/3)
- `python3 tools/test_ct_square_cycles.py`, `test_fe_reduce_wide_carry.py`
- `make lib lib-verify lib-verify-shared lib-verify-guards
  lib-app-owned lib-x25519-1764 lib-x25519-onchip` — every profile
  assembles and verifies; guards fire on their named errors (A, A2, B,
  C, C1, C2, C1b)
- Knob invalidation in both directions (0 / 10 / 0 / 10 TUs)
- Bench before/after as in §5
- **Hardware, `tools/test_reu_mul_u64.py`** (new in this release; builds
  the table on the device, reads 32 rows back through `reu_fetch_mul_row`
  twice — once by the host with the CPU idle, once copied by the 6502
  immediately after the `rts` — against CPU products, then a full RFC
  7748 KAT through `fe25519_mul`'s inlined fetch, oracle pyca):
  - **Ultimate 64 Elite fw 3.15** (fpga 123, core 1.4E), 2026-08-28:
    - master `232bb11` (unfixed): **48 MHz FAIL** — the `cpu-read` leg sees
      `mul_dma_lo[0..1]`/`mul_dma_hi[0]` still holding the scrub poison
      on all 32 rows (64 bad products), KAT FAIL; **1 MHz PASS** (0
      mismatches, KAT PASS). The host-read leg is green even on master —
      the DMA does complete; the CPU merely runs past it — so only the
      cpu-read leg and the KAT discriminate.
    - this branch: **48 MHz PASS, 1 MHz PASS** (0/0 mismatches, KAT PASS
      at both).
  - 64 MHz: **not measured** — no C64 Ultimate reachable; conformance is
    claimed at ≤ 48 MHz only (§8.2 v0.13.0 leaves 64 MHz unbracketed).
- `make test-slow` on this branch (PRG `80664edcd772b458…`): exit 0, every suite 0 failed (128/128, 256/256, 255/255 ladder steps, 68/68, 64/64, 53/53, 49/49, 35/35, 27/27, 19/19)

## Tarball

TBD at tag time — `c64-x25519-v0.12.0.tar.gz`, size and SHA256 to be
filled from the published asset, not the local build.

```
Size:     TBD
SHA256:   TBD
```
