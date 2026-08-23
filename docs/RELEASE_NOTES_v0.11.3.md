# c64-x25519 v0.11.3

A build-correctness release. Two defects were live in every release
through v0.11.2, both in the canonical §6.1 build surface, and both
invisible to the way this repo's gates actually run. No runtime code
changed: `build/x25519.prg` is byte-identical to v0.11.0, v0.11.1 and
v0.11.2 at
`905bb969f027d02b4671ab04436d8c817b2f3fcfe31200af98931f6151b95acc`.

**Version 0/11/3. `LIB_X25519_ABI_VERSION` stays 3** — no exported
symbol was added, removed or renamed. Consumers pinning ABI 3 need no
change; the reason to take this release is that `make lib` now behaves
correctly in build orders where it previously did not.

Contract-aligned through c64-lib-contract SPEC **v0.11.1**.

---

## 1. `make lib` broke after any profile target (#109)

```
$ make lib-app-owned && make lib
cp cfg/x25519-example.cfg build/lib/cfg/x25519-example.cfg
cp: build/lib/cfg/x25519-example.cfg: No such file or directory
make: *** [build/lib/cfg/x25519-example.cfg] Error 1
```

Reproduced from clean on all three profile legs — `lib-app-owned`,
`lib-x25519-onchip`, `lib-x25519-1764`.

**Root cause was order-only prerequisite semantics, not a missing
`mkdir`.** `$(LIB_DIR)`'s recipe created both `build/lib` and
`build/lib/cfg`, but the three profile targets publish their archive
into the canonical tree with a bare `mkdir -p build/lib`. That creates
`$(LIB_DIR)` *without* `cfg/`, and an order-only prerequisite is
satisfied by the directory merely existing — so `| $(LIB_DIR)` was
permanently satisfied, the recipe that would have created `cfg/` never
ran again, and the target stayed broken until someone deleted `build/`.

A from-clean `make lib` never sees it, and that is the only order the
local gates run.

`build/lib/cfg` now has its own order-only target, so the copy rule is
self-sufficient regardless of which target created `$(LIB_DIR)` first.

**Downstream note:** `c64-https` vendors x25519 v0.11.2 and carries the
identical defect at `libs/x25519/Makefile:177`. Re-vendoring at v0.11.3
picks up the fix.

## 2. §6.2 knob changes were silently ignored on a warm tree (#110)

Filed upstream as
[c64-lib-contract#127](https://github.com/JC-000/c64-lib-contract/issues/127),
which listed this library as unverified. Measured here; the hole was
real.

`CONTRACT_DEFINES` / `CONTRACT_ZP_DEFINES` / `CA65FLAGS` reach every
TU's assemble flags, but nothing listed them as a make prerequisite. A
re-invocation with different knobs therefore reused every stale object
and exited 0 having shipped an artifact the knob never requested.

Three vectors, all measured on a warm tree, all now closed. The
discriminator is `od65` structural dumps — never archive bytes, which
`OPT_DATETIME` makes both falsely different and falsely identical — and
each probe was validated from clean first, so it is known to move.

| knob | before | after |
|---|---|---|
| `-D SHARED_CT_MUL_8X8=1` | 5/5 §8.3 provider names still exported, 0 `ca65` invocations | 0/5 |
| `-D LIB_NO_BARE_EXPORTS=1` | 4/4 bare version names still exported | 0/4 |
| `-D LIB_SHARED_SQTAB_BASE=0xC000` | 0 `ca65` invocations | 10 |

The first meant a consumer asking for the *deferring* archive silently
received the *owner* archive.

**The second is the one to read twice.** A wrong profile is at least
loud at link; a suppression that silently did not happen is not, and it
is precisely the
[contract#43](https://github.com/JC-000/c64-lib-contract/issues/43)
duplicate-identifier collision that `LIB_NO_BARE_EXPORTS` exists to
prevent. Passing the flag was not evidence it took effect.

The fix is the fleet-canonical `CONTRACT_STAMP`: the flattened knob
string is recorded at parse time, and objects and archives are
invalidated when it changes. It is stamped from `ALL_DEFINES` rather
than `CONTRACT_DEFINES` alone, so the deprecated `CA65FLAGS` alias is
covered too — a stamp ignoring it would be a guard with a documented
bypass.

**Note for anyone who added a `<LIB>_PROFILE` `$(error)` guard and
considers themselves covered: this is orthogonal.** x25519 had
`X25519_PROFILE`, had the conformant v0.10.5 parse-time guard on it, and
carried this on three knobs regardless. That guard gates the knob's
*name*; this is about a knob's *value* reaching no prerequisite.

### Conformance

SPEC v0.11.1 (contract commit `de5d354`; not yet tagged upstream) states
which consequence §6.3's rule carries in which case: a knob value the
target cannot honor is rejected at parse time, one it can honor MUST
invalidate whatever it reconfigures.

x25519 lands entirely on the invalidation branch — `LIB_OBJS` is a
single unconditional assignment with no conditional member selection, so
there is no member-set axis here and nothing takes the rejection branch.
**v0.11.2 was non-conformant with v0.11.1; v0.11.3 is conformant.**

## 3. The onchip × deferral intersection is now covered

Carried forward since the v0.11.2 cycle: no target built the
intersection of `X25519_ONCHIP_MUL` and the `SHARED_*` deferral
switches. Each was green alone; the combination had been verified once
by hand and left unguarded.

It is now leg 5 of `make lib-verify-shared`, riding the existing target
— no new public make target (§6.5 freezes target names) and no new
`X25519_PROFILE` value.

Deliberately **link-only**: it asserts the combination assembles and
links, and invents no expectation set, because the mask / `CONSUMES` /
footprint values for this intersection would be guesses. A guessed lock
is worse than no lock — it reads as verification while asserting
nothing anyone measured. It links at 7425 bytes, matching the figure
hand-measured during the v0.11.2 cycle.

---

## The common thread

All three items are one shape: **a target green in isolation and broken
in composition, with nothing building the sequence.** #109 needs
`profile-target → lib`; #110 needs `lib → lib-with-different-knobs`;
item 3 needs `onchip × deferral`. Every individual target passed
throughout. This repo has no CI, so from-clean single-target builds were
the entire gate.

That is the same class the contract has been circling in §6.3 and
[nist#123](https://github.com/JC-000/c64-nist-curves/issues/123), and it
is worth stating plainly: for this library the composition, not the
target, is where the defects were.

## Verification

- All four §6.1 sequences green: clean → `lib`, and each of the three
  profile targets → `lib`
- Knob flip verified in both directions on a warm tree
- `lib-verify`, `lib-verify-shared` (five legs), `lib-verify-guards`
  (four legs, including the new knob-staleness leg C)
- All three profile targets, `make`, `make test`
- Guards negative-tested: with the stamp's invalidation disabled, the
  artifact-flipped leg fails with `knob ignored, stale owner archive
  shipped (5/5)`; with the onchip leg's stubs assembled from a
  mismatched define set, the link fails on unresolved
  `LIB_X25519_SHARED_REU_MUL_*` externals **(but see the erratum below
  — only that one direction was actually tested)**
- **Verified on the merged tree**, not on either branch — the two fixes
  were developed independently from master and both touched the
  Makefile, so their combination was itself a composition neither had
  built
- PRG byte-identical to v0.11.0–v0.11.2 → the v0.11.2 VICE suite, bench
  figures and CT posture all carry; no VICE rerun owed

## §6.6 footprint pairs

Unchanged from v0.11.2 — no manifest value moved, since no runtime code
changed. See
[`docs/RELEASE_NOTES_v0.11.2.md`](RELEASE_NOTES_v0.11.2.md) §6.6 for the
seven (profile × variant) pairs.

## Tarball

`c64-x25519-v0.11.3.tar.gz` — vendor-as-source bundle (`cfg docs LICENSE
ORIGIN.txt.template src`; no Makefile or README by design, so running
`make` inside it is expected to fail — the gate is per-file `ca65` over
every `src/*.s`).

```
Size:     128,801 bytes
SHA256:   994091982660197c1f55c32349c6aa706179a83a2ef6837098dab4eed570155f
```

Byte-identical across two independent **post-tag** `make dist` runs, and
the figures above were re-derived from the published asset by
downloading it back and hashing it — not from the local build. All
shipped `src/*.s` assemble standalone from the extracted tarball with
zero diagnostics, and the extracted `src/lib_version.s` reads
`LIB_X25519_VERSION_PATCH = 3`.

---

## Erratum (2026-08-23, post-release)

**The knob-staleness pin shipped in this release was half-inert, and the
verification claim above was narrower than it read.**
[#113](https://github.com/JC-000/c64-x25519/issues/113) broke the stamp
in both directions and measured the result:

| stamp state | `make lib-verify-guards` |
|---|---|
| disabled (never fires) | exit 2 — correct |
| fires unconditionally | **exit 0**, printing `OK: unchanged knobs did NOT rebuild` while all ten TUs rebuilt |

The no-rebuild leg compared `ls -l` month/day/`HH:MM` plus size. That is
minute-granular, against an object whose size does not change when
identical source is recompiled, inside a leg running in seconds — so it
was not intermittently blind, it **could never have failed**. The pin
carried both of SPEC §6.3's required properties by name while one of
them asserted nothing.

Fixed in [#114](https://github.com/JC-000/c64-x25519/pull/114): the legs
now count `ca65` invocations instead of comparing timestamps, and are
renumbered to the clause's own ordering (C1 = unchanged knobs must not
rebuild, C2 = artifact must flip) so failure output cross-references
against the SPEC and against sibling repos. Both breaks now fail.

**A claim made elsewhere was also false**, and is retracted here for the
record: the PR #110 discussion, and my comment on
[contract#127](https://github.com/JC-000/c64-lib-contract/issues/127),
stated that an early unconditionally-firing draft was caught by the
no-rebuild leg. It was not — that run aborted at an unrelated earlier
leg and never reached the staleness legs. The cause was inferred from an
aborted run and not checked.

Nothing about the release's *shipped behaviour* changes: the
`CONTRACT_STAMP` itself was correct, and all three knob vectors were and
remain closed. What was defective is the check that was supposed to keep
it correct.
