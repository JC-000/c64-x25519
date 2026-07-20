# Design: cold-segment split (issue #68)

**Status:** implemented on `feat/issue-68-cold-segment-split`.
**Goal:** move init-only code into a dedicated ld65 segment a consumer
can reclaim after boot, making `LIB_X25519_COLD_BYTES` real for the
first time. Standalone builds are behaviourally unchanged.

## Segment name and §4 posture

`LIB_X25519_INIT_CODE`, per c64-lib-contract SPEC §4 (normative:
`LIB_<X>_` uppercase prefix; type suffixes CODE/RODATA/BSS) and the
only in-ecosystem precedent for functional-unit splits,
`LIB_NISTCURVES_<UNIT>_<TYPE>`. "INIT" names the unit (the boot-only
init path), not a temperature — no sibling uses COLD in a segment
name; COLD exists only as the §5 manifest equate.

This is x25519's first §4-prefixed segment. The remaining plain
CODE/DATA segments are a known §4 gap (adopters.md cell: "n/a"),
tracked separately — folding a full segment-rename into #68 would
bury the reclaim change in a mechanical diff.

## What moves, what stays — and why

**Cold (`LIB_X25519_INIT_CODE`):**

| Item | ~Bytes | Why safe |
|---|---:|---|
| `reu_mul_init` (+ `reu_init_a/b` scratch) | 364 | Sole caller `main.s:88` at boot. Its autoload-latch tail is a one-time state effect; `reu_clear_wide` re-establishes the latch per field op, so reclaim-after-return is safe. Whole proc already gated by `.ifndef SHARED_REU_MUL_INIT`. |
| `reu_probe` | 302 | Zero in-tree callers; banner mandates calling before the first `reu_mul_init` (does not preserve the latch) — boot-time by contract. Exported but not in `x25519.inc`. |
| `sqtab_init` (+ `sq_*` temps) | ~160 | Sole caller `main.s:85` at boot. Runtime consumers read the sqtab *table* at `LIB_SHARED_SQTAB_BASE` ($7800) — an equate-addressed RAM region, not this code. Already gated by `SHARED_SQTAB_INIT`. |

**Resident (unchanged segment):**

- `reu_fetch_mul_row` + `reu_fetch_mul_row_bank_patch` — runtime-hot
  despite the filename: `reu_fetch_doubled_row` JSRs it and SMC-stores
  through the patch hook on every `fe25519_sqr` DMA iteration.
- `reu_fetch_doubled_row`, `reu_clear_wide` — per-field-op hot path.
- **`ct_mul_8x8` / `mul_8x8` (+ `ct_diff_raw`/`ct_sign_mask`,
  `poly_prod_lo/hi`) — deliberately NOT moved** although boot-only in
  x25519, for three reasons: (1) it is the §8.3 shared primitive — in
  an owner-mode composed build a deferring sibling (e.g. chacha's
  poly1305) calls it at *runtime*, and a reclaimed owner body would be
  a crash; (2) `tools/ct_mul_brute_check.py` JSRs it from the live
  image post-boot — the CT gate must keep working; (3) leaving it puts
  zero bytes of the §8.3 byte-identity surface in motion, and keeps
  the runtime-hot `poly_prod_lo/hi` scratch (physically interleaved
  with the body) untouched. Cost: 63 B (59 B body + 4 B scratch) of
  the ~889 B candidate set.

No fallthrough exists between any procs in either file (all end in
RTS), so the moves are clean segment-directive brackets.

## SMC pairs audited

| Patcher → patchee | Segments after split | Verdict |
|---|---|---|
| `reu_mul_init` → `smc_sum_a_imm/_diff_a_imm+1` | INIT → CODE | Stores are absolute-addressed; cross-segment is fine. Runs only at boot, pre-reclaim. |
| `reu_fetch_doubled_row` → `reu_fetch_mul_row_bank_patch` | CODE → CODE | Both resident, unchanged. |
| `ct_mul_8x8` → its own `smc_lo/hi_addr+2` | CODE → CODE | Self-contained, unchanged. |

## cfg placement

Both shipped cfgs gain, as the **last file-emitting** entry in MAIN —
**before** the bss-type BSS entry:

```
LIB_X25519_INIT_CODE: load = MAIN, type = rw, optional = yes, define = yes;
BSS:                  load = MAIN, type = bss, optional = yes, define = yes;
```

- **Ordering is load-bearing** (caught in adversarial review, v1 of
  this design had it wrong): ld65 emits no file bytes for bss-type
  segments, so a file-backed segment declared after a non-empty BSS
  loads `__BSS_SIZE__` bytes below its linked address — silent
  corruption, no link error. The shipped builds have `__BSS_SIZE__ =
  0`, which is exactly why tests can't catch it; consumer builds
  routinely put buffers in BSS.
- **Late in MAIN** → the reclaim window
  `[__LOAD__, __LOAD__ + __SIZE__)` is a contiguous region after all
  resident code/data (abutting the $7800 floor when BSS is empty);
  CODE stays immediately after BASICSTUB (the `start` = $0810 = SYS
  2064 invariant). DATA's start shifts down by the moved bytes; its
  `align = 256` re-establishes the CT page-alignment invariant
  (hard-asserted in data.s) at the cost of +58 B of PRG fill
  (8449 → 8507 B file size; resident bytes unaffected).
- **`optional = yes`** → builds where the deferral switches empty the
  segment (`SHARED_SQTAB_INIT` + `SHARED_REU_MUL_INIT`) still link.
  Note the reverse is NOT optional: any cfg that links `libx25519.a`
  members containing this segment MUST declare it, or ld65 hard-fails
  — this makes the example-cfg + LIBRARY.md updates release-blocking
  for consumers, documented there.
- **`define = yes`** → ld65 exports `__LIB_X25519_INIT_CODE_LOAD__` /
  `_SIZE__` so a consumer can compute the reclaim window symbolically.
- **`load = run`** (no split) → in-place "init then reuse the RAM"
  story; reclaim is entirely the consumer's business, which is exactly
  what `LIB_X25519_COLD_BYTES` advertises per SPEC §5.

## Manifest accounting (SPEC §5: COLD and RESIDENT are disjoint)

`LIB_X25519_COLD_BYTES` = measured `LIB_X25519_INIT_CODE` size;
`LIB_X25519_RESIDENT_BYTES` drops by the same amount. Both variants
measured post-implementation via `od65 --dump-segsize` (the 1764
variant's `reu_mul_init` is 178 B smaller — no doubled-table
generation: INIT 826 B default vs 648 B at K=0). Values recorded in `src/lib_version.s` with the
per-module breakdown comment refreshed.

## Risk register

- **R1 — hot proc moved cold** (crash after consumer reclaim).
  Mitigated by the caller-evidence audit above (every proc's JSR
  sites enumerated); regression surface: the full VICE suite boots
  via `main.s` and then runs field ops — a mis-segmented hot proc
  still works in the standalone image (nothing is reclaimed there),
  so the guard is the audit + review, not the test suite. Called out
  for reviewers explicitly.
- **R2 — §8.3 byte-identity drift.** `mul_8x8.s` is touched (segment
  brackets around `sqtab_init` only). Both brute-check gates re-run;
  the ct_mul_8x8 body bytes must be bit-identical.
- **R3 — consumer link breakage.** Any downstream cfg missing the new
  segment declaration hard-fails at link. Covered by example-cfg
  update + LIBRARY.md consumer-cfg checklist + release-notes callout
  when this ships.
- **R4 — variant divergence.** `optional = yes` + per-variant
  COLD/RESIDENT equates; Makefile 1764 size-report awk extended to
  show the new segment.
- **R5 — file-emitting segment after bss-type (FOUND + FIXED in
  review).** v1 declared INIT after BSS; ld65 links that silently but
  loads the segment `__BSS_SIZE__` bytes low whenever BSS is
  non-empty. Undetectable by this repo's tests (`__BSS_SIZE__ = 0`
  here). Fixed: INIT before BSS in both cfgs, ordering rule stated as
  load-bearing in every cfg comment + LIBRARY.md §4.10.
- **R6 — deferral builds vs lib-verify (pre-existing, documented).**
  `SHARED_REU_MUL_INIT` gates out exports the linkage stub imports
  unconditionally, so stock `lib-verify` cannot link the full-deferral
  build (a consumer shim provides those symbols in real composition).
  Not caused by #68; the near-empty `optional = yes` segment itself
  links fine. A `lib-verify-shared` stub variant is a candidate
  follow-up.

## Out of scope (follow-ups)

- Full SPEC §4 segment-prefix migration (CODE/DATA → LIB_X25519_*).
- contract-repo adopters.md §4 cell update once this ships.
- Any cold-ing of the §8.3 body (would need an owner-mode contract
  amendment first).
