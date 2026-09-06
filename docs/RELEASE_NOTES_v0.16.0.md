# c64-x25519 v0.16.0

The settling release. Closes the last known §6.1 gap and hardens the §5
footprint basis.

**`LIB_X25519_ABI_VERSION` stays 4.** MINOR — a member is added, nothing
is added, removed or renamed at the symbol level. **The PRG is unchanged
from v0.15.0** at `a17cbc81…`, 8628 B: this release moves code between
archive members and adds checks, and emits the same bytes.

Aligned with c64-lib-contract SPEC **v1.2.2** (frozen).

---

## 1. Issue #128 — `mul_8x8.o` mixed two displaceable groups

`mul_8x8.o` exported eight displaceable names, and nothing else, so it
passed §6.1's first conjunct on its face. But they were dropped by **two
different switches**:

| switch | names |
|---|---|
| `SHARED_SQTAB_INIT` | `sqtab_init`, `mul_tables_init` |
| `SHARED_CT_MUL_8X8` | `ct_mul_8x8`, `mul_8x8`, `poly_prod_lo`, `poly_prod_hi`, `smc_sum_a_imm`, `smc_diff_a_imm` |

§6.1 requires a displaceable name to live in a TU exporting nothing else
a consumer may import, *"other displaceable names included, their own
prefixed counterparts excepted"*. Neither group is the other's prefixed
counterpart.

A consumer owning §8.3 but **not** §8.1 defines the second group itself
and still imports `sqtab_init`. That import genuinely needs the member —
unlike the `APP_OWNED` buffer case, where nothing pulled it — so it
arrived carrying the §8.3 names.

Split into `src/sqtab_init.s` (§8.1) and `src/mul_8x8.s` (§8.3). The
bodies had **zero cross-references** and already lived in different
segments, so this is a cut along an existing seam.

### Red-green, same consumer object, same cfg, only the archive differs

| archive | result |
|---|---|
| v0.14.0 | `ld65: Error: Duplicate external identifier: 'smc_diff_a_imm'` — no output |
| v0.16.0 | links clean, 4790 B PRG |

### The grouping rule

A literal one-name-per-TU reading of §6.1 is unsatisfiable for anyone:
`smc_sum_a_imm` / `smc_diff_a_imm` are labels on immediate operands
**inside** the `ct_mul_8x8` body and cannot be separated from it by any
split. So some grouping must be read in, and **"group by which switch
drops them"** is the one that falls out of the clause — §6.1 defines
displaceable *by the mechanism that displaces it*, so the unit is what a
single switch controls.

Reached independently here and by `c64-ChaCha20-Poly1305`, who raised the
observation. It is an interpretive reading, queued as a post-settlement
§6.1 clarification; the contract stays frozen at v1.2.2.

### Two false starts worth recording

The first two harnesses died on `Missing memory area assignment` (under
`-t none`) and then an unresolved `__LOADADDR__` — each time ld65 failed
**before** reaching member resolution, so "no duplicate reported" meant
nothing. Both would have read as confirmation.

> **A negative test proves nothing until the positive control links.**

---

## 2. The §5 footprint basis is now cross-checked against a real link

§5 requires the footprint equates to be safe-direction — *"round up,
never down"* — because a consumer binds them to a budget at assemble time,
and an equate that understates makes that check pass while the library
overruns.

`tools/check_footprint.py` derives them by **summing `od65
--dump-segsize` over the archive's members**. That basis omits any padding
ld65 inserts *between* members' contributions when placing an aligned
segment. `c64-ChaCha20-Poly1305` measured all five of their
`RESIDENT_BYTES` literals low by 39–295 B from exactly this.

**Our exposure is zero — and that is not reassuring.** Measured on this
tree, where `LIB_X25519_CODE` and `LIB_X25519_DATA` each have two
contributing members since v0.15.0:

| segment | placed span (`ld65 -m`) | object-size sum | delta |
|---|---|---|---|
| `LIB_X25519_CODE` | 3898 | 3898 | 0 |
| `LIB_X25519_DATA` | 3584 | 3584 | 0 |
| `LIB_X25519_INIT_CODE` | 947 | 947 | 0 |

It is zero because `data.o`'s contribution *happens* to end on a page
boundary — a whole number of 256-byte tables after its own aligns — so
`mul_stage.o`'s `.align 256` needs no fill. **That is alignment by
derivation**: the same shape as `mul38_lo_tab` inheriting its page
alignment from a neighbour's size, which cost an 83,342-cycle CT
regression at v0.15.0 when a split spent it. Same property, same tree,
different quantity.

So the coincidence is now an invariant. `make lib-verify` compares each
segment's object-size sum against the placed span from an `ld65 -m` map
and fails on any difference. The day a member is added, or a table's size
stops being a multiple of 256, the build fails loudly instead of the
equate quietly under-reporting into a consumer's budget assert.

**Which claim this makes, precisely** — because two are available and they
are not the same:

- It asserts **this tool's basis is currently exact**, under the cfg it
  ran with.
- It does **not** assert a bound holding in every consumer's cfg. A placed
  span is cfg-specific. `c64-ChaCha20-Poly1305` argues for a worst-case
  per-segment charge on exactly that ground — a defensible but *different*
  claim. The tool says so in its own docstring so a future reader cannot
  conflate them.

`make lib-verify-fill-negative` appends one byte to `data.s`'s
contribution on a throwaway source copy, knocking the next member off its
page boundary and forcing ld65 to insert 255 bytes. The check must fail
**and** name the segment, the delta and the direction:

```
LIB_X25519_DATA: object-size sum 3585 ($0E01) != placed span 3840 ($0F00),
delta +255 -- the basis UNDER-reports by the link fill
```

The leg also asserts an unaffected segment still reports clean, so it
cannot be satisfied by breaking something adjacent.

### Fleet position

Four adopters, three on an object-size-sum basis. Only `c64-polyval`
needs neither condition — a link-span basis *and* aligned segments all in
`bss`, outside §5's code+rodata quantity. Our result is clean but our
**method is the same one that failed for CCP**; a clean number is evidence
about exposure, not about the method.

---

## 3. The citation check earned its keep

`make lib-verify-citations` — added at v0.14.0 to fix #122, where nine of
twelve guard-table citations pointed at blank lines or prose — failed on
the **very next change after it landed**. The #128 split moved
`SHARED_SQTAB_INIT` to a new file and shifted `SHARED_CT_MUL_8X8`'s line,
and the check failed the build that moved them rather than leaving two
more citations quietly pointing at comments.

Its negative leg also caught its own control path going stale: the leg
asserts that the five *unperturbed* citations stay green, and that
assertion named `src/mul_8x8.s:37`, which the split had moved. A negative
test whose control drifts is a negative test that can pass for the wrong
reason.

---

## 4. Verification

Full sweep from clean:

| check | result |
|---|---|
| `make all` / `lib` / `lib-verify` | green |
| `lib-verify-shared`, three profile targets, `lib-app-owned` | green |
| `lib-verify-guards`, `lib-verify-negative` (N0–N7) | green |
| `lib-verify-footprint-negative` (both arms) | green |
| `lib-verify-citations` / `-negative` | green |
| `lib-verify-isolation` / `-negative` | green |
| **`lib-verify-fill-negative`** | green — sees 255 B, names the segment and direction |
| **`make test-slow`** (full VICE suite) | green |
| `tools/test_ct_ladder_cycles.py` | spread **0** cycles |
| #128 link, consumer owning §8.3 | clean (was `Duplicate external identifier`) |

PRG unchanged from v0.15.0. Catalogue L1–L32 unchanged; `mul_8x8`'s body
moved file but not a byte, so no `ct_mul_brute_check.py` rerun is owed.

---

## 5. Contract position at this tag

**SPEC v1.2.2 §1–§8 satisfied.** Both member-isolation counts closed.
Issues #122, #127 and #128 closed.

One known gap remains, tracked and *not* a §6.1 matter:
[#130](https://github.com/JC-000/c64-x25519/issues/130) —
`src/x25519.inc` imports `ct_mul_8x8` outside the `SHARED_CT_MUL_8X8`
gate, so a §8.3-owning consumer cannot include the header. #128 fixed the
**archive** side; that is the **header** side, and it fails one step
earlier, at assemble time. §3's header-import-guard rule is textually
scoped to "an overridable equate", so a §8.3 code name is the same hazard
one clause over rather than a §3 breach. It gets its own release and its
own red-green.

---

## 6. Consumer action

**None.** No exported symbol changes name, value or address. The PRG is
byte-identical to v0.15.0.

The archive gains a 13th member, `sqtab_init.o`, holding `sqtab_init` and
`mul_tables_init` — the same names at the same addresses. What changes is
that owning §8.3 while deferring §8.1 now links, where before it could
not.

If you are moving from v0.14.0 or earlier, read
[`docs/RELEASE_NOTES_v0.15.0.md`](docs/RELEASE_NOTES_v0.15.0.md) first —
that release moves `LIB_X25519_ABI_VERSION` to 4 and changes the PRG.
