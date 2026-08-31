# c64-x25519 v0.13.0

A build-integrity and evidence release. **No runtime change:
`build/x25519.prg` is byte-identical to v0.12.0** —
`08d1fef11e62551d690935e3b8ba9d3d39aff5a9f742bd1378dc981cc246f333`,
8628 bytes, from a fresh `BUILD_DIR`. That is the strongest single fact
about this release: everything in it is documentation, header,
build-invalidation and verification machinery. The v0.12.0 VICE suite,
bench figures, hardware runs and CT posture therefore all carry over
unchanged, and no VICE rerun is owed by the emitted code.

**Version 0/13/0. `LIB_X25519_ABI_VERSION` stays 3.** MINOR because the
change is additive at the public surface: `.import reu_probe` was added
to the canonical header `src/x25519.inc`. `reu_probe` was already
exported by the library and already documented as public in two places,
but was absent from the header's `.import` block — so the
`x25519_reu_fault` contract shipped at v0.12.0 with only its *reader*
reachable through the header. Nothing was removed or renamed.

**Why ABI stays 3.** The discriminator — proposed on
[c64-lib-contract#167](https://github.com/JC-000/c64-lib-contract/issues/167),
**which is still open** — is: *can a consumer that was conforming before
this change be broken by it?* On that reading the answer here is no. If
#167 settles differently, this classification is revisited.

The decision itself does not rest on how #167 lands. The exported
surface is **set-identical across this release**: 138 symbols in the
default archive on both sides, zero added and zero removed, measured
with `od65 --dump-exports` over the ten members `ar65 t` reports and
diffed as sets against `9e85818`. So holding ABI 3 is correct under
every candidate rule currently on that issue. What is provisional is the rule cited below,
not the number. Note also that this library's own `reu_fetch_mul_row`
case is one of the cases #167 is still weighing, so we are a subject of
that discussion rather than an authority citing its outcome.

Under the proposed reading: The only consumers affected by the header
gaining `reu_probe`, by the `.import` collision fix, or by the corrected
register contract were consumers that were never conforming in the first
place — they were hand-declaring a symbol the header owns, or relying on
documentation that was wrong about code that never changed. A generation
counter tracks breakage of the conforming set; this release breaks none
of it.

Contract-aligned through c64-lib-contract SPEC **v0.17.0** (§14 at tag
`3a91ebb`, §15 at tag `2d7f40c`), up from v0.15.0 at v0.12.0. See §5.

---

## 1. Read this first: `reu_fetch_mul_row` / `reu_fetch_doubled_row` clobber the carry

This is the one item in this release that can require a consumer to
change code, and it is a **disclosure about code that never changed**,
not a change we made. It is documented here rather than treated as an
ABI event, on the same still-open contract#167 reading.

**The condition.** `reu_fetch_mul_row` and `reu_fetch_doubled_row`
clobber **A and C**, preserving X and Y. The carry was never preserved
at any released tag. `reu_fetch_mul_row` builds its bank byte with `asl`
— which discards the entry carry — and folds bit 7 in with `adc #0`,
which overwrites it; C on return is that add's carry-out.
`reu_fetch_doubled_row` inherits the same contract through its `jsr`.
The correct contract for both is at `src/x25519_init.s:357` and `:471`.

Every release through v0.12.0 documented these routines as clobbering
**A only** — or, in the v0.12.0 wording, **A and X** with "the carry
flag preserved". That documentation was wrong, and it was wrong
**everywhere**: the fetch routines' register contract was stated in
**nine** places, and all nine were wrong. They were reconciled as a set
at #121 — `src/x25519_init.s:357` and `:471` (the two banners),
`src/x25519.inc:206` (the public header), `src/constants.s:333`,
`docs/LIBRARY.md:1004` and `:1063-1068`, and three passages in
`docs/RELEASE_NOTES_v0.12.0.md` (`:30-36`, `:145`, `:150`).

Six *further* register-clobber claims in the same area were, and remain,
correct, because they are scoped to the `REU_SETTLE` macro and its slow
proc rather than to the fetch routines: `src/constants.s:304`,
`src/x25519_init.s:402`, `src/data.s:137`, `src/fe25519.s:721`,
`docs/RELEASE_NOTES_v0.12.0.md:94` and `docs/CT_ANALYSIS.md:151` (L31b).
That split is what makes the count easy to misread — fifteen clobber
claims sit in this area, and the nine that are about the fetch routines
are exactly the nine that were wrong. #123 touched none of them.

v0.12.0's release notes recorded the correction; this release states the
consumer consequence, which is what actually matters.

**The consequence — what you must do.** If you `JSR` either routine
directly *and* held a live carry across the call, **your code was
already wrong at every released tag**, including the one you are running
now. It did not break at v0.13.0; it has been reading a carry the
routine destroyed. Concretely:

- **Add a `clc` after the call** before your next carry-dependent
  instruction, or save and restore C around the call (`php` / `plp`) if
  you genuinely need the entry carry to survive.
- **Re-test.** This is a silent wrong-value bug, not a crash: the fetch
  itself succeeds, the rows land correctly, and only your own
  subsequent `adc`/`sbc`/`rol`/`ror` is off by one. Nothing in the
  library, ca65 or ld65 will tell you. A differential test against a
  known-good oracle will.

We are naming the consequence rather than only the condition
deliberately (the principle proposed on contract#171, also open): a
reader who is
told "the register contract is corrected to A and C" has to work out on
their own that their live carry has been silently wrong for months. The
danger is invisible from the condition, so the condition alone is not a
disclosure.

**Who is not affected.** Callers who only use the public
`x25519_*` / `fe25519_*` API are unaffected — the library's own two hot
callers (`fe25519_sqr` after `jsr reu_fetch_doubled_row`, and
`fe25519_mul`'s inlined fetch) `clc` before their next carry use, and
always have. The `REU_SETTLE` macro added at v0.12.0 is *not* the cause:
it clobbers A only and preserves X, Y and C, and that claim was and
remains correct.

## 2. Consumer-override integrity (#121, `97f3e80`)

Two instances of the shape described at
[c64-lib-contract#164](https://github.com/JC-000/c64-lib-contract/issues/164)
(open): *a documented consumer override produces the wrong artifact and
the build reports success.* The defects below are real and fixed
regardless of how that issue is resolved; #164 is cited for the shape,
not as a ruling.

**Mechanism 2 — the warm-tree link.** `CONTRACT_STAMP` now invalidates
**linked outputs**, not only objects and archives. On a warm tree,
`make all` after a §6.2 knob change exited 0 while retaining the
*previous* configuration's PRG: GNU Make 3.81 (macOS `/usr/bin/make`)
has whole-second mtime granularity, and the newest `.o` lands in the
same second as the existing PRG, so make judged the PRG current.
Measured: `-D SQR_DMA_K=0` retained `08d1fef1`/8628 B where
`a1308f9b`/8414 B was correct, reproduced independently by two audits on
two different knobs. `make lib` was always safe, because the stamp
already deleted `$(LIB_DIR)/*.a`.

`PRG`, `LABELS` and `LIB_VERIFY_DIR` are **hoisted above the stamp
block**: `$(shell)` expands at parse time, so a version naming those
variables in place expands empty and is a silent no-op (measured: 4/4
still stale). Deletion rather than dependency ordering is deliberate —
a nonexistent target is unconditionally rebuilt by every make version.

**No released artifact was ever affected.** `tools/build_release.sh`
ships a `git archive` of source, not a built PRG, and `08d1fef1` is the
correct *default* artifact.

**Mechanism 1 — the header `.import` collision.** `src/x25519.inc`'s §3
imports now take the shape contract#164 proposes: guard a header
`.import` **iff** the defining TU guards the definition with `.ifndef`,
and pair the guard with an `.else` branch that asserts the override
against the library's exported value with `lderror`.
`X25519_REU_BANK` / `_OFFSET` are guarded (`src/reu_config.s:61,74`);
`_BANK_DOUBLED` / `_BANK_CARRY` stay bare, because `reu_config.s:90-91`
assign them unconditionally and a `-D` must collide loudly. A bare guard
*alone* is worse than no guard: it converts a compile error into silent
divergence — measured, a bank-8 override linked clean against a bank-0
archive.

`tests/lib_linkage` drops twelve imports that shadowed the header it
already includes, so the header's guards govern and its divergence
asserts become reachable. Grading is byte-identical: `stub.labels` is
unchanged in all seven profiles — rebuilt against the pre-#121 stub and
compared byte-for-byte. (157 lines in the *default* profile; the line
count itself is profile-dependent and is not the invariant.)

## 3. Documentation defects (#121), each verified against source

- **Four consumer snippets taught a `$`-valued define.** Through make,
  that reaches ca65 as **0**. Nothing downstream catches it: §8.1's
  page-alignment assert passes (`0 & $00ff = 0`, sqtab at `$0000`) and
  `zp_config.s` asserts nothing about a slot being non-zero, so a ZP
  slot lands on `$00`, the 6510 DDR — with no diagnostic from make,
  ca65 or ld65. `cfg/x25519-example.cfg` ships inside `build/lib/cfg/`,
  so one of the four was being handed to consumers by `make lib`. New
  `tools/check_doc_snippets.py` and `make lib-verify-docs` reject the
  form (and cl65's `--asm-define` where it is used to set one). The
  checker folds each file before matching, because two of the four were
  split across wrapped comment lines, which a line-by-line grep cannot
  see. `lib-verify-docs` is wired as a prerequisite of `lib-verify`.
- **The `reu_fetch_*` carry contract** — see §1.
- **`x25519_scalarmult` does not mask the caller's `x25_u`.** The header
  claimed it did; it masks a working copy and leaves `x25_u` untouched
  (`src/x25519.s:146-150`).
- **`reu_probe` is importable** — see the version rationale above.
- **`src/lib_manifest.s`'s footprint itemisations are re-measured.** The
  default and 1764 blocks had drifted from the equates they explain, and
  the 1764 delta never reconciled with its own endpoints. The equates
  themselves are unchanged; the non-comment diff for that file is empty.
- **Two `RELEASE_NOTES` errata annotate broken snippets in place**
  rather than rewriting a shipped record, and the v0.12.0 shipped-bytes
  hardware row is marked **core-unknown**: it ran 2026-08-29, after the
  2026-08-28 / core 1.4E heading it sits under, and the device reads
  1.4F as of 2026-08-30 (first-hand `/v1/info`, `601A96`).

## 4. §15 evidence discharge (#123, `8430284` / `9ca97bd` / `33240a7`)

SPEC v0.17.0 §15.1 is SHOULD-level, not retroactive, and scoped to
checks a library **cites as conformance evidence**: *"A check never
observed to fail is not evidence that the property holds; it is evidence
only that the check ran."* So this is claims hygiene on what we already
assert — nothing here was non-conformant.

**1. A derived footprint check** (`tools/check_footprint.py`, new).
`LIB_X25519_RESIDENT_BYTES` / `_COLD_BYTES` were two *hand-maintained
literals compared against each other*: the equates in
`src/lib_manifest.s` and the `LIB_VERIFY_*_EXPECT` locks in the
Makefile. That catches an inconsistent edit and never a stale pair.
Measured: 16 `nop`s injected into `fe25519_add` grew `fe25519.o`'s
`LIB_X25519_CODE` 2750 → 2766, the bytes reached the linked binary, and
`make lib-verify` exited 0 across all seven profiles. The check now
**measures** both fields with `od65 --dump-segsize` over the members
`ar65 t` reports for the shipped archive. It is wired inside
`lib-verify`, so all seven profiles get it, and exposed standalone as
`make lib-verify-footprint`. Cost: **~0.05–0.07 s of a ~0.25–0.30 s
target** — measured across two machines and five runs each, and varying
with load, so both are approximate rather than pinned. The point the
figures support is only that the check adds a small fraction of an
already sub-second target, which is why it is wired inside `lib-verify`
rather than kept standalone.

It is load-bearing, not decorative: deleting it makes `lib-verify` exit
0 on a +16 B tree. The PRG is fill-padded, so its **size** stays 8628 B either
way — no size check could ever have caught this drift.

**2. `tools/ct_mul_brute_check.py --mutate`.** §8.3 cites this tool by
name, and `docs/CT_ANALYSIS.md` recorded it only ever passing.
`--mutate` points the kernel's high-byte load at `poly_prod_lo`:
65025/65536 mismatches **reported** (not crashed), first five printed.

**3. `make lib-verify-negative`** — eight legs, one per assertion inside
`lib-verify`, per §15.1's per-check-within-an-aggregate-gate rule.

**4. Leg C parameterised** over the default and onchip profiles; legs
A/A2/B are not multiplied, and the scope argument is recorded in place
rather than left implicit.

**Grading, stated rather than implied (§15.2).** Artifact-side legs
reproduce the defect class: the footprint negative leg (16 nops into
`fe25519_add`), N1 (a real deferral archive graded against default
expectations), and leg A3 (a genuinely shrunken cfg region).
Expectation-side legs only show the check *can* report — N0, N2..N7 and
footprint step 1b perturb what the check is told to expect, not the
artifact. Each names where its stronger evidence lives; N2 has none
available and says so.

**`lib-verify-footprint-negative` runs two arms**, default and onchip,
each failing on its **own** numbers:

| arm | declared | measured | `fe25519.o` `LIB_X25519_CODE` |
|---|---:|---:|---|
| default | `$2137` (8503) | 8519 | 2750 → 2766 (+16) |
| onchip | `$202A` (8234) | 8250 | 2692 → 2708 (+16) |

Two arms and not seven, argued structurally: onchip's segment
composition differs most from default (COLD 160 vs 947, no §8.2 REU
contribution to `LIB_X25519_INIT_CODE`, `fe25519.o`'s own
`LIB_X25519_CODE` 2692 vs 2750), so the two **bracket** the composition
range the check handles. RESIDENT spans 8234 (onchip) to 8503 (default,
shared-sqtab); COLD spans 160 to 947; the other five profiles fall
inside both intervals. Recorded plainly in the Makefile's ARM SELECTION
comment: those five are **not** demonstrated per-profile — their
demonstration rests on the bracketing argument, not on a run. A reader
who rejects the bracketing is rejecting that argument, not a claim those
five were exercised.

**`src/main.s`'s SQTAB size assert** compared against a literal `1024`,
so the table size lived in two uncrossed places — the same defect this
change set removes, in the very file `docs/LIBRARY.md` tells consumers
to mirror (§6.7). It now compares against
`LIB_X25519_PRECALC_sqtab_SIZE`. The PRG is byte-identical: `08d1fef1`,
8628 B.

**External line citations converted as a closed set.** A
`SPEC.md:<n>` citation points into a repo we do not control, into a
document that gains sections — it drifts silently and cannot be fixed
from here. Every one is now a section reference plus enough quoted text
to identify the sentence, which is immune by construction; each quoted
fragment was re-verified present in contract `2d7f40c`. Enumerating
rather than trusting a list paid: it turned up an **eighth** instance
nobody had listed, and that one had **already drifted** —
`docs/design/issue_72_onchip_mul.md:160` cited the "§8.0 symmetry rule"
as `SPEC.md:252`, but `:252` is a §5 manifest-table row, §8.0 begins at
`:428`, and the clause itself was promoted out of §8.0 into §8.4 after
that doc was written. Left as-is deliberately: the two mentions of
`SPEC.md:1567` in `CT_ANALYSIS.md` and `ct_mul_brute_check.py` are
records *of* a wrong citation, not live citations.

## 5. Contract alignment: v0.15.0 → v0.17.0

- **§14 (SPEC v0.16.0, tag `3a91ebb`) owes nothing.** N1 is discharged
  by the straight-line Fermat inversion chain and the fixed 256-bit
  ladder, and this library's CT invariant is strictly stronger than what
  §14 asks for.
- **§15 (SPEC v0.17.0, tag `2d7f40c`)** is not retroactive and carries
  no MUST; its obligation is scoped to checks cited as evidence. The
  standing debt was claims hygiene, ranked in the ledger and discharged
  in §4 above.

Unchanged from v0.12.0: v0.15.0's §8.4 zero-consumer carve-out for the
bare `LIB_PRECALC_*` triple remains inapplicable (x25519 has released
consumers), and the vendored `src/precalc_table.inc` is byte-identical
to the contract's.

## 6. §6.6 footprint pairs

**Unchanged from v0.12.0.** RESIDENT default **8503** / 1764 **8355** /
onchip **8234**; COLD **947** / **733** / **160**. A consumer already on
v0.12.0's pinned pair needs no change. A consumer still pinning v0.11.x
will trip its §6.6 asserts at link time — that is §6.6 working as
designed, and the values above are the ones to take.

What *did* change is that these numbers are now **derived rather than
restated** (§4.1): the equates in `src/lib_manifest.s` are measured
against the shipped archive on every `lib-verify`, in every profile.

## Verification

Run on the release branch, all green:

- `make lib`, `make lib-verify`, `make lib-verify-docs`,
  `make lib-verify-footprint`, `make lib-verify-negative`,
  `make lib-verify-footprint-negative`, `make lib-verify-shared`,
  `make lib-verify-guards`
- `make lib-app-owned`, `make lib-x25519-1764`, `make lib-x25519-onchip`
- `make test`
- **Fresh-`BUILD_DIR` PRG:**
  `08d1fef11e62551d690935e3b8ba9d3d39aff5a9f742bd1378dc981cc246f333`,
  8628 bytes — byte-identical to shipped v0.12.0. The version-equate
  bump does **not** reach emitted code: `LIB_X25519_VERSION_MINOR` moves
  0x0C → 0x0D in `lib_version.o`'s export table and in `labels.txt`, and
  the linked image is unchanged, because the §1 equates are absolute
  symbols rather than segment data.
- The v0.12.0 `make test-slow`, bench, U64E fw 3.15 hardware and RFC
  7748 §5.2 1,000-iteration results carry over unchanged, because the
  bytes they were run on are the bytes this release ships.

## Tarball

`c64-x25519-v0.13.0.tar.gz` — vendor-as-source bundle (`cfg docs LICENSE
ORIGIN.txt.template src`; no Makefile or README by design), built by
`tools/build_release.sh v0.13.0` from `git archive` of the annotated tag.

**The recorded SHA256 is captured in the GitHub release description**,
together with the byte size:
<https://github.com/JC-000/c64-x25519/releases/tag/v0.13.0>

That is not an omission, and it is not a value still to be filled in
here. The tarball is `git archive` of the tag, so this file is *inside*
the artifact it would be describing: a hash written here before the tag
cannot be the hash of the archive containing it. Recording the value by
**location** rather than by `TBD` means a reader holding only the
tarball is pointed at the authority instead of at a placeholder
(the approach under discussion on
[c64-lib-contract#168](https://github.com/JC-000/c64-lib-contract/issues/168),
which is **open and not ratified** — we are adopting it ahead of that,
deliberately, because a `TBD` in a shipped immutable artifact is worse
than a pointer either way).
