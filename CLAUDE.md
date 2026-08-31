# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

X25519 (RFC 7748) for the Commodore 64 in ca65 6502 assembly, targeting a stock C64 + 1750 REU. Differentially validated against `pyca/cryptography` driven through VICE. Designed to be **vendored as source** into downstream C64 projects, not linked as a system library.

Current release: **v0.13.0** (prepared 2026-08-31; **NOT YET TAGGED** — release PR open, tagging is behind a review gate; the tarball SHA256 and size are published in the GitHub Release description at tag time, never as a `TBD` here — the approach under discussion on contract#168, which is OPEN and not ratified; we adopt it ahead of ratification deliberately). v0.13.0 is a build-integrity and evidence release: **the PRG is byte-identical to v0.12.0** at `08d1fef1…f333`, 8628 B, and everything in it is documentation, header, build-invalidation and verification machinery (#121 consumer-override integrity + twelve doc defects; #123 SPEC v0.17.0 §15 evidence discharge). MINOR because `.import reu_probe` was added to the canonical header; `LIB_X25519_ABI_VERSION` stays 3. **Do not cite contract#167 as settled — it is OPEN**, and this library's own `reu_fetch_mul_row` case is one of the cases it is still weighing. Its proposed discriminator (can a consumer that was conforming before the change be broken by it?) answers no here, but the decision does not rest on it: the exported surface is set-identical across the release — 138 symbols in the default archive on both sides, zero added, zero removed, `od65 --dump-exports` diffed against `9e85818` — so ABI 3 holds under every candidate rule on that issue. Previous release **v0.12.0** (released 2026-08-29; annotated tag `v0.12.0` on `ce6f8d5`; tarball 143,836 B, SHA256 `b6b7c930…4902`) — full CT certification, catalogue L1–L32 closed. Public `fe25519_*` / `x25519_*` API is semver-locked. Contract-aligned through c64-lib-contract SPEC **v0.17.0** (tag `2d7f40c`). Ledger since v0.11.1 (§6 build-and-consume chapter, §6.6/§6.7 guards, §2 ZP prefix registry, §6.3 reject-or-invalidate): **v0.13.0 §8.2** (`c771935`; REU post-execute settle — #115 / contract#146 / PR #116: every `sta reu_command` is followed by the `REU_SETTLE` macro in `src/constants.s`, knob `X25519_REU_SETTLE_ITER`, clock claim `X25519_MAX_CLOCK_MHZ` asserted ≤ 48, sticky `x25519_reu_fault`; conformance claimed at ≤ 48 MHz only, 64 MHz unbracketed; see `docs/LIBRARY.md` §4.12 and `docs/CT_ANALYSIS.md` L31); v0.14.1 (`62a9d78`, PATCH) names both §8.2 read-once capture forms — we use whole-byte `lda`, keeping bit 5 — and adds a non-normative SHOULD for structural settles, which x25519 does not rely on; v0.14.2 (`bffe36b`) is doc-only; v0.15.0's §8.4 zero-consumer carve-out for the bare `LIB_PRECALC_*` triple is inapplicable (we have released consumers) and `precalc_table.inc` is unchanged; v0.12.0 / v0.12.1 / v0.14.0 are §13.x networking and N/A to x25519; **v0.16.0 §14** (`3a91ebb`) owes nothing — N1 is discharged by the straight-line Fermat inversion chain and the fixed 256-bit ladder, and this library's CT invariant is strictly stronger; **v0.17.0 §15** (`2d7f40c`) is SHOULD-level, not retroactive, and scoped to checks we CITE as evidence — discharged at PR #123 (derived footprint check `tools/check_footprint.py` wired inside `lib-verify`, `ct_mul_brute_check.py --mutate`, eight per-check `lib-verify-negative` legs, and the two-profile `lib-verify-footprint-negative` demonstration). v0.12.0 also carries the 2026-08-28 adversarial audit (PR #117, `docs/AUDIT_2026-08-28.md`): `fe25519_mul_a24` dropped its byte-31 carry-out (fixed, L32), the Inv3 bound is corrected to < 2^256, and two never-passing tests were repaired and wired into `test-slow`.

v0.10.4 required no change here: it scopes §6.3's no-further-matrix posture to *define-reachable* combinations and rules that a documented **member-set** axis must take its own §6.1 target. Every x25519 profile (`lib`, `lib-app-owned`, `lib-x25519-1764`, `lib-x25519-onchip`, all four `SHARED_*` deferral legs) is built by re-invoking `make lib` over the single fixed `LIB_OBJS` list with different `CONTRACT_DEFINES`, so all of them ship the same ten members. No axis here is member-set-shaped.

v0.10.5 **did** require a change: its §6.3 looks-reachable clause (a knob naming an axis MUST select it or fail loudly) caught `X25519_PROFILE` as a live shape-3 "silent no-op" — `make lib X25519_PROFILE=onchip` exited 0 and shipped a default archive, and a typo'd value fell through the `ifeq` chain's closing `else` into `default`. Both are now hard `$(error)`s at parse time (Makefile, just below `X25519_PROFILE ?= default`): unknown values are rejected, and a known value must be accompanied by the `-D` that actually selects it. The named profile targets pass both together, so they satisfy it by construction.

**The guard matches each switch on its own gate style — do not unify the spellings.** `ca65`'s bare `-D NAME` defines the symbol **= 0** (measured), so the two families need opposite treatment:

| family | gate | guard demands | why |
|---|---|---|---|
| `SHARED_SQTAB_INIT`, `SHARED_REU_MUL_INIT`, `SHARED_REU_MUL_FETCH`, `SHARED_CT_MUL_8X8` | `.ifdef` / `.ifndef` (`mul_8x8.s:37,55`, `x25519_init.s:14,94`) | the **bare name** | definedness *is* the axis, so every spelling that defines it selects it. Demanding `=1` here falsely rejects `-D SHARED_SQTAB_INIT`, the form nist#117 and the chacha docs use. |
| `X25519_ONCHIP_MUL` | `.if ::NAME` (`lib_manifest.s:177,361`) | `X25519_ONCHIP_MUL=1` | **load-bearing**: bare `-D X25519_ONCHIP_MUL` is 0, which names the profile while selecting the *default* path — the exact shape-3 no-op the guard exists to kill. |
| `SQR_DMA_K` | `.if ::NAME` (`x25519_init.s:25`, `fe25519.s:40`) | `SQR_DMA_K=0` | deliberately stricter than conformance needs — bare would also select 1764 (ca65 makes it 0) — so that a value-gated switch never rides on the silent bare-means-zero rule and the `=0` stays visible in the build line. |

**v0.11.1 DOES require a change, and it is not optional.** (Cite it by tag: v0.11.1 = `cc3f8a6`. It sat untagged on contract `main` as commit `de5d354` for a while — the contract README tracked that as a #71-shape gap — but as of 2026-08-28 the contract has tagged v0.11.1 `cc3f8a6`, v0.12.0 `a6bb30a`, v0.12.1 `42c84bd`, v0.13.0 `c771935`, v0.14.0 `e76bcff`.) §6.3 now states which consequence its select-or-reject rule carries in which case: *"A §6.2 knob value the target cannot honor MUST be rejected at parse time; one it can honor MUST invalidate whatever it reconfigures."* The branch is decided by the member-set/configuration split the v0.10.4 paragraph draws.

**x25519 lands entirely on the invalidation branch.** `LIB_OBJS` (Makefile:112) is a single unconditional assignment — no `+=`, no conditional member selection — so there is no member-set axis here and nothing takes the parse-time-rejection branch. Every knob we accept is a configuration axis the targets *can* honor, so every one of them owes invalidation. That is what `CONTRACT_STAMP` (Makefile:99) + the leg-C family of `lib-verify-guards` implement, **merged at PR #110**, with the pin itself repaired at **#114** (its no-rebuild leg compared minute-granular `ls -l` output and could never fail — see #113; legs now count `ca65` invocations and follow the clause's C1/C2 ordering) — before it, the three measured vectors (§8.3 deferral, `LIB_NO_BARE_EXPORTS`, `LIB_SHARED_SQTAB_BASE`) were exactly the exit-0-wrong-artifact emission the clause forbids.

**The conformance claim was overstated, and is now repaired.** It read "conformant as of master `76e0e46`, verified on the merged tree rather than on either branch: all four §6.1 sequences, the knob-flip in both directions, and every profile target green, PRG byte-identical." Every measurement in it is true; what was unsound is its **support**. The verification was **object-level**: each named profile target does `rm -rf` first, so it exercised every axis by full rebuild and structurally could not observe a warm-tree staleness bug — "PRG byte-identical" was therefore not evidence for the property it was cited for.

A defect did exist at the **link** step. On a warm tree, `make all` after a knob change exited 0 while retaining the *previous* config's PRG: GNU Make 3.81 (macOS `/usr/bin/make`) has whole-second mtime granularity and the newest `.o` lands in the same second as the existing PRG, so make judged the PRG current. Measured: `-D SQR_DMA_K=0` retained `08d1fef1`/8628 B where `a1308f9b`/8414 B was correct, reproduced independently by two lanes on two different knobs. `make lib` was always safe, because the stamp already deleted `$(LIB_DIR)/*.a`. **No released artifact was affected** — `tools/build_release.sh` ships a `git archive` of source, and the recorded v0.12.0 PRG `08d1fef1` is the correct *default* artifact.

Fixed in this change set: `CONTRACT_STAMP`'s `rm -f` list is extended to the linked outputs (`$(PRG)`, `$(LABELS)`, `$(LABELS).raw`, and the `lib_verify` products), with `PRG` / `LABELS` / `LIB_VERIFY_DIR` **hoisted above** the stamp block (Makefile:95–97; block at :99–109) — `$(shell …)` expands at parse time and those variables were defined *below* it, so a version spelled with them unhoisted expands them empty and is a silent no-op. Legs C/C1/C2/C1b are unchanged, and an unchanged knob still rebuilds 0 TUs. The §6.3 claim now holds at **both object and link level**.

Note the v0.10.5 `X25519_PROFILE` `$(error)` guard does **not** discharge this. It gates the knob's *name*; v0.11.1's duty is about a knob's *value* reaching no make prerequisite. The two are orthogonal, and x25519 is the fleet's demonstration of it: we had the named knob, we had the conformant guard, and we carried shape 3 on three knobs regardless. (Raised on contract#128; the clause as merged still rests only on chacha's *absent* `PROFILE` variable, which lets an adopter holding an `$(error)` guard conclude they are covered.)

Two errors in the released v0.11.1 text worth knowing when citing it: it credits x25519's stamp as covering a deprecated **`EXTRA_CA65FLAGS`** alias — no such variable exists here, ours is `CA65FLAGS` (Makefile:23) and the stamp reads `ALL_DEFINES` (Makefile:24) — and the contract README asserts SPEC v0.11.0 "is on `main` but not yet tagged", which is false (tag `39441e0f`, created 2026-08-23T11:23:03Z, over an hour before the PR claiming otherwise). Both reported upstream; neither changes what we owe.

v0.10.7 and v0.11.0 required no change, verified rather than assumed — both are about **onboarding a new library**, and x25519 is on the far side of every test they apply.

**v0.10.7 (PATCH)** registers `mlkem_` to the new adopter `c64-mlkem`. Collision-free against x25519's six registered prefixes (`fe25519_ fe_ x25_ mul_ sqr_ x25519_`); every name in `src/zp_config.s`'s `.exportzp` block sits under them, so the §2 intake check passes with nothing to move. The §6.5 wording fix that rides along ("ship **unprefixed** in four adopters") keeps x25519 in the unprefixed four — our `lib_version.o` / `lib_manifest.o` / `zp_config.o` basenames are untouched.

**v0.11.0 (MINOR)** adds two zero-consumer carve-outs — §6.5 "a library with no released consumers SHOULD be born prefixed" (member basenames) and §1 "such a library SHOULD NOT export the bare `LIB_VERSION_*` / `LIB_ABI_VERSION` forms at all". Both share one scope test: *no tagged release that any consumer pins*, checkable from the library's tags and the contract's `consumers.md`. **x25519 fails that test, so both carve-outs are inapplicable and the incumbent rules continue to bind.** Measured, not asserted: `consumers.md` records `c64-https` pinning **v0.11.2** (§6.1 satisfied at c64-https PR #122, archives linked byte-for-byte from our `make`) and `c64-wireguard` pinning v0.10.1 with v0.11.1 as its next target. So member basenames stay on the **MAJOR** path, and §1's `MUST also export` the bare forms still applies. The one requirement the carve-out explicitly leaves untouched — that the bare forms never ship ungated — already holds: `src/lib_version.s` wraps them in `.ifndef LIB_NO_BARE_EXPORTS`, aliased to the prefixed equates rather than restating literals.

One upstream inaccuracy noted while checking §2: its "Known migration items" list still carries **`c64-x25519`'s `poly_carry`** as pending on the §6.5 rename window. That rename shipped here at **v0.11.0** (`0fbe985`) — the slot is `mul_carry`, and `src/zp_config.s:134` raises a loud `.error` if a consumer still passes `-D poly_carry=`, so there is no bare alias riding the window. The entry is stale for x25519 (it remains live for the other two libraries it names). Note this is separate from `poly_prod_lo`/`poly_prod_hi`, which are `.export`ed absolute data in `mul_8x8.s`, not §2 ZP slots, and are canonical §8.3 provider-surface names that v0.10.6 *obliges* us to export — §2's own text exempts "a §8.x canonical contract item" from the same-name defect rule.

v0.10.6 required no change: §8.3 now *obliges* the provider-surface enumeration (`ct_mul_8x8`, `smc_sum_a_imm`, `smc_diff_a_imm`, `poly_prod_lo`, `poly_prod_hi`) and adds the gating corollary that a deferral switch MUST leave `.import`s behind for every referenced name it un-defines. Both already hold here, verified at symbol level with `od65`: the owner build exports all five from `mul_8x8.o`; under `-D SHARED_CT_MUL_8X8` none of the five is exported anywhere, and each referenced name is imported by the TU that uses it (`x25519_init.o` all five, `fe25519.o` `poly_prod_lo/hi`). `mul_8x8.o` itself shows only `mul_8x8` because **ca65 emits import records only for referenced symbols** — an `.import` of an unused name is dropped, so `od65 --dump-imports` is the honest check, not the `.import` line in the source. The combination that broke nist#123 (deferral × on-chip) builds here: `-D SHARED_CT_MUL_8X8=1 -D X25519_ONCHIP_MUL=1` and the full app-owned × on-chip set both assemble.

**v0.16.0 (MINOR, tag `3a91ebb`; PR #161, closes contract#155)** adds §14 "entry-point termination and documented domain". **x25519 owes nothing.** N1 is discharged by construction: `fe25519_inv` is a straight-line Fermat addition chain (`src/fe25519.s:2150-2453` — zero branches, literal `sqrn` counts) and the ladder is a fixed 256-bit loop (`src/x25519.s:259,265`). The CT invariant we already hold — *every branch depends only on public loop indices* — is strictly stronger than N1, so N1 is a corollary of the CT posture rather than new work. Three input-domain behaviours are undocumented: a non-canonical `u` is accepted and implicitly reduced, a low-order `u` is computed normally with `z_2 = 0`, and an all-zero shared secret is not detected (RFC 7748 §6.1 makes that check a MAY). **All three terminate**, so N1's MUST never engages; N3 binds only "a documented domain" and there is none; N2's SHOULD is conditioned on non-terminating inputs we do not have. Documenting the three remains a genuine improvement — it is simply not owed.

**v0.17.0 (MINOR, tag `2d7f40c`; PR #162, closes contract#154)** adds §15 "conformance evidence must be shown capable of failing". **Not retroactive** — §15.4 says so in the clause body, and the changelog agrees rather than substituting. There is no MUST anywhere in §15; it carries two SHOULDs. The obligation is scoped to *checks cited as conformance evidence for a clause*, so this is **claims hygiene, not conformance**: a library is not non-conformant for carrying an undemonstrated check, it is not entitled to *cite* it as evidence. Each item therefore has two valid discharges — fix the check, or stop citing it. Standing debt, ranked:

1. **The §6.6 footprint check** — the only one that *cannot* report its named property. Both sides are hand-written literals: injecting 16 `nop`s into `fe25519_add` grew `fe25519.o` 2750 → 2766 with the bytes present in the linked binary, while `make lib-verify` exited 0 and all seven profiles stayed green.
2. **`tools/ct_mul_brute_check.py`** — cited by §8.3 *by name*; the `docs/CT_ANALYSIS.md` citations record it passing and never failing.
3. **`lib-verify`'s symbol / mask / `CONSUMES` / `BANKS_USED` assertions** — capable of failing, but never driven red.
4. **The leg-C knob-invalidation family** — demonstrated in the default profile only, and the check is profile-shaped.

What already conforms: **`lib-verify-docs`** (five reds, each naming the rule that fired, including a snippet wrapped across comment lines that a line-wise `grep` cannot see — §15.2 grade) and **`lib-verify-guards`'** seven legs, each driven red individually with its own named error.

**§3 header-import guard rule (contract#164), so it is not re-derived:** guard a header `.import` **iff** the defining TU guards the definition with `.ifndef`, and pair every such guard with an `.else` branch asserting the override against the library's exported value with `lderror`; if the defining TU assigns **unconditionally** the equate is derived, so leave the import bare and let the `-D` collide loudly. Here `X25519_REU_BANK` / `X25519_REU_OFFSET` are guarded (`src/reu_config.s:61,74` use `.ifndef`), while `X25519_REU_BANK_DOUBLED` / `X25519_REU_BANK_CARRY` are bare (`src/reu_config.s:90-91` assign unconditionally, derived from `X25519_REU_BANK`).

**Verifying a profile axis:** compare **linked output or `od65 --dump-segsize` dumps**, never archive or object bytes. `ca65` stamps `OPT_DATETIME` plus source paths into every object unconditionally, so raw byte comparison is non-deterministic across rebuilds yet byte-*identical* within the same second — it can report both false differences and false sameness. `od65` is structural: e.g. `x25519_init.o` carries 666 bytes of `LIB_X25519_INIT_CODE` in the default profile and 0 in onchip.

## Build / test commands

```
make                 # build build/x25519.prg (standalone test harness)
make clean
make lib             # build build/lib/x25519.a (canonical §6.1 basename; libx25519.a
                     #   ships alongside as the deprecated dialect) + .o + inc + cfg
make lib-verify      # smoke-test the archive via tests/lib_linkage stub
make lib-verify-docs # assert the doc/header consumer snippets are pasteable as
                     #   written (prerequisite of lib-verify)
make lib-verify-shared  # linkage matrix for the four SHARED_* deferral builds (R6)
make lib-verify-guards  # §6.6/§6.7 NEGATIVE legs — guards must fail with named errors
                     #   (leg C family runs for BOTH default and onchip)
make lib-verify-footprint  # §5 RESIDENT/COLD DERIVED from od65 over the shipped
                     #   archive, not restated. Also runs inside lib-verify, so
                     #   all seven profiles get it.

# --- SPEC v0.17.0 §15 evidence legs (a check never seen to fail is not
# --- evidence). Each is re-runnable, not a one-off transcript.
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

The library is 10 ca65 `.o` modules (no `main.o`, which is the BASIC stub / test harness / §6.7 guard TU — downstream supplies its own entry point and mirrors the guard). Module layout in `src/`:

```
x25519.s       Montgomery ladder, x25519_clamp / _scalarmult / _base
fe25519.s      Field arithmetic mod p = 2^255 - 19
mul_8x8.s      8x8→16 multiply via quarter-square table (CT); §8.1/§8.3 owner-or-defer gates
x25519_init.s  sqtab_init, reu_mul_init, REU fetch helpers; §8.2 deferral gates
data.s         Page-aligned static buffers (CT-critical alignment)
util.s         vic_blank/unblank, bench_start/stop (jiffy clock)
lib_version.s  Contract §1 version equates ONLY (TU-isolated; bare aliases gated)
lib_manifest.s Contract §5 aggregates, §8.0 masks, §8.4 precalc enumeration
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
