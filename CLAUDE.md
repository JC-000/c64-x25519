# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

X25519 (RFC 7748) for the Commodore 64 in ca65 6502 assembly, targeting a stock C64 + 1750 REU. Differentially validated against `pyca/cryptography` driven through VICE. Designed to be **vendored as source** into downstream C64 projects, not linked as a system library.

Current release: **v0.11.2** (full CT certification, catalogue L1–L30 closed; `LIB_X25519_ABI_VERSION = 3`). Public `fe25519_*` / `x25519_*` API is semver-locked. Contract-aligned through c64-lib-contract SPEC v0.11.1 (§6 build-and-consume chapter, §6.6/§6.7 guards, §2 ZP prefix registry, §6.3 reject-or-invalidate).

v0.10.4 required no change here: it scopes §6.3's no-further-matrix posture to *define-reachable* combinations and rules that a documented **member-set** axis must take its own §6.1 target. Every x25519 profile (`lib`, `lib-app-owned`, `lib-x25519-1764`, `lib-x25519-onchip`, all four `SHARED_*` deferral legs) is built by re-invoking `make lib` over the single fixed `LIB_OBJS` list with different `CONTRACT_DEFINES`, so all of them ship the same ten members. No axis here is member-set-shaped.

v0.10.5 **did** require a change: its §6.3 looks-reachable clause (a knob naming an axis MUST select it or fail loudly) caught `X25519_PROFILE` as a live shape-3 "silent no-op" — `make lib X25519_PROFILE=onchip` exited 0 and shipped a default archive, and a typo'd value fell through the `ifeq` chain's closing `else` into `default`. Both are now hard `$(error)`s at parse time (Makefile, just below `X25519_PROFILE ?= default`): unknown values are rejected, and a known value must be accompanied by the `-D` that actually selects it. The named profile targets pass both together, so they satisfy it by construction.

**The guard matches each switch on its own gate style — do not unify the spellings.** `ca65`'s bare `-D NAME` defines the symbol **= 0** (measured), so the two families need opposite treatment:

| family | gate | guard demands | why |
|---|---|---|---|
| `SHARED_SQTAB_INIT`, `SHARED_REU_MUL_INIT`, `SHARED_REU_MUL_FETCH`, `SHARED_CT_MUL_8X8` | `.ifdef` / `.ifndef` (`mul_8x8.s:37,55`, `x25519_init.s:14,94`) | the **bare name** | definedness *is* the axis, so every spelling that defines it selects it. Demanding `=1` here falsely rejects `-D SHARED_SQTAB_INIT`, the form nist#117 and the chacha docs use. |
| `X25519_ONCHIP_MUL` | `.if ::NAME` (`lib_manifest.s:177,361`) | `X25519_ONCHIP_MUL=1` | **load-bearing**: bare `-D X25519_ONCHIP_MUL` is 0, which names the profile while selecting the *default* path — the exact shape-3 no-op the guard exists to kill. |
| `SQR_DMA_K` | `.if ::NAME` (`x25519_init.s:25`, `fe25519.s:40`) | `SQR_DMA_K=0` | deliberately stricter than conformance needs — bare would also select 1764 (ca65 makes it 0) — so that a value-gated switch never rides on the silent bare-means-zero rule and the `=0` stays visible in the build line. |

**v0.11.1 DOES require a change, and it is not optional.** (Cite it as commit `de5d354` for now — v0.11.1 is on contract `main` but **not yet tagged**, so unlike every version through v0.11.0 it is not pinnable by tag; the contract README tracks this as a #71-shape gap affecting the three libraries implementing the rule, of which we are one.) §6.3 now states which consequence its select-or-reject rule carries in which case: *"A §6.2 knob value the target cannot honor MUST be rejected at parse time; one it can honor MUST invalidate whatever it reconfigures."* The branch is decided by the member-set/configuration split the v0.10.4 paragraph draws.

**x25519 lands entirely on the invalidation branch.** `LIB_OBJS` (Makefile:83) is a single unconditional assignment — no `+=`, no conditional member selection — so there is no member-set axis here and nothing takes the parse-time-rejection branch. Every knob we accept is a configuration axis the targets *can* honor, so every one of them owes invalidation. That is what `CONTRACT_STAMP` (Makefile:70) + leg C of `lib-verify-guards` implement, **merged at PR #110** — before it, the three measured vectors (§8.3 deferral, `LIB_NO_BARE_EXPORTS`, `LIB_SHARED_SQTAB_BASE`) were exactly the exit-0-wrong-artifact emission the clause forbids. Conformant as of master `76e0e46`, verified on the merged tree rather than on either branch: all four §6.1 sequences, the knob-flip in both directions, and every profile target green, PRG byte-identical.

Note the v0.10.5 `X25519_PROFILE` `$(error)` guard does **not** discharge this. It gates the knob's *name*; v0.11.1's duty is about a knob's *value* reaching no make prerequisite. The two are orthogonal, and x25519 is the fleet's demonstration of it: we had the named knob, we had the conformant guard, and we carried shape 3 on three knobs regardless. (Raised on contract#128; the clause as merged still rests only on chacha's *absent* `PROFILE` variable, which lets an adopter holding an `$(error)` guard conclude they are covered.)

Two errors in the released v0.11.1 text worth knowing when citing it: it credits x25519's stamp as covering a deprecated **`EXTRA_CA65FLAGS`** alias — no such variable exists here, ours is `CA65FLAGS` (Makefile:23) and the stamp reads `ALL_DEFINES` (Makefile:24) — and the contract README asserts SPEC v0.11.0 "is on `main` but not yet tagged", which is false (tag `39441e0f`, created 2026-08-23T11:23:03Z, over an hour before the PR claiming otherwise). Both reported upstream; neither changes what we owe.

v0.10.7 and v0.11.0 required no change, verified rather than assumed — both are about **onboarding a new library**, and x25519 is on the far side of every test they apply.

**v0.10.7 (PATCH)** registers `mlkem_` to the new adopter `c64-mlkem`. Collision-free against x25519's six registered prefixes (`fe25519_ fe_ x25_ mul_ sqr_ x25519_`); every name in `src/zp_config.s`'s `.exportzp` block sits under them, so the §2 intake check passes with nothing to move. The §6.5 wording fix that rides along ("ship **unprefixed** in four adopters") keeps x25519 in the unprefixed four — our `lib_version.o` / `lib_manifest.o` / `zp_config.o` basenames are untouched.

**v0.11.0 (MINOR)** adds two zero-consumer carve-outs — §6.5 "a library with no released consumers SHOULD be born prefixed" (member basenames) and §1 "such a library SHOULD NOT export the bare `LIB_VERSION_*` / `LIB_ABI_VERSION` forms at all". Both share one scope test: *no tagged release that any consumer pins*, checkable from the library's tags and the contract's `consumers.md`. **x25519 fails that test, so both carve-outs are inapplicable and the incumbent rules continue to bind.** Measured, not asserted: `consumers.md` records `c64-https` pinning **v0.11.2** (§6.1 satisfied at c64-https PR #122, archives linked byte-for-byte from our `make`) and `c64-wireguard` pinning v0.10.1 with v0.11.1 as its next target. So member basenames stay on the **MAJOR** path, and §1's `MUST also export` the bare forms still applies. The one requirement the carve-out explicitly leaves untouched — that the bare forms never ship ungated — already holds: `src/lib_version.s` wraps them in `.ifndef LIB_NO_BARE_EXPORTS`, aliased to the prefixed equates rather than restating literals.

One upstream inaccuracy noted while checking §2: its "Known migration items" list still carries **`c64-x25519`'s `poly_carry`** as pending on the §6.5 rename window. That rename shipped here at **v0.11.0** (`0fbe985`) — the slot is `mul_carry`, and `src/zp_config.s:134` raises a loud `.error` if a consumer still passes `-D poly_carry=`, so there is no bare alias riding the window. The entry is stale for x25519 (it remains live for the other two libraries it names). Note this is separate from `poly_prod_lo`/`poly_prod_hi`, which are `.export`ed absolute data in `mul_8x8.s`, not §2 ZP slots, and are canonical §8.3 provider-surface names that v0.10.6 *obliges* us to export — §2's own text exempts "a §8.x canonical contract item" from the same-name defect rule.

v0.10.6 required no change: §8.3 now *obliges* the provider-surface enumeration (`ct_mul_8x8`, `smc_sum_a_imm`, `smc_diff_a_imm`, `poly_prod_lo`, `poly_prod_hi`) and adds the gating corollary that a deferral switch MUST leave `.import`s behind for every referenced name it un-defines. Both already hold here, verified at symbol level with `od65`: the owner build exports all five from `mul_8x8.o`; under `-D SHARED_CT_MUL_8X8` none of the five is exported anywhere, and each referenced name is imported by the TU that uses it (`x25519_init.o` all five, `fe25519.o` `poly_prod_lo/hi`). `mul_8x8.o` itself shows only `mul_8x8` because **ca65 emits import records only for referenced symbols** — an `.import` of an unused name is dropped, so `od65 --dump-imports` is the honest check, not the `.import` line in the source. The combination that broke nist#123 (deferral × on-chip) builds here: `-D SHARED_CT_MUL_8X8=1 -D X25519_ONCHIP_MUL=1` and the full app-owned × on-chip set both assemble.

**Verifying a profile axis:** compare **linked output or `od65 --dump-segsize` dumps**, never archive or object bytes. `ca65` stamps `OPT_DATETIME` plus source paths into every object unconditionally, so raw byte comparison is non-deterministic across rebuilds yet byte-*identical* within the same second — it can report both false differences and false sameness. `od65` is structural: e.g. `x25519_init.o` carries 666 bytes of `LIB_X25519_INIT_CODE` in the default profile and 0 in onchip.

## Build / test commands

```
make                 # build build/x25519.prg (standalone test harness)
make clean
make lib             # build build/lib/x25519.a (canonical §6.1 basename; libx25519.a
                     #   ships alongside as the deprecated dialect) + .o + inc + cfg
make lib-verify      # smoke-test the archive via tests/lib_linkage stub
make lib-verify-shared  # linkage matrix for the four SHARED_* deferral builds (R6)
make lib-verify-guards  # §6.6/§6.7 NEGATIVE legs — guards must fail with named errors
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

The threat model is network-observable timing against `fe25519_*` and the outer ladder. (`mul_8x8` is boot-only — sole caller `reu_mul_init`'s public table enumeration, no secret inputs — so it has no network-observable exposure; it retains constant-time discipline as the canonical c64-lib-contract §8.3 shared-primitive shape, byte-identical to the chacha owner.) All 30 catalogued leak sites L1–L30 are closed. When touching the hot path:

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
- `docs/CT_ANALYSIS.md` — leak catalogue L1–L30, threat model, Phase 6 correctness/CT argument. **Authoritative for any CT discussion.**
- `docs/RELEASE_NOTES_v*.md` — per-release perf + CT posture story

## Workflow notes

- `build/` and `build/lib/` are `.gitignore`d. Don't commit generated artifacts.
- Don't "fix" a failing differential test by editing the test — pyca is the oracle; the asm is wrong until proven otherwise.
- After CT-relevant changes: update `docs/CT_ANALYSIS.md`, re-run `ct_mul_brute_check.py` if `mul_8x8`/quarter-square changed, and run `make test-slow`.
- After perf changes: re-measure via `tools/bench_x25519.py` / `bench_fe_mul.py` / `bench_fe_ops.py` with `jsr vic_blank`, then update jiffy counts in `README.md` and the relevant release notes — don't leave stale numbers.

## Serena MCP

This repo is a Serena-onboarded project (`.serena/` present, memories under `.serena/memories/`). Activation is **not automatic** — call `mcp__serena__activate_project` with this path at the start of a session, then `mcp__serena__initial_instructions` if not already read. Existing memories: `project_overview`, `code_structure`, `tech_stack`, `suggested_commands`, `style_and_conventions`, `ct_and_security_notes`, `task_completion_checklist`.
