# c64-x25519 v0.15.0

The settling release against **c64-lib-contract SPEC v1.2.2** (frozen).
It closes the second half of §6.1 member isolation and implements §8.2's
documented fetch entry.

**`LIB_X25519_ABI_VERSION` moves 3 → 4.** MINOR, not MAJOR. **The PRG
changes** — this is the first release since v0.11.3 where it does, and
the reason is worth reading (§3).

Two things a consumer must act on are in §7.

---

## 1. Member isolation, count 2 — the §8.2 staging buffers

v0.14.0 split the §8.4 precalc triple out of `src/lib_manifest.s`. This
release does the other half.

`src/data.s` defined `mul_dma_lo` / `mul_dma_hi` / `mul_dma_carry` — an
`APP_OWNED` surface, which a consumer providing the §8.2 multiply tables
defines and places itself — beside 33 names the library's own code
references (`fe_p`, `x25_scalar`, `fe25519_tmp1..4`, `sqr_lo/hi`,
`mul38_*_tab`, and the §8.2 settle state). ld65 links whole members, so
any reference to any of those 33 pulled `data.o` in and dragged the
buffers along. The consumer's own definitions then collided, and the only
remedies were `ar65` member surgery — banned by §6.1 — or abandoning the
release.

Not hypothetical. It is what `c64-nist-curves` v0.12.0 shipped, and it
cost `c64-https` all three of its configurations (contract#179,
nist-curves#149).

Fixed by isolating the three buffers in `src/mul_stage.s`, which contains
nothing else. Red-green against the real archives, consumer defining its
own `mul_dma_*`:

| archive | result |
|---|---|
| v0.14.0 (buffers in `data.o`) | `ld65: Error: Duplicate external identifier: 'mul_dma_carry'` |
| v0.15.0 (isolated member) | links clean |

**It is a split, not conditional definition.** ld65 pulls a member only
to resolve a *still-unresolved* import. Under `APP_OWNED` the consumer's
own object is a command-line object, in the symbol table before any
archive is scanned, so the imports resolve there and the isolated member
is never pulled. `src/fe25519.s` and `src/x25519_init.s` keep their
`.import`s; those are the hook the consumer's definition hangs on.

---

## 2. §8.2's documented `A = a` fetch entry (#127, contract#182)

> **Fetch.** The canonical per-row entry point is `reu_fetch_mul_row`;
> `A = a` (row index) on entry…

`src/x25519_init.s` opened with `lda mul_cached_a`, discarding the
caller's `A` on the first instruction. The documented entry was simply
not implemented. The contract needed no change; the defect was ours.

Invisible standalone, because every in-tree caller set `mul_cached_a`
first. It bites **§8.2 fetch deferral**: a deferring build imports the
provider's `reu_fetch_mul_row`, its callers write *their* private byte,
the provider reads *its own*, both symbols exist and the link is clean —
so the fetch silently returns whatever row the provider last cached.
`c64-nist-curves` had the identical defect from
`nistcurves_mul_cached_a`; both are fixed independently, and neither
waits on the other.

`sta` sets no flags, so the carry the following `asl` / `adc #0` pair
depends on is untouched. `mul_cached_a` is still written, because it is
not merely a parameter to this proc — `src/fe25519.s` reads it in the
squaring cross-term path.

### The caller audit was load-bearing, not belt-and-braces

`c64-nist-curves` measured zero in-tree callers, so a bare shim was safe
for them. **We had one, and it would have broken.**
`reu_fetch_doubled_row` reaches its `jsr reu_fetch_mul_row` with `A`
holding `X25519_REU_BANK_DOUBLED` — the SMC bank patch value, not the row
index. A shim alone would have stored the *bank* into `mul_cached_a` and
fetched a garbage row, turning a stale-row read into a wrong-row read.
The shim and the `lda mul_cached_a` that precedes the call are in the
same commit for that reason.

### Why the counter moves

Ruled at contract#182 against §7, and identical for both §8.2 providers.

**Not MAJOR.** §7's "changed calling conventions" bullet means the
*documented* convention, and §8.2 has said `A = a` throughout — before
this change and after. What changes is conformance to it. And the
bullet's operative word is *breaking*: a consumer who passed the row
index in `A` is broken **today**, and this fixes them.

**The counter still moves.** §7's v1.1.0 paragraph names two holding
cases — undocumented behaviour becoming documented, and documentation
corrected to match unchanged code. This is the mirror of the second:
*code* corrected to match unchanged documentation. §7 is silent there, so
it falls back to §1: "Incremented on any breaking export change — …a
changed calling convention…". A consumer who reverse-engineered
`mul_cached_a` breaks with no other signal. That is what the counter is
for.

---

## 3. A constant-time regression the split caused, and how it was caught

**This is the most important thing in the release.** The count-2 split is
correct by the letter of §6.1 and *still broke the library*.

`tools/test_ct_ladder_cycles.py`, `x25519_scalarmult` cycle spread across
structurally distinct inputs:

| build | spread | threshold |
|---|---|---|
| v0.14.0 | **0** cycles | 17,045 |
| count 2, first cut | **83,342** cycles | 17,045 — **FAIL** |

**The cause was not the buffers that moved.** In `src/data.s` the ×38
reduction tables sat immediately after the three 256-byte `mul_dma_*`
buffers, which followed a `.align 256`. So `mul38_lo_tab` was page-aligned
**by accident** — the location counter simply happened to arrive
page-aligned, and no directive anywhere said it had to:

| build | `mul38_lo_tab` | aligned? |
|---|---|---|
| v0.14.0 | `$1E00` | yes, by coincidence |
| count 2, first cut | `$1A85` | **no** |

`mul_by_38` indexes both tables `abs,y` with a secret byte over the full
0..255 range, so some indices crossed a page and cost an extra cycle — a
data-dependent time.

**Nothing else caught it.** Every functional test passed. All seven
profiles built. `lib-verify`, the isolation check and the `mul_dma_*`
page-alignment asserts all passed — because those buffers were still
aligned. Only the cycle-spread test failed.

### The fix is the class, not the instance

An explicit `.align 256`, plus alignment asserts over **every**
secret-indexed table in `src/data.s`. And the audit that produced them
asked the durable question — not *"does every table have an `.align`?"*,
which finds neither unguarded case, but **"what makes each one aligned,
and what would have to change for that to stop being true?"**

| table | provenance | guard |
|---|---|---|
| `mul38_lo_tab` | `.align` directive | `lderror` |
| `mul38_hi_tab` | derived (predecessor is exactly 256 B) | `lderror` |
| `sqr_lo` | `.align` directive | `lderror` |
| `sqr_hi` | derived | `lderror` |
| `a24_b0` | `.align` directive | `lderror` |
| `a24_b1..b3` | derived | `lderror` |
| `mul_dma_lo` | `.align` directive (`src/mul_stage.s`) | `lderror` |
| `mul_dma_hi` / `_carry` | derived | `lderror` |
| `sqtab_lo` / `_hi` | **consumer equate** | `error` |

Several remain legitimately aligned-by-derivation. That is fine and
deliberate — the asserts are what turn a coincidence into an invariant.

Two findings recorded in `src/data.s` that a directive sweep misses:

1. **The absolute-literal class is absent here, and that is a finding.**
   A table pinned to a literal address is unguarded in the *opposite*
   direction from a derived one: no split can disturb it, so it always
   looks correctly placed, and it breaks on a one-character edit instead.
   `c64-ChaCha20-Poly1305` has that shape. We do not. Anyone adding one
   needs `error`, not `lderror`.
2. **The assert keyword is not cosmetic.** For a relocatable address ca65
   defers to ld65 whatever keyword is written, so an `error` there would
   be a link-time check wearing an assemble-time label. For
   `sqtab_lo`/`_hi` both sides are assemble-time constants (the base
   arrives as a `-D`), so `error` is genuinely assemble-time and correct.

The new asserts were driven red and confirmed to fail **for the right
reason** — deleting the `.align` fires
`mul38_lo_tab must be page-aligned (CT invariant…)`, the assert under
test, not an adjacent overrun guard.

**Catalogue impact: none.** L1–L32 are unchanged; no leak site is added
or reopened. This was a build-layout regression caught before release,
not a change to the CT argument.

---

## 4. `make lib-verify-isolation` — and why it is a tool, not three greps

An isolation check is an **absence assertion**, and absence assertions
fail open: if the export extraction returns nothing, every "must not
co-occur" test passes and the check goes quiet rather than red.

`tools/check_member_isolation.py` therefore never merely asserts absence.
It **reconciles**: for every member, the names it parsed must equal
`od65`'s own `Name:` record count for that member. A dropped name fails
the check even when every co-occurrence test happens to pass. Plus a
per-profile non-empty sentinel (9 bare precalc names in the default
profile, 6 at 1764, 3 at onchip).

Three real ways it would otherwise have gone quiet, all observed in this
fleet rather than imagined:

1. **`od65` pads `Name:` to a fixed column, and at name length exactly 24
   the padding is zero-width** — it emits `Name:"LIB_PRECALC_sqtab_REGION"`
   with no space. `awk '/Name:/{print $2}'` drops the name silently, and
   so does any `Name:\s+"` regex. This library exports three such names,
   and **all three are bare** — precisely the class the check counts. An
   unsafe extraction reports "0 bare names" on a member exporting 9.
2. A member that fails to dump at all contributes an empty set and passes
   everything.
3. After a split, the member a leg was written about may no longer be
   pulled into the artifact the leg inspects.

`make lib-verify-isolation-negative` re-runs the check with the
awk-equivalent extraction and **requires it to fail**, naming both
"dropped 3 of 18" and the sentinel undercount — so the check is
demonstrated able to detect its own blind spot.

The population is **derived**, never enumerated. The instinct to add a
readable roster of expected names is the regression, not the improvement:
`c64-nist-curves` had a hand-written roster that listed none of the 18
bare names their macro generates, so it reported "0 bare names" for a TU
it had never examined.

---

## 5. Verification

Full sweep from clean:

| check | result |
|---|---|
| `make all` / `lib` / `lib-verify` | green |
| `lib-verify-shared` (four `SHARED_*` legs + onchip × deferral) | green |
| `lib-x25519-1764` / `-onchip` / `lib-app-owned` | green |
| `lib-verify-guards` (seven legs) | green, each red with its named error |
| `lib-verify-negative` (N0–N7) | green |
| `lib-verify-footprint-negative` (both arms) | green |
| `lib-verify-citations` / `-negative` | green |
| `lib-verify-isolation` / `-negative` | green |
| **`make test-slow`** (full VICE suite) | green |
| `tools/test_ct_ladder_cycles.py` | spread **0** cycles |
| APP_OWNED link, consumer defining `mul_dma_*` | clean (was `Duplicate external identifier`) |
| new alignment asserts | driven red, fire with their own message |

`mul_8x8` and the quarter-square path are untouched, so no
`ct_mul_brute_check.py` rerun is owed.

The §5 footprint equates moved `+3` bytes in the default profile — the
caller-audit `lda mul_cached_a` — and the derived footprint check caught
the stale equate rather than a human noticing. `RESIDENT` 8503 → 8506
(default only; 1764 and onchip have no `reu_fetch_doubled_row`).

---

## 6. Contract position

Aligned with **SPEC v1.2.2**, which is frozen. Both new translation units
quote the **v1.2.2** §6.1 wording verbatim, including "their own prefixed
counterparts excepted" — the exception that makes `precalc_manifest.o`,
exporting 9 bare and 9 prefixed names, conformant. An earlier draft quoted
the superseded v1.2.0 text, under which that file would have been
non-conformant *by its own header comment*. Quote the tag you conform to,
not `main`.

`src/precalc_manifest.s` exists because the bare `LIB_PRECALC_*` namespace
is **flat across everything that includes `precalc_table.inc`** —
adopters, consumers, and any application vendoring the macro. That is the
rule, and it is stronger than any count of adopters: a count invites
scoping to the adopter list, which is how two different wrong figures for
this were produced upstream.

---

## 7. Consumer action

**Two things, both deliberate.**

1. **`LIB_X25519_ABI_VERSION` is now 4.** Your `.assert` gate will fire.
   That is the gate working. Re-check the integration and update the
   expected value:

   ```asm
   .assert LIB_X25519_ABI_VERSION = 4, lderror, "c64-x25519 exported-surface generation changed; re-check the integration"
   ```

   **If you call `reu_fetch_mul_row` directly, pass the row index in `A`.**
   That is now what it reads, per §8.2. If you were instead writing
   `mul_cached_a` and relying on the entry point to pick it up, switch to
   passing `A` — the private byte is not a supported interface and never
   was.

2. **The archive gains a 12th member**, `mul_stage.o`, holding
   `mul_dma_lo` / `_hi` / `_carry`. Same names, same values, same
   alignment. If you provide the §8.2 multiply tables yourself under
   `APP_OWNED`, this is the change that lets you: define the three buffers
   in your own tree and the library's member is no longer pulled in to
   collide with them.

**The PRG changes** (`LIB_X25519_DATA` is reordered by the split, plus 3
bytes from the caller audit). If you pin a hash of the standalone harness
binary, update it. The library's behaviour is unchanged — the full VICE
differential suite against `pyca/cryptography` passes, and the ladder's
cycle spread is 0.
