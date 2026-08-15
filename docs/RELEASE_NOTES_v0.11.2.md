# c64-x25519 v0.11.2 — the documented speedup was wrong

**Released:** 2026-08-15 · **ABI:** `LIB_X25519_ABI_VERSION = 3` (unchanged)
· **Runtime change:** none — `build/x25519.prg` is byte-identical to v0.11.0
and v0.11.1 at `905bb969f027d02b4671ab04436d8c817b2f3fcfe31200af98931f6151b95acc`.

A documentation-accuracy release. No code path changed; what changed is that
the numbers we publish are now true, and a bench that could not have detected
the error now guards against it.

## §6.6 footprint pairs — zero delta in every profile × variant

Contract §6.6 obligation 2 requires the footprint deltas stated per
(profile × variant) even when they are zero. All seven are unchanged from
v0.11.0 / v0.11.1:

| profile × variant | `RESIDENT` | `COLD` | delta |
|---|---:|---:|---:|
| default | `$0020BF` | `$00033A` | 0 / 0 |
| `lib-x25519-onchip` | `$00200F` | `$0000A0` | 0 / 0 |
| `lib-x25519-1764` | `$002037` | `$000288` | 0 / 0 |
| `shared-sqtab` | `$0020BF` | `$00029A` | 0 / 0 |
| `shared-reu` | `$0020AB` | `$0001CE` | 0 / 0 |
| `shared-ct` | `$002080` | `$00033A` | 0 / 0 |
| `shared-all` (app-owned) | `$00206C` | `$00012E` | 0 / 0 |

Verified two ways rather than asserted: `git diff v0.11.1..HEAD -- Makefile`
shows no change to any `LIB_VERIFY_RESIDENT_EXPECT` / `LIB_VERIFY_COLD_EXPECT`
value, and all seven profiles' `lib-verify` footprint asserts pass green at
the release commit. The byte-identical PRG is consistent with this — nothing
in this release emits a single byte of code or data.

## The headline: `vic_blank` is worth ~6%, not ~20-25%

Since v0.1.0 this library documented `vic_blank` as a "~20-25% CPU speedup", in
eight separate places including the public header that `make lib` ships to
consumers. That figure was never correct for any configuration this library
runs in.

Blanking the VIC-II suppresses badlines. A standard 25-row text screen costs
one badline per character row at ~40-43 cycles each:

| standard | frame | 25 × 40 cyc | 25 × 43 cyc |
|---|---:|---:|---:|
| NTSC (65 × 262) | 17030 | 5.87 % (1.0624x) | 6.31 % (1.0674x) |
| PAL (63 × 312) | 19656 | 5.09 % (1.0536x) | 5.47 % (1.0579x) |

Reaching 20-25% would take 3406-4258 stolen cycles — 79-99 badline-equivalent
rows, roughly 3-4× more than a text screen has to give. That is achievable with
sprites or a bitmap mode, but not here: `$d011` is the only VIC register this
library ever writes, nothing in `src/` writes `$d015` or selects bitmap mode,
and `src/main.s` touches no VIC register at all, so the harness and every
published benchmark run the KERNAL default text screen with sprites off.

Three independent measurements agree:

| source | result |
|---|---|
| `tools/bench_fe_ops.py --no-blank` vs default, 7 ops, CIA1 cycle-exact | 1.0651–1.0683 (mean 1.0665) |
| `tools/test_opt_vic_reduce38.py` guard (new) | 6.27 %, ratio 1.0669x |
| consumer-side, independently (#103) | 1.067–1.069x |

`fe25519_inv` is deliberately excluded from the A/B: it is only benched
single-call, a path `--no-blank` never reaches, so it reads a meaningless
1.0000 in both legs.

### Why it went unchallenged for ten releases

`tools/test_opt_vic_reduce38.py` had been measuring this the whole time and
printing `Speedup: N%` — **with no assertion**, so nothing ever gated on it.
Worse, its `bench_fe_mul` timed a *single* ~6-jiffy `fe25519_mul` on the
**jiffy clock**, where one tick is ~17% of the measurement: 6→7 ticks reads as
14%, 6→8 as 25%. That quantization is the most plausible origin of the
inflated number — roughly the only way to *get* 20-25% out of this library.

Both halves are fixed. The bench now uses the CIA1 phi2 counter (cycle-exact,
`sei`-safe), and the printed number is a guard asserting a 3-12% band — wide
enough for VICE/host jitter, far too narrow to re-admit 20-25%. It runs in
`make test-slow`.

### If you are a consumer

The figure is a property of **your** display, not of this library. Quote ~6%
for a text screen; sprites and bitmap modes raise it. `docs/LIBRARY.md` now
carries the repro recipe (`tools/bench_fe_ops.py --no-blank`) so the number
stays checkable rather than inherited.

Note two of the corrected sites used the inverted framing ("display-active
costs N% *more* cycles"), which needs the reciprocal rather than the same
number: 6.31% recovered is 6.74% more cycles. `src/x25519.inc` carried both
framings and they disagreed with each other before this release.

`docs/RELEASE_NOTES_v0.1.0.md` keeps its original text with an erratum note
appended — release notes record what was claimed at that tag, and rewriting
them would erase the trail for anyone who meets the old number elsewhere.

## Contract alignment: v0.10.3 → v0.10.6

**v0.10.4** (§6.3 scoped to define-reachable combinations; documented
member-set axes take a §6.1 target) — **no change required**. Every x25519
profile is built by re-invoking `make lib` over the single fixed `LIB_OBJS`
list with different `CONTRACT_DEFINES`, so all four ship the same ten members.
Notably `lib-app-owned` defers all four §8.x primitives and still retains
`mul_8x8.o` and `x25519_init.o` — the code is gated out, the objects stay,
which is exactly the define-reachable shape the clause blesses.

**v0.10.5** (§6.3 looks-reachable clause: a knob naming an axis MUST select it
or fail loudly) — **change required, and it came from here.** The clause's
third shape, the "silent no-op", was surfaced by this library's own adopter
check: `make lib X25519_PROFILE=onchip` exited 0 and shipped a *default*
archive. A typo'd value was absorbed just as quietly, because the profile
`ifeq` chain's closing `else` is the default branch. Both are now parse-time
`$(error)`s.

The guard matches each switch on its **gate style**, which matters because
ca65's bare `-D NAME` defines the symbol **= 0**:

| family | gate | demands | why |
|---|---|---|---|
| `SHARED_*` | `.ifdef` | the bare name | definedness *is* the axis; every spelling that defines it selects it |
| `X25519_ONCHIP_MUL` | `.if ::NAME` | `=1` | bare is 0 → names the profile while selecting the *default* path |
| `SQR_DMA_K` | `.if ::NAME` | `=0` | deliberately stricter, so a value-gated switch never rides on the silent bare-means-zero rule |

**v0.10.6** (§8.3 provider-surface enumeration; deferral switches must leave
`.import`s behind) — **no change required**, verified at symbol level. The
owner build exports all five names; under `-D SHARED_CT_MUL_8X8` none is
exported and each referenced name is imported by the TU that uses it. The
combination that broke a sibling adopter builds and links here: onchip ×
app-owned links clean at 7,425 bytes.

## Measurement house rules (added to CLAUDE.md)

Two methods that look right and are not — both learned by getting them wrong
first, and both now written down:

1. **To check whether a profile axis bites**, compare linked output or
   `od65 --dump-segsize`, *never* archive or object bytes. `ca65` stamps
   `OPT_DATETIME` plus source paths into every object unconditionally, so byte
   comparison yields false differences across rebuilds *and* false sameness
   within the same second.
2. **To check imports survive a deferral gate**, read `od65 --dump-imports`
   across *all* TUs, never the source `.import` line and never just the gated
   TU. ca65 emits import records only for *referenced* symbols, so an `.import`
   of an unused name is silently dropped — `mul_8x8.o` shows only `mul_8x8`
   despite the source importing six. The `.import` line is not evidence an
   import survives, and a thin list is not evidence one is missing.

## Also in this release

- `.gitignore` and `make clean` now cover all five profile `BUILD_DIR`s;
  previously `make lib-app-owned` left an untracked tree behind.
- The alignment ledger in `CLAUDE.md` records the release and contract version
  it was actually verified against, with the evidence.

## Upgrading

Nothing to do. No API, no ABI, no runtime change. If you quoted the ~20-25%
figure in your own documentation or capacity planning, that is the one thing
worth revisiting — the correction is a factor of three to four.

## Tarball

`c64-x25519-v0.11.2.tar.gz` — vendor-as-source bundle (`cfg docs LICENSE
ORIGIN.txt.template src`; no Makefile by design).

```
Size:     129,363 bytes
SHA256:   0f8bee6a81276a6fd16b16b81382b1fbb8685cfca714ba8abaf8ce8e02be1e10
```

Byte-identical across two independent post-tag `make dist` runs; all 11
shipped `src/*.s` verified to assemble standalone from the extracted tarball.

Note for anyone comparing against the figures quoted on PR #107 before the tag
(`61b0d0ee…`, 128,961 bytes): those were produced from the release branch
*before* the §6.6 amendment commit, and the values above supersede them. The
only file differing between the two archives is
`docs/RELEASE_NOTES_v0.11.2.md` (7,394 → 8,430 bytes); `src/`, `cfg/` and
`LICENSE` are identical, so the shipped source is unaffected.

## Known follow-up

No `make` target yet covers the onchip × deferral combination in CI; it was
verified by hand for this release (assembles and links) but is not guarded.
That is the shape that failed for a sibling adopter precisely because CI never
built it, so it is worth closing.
