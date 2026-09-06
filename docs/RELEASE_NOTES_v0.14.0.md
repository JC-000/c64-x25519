# c64-x25519 v0.14.0

A contract-alignment release. **No runtime change: `build/x25519.prg` is
byte-identical to v0.12.0 and v0.13.0** —
`08d1fef11e62551d690935e3b8ba9d3d39aff5a9f742bd1378dc981cc246f333`,
8628 bytes, from a fresh `BUILD_DIR`. The v0.12.0 VICE suite, bench
figures, hardware runs and CT posture therefore carry over unchanged,
and no VICE rerun is owed by the emitted code.

**Version 0/14/0. `LIB_X25519_ABI_VERSION` stays 3.** MINOR because two
build targets are added (`lib-verify-citations`,
`lib-verify-citations-negative`), which SPEC §7 lists as additive.
Nothing is removed or renamed, and no exported symbol changes name,
value or address.

Aligned with c64-lib-contract SPEC **v1.1.0** (tag `358c2b4`), up from
v0.17.0 at v0.13.0.

---

## 1. What the contract did, and what it means here

Contract **v1.0.0** deleted roughly seven eighths of `SPEC.md` — 40,737
words down to 5,154 — and **changed no symbol, equate, bit value,
segment name, build target or error code**. Sections **§9, §12, §13,
§14, §15** and sub-clauses **§6.3, §6.6, §6.7** are retired. Surviving
sections kept their numbers, so every citation to §1–§8 still resolves.
The retired text is permanent at contract tag `v0.17.1`.

Contract **v1.1.0** then added one normative paragraph to §7.

So the conformance position did not move. What moved is almost
everything this repository *said about* the contract: CLAUDE.md carried
a fifty-line clause-by-clause ledger tracking §6.3's three shapes,
§6.7's guard TU, §14's termination limbs and §15's evidence ranking, and
all four of those clauses are now gone.

### The scope rule that drove the cut

Worth stating because it is the test any future proposal will be held
to. A clause belongs in the contract only if it governs **(1) a name,
value or placement that two independently-built artifacts must agree on,
where (2) a violation is invisible from inside any single repository's
own build.** Both prongs are required.

### The verification machinery stays

`lib-verify-guards`, `lib-verify-negative` (N0–N7), `lib-verify-footprint`
and `-footprint-negative`, `ct_mul_brute_check.py --mutate`, and the
`CONTRACT_STAMP` knob-invalidation leg-C family were all built to
discharge clauses that no longer exist. **None of them is removed.**

They are kept because each has caught a real defect in this repository:
the leg-C family caught a shipped exit-0-wrong-artifact bug (#113/#114),
and the §15 evidence pass caught a footprint check that was structurally
incapable of failing (#121). The contract reaches the same conclusion
for the fleet — `RETIRED.md`: *"Keep the practice; do not keep it as an
obligation this contract imposes."*

The one thing that would now be wrong is to describe any of them as
required for conformance, or to cite one as discharging a duty. There is
no such duty. A retired-section citation in this repository describes
**repo policy we chose to keep**. That status is stated once at the top
of the `Makefile`, and once each in `tools/check_footprint.py`,
`tools/ct_mul_brute_check.py` and `docs/CT_ANALYSIS.md`.

### Retired-section citations are deliberately not rewritten

Forty-six comment lines in the `Makefile`, plus the historical
`docs/RELEASE_NOTES_v0.1*.md` files, cite §6.3 / §6.6 / §6.7 / §15.
They stay as written. `RETIRED.md` makes `v0.17.1` their permanent home
and says adopters should leave such citations alone; rewriting forty-six
comments would be forty-six chances to introduce a wrong claim while fixing
nothing a reader gets wrong. **A conformance record that cites a retired
section remains valid at the tag it cites.**

---

## 2. Normative deltas adopted

Only two clauses in the cut asked anything of this library.

### 2.1 §8.2's base-bank bound: `< $FE` → `< 31`

`src/reu_config.s`. The contract's v1.0.0 CHANGELOG names this line as
an adopter still carrying the loose bound.

`$FE` bounded the bank *number*, but not the 32-bit §5 mask the number
feeds. §5 defines `LIB_<X>_REU_BANKS_USED` as "bit *n* = bank *n*, banks
0–31", and that mask is the only thing a consumer's collision assert
reads:

```asm
.assert (LIB_NISTCURVES_REU_BANKS_USED & LIB_X25519_REU_BANKS_USED) = 0, error, "REU bank collision"
```

A base near the top of the range therefore exported a mask that omitted
a bank the table really claims, and the consumer's assert passed over
it. The default bank is `$00`, so nothing measurable changes for any
shipped configuration.

### 2.2 `src/precalc_table.inc` refreshed

To the v1.1.0 byte-verbatim copy. The upstream edits are comment-only
and the contract says adopters' copies need not be refreshed — but ours
carried a line that was **wrong**, not merely old: it said the bare
`LIB_PRECALC_<name>_*` forms were *"scheduled for removal at contract
v1.0"*, and v1.0 deliberately deferred that removal to a future MAJOR.
The header now also cites §8.4 rather than §8.0, matching the section
number the block has had since contract v0.10.3.

**Never hand-edit this file.** A local change makes the cross-adopter
audit compare things that are no longer the same macro.

---

## 3. A defect found while adopting §8.2's bound — wider than the contract's own

Adopting an upstream bound is not the same as checking your own.

§8.2's `< 31` guards the **shared two-bank pair**. x25519's default §5
mask is `$3B << X25519_REU_BANK` — five banks, spanning `base+0`,
`base+1`, `base+3`, `base+4`, `base+5` — so the binding constraint here
is `base ≤ 26`, which §8.2's bound does not reach. There was no assert
on it at all.

Measured with `od65 --dump-exports` on the emitted symbol:

| `X25519_REU_BANK` | exported mask | banks named | correct? |
|---|---|---|---|
| 26 | `0xEC000000` | 26, 27, 29, 30, 31 | yes |
| 27 | `0xD8000000` | 27, 28, 30, 31 | **no — bank 32 is gone** |

ca65 computes the shift in wider-than-32-bit arithmetic and narrows only
when it writes the export, so nothing in the assemble reports the loss.
The one diagnostic that does fire — *"Symbol is long but exported
absolute"* — starts at base 26, where the mask is still **correct**, and
says nothing about truncation. It is noise here, not a guard.

Two profile-aware asserts now sit beside the mask construction in
`src/lib_manifest.s`:

| profile | mask | bound | why |
|---|---|---|---|
| default | `$3B << base` | `base ≤ 26` | top bit is `base+5` |
| 1764 (`SQR_DMA_K=0`) | `$03 << base` | `base ≤ 30` | top bit is `base+1` |
| onchip (`X25519_ONCHIP_MUL=1`) | `0` | none | claims no banks |

Both were driven red (base 27 and base 31 respectively) and base 26 was
confirmed still green.

This is the same defect the contract just fixed one level down. It is
recorded here because the general lesson outlives the specific bound: a
guard on an input is not a guard on the derived value a consumer
actually reads.

---

## 4. Issue #122 — the guard table's citations are now checked

`make lib-verify-citations`, a new prerequisite of `lib-verify`.

The `_NEEDS_DEF_*` / `_NEEDS_VAL_*` block in the `Makefile` documents a
genuinely subtle rule: definedness-gated switches (`.ifdef` / `.ifndef`)
are matched on the **bare name**, because definedness *is* the axis and
every spelling that defines the symbol selects it; value-gated switches
(`.if ::NAME`) demand an explicit `=<value>`, because ca65's bare
`-D NAME` defines the symbol as **0** and would otherwise name an axis
while selecting the default path.

The evidence for that rule was twelve hand-maintained `file:line`
citations, and **nine pointed at blank lines, prose comments or ordinary
instructions**. The `src/fe25519.s` pair was off by one and off by nine
— correct when written, and drifted as lines were inserted above them.
Nothing read them, so nothing caught it.

Two changes:

1. **The prose now carries no line numbers at all**, so it cannot drift.
2. Six representative sites — one per switch, **deliberately not
   exhaustive**, since every one of the nine wrong citations was in a
   multi-site list — live as checked data in
   `tools/check_gate_citations.py`.

The check discriminates gate **style**, not just gate presence: a
`_NEEDS_VAL_` switch cited at a `.ifndef` line fails, and so does a
`_NEEDS_DEF_` switch cited at a `.if ::NAME` line. Asking only *"is this
line a gate?"* would let the two families be documented by each other's
shape, which is the exact confusion the table exists to prevent. All
three crossing cases were verified, plus a citation naming the wrong
switch.

`make lib-verify-citations-negative` perturbs one citation by a single
line and requires the check to fail **and** to name which switch
drifted. The `+1` line chosen is a *comment that mentions* `SQR_DMA_K`,
so a weaker "does this line mention the switch?" check would pass it;
the leg also asserts the other five citations stay green, so it cannot
be satisfied by breaking something adjacent.

Not owed to anyone — §15 is retired — but a check added specifically to
fix an unverified claim should not itself arrive unverified.

---

## 5. Two contract questions closed, one raised

### Closed: contract#167 — the ABI counter

Ruled at **v1.1.0 §7**. The counter moves on *what the code does*, not
on whether the export list changed: it moves when a consumer conforming
to the previously documented contract can be broken, and it **holds**
when documentation is corrected to match code that did not change.

v0.13.0's release notes flagged this as open and said the classification
would be revisited if #167 settled differently. It did not. The contract
CHANGELOG names x25519's case explicitly — *"c64-x25519 holds 3 at
v0.13.0 (a corrected `Clobbers` banner over unchanged code)"*.
**ABI 3 was right and stays 3**, now by ruling rather than by the
set-identity argument v0.13.0 leaned on. That argument — 138 exported
symbols on both sides, zero added, zero removed — remains true and
remains a fine sanity check; it is simply no longer what the answer
rests on.

### Closed: contract#164 — §3 header-import guards

Folded into §3 as normative at v1.0.0, and noted there as already
implemented fleet-wide. The rule is unchanged from the convention
v0.13.0 adopted ahead of ratification, so `src/x25519.inc` needed no
edit: guard a header `.import` **iff** the defining TU guards the
definition with `.ifndef`, and pair every such guard with an `.else`
asserting the override against the library's exported value via
`lderror`; where the defining TU assigns unconditionally the equate is
derived, so leave the import bare and let the `-D` collide loudly.

### Raised, and OPEN: [contract#177](https://github.com/JC-000/c64-lib-contract/issues/177)

§1 requires the deprecated bare version exports to be TU-isolated,
because *"ld65 pulls in whole object members: if the bare names share a
member with anything a consumer legitimately imports, they enter the
link uninvited and collide even when the consumer never referenced
them."*

§8.4 emits a **second** family of unprefixed, cross-library-identical
exports — `LIB_PRECALC_<name>_{SIZE,REGION,SHARED}` — under the same
`LIB_NO_BARE_EXPORTS` gate, for the same back-compat reason. Nothing
says where they may live. Ours are in `src/lib_manifest.s`, which §5
requires a consumer to import from.

Measured: a consumer importing **only** two prefixed §5 equates from two
libraries, referencing no bare name, gets

```
ld65: Error: Duplicate external identifier: 'LIB_PRECALC_sqtab_SHARED'
```

Splitting the invocations into their own archive member, changing
nothing else, links clean. `c64-nist-curves` already isolates its
invocations in `src/precalc_manifest.s`, so the fleet is split on a
point the contract does not decide.

**Nothing is changed here pending the ruling.** It would be a member-set
change in two archives, and the entire value of the rule is that both
sides do the same thing.

---

## 6. Verification

Everything below was run on the release commit, from a clean tree.

| check | result |
|---|---|
| `make all` | `build/x25519.prg` `08d1fef1…f333`, 8628 B — byte-identical to v0.12.0 and v0.13.0 |
| `make lib` + `make lib-verify` | green, default profile, mask `$000007` |
| `make lib-verify-shared` | green, four `SHARED_*` deferral legs |
| `make lib-x25519-1764` / `-onchip` / `lib-app-owned` | green |
| `make lib-verify-guards` | green — seven negative legs, each red with its own named error |
| `make lib-verify-negative` | green — N0–N7, each red with its named message |
| `make lib-verify-footprint-negative` | green — falsifiable in both the default and onchip arms |
| `make lib-verify-citations` / `-negative` | green — six sites; the negative leg names `SQR_DMA_K` |
| `make test` | green |
| `make test-vice` | green |
| new §5 mask asserts | driven red at base 27 (default) and base 31 (shared pair); base 26 confirmed green |

No CT-relevant code changed, so `docs/CT_ANALYSIS.md`'s catalogue L1–L32
is unchanged and no leak site is added or reopened. `mul_8x8` /
quarter-square are untouched, so no `ct_mul_brute_check.py` rerun is
owed by this release.

---

## 7. Consumer action

**None.** No exported symbol changes name, value or address; the archive
member set is unchanged; the header is unchanged. A consumer pinning
v0.13.0 can move to v0.14.0 with no edit and no rebuild of its own
sources.

The one thing worth knowing is the new assert in `src/lib_manifest.s`:
if you relocate the REU window with `-D X25519_REU_BANK=<n>` and pick
`n > 26` on the default profile (or `n > 30` on 1764), the build now
**fails at assemble time with a named error** where it previously
succeeded and exported a mask that quietly under-reported the banks the
library claims. That is a fix, but it is a build that used to exit 0.
