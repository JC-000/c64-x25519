# TODO: library-state follow-ups

This file lists concrete steps for turning `c64-x25519` from a
test-driven optimization harness into a drop-in library. It is the
follow-up to the cataloging/documentation pass that produced
`src/x25519.inc` and `docs/LIBRARY.md`. Each step is ordered to
minimize blast-radius and to keep the VICE-harness label-file based
tests passing throughout.

## Safety preamble

- **Do not rename symbols without coordinating with `tools/` and
  `test/`.** The VICE test harness looks symbols up in
  `build/labels.txt` by name; renames will silently break tests until
  the Python side is updated in lockstep.
- **One rename per commit.** After each rename, rebuild and run the
  full VICE test suite before moving on. This is the only way to
  catch typos in the Python side.
- **Keep aliases during migration.** For each renamed label, leave a
  line of the form `old_name = new_name` for one commit so both names
  resolve. Drop the alias in a follow-up commit after tests are green.

## Ordered follow-ups

### 1. Prefix public entry points

Add `x25519_` / `fe25519_` prefixes to the public API, keeping the
old names as equate aliases for one commit:

- `fe_copy`   -> `fe25519_copy`
- `fe_zero`   -> `fe25519_zero`
- `fe_one`    -> `fe25519_one`
- `fe_add`    -> `fe25519_add`
- `fe_sub`    -> `fe25519_sub`
- `fe_mul`    -> `fe25519_mul`
- `fe_sqr`    -> `fe25519_sqr`
- `fe_mul_a24`-> `fe25519_mul_a24`
- `fe_inv`    -> `fe25519_inv`
- `fe_cswap`  -> `fe25519_cswap`
- `fe_reduce_final` -> `fe25519_reduce_final`
- `fe_cmp_p`  -> `fe25519_cmp_p`

`x25519_clamp`, `x25519_scalarmult`, `x25519_base` are already prefixed.

Coordinate with `tools/` Python harness owners before touching any
label referenced from Python test code.

### 2. Mark private helpers clearly

These are currently top-level labels but are library-internal; add a
`_priv_` infix (or similar) and/or move them inside `!zone` blocks:

- `fe_reduce_wide`, `mul_by_38`, `mul38_in/lo/hi`
- `fe_inv_dst`, `fe_inv_sqrn_tmp2`, `fe_inv_sqr_cnt`
- `x25519_ladder_step`
- `reu_fetch_mul_row`, `reu_fetch_doubled_row`, `reu_clear_wide`
- `sq_acc`, `sq_i`, `sq_sh`, `sq_ad`, `mul_s_pg`, `mul_a`, `mul_b`
- `poly_prod_lo`, `poly_prod_hi`
- Self-mod patch sites inside `fe_mul` / `fe_sqr` / `fe_add` / `fe_sub`

### 3. Split main.asm into harness vs library-init

`main.asm` currently mixes:

- BASIC stub + test driver loop (harness-only)
- `clrscr`, `print_string`, `bench_*`, `vic_blank`, `vic_unblank` (public)
- `sqtab_init` caller, `reu_mul_init` (library init)
- REU helper primitives (library-internal)

Extract the library-init + REU helpers into a new `src/x25519_init.asm`
so that downstream projects can `!source` it without pulling in the
BASIC stub, the idle loop, or the test trampoline.

### 4. Introduce a true header file

Once step 1 and step 3 are done, rewrite `src/x25519.inc` to contain
*only* equates and commented prototypes — no prose documentation
(move that to `docs/LIBRARY.md` which already exists). Treat it as
the actual public ABI definition.

### 5. Produce a relocatable build artifact

Current build is one monolithic `.prg` at `$0801`. For library use,
add a make target that assembles the library modules to a fixed
upper-RAM origin (e.g. `$A000` with BASIC banked out) and emits:

- a `.bin` stripped of load address
- a `.sym` / relocation table
- optionally a `.o` equivalent if migrating to ca65/ld65 is on the
  table (ACME has no native linker; ca65 would be a bigger change
  but yields a real library).

Decide whether ACME-at-fixed-origin is "good enough" or whether to
port the build to ca65. If ca65, this also unlocks `.export` /
`.import` / `.scope` which makes step 1 and step 2 much cleaner.

### 6. Document alignment enforcement at the language level

Once headers are real, add a static assertion (ACME `!if` / `!warn`)
that every public 32-byte field buffer passed in is at a
`$00/$20/.../$E0` offset. Currently alignment is a comment-level
contract only (see commit `14920b7`).

## Non-goals for the library pass

- **Do NOT add** constant-time hardening beyond what is already in
  `fe_cswap`. X25519-on-6502 is inherently cache/timing-noisy; the
  threat model is wire-level attackers, not local adversaries.
- **Do NOT add** an RNG, KDF, or Ed25519. Those belong in higher
  layers.
- **Do NOT rewrite** the field arithmetic during the library pass.
  Performance work goes on its own branches.
