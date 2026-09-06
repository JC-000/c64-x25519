# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

X25519 (RFC 7748) for the Commodore 64 in ca65 6502 assembly, targeting a stock C64 + 1750 REU. Differentially validated against `pyca/cryptography` driven through VICE. Designed to be **vendored as source** into downstream C64 projects, not linked as a system library.

Current release: **v0.16.0** (released 2026-09-06) — the settling release against c64-lib-contract SPEC **v1.2.2** (frozen). ABI stays **4**; MINOR (a member is added, no symbol added/removed/renamed). **PRG unchanged from v0.15.0** at `a17cbc81…`, 8628 B. Closes #128: `mul_8x8.o` mixed two displaceable groups dropped by *different* switches, so owning §8.3 while deferring §8.1 could not link from the shipped archive — split into `src/sqtab_init.s` (§8.1) and `src/mul_8x8.s` (§8.3). Also cross-checks the §5 footprint basis against a real link map. Previous: **v0.15.0** (member isolation count 2, §8.2's `A = a` entry, ABI 3 → 4, the CT alignment fix; PRG changed), **v0.14.0** (contract alignment, count 1, §8.2 staging pin, #122; PRG byte-identical to v0.12.0 at `08d1fef1…f333`). Public `fe25519_*` / `x25519_*` API is semver-locked.

**Contract position: SPEC v1.2.2 §1–§8 satisfied; both member-isolation counts closed; #122/#127/#128 closed.** One known gap, tracked at [#130](https://github.com/JC-000/c64-x25519/issues/130) and **not** a §6.1 matter: `src/x25519.inc` imports `ct_mul_8x8` outside the `SHARED_CT_MUL_8X8` gate (the gate on the next line covers only `mul_8x8`), so a §8.3-owning consumer gets `Cannot import exported symbol` at assemble time and cannot use the header at all. #128 fixed the *archive* side; this is the *header* side. §3's guard rule is textually scoped to "an overridable equate", so a §8.3 code name is the same hazard one clause over, not a §3 breach.

**Three things this repo learned the hard way today. They are cheap to state and expensive to rediscover.**

1. **Alignment by derivation is everywhere, and a split spends it.** `mul38_lo_tab` was page-aligned only because it followed three exact 256-byte buffers; moving those buffers dropped it to `$1A85` and the ladder's cycle spread went 0 → 83,342 against a 17,045 threshold. Every functional test, all seven profiles and every existing alignment assert stayed green — **only `tools/test_ct_ladder_cycles.py` failed.** The same shape then turned up in the §5 footprint basis (`data.o`'s contribution ends on a page boundary *by luck*, so no link fill appears). Ask "what makes this true, and what would have to change for it to stop being true", not "does it have an `.align`" — a directive sweep finds neither unguarded case.
2. **A negative test proves nothing until the positive control links.** Two #128 harnesses failed *before* ld65 reached member resolution, so "no duplicate reported" meant nothing. Both would have read as confirmation.
3. **A check can be green because of the bug it sits next to.** `lib-verify` grepped the linked stub for `LIB_PRECALC_sqtab_SIZE`, which only ever resolved because the precalc names rode in on `lib_manifest.o`. Fixing the defect turned the check red. When a check goes red after a fix, ask whether it was testing the fix or the bug.

**Known gap, tracked at [#128](https://github.com/JC-000/c64-x25519/issues/128), targeted at v0.16.0.** `mul_8x8.o` exports two displaceable groups dropped by *different* switches — `SHARED_SQTAB_INIT` takes `sqtab_init`/`mul_tables_init`, `SHARED_CT_MUL_8X8` takes the six §8.3 names. A consumer owning §8.3 but not §8.1 defines the second group itself and still imports `sqtab_init`; that import pulls the member, which arrives carrying the §8.3 names. Measured against the shipped v0.14.0 archive with the real example cfg: `ld65: Error: Duplicate external identifier: 'smc_diff_a_imm'`. The seam is clean — the two bodies have zero cross-references and already live in different segments — but the split moves *code*, so it changes the PRG and owes its own full VICE suite rather than riding on v0.15.0's.

## The contract, after the v1.0.0 cut

**Aligned with c64-lib-contract SPEC v1.1.0** (tag `358c2b4`, 2026-09-03). Read this section before citing any section number, because the document changed shape more than it changed content.

**What v1.0.0 did.** It deleted roughly seven eighths of SPEC.md — 40,737 words to 5,154 — and **changed no symbol, equate, bit value, segment name, build target or error code**. A library conformant at v0.17.1 is conformant at v1.1.0 without edits, and x25519 was. Retired outright: **§9, §12, §13, §14, §15 and sub-clauses §6.3, §6.6, §6.7**. Surviving sections kept their numbers, so §1 §2 §3 §4 §5 §6.1 §6.2 §6.4 §6.5 §7 §8.x still resolve. The retired text is permanent at contract tag `v0.17.1` (`git show v0.17.1:SPEC.md`).

The cut is governed by a stated scope rule, and it is the thing to apply to any future proposal: a clause belongs in the contract only if it governs **(1) a name, value or placement that two independently-built artifacts must agree on, where (2) a violation is invisible from inside any single repository's own build.** Both prongs required.

**What this repo owes now: §1–§8 of v1.1.0, and nothing else.** `make lib-verify` covers it.

**What NOT to do about the retired sections.** Forty-six comment lines in the `Makefile` (measured), plus `tools/check_footprint.py`, `tools/ct_mul_brute_check.py`, `docs/CT_ANALYSIS.md` and every `docs/RELEASE_NOTES_v0.1*.md`, cite §6.3 / §6.6 / §6.7 / §15. **Leave them.** RETIRED.md makes `v0.17.1` their permanent home and says in terms that adopters should not rewrite such citations; doing so would be forty-six chances to introduce a wrong claim while fixing nothing a reader gets wrong. What was fixed instead is the *status* those citations carry, stated once at the top of the `Makefile` and once each in the three tools/docs above: **a retired-section citation here describes repo policy this project chose to keep, not a live obligation.**

**The machinery stays.** `lib-verify-guards` (seven legs), `lib-verify-negative` (N0–N7), `lib-verify-footprint` and `-footprint-negative`, `ct_mul_brute_check.py --mutate`, and the `CONTRACT_STAMP` leg-C knob-invalidation family were all built to discharge clauses that no longer exist. They are kept because they work, and because this family of checks has caught real defects here: leg C caught a shipped exit-0-wrong-artifact bug (#113/#114), and the footprint evidence pass caught a check structurally incapable of failing (#121). That is two named finds, not one per target — the rest are kept on the same reasoning, not on their own track record. The contract agrees — RETIRED.md: *"Keep the practice; do not keep it as an obligation this contract imposes."* Deleting any of it would be the wrong reading of a release whose headline is that **text** was deleted. The one thing now wrong is to describe any of them as required for conformance.

**Two rulings that closed open questions this file used to hedge on.** Both are settled; do not re-open them.

- **contract#167 (ABI counter) is CLOSED**, ruled at v1.1.0 §7: the counter moves on *what the code does*, not on whether the export list changed — it moves when a consumer conforming to the previously documented contract can be broken, and **holds** when documentation is corrected to match code that did not change. x25519's v0.13.0 `Clobbers`-banner correction over unchanged code is named in the contract CHANGELOG as exactly that case. **ABI 3 holds**, now by ruling rather than by the export-set argument this file used to make. (That argument — 138 symbols either side, `od65 --dump-exports` diffed against `9e85818` — remains true and remains a fine sanity check; it is simply no longer what the answer rests on.)
- **contract#164 (§3 header-import guards) is CLOSED**, folded into §3 as normative at v1.0.0 and noted there as already implemented fleet-wide. The rule is unchanged from the convention this repo already followed: guard a header `.import` **iff** the defining TU guards the definition with `.ifndef`, and pair every such guard with an `.else` asserting the override against the library's exported value via `lderror`; where the defining TU assigns unconditionally the equate is derived, so leave the import bare and let the `-D` collide loudly. Here `X25519_REU_BANK` / `X25519_REU_OFFSET` are guarded (`src/reu_config.s` defines them under `.ifndef`), while `X25519_REU_BANK_DOUBLED` / `X25519_REU_BANK_CARRY` are bare (assigned unconditionally, derived from `X25519_REU_BANK`). See `src/x25519.inc`.

**Normative deltas adopted at v0.14.0.** Only two clauses in the cut actually asked anything of us:

- **§8.2's base-bank bound, `< $FE` → `< 31`** (`src/reu_config.s`). The contract CHANGELOG names our line as an adopter still carrying the loose bound. `$FE` bounded the bank *number* but not the 32-bit §5 mask it feeds, so a base near the top exported a mask that omitted a bank the table really claims — and a consumer's disjointness assert passed over it. Default bank is 0, so nothing measurable changed.
- **`src/precalc_table.inc` refreshed** to the v1.1.0 byte-verbatim copy (comment-only upstream edits: the header now says §8.4 rather than §8.0, and the bare-form removal is "deferred to a future MAJOR" rather than "scheduled for contract v1.0"). The contract says adopters' copies need not be refreshed; ours was refreshed because the stale line was *wrong*, not merely old. **Never hand-edit this file** — a local change makes the cross-adopter audit compare things that are no longer the same macro.

**One defect found while aligning, fixed here, wider than the contract's own.** §8.2's `< 31` guards the *shared two-bank pair*. x25519's default §5 mask is `$3B << X25519_REU_BANK` — five banks spanning base+0..base+5 — so the binding constraint is base ≤ 26, which §8.2's bound does not reach. Measured with `od65 --dump-exports`: base 26 exports `0xEC000000` (correct), base 27 exports `0xD8000000` — bank 32 silently gone, because ca65 computes the shift in wider-than-32-bit arithmetic and narrows only when writing the export. Two profile-aware `.assert`s now sit beside the mask construction in `src/lib_manifest.s` (≤ 26 default, ≤ 30 for 1764, none for onchip, which claims no banks). This is the same defect the contract just fixed one level down, and it is worth remembering that adopting an upstream bound is not the same as checking your own.

**contract#177 is SETTLED, and it cost us a member split.** §1 required the deprecated bare version exports to be TU-isolated because "ld65 pulls in whole object members"; §8.4 emitted a second family of unprefixed, cross-library-identical exports — `LIB_PRECALC_<name>_{SIZE,REGION,SHARED}` — and nothing said where they may live. Ours were in `src/lib_manifest.s`, the member §5 requires a consumer to import from. Measured: a consumer importing *only* two prefixed §5 equates from two libraries, referencing no bare name, got `ld65: Error: Duplicate external identifier: 'LIB_PRECALC_sqtab_SHARED'`. Settled at contract **SPEC v1.2.0**, which states the mechanism once as **§6.1 member isolation** and has §1 and §8.4 cite it:

> ld65 links whole archive members. A symbol a consumer may displace — suppress under `LIB_NO_BARE_EXPORTS`, or define itself under `APP_OWNED` (§8.0) — MUST live in a translation unit that exports nothing else a consumer may import — other displaceable names included — and defines nothing else the library's own code references.

Discharged here at v0.14.0 by `src/precalc_manifest.s`, matching `c64-nist-curves`. **Do not add anything to that file**, and note `make lib-verify-isolation` now asserts the property rather than trusting it.

One thing that split taught, worth keeping: **`lib-verify` had a green check whose greenness depended on the defect.** It grepped the linked stub for `LIB_PRECALC_sqtab_SIZE`, which only ever resolved because the precalc names rode into the link on `lib_manifest.o`. After the split the member is correctly absent from a stub referencing nothing in it, and the check failed. It is now split in two: the stub imports the sqtab SIZE the way a real consumer would, and the `far`-sized `reu_mul` ones (ca65 auto-sizes 131072 to `far`, and the 6502 target has no matching import hint) are checked at archive level with `od65`. When a check goes red after a fix, ask whether it was testing the fix or the bug.

**Still owed — member isolation count 2, deliberately NOT in v0.14.0.** `src/data.s` defines the §8.2 staging buffers `mul_dma_lo` / `mul_dma_hi` / `mul_dma_carry` — an `APP_OWNED` surface — beside 33 names the library's own code references, so any reference to any of them pulls `data.o` in and drags the buffers along, colliding with a consumer's own definitions. This is the shape that cost `c64-https` all three configurations on `c64-nist-curves` v0.12.0 (contract#179, nist-curves#149). The fix is to isolate the three buffers in a TU containing nothing else — **not** conditional definition: ld65 pulls a member only to resolve a *still-unresolved* import, so under APP_OWNED the consumer's own object satisfies them before the archive is scanned and an isolated member is never pulled. It is held out of v0.14.0 because it reorders `LIB_X25519_DATA` and **changes the PRG** (measured: `6208f1f2…`, still 8628 B), and these buffers are CT-critical — page alignment is hard-asserted, and eight `adc mul_dma_*,y` sites index with secret Y across 0..255 — so it owes a full VICE suite, not a packaging release's evidence. Verified clean already: the SMC patch site (`reu_fetch_mul_row_bank_patch`) carries a *bank* byte, not a buffer address, and every buffer reference is a `#<(mul_dma_*)` relocation ld65 fills in, so a consumer-supplied address propagates with no hand-rebuilt copy.

**Earlier clause-by-clause history has been removed from this file.** It ran to fifty lines tracking §6.3's three shapes, §6.7's guard TU, §14's termination limbs and §15's evidence ranking — every one of those clauses is now retired, and the surviving obligations are short enough to state directly. The reasoning is not lost: it is in `docs/RELEASE_NOTES_v0.11.*.md` through `v0.13.0.md`, which are historical records and stay as written. Two facts from it are still load-bearing and are restated below because nothing else records them.

**Fact 1 — the guard matches each switch on its own gate style; do not unify the spellings.** `ca65`'s bare `-D NAME` defines the symbol **= 0** (measured), so the two families need opposite treatment:

| family | gate | guard demands | why |
|---|---|---|---|
| `SHARED_SQTAB_INIT`, `SHARED_REU_MUL_INIT`, `SHARED_REU_MUL_FETCH`, `SHARED_CT_MUL_8X8` | `.ifdef` / `.ifndef` | the **bare name** | definedness *is* the axis, so every spelling that defines it selects it. Demanding `=1` here falsely rejects `-D SHARED_SQTAB_INIT`, the form nist#117 and the chacha docs use. |
| `X25519_ONCHIP_MUL` | `.if ::NAME` | `X25519_ONCHIP_MUL=1` | **load-bearing**: bare `-D X25519_ONCHIP_MUL` is 0, which names the profile while selecting the *default* path — a silent no-op. |
| `SQR_DMA_K` | `.if ::NAME` | `SQR_DMA_K=0` | deliberately stricter than needed — bare would also select 1764 (ca65 makes it 0) — so that a value-gated switch never rides on the silent bare-means-zero rule and the `=0` stays visible in the build line. |

The gate **sites** are deliberately not listed here or in the Makefile. They live as checked data in `tools/check_gate_citations.py`, verified by `make lib-verify-citations` on every `lib-verify`. That is issue #122's fix: the Makefile used to carry twelve hand-maintained `file:line` citations and **nine pointed at blank lines, prose comments or ordinary instructions** — the `src/fe25519.s` pair off by one and off by nine, i.e. correct when written and drifted as lines were inserted above. Nothing read them, so nothing caught it. Prose holding no line numbers cannot drift, and the numbers that remain now fail the build that moves them.

**Fact 2 — `X25519_PROFILE` is guarded at parse time, and the knob stamp is separate from it.** Unknown `X25519_PROFILE` values are a hard `$(error)`, and a known value must be accompanied by the `-D` that actually selects it (Makefile, just below `X25519_PROFILE ?= default`). Separately, `CONTRACT_STAMP` deletes both objects **and linked outputs** on a knob change — `PRG` / `LABELS` / `LIB_VERIFY_DIR` are hoisted **above** the stamp block because `$(shell …)` expands at parse time and a version spelled with them unhoisted expands them empty and is a silent no-op. Both were needed: we had the guard and still shipped a stale PRG on three knobs, because GNU Make 3.81's whole-second mtime granularity let the newest `.o` land in the same second as the existing PRG. No released artifact was ever affected (`tools/build_release.sh` ships a `git archive` of source).

**Verifying a profile axis:** compare **linked output or `od65 --dump-segsize` dumps**, never archive or object bytes. `ca65` stamps `OPT_DATETIME` plus source paths into every object unconditionally, so raw byte comparison is non-deterministic across rebuilds yet byte-*identical* within the same second — it can report both false differences and false sameness. `od65` is structural: e.g. `x25519_init.o` carries 666 bytes of `LIB_X25519_INIT_CODE` in the default profile and 0 in onchip.

**Consumers pin us, so no zero-consumer carve-out applies.** The contract's §1 and §8.4 carve-outs (a library with no released consumers SHOULD NOT export the bare forms) and §6.5's prefixed-basename one all share the scope test *no tagged release any consumer pins*. `consumers.md` records `c64-https` pinning v0.11.2 and `c64-wireguard` pinning v0.10.1. **x25519 fails that test, so the incumbent rules bind**: member basenames stay on the MAJOR path, and §1's `MUST also export` the bare forms still applies — gated, as they already are, in `src/lib_version.s` under `.ifndef LIB_NO_BARE_EXPORTS`.

## Build / test commands

```
make                 # build build/x25519.prg (standalone test harness)
make clean
make lib             # build build/lib/x25519.a (canonical §6.1 basename; libx25519.a
                     #   ships alongside as the deprecated dialect) + .o + inc + cfg
make lib-verify      # smoke-test the archive via tests/lib_linkage stub
make lib-verify-docs # assert the doc/header consumer snippets are pasteable as
                     #   written (prerequisite of lib-verify)
make lib-verify-citations  # assert the Makefile guard table's file:line gate
                     #   citations still name a gate OF THE DOCUMENTED STYLE
                     #   (#122; prerequisite of lib-verify)
make lib-verify-shared  # linkage matrix for the four SHARED_* deferral builds (R6)
make lib-verify-guards  # §6.6/§6.7 NEGATIVE legs — guards must fail with named errors
                     #   (leg C family runs for BOTH default and onchip)
make lib-verify-footprint  # §5 RESIDENT/COLD DERIVED from od65 over the shipped
                     #   archive, not restated. Also runs inside lib-verify, so
                     #   all seven profiles get it.

# --- Negative legs: a check never seen to fail is not evidence that the
# --- property holds. Built for SPEC v0.17.0 §15, RETIRED at contract v1.0.0
# --- and KEPT as repo policy. Each is re-runnable, not a one-off transcript.
make lib-verify-citations-negative  # perturb one gate citation by a line; the
                     #   check must fail AND name which switch drifted
make lib-verify-footprint-negative  # 16 nops into fe25519_add on a throwaway
                     #   src copy; the derived check MUST fail and name the segment
make lib-verify-negative            # one negative leg per assertion INSIDE
                     #   lib-verify (N0..N7); each must fail with its named message
python3 tools/ct_mul_brute_check.py --mutate  # §8.3 tool's own negative leg;
                     #   must report counted mismatches, not error out (needs VICE)
make lib-app-owned   # §6.3 all-primitives-app-owned archive (x25519-app-owned.a)
make lib-x25519-1764 # 256 KB-REU variant (SQR_DMA_K=0)
make lib-x25519-onchip  # no-REU variant (X25519_ONCHIP_MUL=1)

# Consumer overrides flow through §6.2 defines-forwarding:
#   make lib CONTRACT_DEFINES="-D LIB_SHARED_SQTAB_BASE=0xC000"
#   make lib CONTRACT_ZP_DEFINES="-D fe25519_src1=0x32"   # library TUs only
# (CA65FLAGS remains as a deprecated alias; hex values use 0x — an
#  unquoted $-hex is eaten by the shell and silently defines 0.)

make test            # python3 tools/ref_x25519.py (no VICE, fastest)
make test-vice       # subset: mul38, fe25519, fe_mul/sqr stress, ct_square_cycles, reduce_wide_carry
make test-slow       # full suite (requires VICE + built .prg)
```

Single test run: `python3 tools/<name>.py [--slow]`. Benches live in `tools/bench_*.py` and are NOT run by `make test-slow`.

## Toolchain

- `ca65` / `ld65` / `ar65` (cc65 suite) — `brew install cc65`
- VICE emulator for `make test-vice` / `make test-slow` — `brew install vice`
- Python 3 + `pyca/cryptography` + `c64-test-harness` package
- macOS: zsh, BSD `sed`/`grep`. `sha256sum` is not installed — use `shasum -a 256`.

## Architecture (big picture)

The library is 13 ca65 `.o` modules (no `main.o`, which is the BASIC stub / test harness / region-guard TU — downstream supplies its own entry point and mirrors the guard; the guard was built for §6.7, retired at contract v1.0.0 and kept because the overrun it catches is real). Module layout in `src/`:

```
x25519.s       Montgomery ladder, x25519_clamp / _scalarmult / _base
fe25519.s      Field arithmetic mod p = 2^255 - 19
mul_8x8.s      §8.3 ct_mul_8x8 CT multiply body ONLY — ISOLATED TU
sqtab_init.s   §8.1 sqtab_init / mul_tables_init ONLY — ISOLATED TU
               (split at v0.16.0, #128: the two groups are dropped by
               DIFFERENT switches, so sharing a member made "own §8.3,
               defer §8.1" unsatisfiable. Do not merge them back.)
x25519_init.s  sqtab_init, reu_mul_init, REU fetch helpers; §8.2 deferral gates
data.s         Page-aligned static buffers (CT-critical alignment)
util.s         vic_blank/unblank, bench_start/stop (jiffy clock)
lib_version.s  Contract §1 version equates ONLY (TU-isolated; bare aliases gated)
lib_manifest.s Contract §5 aggregates and §8.0 masks ONLY
precalc_manifest.s  §8.4 precalc enumeration — ISOLATED TU, add nothing to it
mul_stage.s    §8.2 staging buffers mul_dma_lo/hi/carry — ISOLATED TU, add
               nothing to it (§6.1 member isolation; contract#179's shape)
zp_config.s    Contract §2 ZP slot inventory (.ifndef-guarded, .exportzp'd)
reu_config.s   Contract §3/§8.2 REU bank + placement equates and asserts
constants.s    .include'd by every .s; never assembled alone
precalc_table.inc  Byte-verbatim copy of the contract's §8.4 macro — never hand-edit
x25519.inc     Public header (imports list + full API docs) — canonical API surface
```

Dep sketch: `x25519.s → fe25519.s → mul_8x8.s` and `x25519.s → x25519_init.s (REU)` and `→ data.s (buffers)`. `util.s` is standalone.

### Hardware contract

- **REU:** 1750 or equivalent, ≥512 KB default (claims 5 banks = mask `$3B`: mul tables + doubled/carry; bank 2 in the window is NOT claimed). The 1764 variant claims banks 0–1 only (`$03`, 256 KB); the onchip variant claims none. Library uses REU autoload; leaves `$DF00–$DF0A` ready-for-next-call. Callers that also touch the REU must save/restore.
- **Zero page:** library owns `$14–$7F` while running and does NOT preserve it across calls. (`$FB-$FE` is test-harness-only scratch, local to `main.s` since contract #83 — not part of the library claim.) Hosts can override the ZP layout via `.ifndef` guards in `src/constants.s` (see `docs/LIBRARY.md` §4.2) to compose with sibling crypto libs.
- **No RNG.** Caller generates / stores / zeros keys.

### Constant-time discipline (NON-NEGOTIABLE)

The threat model is network-observable timing against `fe25519_*` and the outer ladder. (`mul_8x8` is boot-only — sole caller `reu_mul_init`'s public table enumeration, no secret inputs — so it has no network-observable exposure; it retains constant-time discipline as the canonical c64-lib-contract §8.3 shared-primitive shape, byte-identical to the chacha owner.) All 31 catalogued leak sites L1–L31 are closed (L31 is the §8.2 REU settle — a branch on hardware state, argued in `docs/CT_ANALYSIS.md`). When touching the hot path:

- **No secret-dependent branches.** Every branch must depend only on **public** loop indices.
- **No `(zp),y` indirect loads on secret operands.** Use direct indexed loads from page-aligned buffers.
- **No zero-skip / early-exit shortcuts** on secret data.
- **32-byte buffer alignment is a CT invariant**, not a perf hint. Field buffers MUST start at `$00/$20/.../$E0` within their page so `,y`-indexed access over 32 bytes never crosses a page boundary. This is hard-asserted in `src/data.s`.
- `fe25519_sqr` carries use an unconditional per-body pending-carry chain + public-indexed end-of-inner ripple (Phase 6 / L19–L22 fix). The diagonal `@diag_prop` path uses the same Phase-6-style unconditional ripple (L23 fix).
- Ladder bit-loop branches use the branchless `cmp/sbc/eor` bit-to-mask idiom (L24 fix).

When you add or change anything CT-relevant, **extend the leak catalogue in `docs/CT_ANALYSIS.md`** — do not assume "probably fine." Re-run `tools/ct_mul_brute_check.py` if the change touches `mul_8x8` / quarter-square. CT regressions are not allowed to be "fixed later" — correctness and CT-cleanliness take precedence over jiffy count.

### Testing posture

- Oracle is `pyca/cryptography`, **never** a repo-local reimplementation — avoids shared-bug failure modes between test code and asm under test.
- Differential tests use reproducible random seeds, hard asserts on every comparison.
- `tools/test_fe_reduce_wide_carry.py` is a permanent regression for a real `$FF`-cascade carry bug caught in v0.1.0 prep (`48092b5`). Don't delete it.
- `tools/test_ct_square_cycles.py` is the CT cycle-count guard for `fe25519_sqr` (≤1 jif spread across structurally distinct inputs). Treat as a CT regression gate, not a perf bench.

## Conventions

### Assembly (`src/*.s`)
- Long `;` header block per file (purpose, invariants, design notes), then `.setcpu "6502"`, `.include "constants.s"`, `.export`/`.import`, `.segment "CODE"`.
- Every public routine wrapped in `.proc name … .endproc` with banner comment for inputs / outputs / clobbers (A / X / Y / ZP / wide).
- Local labels inside `.proc` use `@label` form for per-proc namespacing.
- Naming prefixes: `x25519_*` (public ECDH), `fe25519_*` (field), `mul_*` (multiply), `reu_*` (REU), `sqtab_*` / `mul38_*` / `sqr_*` (tables), `bench_*`, `vic_*`. ZP scratch: `fe_*`, `x25_*`, `mul_*`, `lmul0/1`, `mul_dma_*` (the old `poly_*` ZP prefix is chacha-registered per SPEC v0.9.0 §2 and no longer used here). Public buffers: `x25_scalar`, `x25_u`, `x25_result`, `x25_basepoint`.
- Little-endian throughout. Prefer `DEX`/`DEY` for carry-dependent loops (CPX/CPY clobber carry).

### Python (`tools/*.py`)
- Python 3, no required formatter or type hints. No `pytest`/`ruff`/`black` config — tools are run directly via `python3 tools/...`.

### API stability
- `src/x25519.inc` is the canonical API header — copied to `build/lib/x25519.inc` by `make lib`. Keep its `.import` block in sync with library exports. Additive → minor bump; breaking → major bump. `make lib-verify` asserts the expected public symbols are still present.

## Reference docs in repo

- `docs/LIBRARY.md` — integration guide, memory map, public API
- `docs/CT_ANALYSIS.md` — leak catalogue L1–L32, threat model, Phase 6 correctness/CT argument. **Authoritative for any CT discussion.**
- `docs/RELEASE_NOTES_v*.md` — per-release perf + CT posture story

## Workflow notes

- `build/` and `build/lib/` are `.gitignore`d. Don't commit generated artifacts.
- Don't "fix" a failing differential test by editing the test — pyca is the oracle; the asm is wrong until proven otherwise.
- After CT-relevant changes: update `docs/CT_ANALYSIS.md`, re-run `ct_mul_brute_check.py` if `mul_8x8`/quarter-square changed, and run `make test-slow`.
- After perf changes: re-measure via `tools/bench_x25519.py` / `bench_fe_mul.py` / `bench_fe_ops.py` with `jsr vic_blank`, then update jiffy counts in `README.md` and the relevant release notes — don't leave stale numbers.

## Serena MCP

This repo is a Serena-onboarded project (`.serena/` present, memories under `.serena/memories/`). Activation is **not automatic** — call `mcp__serena__activate_project` with this path at the start of a session, then `mcp__serena__initial_instructions` if not already read. Existing memories: `project_overview`, `code_structure`, `tech_stack`, `suggested_commands`, `style_and_conventions`, `ct_and_security_notes`, `task_completion_checklist`.
