# ca65/ld65 toolchain (cc65 suite)
CA65 = ca65
LD65 = ld65
CC65_CFG = cfg/x25519.cfg

# §6.2 defines-forwarding (contract SPEC v0.9.0). CONTRACT_DEFINES
# carries consumer `-D` overrides into every TU:
#   make lib CONTRACT_DEFINES="-D LIB_SHARED_SQTAB_BASE=0xC000"
# CONTRACT_ZP_DEFINES routes per the §6.2 two-variable contract, with
# the scope adapted to x25519's include-model ZP delivery: it reaches
# EVERY LIBRARY TU (each .include-s zp_config.s, so scoping it to
# zp_config.o alone would silently diverge slot addresses between
# TUs), but NOT consumer-model TUs that .importzp the slots — a -D of
# a slot in an .importzp TU is a hard "already defined" error
# (measured on our own verify stub). Consumer .importzp sites get the
# overridden address at link time from the library objects.
# CA65FLAGS remains as a deprecated alias through the §6.5
# rename window. Variant targets APPEND their profile defines (last
# wins on conflicts) instead of clobbering consumer values — the
# pre-v0.9.0 recursive $(MAKE) hard-assignment silently dropped them.
CONTRACT_DEFINES ?=
CONTRACT_ZP_DEFINES ?=
CA65FLAGS ?=
ALL_DEFINES = $(CA65FLAGS) $(CONTRACT_DEFINES) $(CONTRACT_ZP_DEFINES)

SRC_DIR = src
BUILD_DIR = build
LIB_DIR = $(BUILD_DIR)/lib

# --- §6.3 knob-staleness guard (SPEC v0.10.5 shape 3; contract#127) ----------
# ALL_DEFINES reaches every TU's assemble flags, but make cannot see a knob
# VALUE change: nothing lists the knobs as a prerequisite, so a re-invocation
# with different defines reuses every stale object and exits 0 having shipped
# an artifact other than the one requested. That is the v0.10.5 shape-3
# "silent no-op", and it bites here even though X25519_PROFILE is already
# guarded at parse time -- that guard is on the knob's NAME and does not
# touch this shape (contract#127's point exactly).
#
# All three measured on a warm tree before this guard existed:
#   CONTRACT_DEFINES="-D SHARED_CT_MUL_8X8=1"     -> owner archive shipped,
#     all five §8.3 provider names still exported, 0 ca65 invocations
#   CONTRACT_DEFINES="-D LIB_NO_BARE_EXPORTS=1"   -> suppression silently NOT
#     applied, bare four still exported (the #43 duplicate-identifier failure
#     the mitigation exists to prevent)
#   CONTRACT_DEFINES="-D LIB_SHARED_SQTAB_BASE=0xC000" -> 0 ca65 invocations,
#     stale address for the §8.1 window
#
# The stamp records the flattened knob string at parse time; when it changes,
# every object and archive is invalidated -- the knobs reach every TU, so
# every object genuinely IS stale -- and the requested configuration is built.
# Unchanged knobs leave the tree alone, so same-knob incremental builds stay
# incremental. Both properties are pinned by leg C of `make lib-verify-guards`;
# a guard missing either is worse than none (an unconditional rebuild wearing
# a stamp, or a check that only proves something rebuilt rather than that the
# artifact flipped).
#
# Stamped from ALL_DEFINES rather than CONTRACT_DEFINES alone: the deprecated
# CA65FLAGS alias reaches ca65 too, so a stamp ignoring it would be honest
# about the modern spelling only. The stamp lives under $(BUILD_DIR), so the
# profile targets -- which re-invoke make with their own BUILD_DIR -- each get
# their own, and the sibling shape from c64-nist-curves (Makefile ~86-103,
# pinned by tools/check_archives.py) is preserved.
#
# It mkdir's only $(BUILD_DIR), never $(LIB_DIR): `rm -f` tolerates missing
# paths, and creating $(LIB_DIR) here would satisfy the `| $(LIB_DIR)`
# order-only prerequisite without its cfg/ subdirectory -- re-triggering
# the exact staleness-shaped breakage fixed on the sibling branch
# (measured: `make lib CONTRACT_DEFINES=...` on a clean tree died with
# `cp: build/lib/cfg/x25519-example.cfg: No such file or directory`).
# The invalidation deletes the LINKED outputs too, not just .o/.a, and it
# deletes rather than re-orders dependencies. /usr/bin/make here is GNU Make
# 3.81, whose mtime comparison has whole-second granularity: after a knob
# change every .o reassembles, but the newest .o lands in the SAME SECOND as
# the existing x25519.prg, so 3.81 judges the PRG up to date and ld65 never
# runs. `make all` then exits 0 holding the PREVIOUS config's binary --
# exactly the exit-0-wrong-artifact emission SPEC v0.11.1 §6.3 forbids, and
# the same mtime-granularity family as issue #113 (whose no-rebuild leg
# compared minute-granular `ls -l` and could never fail). A nonexistent
# target is unconditionally rebuilt by every make version, so removing the
# artifact sidesteps the comparison instead of trying to win it.
#
# The lib_verify globs are load-bearing on their own: without them
# `lib-verify` grades the PRIOR config's stub PRG and stub.labels, which
# surfaces as a spurious "symbol sqtab_init present but must be gated out"
# under the shared-sqtab profile. Fixing the top-level PRG alone leaves that
# defect standing.
#
# These three names are defined HERE, above the stamp block, and nowhere
# else: $(shell) expands at PARSE time, so any variable the rm list names
# must already be set at this point or it expands to empty and the rm
# silently covers nothing. (Measured: spelling the list with $(PRG)/$(LABELS)
# while they were still defined below left the fix a 4/4 no-op.) Naming the
# variables rather than repeating the path literals keeps a future rename of
# labels.txt from silently dropping out of the invalidation set.
PRG = $(BUILD_DIR)/x25519.prg
LABELS = $(BUILD_DIR)/labels.txt
LIB_VERIFY_DIR = $(BUILD_DIR)/lib_verify

CONTRACT_STAMP := $(BUILD_DIR)/.contract-defines.stamp
CURRENT_KNOBS  := $(strip $(ALL_DEFINES))
STORED_KNOBS   := $(strip $(shell cat $(CONTRACT_STAMP) 2>/dev/null))
ifneq ($(CURRENT_KNOBS),$(STORED_KNOBS))
$(shell mkdir -p $(BUILD_DIR); \
        rm -f $(BUILD_DIR)/*.o $(LIB_DIR)/*.o $(LIB_DIR)/*.a \
              $(PRG) $(LABELS) $(LABELS).raw \
              $(LIB_VERIFY_DIR)/*.o $(LIB_VERIFY_DIR)/*.prg \
              $(LIB_VERIFY_DIR)/*.labels; \
        printf '%s' "$(CURRENT_KNOBS)" > $(CONTRACT_STAMP))
endif

# Library .o set (what ships in libx25519.a — no test harness code).
LIB_OBJS = $(BUILD_DIR)/x25519_init.o \
           $(BUILD_DIR)/mul_8x8.o \
           $(BUILD_DIR)/fe25519.o \
           $(BUILD_DIR)/x25519.o \
           $(BUILD_DIR)/data.o \
           $(BUILD_DIR)/util.o \
           $(BUILD_DIR)/lib_version.o \
           $(BUILD_DIR)/lib_manifest.o \
           $(BUILD_DIR)/zp_config.o \
           $(BUILD_DIR)/reu_config.o

# Separate compilation: each .s file produces its own .o
CA65_SRCS = $(SRC_DIR)/main.s \
            $(SRC_DIR)/constants.s \
            $(SRC_DIR)/x25519_init.s \
            $(SRC_DIR)/mul_8x8.s \
            $(SRC_DIR)/fe25519.s \
            $(SRC_DIR)/x25519.s \
            $(SRC_DIR)/data.s \
            $(SRC_DIR)/util.s \
            $(SRC_DIR)/lib_version.s \
            $(SRC_DIR)/lib_manifest.s \
            $(SRC_DIR)/zp_config.s \
            $(SRC_DIR)/reu_config.s

CA65_OBJS = $(BUILD_DIR)/main.o $(LIB_OBJS)

LIBX25519 = $(LIB_DIR)/libx25519.a

.PHONY: all clean test test-slow test-ref test-vice lib lib-verify \
        lib-verify-shared lib-app-owned lib-verify-guards lib-verify-docs \
        lib-verify-footprint lib-verify-footprint-negative \
        lib-verify-footprint-negative-arm \
        lib-verify-negative lib-verify-guards-legc \
        dist bench-record perf-diff lib-x25519-1764 lib-x25519-onchip

all: $(PRG)

# Fast test suite: Python-only checks that do not launch VICE.
test:
	@set -e; \
	python3 tools/ref_x25519.py

# Slow test suite: full RFC 7748 vector cross-check and ladder checkpoint
# replay. Requires a built .prg and a working VICE install.
test-slow: $(PRG)
	@set -e; \
	python3 tools/ref_x25519.py; \
	python3 tools/test_fe25519.py; \
	python3 tools/test_reu_settle_slowpath.py; \
	python3 tools/test_fe_mul_stress.py; \
	python3 tools/test_fe_sqr_stress.py; \
	python3 tools/test_ct_square_cycles.py; \
	python3 tools/test_ct_mul_cycles.py; \
	python3 tools/test_ct_mul_a24_cycles.py; \
	python3 tools/test_ct_reduce_wide_cycles.py; \
	python3 tools/test_fe_reduce_wide_carry.py; \
	python3 tools/test_fe_reduce_wide_bound.py; \
	python3 tools/test_opt_sqr.py; \
	python3 tools/test_opt_karatsuba.py; \
	python3 tools/test_opt_fast_mul.py; \
	python3 tools/test_opt_vic_reduce38.py; \
	python3 tools/test_mul38_tables.py; \
	python3 tools/test_x25519.py --slow; \
	python3 tools/test_ladder_checkpoint.py --start 0 --count 255; \
	python3 tools/test_fe_adversarial_bigint.py; \
	python3 tools/test_x25519_adversarial_kat.py --quick; \
	python3 tools/test_x25519_edge_u.py --slow; \
	python3 tools/test_rfc7748_iterated.py --slow; \
	python3 tools/test_rfc7748_iter1000.py --iterations 1; \
	python3 tools/test_ct_ladder_cycles.py
# The four audit-2026-08-28 tests above (fe_adversarial_bigint,
# x25519_adversarial_kat, ct_ladder_cycles, rfc7748_iter1000 at 1
# iteration) plus the repaired edge_u / rfc7748_iterated members were
# added so they can never silently rot behind a --slow gate again.
# `tools/test_rfc7748_iter1000.py --iterations 1000` (RFC 7748 §5.2
# 1,000-iteration vector) is ~5-7 h under VICE warp and is MANUAL only,
# as is the full (non --quick) test_x25519_adversarial_kat.py (~80 ladders).

# VICE test suite: run key tests against the built .prg.
test-vice: $(PRG)
	@set -e; \
	echo "=== Running VICE tests ==="; \
	python3 tools/test_mul38_tables.py; \
	python3 tools/test_fe25519.py; \
	python3 tools/test_fe_mul_stress.py; \
	python3 tools/test_fe_sqr_stress.py; \
	python3 tools/test_ct_square_cycles.py; \
	python3 tools/test_ct_mul_cycles.py; \
	python3 tools/test_ct_mul_a24_cycles.py; \
	python3 tools/test_ct_reduce_wide_cycles.py; \
	python3 tools/test_fe_reduce_wide_carry.py; \
	python3 tools/test_fe_reduce_wide_bound.py

# Reference-only self-test (no VICE, no build required).
test-ref:
	python3 tools/ref_x25519.py

# --- ca65 build ----------------------------------------------------------

# Each .s file compiles to its own .o (constants.s is .include'd by every
# unit; zp_config.s + reu_config.s are .include'd transitively via
# constants.s and are also their own translation units for the public
# .exportzp / .export emission).
$(BUILD_DIR)/%.o: $(SRC_DIR)/%.s $(SRC_DIR)/constants.s $(SRC_DIR)/zp_config.s $(SRC_DIR)/reu_config.s $(SRC_DIR)/precalc_table.inc | $(BUILD_DIR)
	$(CA65) $(ALL_DEFINES) -o $@ $<

$(PRG): $(CA65_OBJS) $(CC65_CFG) | $(BUILD_DIR)
	$(LD65) -C $(CC65_CFG) -o $(PRG) -Ln $(LABELS).raw $(CA65_OBJS)
	sed 's/^al \([0-9a-fA-F]\{6\}\) /al C:\1 /' $(LABELS).raw > $(LABELS)
	rm -f $(LABELS).raw

# --- directories ----------------------------------------------------------

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(LIB_DIR):
	mkdir -p $(LIB_DIR)

# `build/lib/cfg` gets its OWN order-only target rather than riding the
# `$(LIB_DIR)` recipe above. Order-only prerequisites are satisfied by the
# directory merely existing, and three profile targets (lib-app-owned,
# lib-x25519-onchip, lib-x25519-1764) publish their archive with a bare
# `mkdir -p build/lib` — creating $(LIB_DIR) WITHOUT the cfg subdirectory.
# That permanently satisfied `| $(LIB_DIR)` for every later rule, so the
# recipe that would have created cfg/ never ran again and the canonical
# §6.1 target broke on a stale tree:
#
#     make lib-app-owned && make lib
#     cp: build/lib/cfg/x25519-example.cfg: No such file or directory
#
# Present in every release through v0.11.2 (two of the three bare mkdirs
# date to 0fbe985, the third to d304752); invisible to a from-clean
# `make lib`, which is the only order this repo's local gates ever ran.
# Naming the real directory as the prerequisite makes the copy rule
# self-sufficient no matter who created $(LIB_DIR) first.
$(LIB_DIR)/cfg:
	mkdir -p $(LIB_DIR)/cfg

clean:
	rm -f $(BUILD_DIR)/*.o $(PRG) $(LABELS) $(LABELS).raw $(CONTRACT_STAMP)
	rm -rf $(LIB_DIR)
	# Profile targets build into their own BUILD_DIR and clean it on entry,
	# but nothing swept them afterwards, so they lingered as untracked trees.
	rm -rf build-1764 build-onchip build-app-owned build-guards build-shared
	rm -rf build-fp build-fp-default build-fp-onchip
	rm -rf build-guards-default build-guards-onchip
	rm -rf build-neg build-neg-artifact

# --- Relocatable library archive ---------------------------------------------
#
# `make lib` produces a ca65/ld65-ready library package under build/lib/ that
# downstream c64 crypto projects can vendor and link against:
#
#   build/lib/libx25519.a      — ca65 archive of all library .o modules
#   build/lib/*.o              — individual .o files (alternative to the archive)
#   build/lib/x25519.inc       — public header (copy of src/x25519.inc)
#   build/lib/cfg/x25519-example.cfg — starter linker config fragment
#
# The archive contains ONLY library code (fe25519, x25519, x25519_init,
# mul_8x8, data, util). It does NOT include main.o (BASIC stub, test harness
# idle loop, print helpers) — downstream users supply their own entry point.

lib: $(LIBX25519) \
     $(LIB_DIR)/x25519.inc \
     $(LIB_DIR)/cfg/x25519-example.cfg \
     $(addprefix $(LIB_DIR)/, $(notdir $(LIB_OBJS)))
	@cp $(LIBX25519) $(LIB_DIR)/x25519.a
	@echo "(§6.1 canonical basename: $(LIB_DIR)/x25519.a — libx25519.a is the"
	@echo " deprecated dialect, shipped alongside through the §6.5 window,"
	@echo " dropped at the next MAJOR)"

$(LIBX25519): $(LIB_OBJS) | $(LIB_DIR)
	rm -f $@
	ar65 r $@ $(LIB_OBJS)

$(LIB_DIR)/%.o: $(BUILD_DIR)/%.o | $(LIB_DIR)
	cp $< $@

$(LIB_DIR)/x25519.inc: $(SRC_DIR)/x25519.inc | $(LIB_DIR)
	cp $< $@

$(LIB_DIR)/cfg/x25519-example.cfg: cfg/x25519-example.cfg | $(LIB_DIR)/cfg
	cp $< $@

# --- Library linkage smoke test ----------------------------------------------
#
# `make lib-verify` assembles a tiny downstream stub, links it against
# libx25519.a via the example config, and asserts the resulting binary is
# non-zero and contains all the expected public symbols. This proves the
# archive is actually usable, not just a pile of .o files in a tarball.

LIB_VERIFY_PRG = $(LIB_VERIFY_DIR)/lib_linkage_stub.prg
LIB_VERIFY_STUB = tests/lib_linkage/lib_linkage_stub.s
LIB_VERIFY_PROVIDER = tests/lib_linkage/shared_provider_stub.s

# The onchip x full-deferral define set (leg 5 of lib-verify-shared). Kept as
# one variable so the archive and BOTH stubs are assembled from the identical
# set -- assembling the stubs from a different set is the failure this leg
# exists to catch, and it is silent until link.
ONCHIP_DEFER_DEFINES = -D SHARED_SQTAB_INIT=1 -D SHARED_REU_MUL_INIT=1 \
                       -D SHARED_REU_MUL_FETCH=1 -D SHARED_CT_MUL_8X8=1 \
                       -D X25519_ONCHIP_MUL=1

# Profile selector for lib-verify's symbol expectations. The onchip
# profile (issue #72) ships no REU surface, so its expected-symbol set
# both DROPS the reu_* / §8.2 names and ASSERTS their absence (a
# present-but-should-be-gone symbol is as much a bug as a missing one).
# The shared-* profiles (R6 / `make lib-verify-shared`) verify the
# §8.x SHARED_* deferral builds link against a provider stand-in
# (tests/lib_linkage/shared_provider_stub.s) with the deferred
# x25519-own names absent. Default `make lib-verify` is unchanged.
X25519_PROFILE ?= default

# --- §6.3 looks-reachable guard (contract v0.10.5, issue #117) --------------
# X25519_PROFILE *names* an axis, so per §6.3's three-shape ladder it MUST
# select that axis or fail loudly — silent exit-0 disagreement is
# non-conformant whether or not a target exists for the combination.
#
# It does not select anything on its own: it picks lib-verify EXPECTATIONS,
# while the axis itself rides CONTRACT_DEFINES. Before this guard x25519 was
# shape 3 (silent no-op), measured at v0.11.1: `make lib X25519_PROFILE=onchip`
# exited 0 and shipped an archive identical to the default build rather than
# the onchip one. A typo'd value was absorbed just as quietly — the ifeq
# chain's closing `else` is the default branch, so X25519_PROFILE=onchipp
# silently built default.
#
# Both holes are closed here: an unknown value is rejected, and a known value
# must be accompanied by the -D that actually selects it. The named profile
# targets (lib-x25519-onchip, lib-x25519-1764, lib-verify-shared,
# lib-app-owned) all pass the matching -D alongside X25519_PROFILE, so they
# satisfy this by construction. The reverse direction — defines without the
# matching profile — already fails loudly in lib-verify via the mask/CONSUMES
# asserts (e.g. onchip's $000005 vs default's $000007).
X25519_PROFILE_VALID := default onchip 1764 \
	shared-sqtab shared-reu shared-ct shared-all

ifeq ($(filter $(X25519_PROFILE),$(X25519_PROFILE_VALID)),)
$(error X25519_PROFILE='$(X25519_PROFILE)' is not a known profile. Valid values: $(X25519_PROFILE_VALID))
endif

# The switches split by GATE STYLE, and the guard must match each on its own
# terms — demanding one spelling fleet-wide falsely rejects working builds.
#
#   _NEEDS_DEF_* — definedness-gated (.ifdef / .ifndef): src/mul_8x8.s:37,55,
#     src/x25519_init.s:14,94, src/reu_config.s:118. The axis IS definedness,
#     so EVERY spelling that defines the symbol selects it — bare
#     `-D SHARED_SQTAB_INIT` as much as `=1`, and the bare form is what
#     nist#117's example and the chacha docs use. Match the bare name, which
#     also substring-matches the `=1` spelling our own targets pass.
#
#   _NEEDS_VAL_* — value-gated (.if ::NAME): src/lib_manifest.s:177,361,
#     src/reu_config.s:177 for X25519_ONCHIP_MUL; src/x25519_init.s:25,194,456
#     and src/fe25519.s:40,1211 for SQR_DMA_K. Here the exact value decides,
#     and ca65's bare `-D NAME` defines the symbol **= 0** (measured: `.out`
#     prints `FOO=0` under bare `-D FOO`). For X25519_ONCHIP_MUL that is
#     load-bearing: bare `-D X25519_ONCHIP_MUL` names the profile while
#     selecting the DEFAULT path — precisely the shape-3 no-op this guard
#     exists to kill — so the `=1` demand is deliberate. Do not "simplify" it
#     to a bare-name match.
#
#     SQR_DMA_K=0 is the deliberate-but-stricter case: bare `-D SQR_DMA_K`
#     would also select the 1764 axis (ca65 makes it 0, which is what 1764
#     wants), so rejecting it is stricter than conformance requires. We demand
#     the explicit spelling anyway, so that a value-gated switch never rides on
#     ca65's silent bare-means-zero rule and the `=0` stays visible in the
#     build line. The error text says so rather than leaving it looking like
#     an oversight.
X25519_PROFILE_NEEDS_DEF_shared-sqtab := SHARED_SQTAB_INIT
X25519_PROFILE_NEEDS_DEF_shared-reu   := SHARED_REU_MUL_INIT SHARED_REU_MUL_FETCH
X25519_PROFILE_NEEDS_DEF_shared-ct    := SHARED_CT_MUL_8X8
X25519_PROFILE_NEEDS_DEF_shared-all   := SHARED_SQTAB_INIT SHARED_REU_MUL_INIT \
	SHARED_REU_MUL_FETCH SHARED_CT_MUL_8X8

X25519_PROFILE_NEEDS_VAL_onchip := X25519_ONCHIP_MUL=1
X25519_PROFILE_NEEDS_VAL_1764   := SQR_DMA_K=0

$(foreach d,$(X25519_PROFILE_NEEDS_DEF_$(X25519_PROFILE)),\
  $(if $(findstring $(d),$(CONTRACT_DEFINES)),,\
    $(error X25519_PROFILE=$(X25519_PROFILE) does not select that axis: '$(d)' is not defined in CONTRACT_DEFINES. It is .ifdef-gated, so any spelling that defines it works -- `-D $(d)` or `-D $(d)=1`. Use the named target, or pass CONTRACT_DEFINES="-D $(d)". Contract v0.10.5 6.3: a knob naming an axis MUST select it or fail loudly.)))

$(foreach d,$(X25519_PROFILE_NEEDS_VAL_$(X25519_PROFILE)),\
  $(if $(findstring $(d),$(CONTRACT_DEFINES)),,\
    $(error X25519_PROFILE=$(X25519_PROFILE) does not select that axis: '-D $(d)' is missing from CONTRACT_DEFINES. This switch is value-gated (.if ::NAME), and ca65's bare `-D NAME` defines it = 0, so the explicit value spelling is required -- for X25519_ONCHIP_MUL a bare -D would silently select the DEFAULT path. Use the named target, or pass CONTRACT_DEFINES="-D $(d)". Contract v0.10.5 6.3: a knob naming an axis MUST select it or fail loudly.)))

LIB_VERIFY_SYMS_COMMON = x25519_clamp x25519_scalarmult x25519_base \
	fe25519_add fe25519_sub fe25519_mul fe25519_sqr \
	x25_scalar x25_u x25_result \
	vic_blank vic_unblank bench_start bench_stop \
	bench_cycles_start bench_cycles_stop bench_cycles \
	LIB_VERSION_MAJOR LIB_VERSION_MINOR LIB_VERSION_PATCH \
	LIB_ABI_VERSION \
	LIB_X25519_VERSION_MAJOR LIB_X25519_VERSION_MINOR \
	LIB_X25519_VERSION_PATCH LIB_X25519_ABI_VERSION \
	fe25519_src1 fe25519_src2 fe25519_dst \
	fe_carry mul_carry \
	LIB_X25519_ZP_USAGE_BYTES LIB_X25519_REU_BANKS_USED \
	LIB_X25519_RESIDENT_BYTES LIB_X25519_COLD_BYTES \
	x25519_reu_fault \
	LIB_X25519_SHARED_PRIMITIVES \
	LIB_X25519_SHARED_CONSUMES \
	LIB_PRECALC_sqtab_SIZE \
	LIB_X25519_PRECALC_sqtab_SIZE \
	mul_tables_init

# Doubled-table surface (SQR_DMA_K > 0 only): present in the default
# archive, gated out of 1764 (SQR_DMA_K=0) and onchip (profile forces
# SQR_DMA_K=0). The 1764 profile asserts these ABSENT — the contract
# #62 audit found nothing had ever locked that archive's smaller
# export set (it verified under the default expectations).
LIB_VERIFY_SYMS_DOUBLED = reu_fetch_doubled_row \
	LIB_PRECALC_reu_mul_doubled_SIZE \
	LIB_X25519_PRECALC_reu_mul_doubled_SIZE

# §8.x bit constants must NEVER be exported (issues #77/#78 item 3):
# they are unprefixed names with identical values in every §8 adopter,
# so any export collides at link time with a sibling library (the
# c64-ChaCha20-Poly1305 pair). Asserted absent in EVERY profile —
# consumers get them by copying the SPEC §8.0 equate block instead.
LIB_VERIFY_SYMS_ABSENT_ALWAYS = \
	LIB_SHARED_PRIMITIVES_SQTAB LIB_SHARED_PRIMITIVES_REU_MUL \
	LIB_SHARED_PRIMITIVES_CT_MUL_8X8 \
	LIB_SHARED_REU_MUL_BANK LIB_SHARED_REU_MUL_OFFSET \
	LIB_SHARED_REU_MUL_BANKS_USED \
	LIB_SHARED_REU_MUL_STAGE_LO LIB_SHARED_REU_MUL_STAGE_HI \
	LIB_SHARED_REU_MUL_ZP_INIT_A LIB_SHARED_REU_MUL_ZP_INIT_B \
	zp_ptr1 zp_tmp1 zp_tmp2

# §8.1 init surface. mul_tables_init is canonical (in COMMON — resolves
# in every profile: owner body or provider stand-in); sqtab_init is the
# x25519-own historical name, absent from §8.1 deferral builds since
# the v0.9.0 import-never-stub migration.
LIB_VERIFY_SYMS_SQTAB_OWN = sqtab_init

# §8.3 body surface. ct_mul_8x8 is the canonical name (resolves to the
# provider stand-in under SHARED_CT_MUL_8X8); mul_8x8 is the x25519-own
# back-compat alias, gated out of a §8.3 deferral build.
LIB_VERIFY_SYMS_CT_CANON = ct_mul_8x8
LIB_VERIFY_SYMS_CT_OWN = mul_8x8

# §8.2 REU surface, split by deferral behavior under SHARED_REU_MUL_INIT:
#   _REU_OWN     x25519-private init name — gated out of a deferral build
#   _REU_CANON   canonical §8.2 entry — own standalone, provider stand-in
#                under deferral, present either way
#   _REU_SURFACE fetch hook + placement equates + precalc row — x25519-own
#                in every REU-consuming build (the deferral moves the init
#                provider, not the table consumption)
LIB_VERIFY_SYMS_REU_OWN = reu_mul_init \
	LIB_X25519_SHARED_REU_MUL_ZP_INIT_A LIB_X25519_SHARED_REU_MUL_ZP_INIT_B
LIB_VERIFY_SYMS_REU_CANON = reu_mul_tables_init
LIB_VERIFY_SYMS_REU_SURFACE = reu_fetch_mul_row reu_fetch_mul_row_bank_patch \
	X25519_REU_BANK X25519_REU_OFFSET \
	X25519_REU_BANK_DOUBLED X25519_REU_BANK_CARRY \
	LIB_X25519_SHARED_REU_MUL_BANK LIB_X25519_SHARED_REU_MUL_OFFSET \
	LIB_X25519_SHARED_REU_MUL_BANKS_USED \
	LIB_X25519_SHARED_REU_MUL_STAGE_LO LIB_X25519_SHARED_REU_MUL_STAGE_HI \
	LIB_PRECALC_reu_mul_SIZE \
	LIB_X25519_PRECALC_reu_mul_SIZE

LIB_VERIFY_SYMS_REU = $(LIB_VERIFY_SYMS_REU_OWN) $(LIB_VERIFY_SYMS_REU_CANON) \
	$(LIB_VERIFY_SYMS_REU_SURFACE)

# Per-profile expected symbol sets + the expected
# LIB_X25519_SHARED_PRIMITIVES / LIB_X25519_SHARED_CONSUMES values
# (PR #63 conditional-mask matrix + SPEC v0.5.0 consumes companion,
# as 6-hex-digit ld65 -Ln label values). The mask asserts are a
# regression guard on the §8.0 mask construction in
# src/lib_manifest.s. CONSUMES stays $0007 across every SHARED_*
# deferral profile (deferral moves ownership, not consumption) and
# drops the §8.2 bit only under the onchip profile gate.
# v0.12.0 (§8.2 v0.13.0 REU settle, #115): RESIDENT/COLD locks re-derived
# from od65 — default 8488/1154 ($2128/$0482), 1764 8317/871, onchip
# unchanged 8207/160; deferral deltas _D_RES_REU 55, _D_COLD_REU 542
# (K>0). See src/lib_manifest.s and docs/RELEASE_NOTES_v0.12.0.md §6.
ifeq ($(X25519_PROFILE),onchip)
LIB_VERIFY_SYMS_EXPECT = $(LIB_VERIFY_SYMS_SQTAB_OWN) $(LIB_VERIFY_SYMS_COMMON) \
	$(LIB_VERIFY_SYMS_CT_CANON) $(LIB_VERIFY_SYMS_CT_OWN)
LIB_VERIFY_SYMS_ABSENT = $(LIB_VERIFY_SYMS_REU) $(LIB_VERIFY_SYMS_DOUBLED)
LIB_VERIFY_MASK_EXPECT = 000005
LIB_VERIFY_CONSUMES_EXPECT = 000005
LIB_VERIFY_BANKS_EXPECT = 000000
LIB_VERIFY_RESIDENT_EXPECT = 00202A
LIB_VERIFY_COLD_EXPECT = 0000A0
else ifeq ($(X25519_PROFILE),1764)
LIB_VERIFY_SYMS_EXPECT = $(LIB_VERIFY_SYMS_SQTAB_OWN) $(LIB_VERIFY_SYMS_COMMON) \
	$(LIB_VERIFY_SYMS_CT_CANON) $(LIB_VERIFY_SYMS_CT_OWN) \
	$(LIB_VERIFY_SYMS_REU)
LIB_VERIFY_SYMS_ABSENT = $(LIB_VERIFY_SYMS_DOUBLED)
LIB_VERIFY_MASK_EXPECT = 000007
LIB_VERIFY_CONSUMES_EXPECT = 000007
LIB_VERIFY_BANKS_EXPECT = 000003
LIB_VERIFY_RESIDENT_EXPECT = 0020A3
LIB_VERIFY_COLD_EXPECT = 0002DD
else ifeq ($(X25519_PROFILE),shared-sqtab)
LIB_VERIFY_SYMS_EXPECT = $(LIB_VERIFY_SYMS_COMMON) \
	$(LIB_VERIFY_SYMS_CT_CANON) $(LIB_VERIFY_SYMS_CT_OWN) \
	$(LIB_VERIFY_SYMS_REU)
LIB_VERIFY_SYMS_ABSENT = $(LIB_VERIFY_SYMS_SQTAB_OWN)
LIB_VERIFY_MASK_EXPECT = 000006
LIB_VERIFY_CONSUMES_EXPECT = 000007
LIB_VERIFY_BANKS_EXPECT = 00003B
LIB_VERIFY_RESIDENT_EXPECT = 002137
LIB_VERIFY_COLD_EXPECT = 000313
else ifeq ($(X25519_PROFILE),shared-reu)
LIB_VERIFY_SYMS_EXPECT = $(LIB_VERIFY_SYMS_SQTAB_OWN) $(LIB_VERIFY_SYMS_COMMON) \
	$(LIB_VERIFY_SYMS_CT_CANON) $(LIB_VERIFY_SYMS_CT_OWN) \
	$(LIB_VERIFY_SYMS_REU_CANON) $(LIB_VERIFY_SYMS_REU_SURFACE)
LIB_VERIFY_SYMS_ABSENT = $(LIB_VERIFY_SYMS_REU_OWN)
LIB_VERIFY_MASK_EXPECT = 000005
LIB_VERIFY_CONSUMES_EXPECT = 000007
LIB_VERIFY_BANKS_EXPECT = 00003B
LIB_VERIFY_RESIDENT_EXPECT = 002117
LIB_VERIFY_COLD_EXPECT = 000208
else ifeq ($(X25519_PROFILE),shared-ct)
LIB_VERIFY_SYMS_EXPECT = $(LIB_VERIFY_SYMS_SQTAB_OWN) $(LIB_VERIFY_SYMS_COMMON) \
	$(LIB_VERIFY_SYMS_CT_CANON) $(LIB_VERIFY_SYMS_REU)
LIB_VERIFY_SYMS_ABSENT = $(LIB_VERIFY_SYMS_CT_OWN)
LIB_VERIFY_MASK_EXPECT = 000003
LIB_VERIFY_CONSUMES_EXPECT = 000007
LIB_VERIFY_BANKS_EXPECT = 00003B
LIB_VERIFY_RESIDENT_EXPECT = 0020F8
LIB_VERIFY_COLD_EXPECT = 0003B3
else ifeq ($(X25519_PROFILE),shared-all)
LIB_VERIFY_SYMS_EXPECT = $(LIB_VERIFY_SYMS_COMMON) \
	$(LIB_VERIFY_SYMS_CT_CANON) \
	$(LIB_VERIFY_SYMS_REU_CANON) $(LIB_VERIFY_SYMS_REU_SURFACE)
LIB_VERIFY_SYMS_ABSENT = $(LIB_VERIFY_SYMS_CT_OWN) $(LIB_VERIFY_SYMS_REU_OWN) \
	$(LIB_VERIFY_SYMS_SQTAB_OWN)
LIB_VERIFY_MASK_EXPECT = 000000
LIB_VERIFY_CONSUMES_EXPECT = 000007
LIB_VERIFY_BANKS_EXPECT = 00003B
LIB_VERIFY_RESIDENT_EXPECT = 0020D8
LIB_VERIFY_COLD_EXPECT = 000168
else
LIB_VERIFY_SYMS_EXPECT = $(LIB_VERIFY_SYMS_SQTAB_OWN) $(LIB_VERIFY_SYMS_COMMON) \
	$(LIB_VERIFY_SYMS_CT_CANON) $(LIB_VERIFY_SYMS_CT_OWN) \
	$(LIB_VERIFY_SYMS_REU) $(LIB_VERIFY_SYMS_DOUBLED)
LIB_VERIFY_SYMS_ABSENT =
LIB_VERIFY_MASK_EXPECT = 000007
LIB_VERIFY_CONSUMES_EXPECT = 000007
LIB_VERIFY_BANKS_EXPECT = 00003B
LIB_VERIFY_RESIDENT_EXPECT = 002137
LIB_VERIFY_COLD_EXPECT = 0003B3
endif

# --- consumer-snippet hygiene (SPEC §2 / §8.1, contract v0.14.2) ---------
#
# `make lib-verify-docs` rejects two spellings that are broken as pasted:
# a `$`-valued define, and cl65's `--asm-define` where it is used to set
# one (prose *about* the flag is fine).
#
# The `$` rule is about make, not about `$` as such: a direct ca65
# invocation with the value shell-quoted correctly yields 64.  But these
# defines are documented to ride CONTRACT_DEFINES / CONTRACT_ZP_DEFINES
# through *make*, which expands a `$`-value to 0 before ca65 ever sees
# it -- and shell quotes in the snippet do not prevent that, because make
# expands the recipe first.  Nothing downstream catches the zero: the
# §8.1 page-alignment assert passes (0 & 00ff = 0 -> sqtab at 0000), and
# zp_config.s asserts nothing about a slot being non-zero (-> the slot
# lands on 00, the 6510 DDR).  No diagnostic from make, ca65 or ld65.
# A make-variable reference in parens or braces is legitimate and is
# excluded -- Makefile is itself in scope here, which is also why the
# offending forms are described in words above rather than quoted: this
# comment would otherwise trip the checker it documents.
#
# Four such snippets shipped before this guard existed: cfg/x25519.cfg,
# cfg/x25519-example.cfg (which `make lib` copies into build/lib/cfg/),
# src/constants.s and docs/LIBRARY.md.  Measured against the pre-fix
# copies of those four files, the checker catches all four.  Its first
# cut caught only three: both regexes demanded an identifier-shaped NAME,
# so the angle-bracket metavariable form src/constants.s used -- one of
# the four defects this checker exists for -- slipped through.  Both
# regexes now accept an angle-bracket metavariable as well.
# Two of the four were split across wrapped comment lines, which is why
# the checker folds each file before matching rather than grepping
# line-by-line.
#
# Wired as a prerequisite of `lib-verify` so it actually runs: it is
# pure-python, sub-second, touches no build output and has no build
# prerequisites of its own, so it cannot introduce a cycle or cost.
#
# docs/RELEASE_NOTES_*.md are deliberately out of scope, but NOT because
# they cannot be touched -- this change set edits RELEASE_NOTES_v0.12.0.md.
# The reason is that a shipped release note is a historical record, so a
# broken snippet in one is ANNOTATED in place rather than rewritten: the
# original text has to stay readable as what actually shipped. That is a
# fix the checker cannot recognise, so scanning them would report permanent
# hits. Two such snippets are known and are annotated where they sit:
# docs/RELEASE_NOTES_v0.5.0.md:81 and :140.
#
# src/precalc_table.inc IS scanned, deliberately, even though CLAUDE.md
# forbids hand-editing it (byte-verbatim copy of the contract's §8.4
# macro). It is clean today; a hit there would mean the UPSTREAM macro
# carries a broken snippet -- fix it in c64-lib-contract and re-copy the
# file, never patch it locally. Detection is worth more than the
# inconvenience of an escalation path.
DOC_SNIPPET_FILES = $(wildcard cfg/*.cfg src/*.s src/*.inc) \
                    docs/LIBRARY.md README.md Makefile

lib-verify-docs:
	@python3 tools/check_doc_snippets.py $(DOC_SNIPPET_FILES)

# --- §5 footprint: DERIVED, not restated (contract SPEC v0.17.0 §15.1) ------
#
# The `LIB_X25519_RESIDENT_BYTES` / `_COLD_BYTES` pair in the loop below
# compares two HAND-WRITTEN numbers: the equates are literals in
# src/lib_manifest.s and the LIB_VERIFY_*_EXPECT locks are literals here.
# It therefore catches an INCONSISTENT edit but never a STALE PAIR.
# Measured: 16 `nop`s injected into fe25519_add grew fe25519.o's
# LIB_X25519_CODE 2750 -> 2766, the bytes reached the linked binary, and
# `make lib-verify` exited 0 across all seven profiles. Per §15.1 ("A
# check never observed to fail is not evidence that the property holds")
# that made the pair "evidence only that the check ran".
#
# tools/check_footprint.py MEASURES both fields with `od65 --dump-segsize`
# over the members `ar65 t` reports for the shipped archive, so the
# property being asserted is the one the equates name. It is wired as a
# step of `lib-verify` rather than a bolt-on target, so all seven profiles
# (default + the three profile targets + the four SHARED_* legs) get it
# for free; `lib-verify-footprint` exposes it standalone.
#
# Its own negative demonstration is `lib-verify-footprint-negative`
# (§15.1's "SHOULD be accompanied by a demonstration that it fails when
# the property it checks is false"), which replays exactly the 16-nop
# mutation above against a throwaway source copy.
LIB_VERIFY_FOOTPRINT_CMD = python3 tools/check_footprint.py \
	--archive $(LIBX25519) \
	--labels $(LIB_VERIFY_DIR)/stub.labels \
	--profile $(X25519_PROFILE)

lib-verify-footprint: lib $(LIB_VERIFY_PRG)
	@$(LIB_VERIFY_FOOTPRINT_CMD)

lib-verify: lib-verify-docs lib $(LIB_VERIFY_PRG)
	@set -e; \
	test -s $(LIB_VERIFY_PRG) || (echo "FAIL: $(LIB_VERIFY_PRG) is empty" && exit 1); \
	for sym in $(LIB_VERIFY_SYMS_EXPECT); do \
	  grep -q "\\b$$sym\\b" $(LIB_VERIFY_DIR)/stub.labels \
	    || (echo "FAIL: expected symbol $$sym not in linked binary" && exit 1); \
	done; \
	for sym in $(LIB_VERIFY_SYMS_ABSENT) $(LIB_VERIFY_SYMS_ABSENT_ALWAYS); do \
	  ! grep -q "\\b$$sym\\b" $(LIB_VERIFY_DIR)/stub.labels \
	    || (echo "FAIL: symbol $$sym present but must be gated out in $(X25519_PROFILE) profile" && exit 1); \
	done; \
	grep -q "^al $(LIB_VERIFY_MASK_EXPECT) \.LIB_X25519_SHARED_PRIMITIVES$$" \
	    $(LIB_VERIFY_DIR)/stub.labels \
	  || (echo "FAIL: LIB_X25519_SHARED_PRIMITIVES != \$$$(LIB_VERIFY_MASK_EXPECT) in $(X25519_PROFILE) profile:" \
	      && grep "LIB_X25519_SHARED_PRIMITIVES" $(LIB_VERIFY_DIR)/stub.labels \
	      && exit 1); \
	grep -q "^al $(LIB_VERIFY_CONSUMES_EXPECT) \.LIB_X25519_SHARED_CONSUMES$$" \
	    $(LIB_VERIFY_DIR)/stub.labels \
	  || (echo "FAIL: LIB_X25519_SHARED_CONSUMES != \$$$(LIB_VERIFY_CONSUMES_EXPECT) in $(X25519_PROFILE) profile:" \
	      && grep "LIB_X25519_SHARED_CONSUMES" $(LIB_VERIFY_DIR)/stub.labels \
	      && exit 1); \
	for pair in "$(LIB_VERIFY_BANKS_EXPECT):LIB_X25519_REU_BANKS_USED" \
	            "$(LIB_VERIFY_RESIDENT_EXPECT):LIB_X25519_RESIDENT_BYTES" \
	            "$(LIB_VERIFY_COLD_EXPECT):LIB_X25519_COLD_BYTES"; do \
	  val=$${pair%%:*}; sym=$${pair##*:}; \
	  grep -q "^al $$val \.$$sym$$" $(LIB_VERIFY_DIR)/stub.labels \
	    || (echo "FAIL: $$sym != \$$$$val in $(X25519_PROFILE) profile (stale manifest or gate wiring — contract #62 audit lock):" \
	        && grep "$$sym" $(LIB_VERIFY_DIR)/stub.labels && exit 1); \
	done; \
	$(LIB_VERIFY_FOOTPRINT_CMD); \
	bytes=$$(wc -c < $(LIB_VERIFY_PRG)); \
	echo "OK: $(LIB_VERIFY_PRG) is $$bytes bytes, $(X25519_PROFILE)-profile symbol surface verified (mask \$$$(LIB_VERIFY_MASK_EXPECT))"

# --- §15.1 negative legs for lib-verify's OWN assertions ---------------------
#
# `make lib-verify` is an AGGREGATE gate, and SPEC v0.17.0 §15.1 says
# the evidence obligation "applies per check within it, not to the gate
# as a whole" (the aggregate-gate sub-clause). Every assertion inside it grades
# link-produced values out of stub.labels and every one of them CAN
# report — but until now none had ever been observed reporting, which
# §15.1 (:1278) rates as "evidence only that the check ran".
#
# One leg per assertion, in the order lib-verify evaluates them:
#
#   N0  the non-empty-output test
#   N1  the expected-symbol loop          (LIB_VERIFY_SYMS_EXPECT)
#   N2  the must-be-absent loop           (…_ABSENT / …_ABSENT_ALWAYS)
#   N3  the §8.0 owned-primitives mask    (LIB_X25519_SHARED_PRIMITIVES)
#   N4  the §8.0 consumes companion       (LIB_X25519_SHARED_CONSUMES)
#   N5  the §3 REU bank claim             (LIB_X25519_REU_BANKS_USED)
#   N6  the §5 resident footprint lock    (LIB_X25519_RESIDENT_BYTES)
#   N7  the §5 cold footprint lock        (LIB_X25519_COLD_BYTES)
#
# GRADE, stated honestly rather than implied (§15.2 — "a
# negative build shows a check CAN report. It does not show that the
# check measures the property it names"):
#
#   N1 is ARTIFACT-side and therefore §15.2-grade: it builds a genuine
#   §8.3 deferral archive and grades it against the DEFAULT expectations,
#   so the value under test really is the wrong one and the check reads
#   it from the link. This is the documented reverse direction of the
#   §6.3 looks-reachable guard (defines without the matching profile),
#   made standing.
#
#   N0 and N2..N7 are EXPECTATION-side: they perturb what the check is
#   told to expect, not the artifact. That proves the comparison is live
#   and really reads the linked value — it does not by itself prove the
#   check measures the named property. Where that stronger evidence
#   exists it is elsewhere and is named here rather than claimed:
#     N3/N4  artifact-side coverage is `lib-verify-shared`, which builds
#            four genuinely different archives and grades each against a
#            different mask, plus leg C2 of `lib-verify-guards`, which
#            proves the artifact actually flips when the knob moves.
#     N6/N7  artifact-side coverage is `lib-verify-footprint-negative`,
#            which grows the real footprint by 16 bytes and requires the
#            derived check to catch it. That leg exists precisely because
#            N6/N7 alone are the weak form.
#     N2     no artifact-side form is available without editing library
#            source to export a name the contract forbids exporting, so
#            it stays expectation-side deliberately.
#
# All perturbations are command-line variable overrides on a sub-make, so
# nothing in the tracked tree changes and every leg is re-runnable. They
# never touch ALL_DEFINES, so the §6.3 stamp does not wipe build-neg and
# the legs after the first cost no rebuild.
NEG_DIR = build-neg
NEG_ART_DIR = build-neg-artifact
NEG_MAKE = $(MAKE) BUILD_DIR=$(NEG_DIR) LIB_DIR=$(NEG_DIR)/lib \
	CA65FLAGS="$(CA65FLAGS)" CONTRACT_DEFINES="$(CONTRACT_DEFINES)" \
	CONTRACT_ZP_DEFINES="$(CONTRACT_ZP_DEFINES)"

# Shell function shared by the expectation-side legs: run lib-verify with
# one override, require a NON-ZERO exit AND the named message. Requiring
# both matters — a leg that only greps would pass on a build error that
# happened to print the string, and a leg that only checks the exit code
# would pass on any unrelated failure (§15.2's "broken something adjacent").
define NEG_LEG
	@out=$$($(NEG_MAKE) $(2) lib-verify 2>&1); rc=$$?; \
	 if [ $$rc -eq 0 ]; then \
	   echo "FAIL: $(1) — lib-verify exited 0 with the assertion perturbed; that check is inert"; exit 1; \
	 fi; \
	 printf '%s\n' "$$out" | grep -q $(3) \
	   && echo "OK: $(1) — $$(printf '%s\n' "$$out" | grep -m1 '^FAIL:')" \
	   || (echo "FAIL: $(1) — lib-verify failed, but not with the named message:" \
	       && printf '%s\n' "$$out" | tail -5 && exit 1)
endef

lib-verify-negative:
	@echo "=== lib-verify-negative: §15.1 per-check negative legs for lib-verify ==="
	rm -rf $(NEG_DIR) $(NEG_ART_DIR)
	@echo "--- baseline: unperturbed lib-verify must PASS (else the legs below"
	@echo "    would be proving nothing about a working gate)"
	$(NEG_MAKE) lib-verify >/dev/null
	@echo "OK: baseline lib-verify is green"
	@echo "--- N0: non-empty-output test"
	@: > $(NEG_DIR)/lib_verify/empty.prg
	$(call NEG_LEG,N0 empty output,LIB_VERIFY_PRG=$(NEG_DIR)/lib_verify/empty.prg,"is empty")
	@echo "--- N1: expected-symbol loop (ARTIFACT-side: a real §8.3 deferral"
	@echo "    archive graded against the DEFAULT expectations)"
	@out=$$($(MAKE) BUILD_DIR=$(NEG_ART_DIR) LIB_DIR=$(NEG_ART_DIR)/lib \
	        CA65FLAGS="$(CA65FLAGS)" CONTRACT_ZP_DEFINES="$(CONTRACT_ZP_DEFINES)" \
	        CONTRACT_DEFINES="$(CONTRACT_DEFINES) -D SHARED_CT_MUL_8X8=1" \
	        X25519_PROFILE=default lib-verify 2>&1); rc=$$?; \
	 if [ $$rc -eq 0 ]; then \
	   echo "FAIL: N1 — a deferral archive passed the default expectations; the symbol loop is inert"; exit 1; \
	 fi; \
	 printf '%s\n' "$$out" | grep -q "expected symbol mul_8x8 not in linked binary" \
	   && echo "OK: N1 — $$(printf '%s\n' "$$out" | grep -m1 '^FAIL:')" \
	   || (echo "FAIL: N1 — did not name the missing symbol:" && printf '%s\n' "$$out" | tail -5 && exit 1)
	rm -rf $(NEG_ART_DIR)
	@echo "--- N2: must-be-absent loop"
	$(call NEG_LEG,N2 absent-symbol loop,LIB_VERIFY_SYMS_ABSENT_ALWAYS=x25519_clamp,"must be gated out")
	@echo "--- N3: §8.0 owned-primitives mask"
	$(call NEG_LEG,N3 §8.0 mask,LIB_VERIFY_MASK_EXPECT=0000FF,"LIB_X25519_SHARED_PRIMITIVES !=")
	@echo "--- N4: §8.0 consumes companion"
	$(call NEG_LEG,N4 §8.0 consumes,LIB_VERIFY_CONSUMES_EXPECT=0000FF,"LIB_X25519_SHARED_CONSUMES !=")
	@echo "--- N5: §3 REU bank claim"
	$(call NEG_LEG,N5 REU banks,LIB_VERIFY_BANKS_EXPECT=0000FF,"LIB_X25519_REU_BANKS_USED !=")
	@echo "--- N6: §5 resident footprint lock"
	$(call NEG_LEG,N6 resident lock,LIB_VERIFY_RESIDENT_EXPECT=00FFFF,"LIB_X25519_RESIDENT_BYTES !=")
	@echo "--- N7: §5 cold footprint lock"
	$(call NEG_LEG,N7 cold lock,LIB_VERIFY_COLD_EXPECT=00FFFF,"LIB_X25519_COLD_BYTES !=")
	rm -rf $(NEG_DIR) $(NEG_ART_DIR)
	@echo "OK: every assertion inside lib-verify has been observed reporting"

# --- §15.1 negative leg for the footprint check ------------------------------
#
# "A conformance check offered as evidence SHOULD be accompanied by a
# demonstration that it fails when the property it checks is false."
# (SPEC v0.17.0 §15.1, opening sentence.)
#
# This replays the exact defect that motivated tools/check_footprint.py:
# 16 `nop`s injected into fe25519_add, which grows LIB_X25519_CODE by 16
# bytes without touching a single symbol name, mask bit, bank claim, or
# either footprint equate. Before the checker, `make lib-verify` passed.
#
# It is a §15.2-grade demonstration, not merely §15.1: the mutation
# changes the property the check NAMES (the resident footprint of the
# shipped archive), not something adjacent to it. Nothing else in
# lib-verify can see it, which is precisely why the leg is here.
#
# The mutation is applied to a THROWAWAY COPY of src/ under build-fp/src
# and the build is re-invoked with SRC_DIR pointed at the copy, so the
# tracked tree is never edited and an interrupted run cannot leave a
# `nop`-laden source behind. (ca65 resolves `.include "constants.s"`
# relative to the including file, so a relocated SRC_DIR assembles.)
#
# The rebuild deletes the affected outputs rather than relying on
# mtimes: GNU Make 3.81 compares with whole-second granularity, so a
# same-second rewrite of fe25519.s would be judged up to date and the
# leg would silently grade the UNMUTATED archive -- the same
# mtime-granularity family as issue #113. The baseline map is emitted
# from the pristine build one step earlier and is never checked in; a
# stored baseline would reintroduce the stale-literal defect the checker
# exists to remove.
# --- ARM SELECTION (SPEC v0.17.0 §15.1, scoping sub-clause) -----------------
#
# "A demonstration is scoped to the configuration it was performed in."
# The CHECK runs in all seven profiles (it is a step of lib-verify); the
# DEMONSTRATION is what this clause is about, and a single default-profile
# run would leave six profiles carrying a check whose failability was shown
# somewhere else.
#
# Run in TWO arms — default and onchip — and argue the rest structurally.
# This is the same reasoning already applied to the leg C family, used a
# second time rather than hand-waved:
#
#   onchip is the profile whose SEGMENT COMPOSITION differs most from
#   default. Measured on this tree, per archive member:
#
#     COLD           947 -> 160   (x25519_init.o's 787 B
#                                  LIB_X25519_INIT_CODE goes away entirely;
#                                  mul_8x8.o's 160 B is all that remains)
#     x25519_init.o  LIB_X25519_CODE 213 -> 10   (NOT to zero -- the §8.2
#                                  members shrink to a 10-byte residue,
#                                  they do not vanish)
#     fe25519.o      LIB_X25519_CODE 2750 -> 2692
#     x25519.o       LIB_X25519_CODE  717 -> 709
#     member count   10 -> 10     (unchanged: LIB_OBJS is a single fixed
#                                  list, so NO profile here is member-set-
#                                  shaped -- only the segment mix moves)
#
#   Those two are the ENDPOINTS of the range, which is checkable rather
#   than asserted: across all seven profiles RESIDENT spans 8234 (onchip)
#   to 8503 (default and shared-sqtab) and COLD spans 160 (onchip) to 947
#   (default and shared-ct), and every remaining profile sits inside both
#   intervals -- 1764 8355/733, shared-sqtab 8503/787, shared-reu
#   8471/520, shared-ct 8440/947, shared-all 8408/360. So default and
#   onchip BRACKET the composition range the check has to handle, and a
#   demonstration at both ends shows the check fails correctly across that
#   range rather than in one arbitrary configuration.
#
# STATED PLAINLY so a reader can disagree with the right thing: the
# remaining five profiles (1764, shared-sqtab, shared-reu, shared-ct,
# shared-all) are NOT demonstrated per-profile. Their demonstration rests
# on the bracketing argument above -- that their segment mix lies inside
# the interval the two arms span -- not on a run. If you do not accept the
# bracketing, what you are rejecting is that argument — not a claim that
# those five were exercised, because they were not.
#
# Seven arms were considered and rejected on cost: each arm copies the
# whole src/ tree and does two full builds.
#
# Arm name is SPACE-FREE and the defines are looked up here, for the same
# GNU Make 3.81 MAKEFLAGS reason documented on LEGC_NAME.
FPNEG_DEFINES_default :=
FPNEG_DEFINES_onchip  := -D X25519_ONCHIP_MUL=1
FPNEG_PROFILE_default := default
FPNEG_PROFILE_onchip  := onchip

FPNEG_NAME ?= default
FPNEG_DEFINES = $(FPNEG_DEFINES_$(FPNEG_NAME))
FPNEG_PROFILE = $(FPNEG_PROFILE_$(FPNEG_NAME))

# Derived from $(LIB_VERIFY_PRG) rather than respelled, so a rename of the
# stub or of lib_verify/ cannot silently drop this leg's rebuild step.
FP_DIR = build-fp-$(FPNEG_NAME)
FP_VERIFY_PRG = $(patsubst $(BUILD_DIR)/%,$(FP_DIR)/%,$(LIB_VERIFY_PRG))
FP_VERIFY_LABELS = $(FP_DIR)/lib_verify/stub.labels

lib-verify-footprint-negative:
	@echo "=== lib-verify-footprint-negative: §15.1 demonstration that the"
	@echo "    derived-footprint check FAILS when the footprint is wrong ==="
	@echo "    Two arms: default and onchip. See the ARM SELECTION comment"
	@echo "    above for why two and not seven, and for exactly which claim"
	@echo "    the other five profiles rest on."
	$(MAKE) FPNEG_NAME=default lib-verify-footprint-negative-arm
	$(MAKE) FPNEG_NAME=onchip lib-verify-footprint-negative-arm
	@echo "OK: the footprint check is falsifiable at BOTH ends of the"
	@echo "    profile composition range (default and onchip)"

lib-verify-footprint-negative-arm:
	@echo "=== arm [$(FPNEG_NAME)]: profile $(FPNEG_PROFILE), defines '$(FPNEG_DEFINES)' ==="
	rm -rf $(FP_DIR); mkdir -p $(FP_DIR)/src
	cp -R $(SRC_DIR)/. $(FP_DIR)/src/
	@echo "--- step 1: pristine copy must PASS and emit the segment baseline"
	$(MAKE) BUILD_DIR=$(FP_DIR) LIB_DIR=$(FP_DIR)/lib SRC_DIR=$(FP_DIR)/src \
	        CA65FLAGS="$(CA65FLAGS)" CONTRACT_ZP_DEFINES="$(CONTRACT_ZP_DEFINES)" \
	        CONTRACT_DEFINES="$(CONTRACT_DEFINES) $(FPNEG_DEFINES)" \
	        X25519_PROFILE=$(FPNEG_PROFILE) lib-verify >/dev/null
	@python3 tools/check_footprint.py --archive $(FP_DIR)/lib/libx25519.a \
	    --labels $(FP_VERIFY_LABELS) \
	    --emit-baseline $(FP_DIR)/segmap.json >/dev/null \
	  && echo "OK: [$(FPNEG_NAME)] pristine relocated-source build passes; baseline recorded" \
	  || (echo "FAIL: pristine build does not pass its own footprint check" && exit 1)
	@echo "--- step 1b: the sqtab window is DERIVED and cross-checked against"
	@echo "    the cfg region — that cross-check must itself be falsifiable"
	@# GRADE, named rather than left to inference, as N3/N4/N6/N7 are:
	@# this leg is LABEL-FILE-side. It perturbs the number the check reads,
	@# not the cfg, so it proves the comparison is live and not that the
	@# check measures a real undersized region. The artifact-side
	@# counterpart is leg A3 of `make lib-verify-guards`, which shrinks the
	@# SQTAB region in an actual cfg and requires src/main.s's assert to
	@# fire at link time on a real build. Both relations are now the same
	@# relation: since src/main.s:55 compares against
	@# LIB_X25519_PRECALC_sqtab_SIZE, leg A3 and this leg check one
	@# property at two layers rather than two literals that happen to
	@# agree.
	@# Finding 5's fix replaced a hardcoded 1024 with a value read from the
	@# §8.4 enumeration plus a >= test against the linker-reserved region.
	@# A cross-check nobody has seen fail is the same debt one level down,
	@# so shrink the reserved region in a COPY of the label file and require
	@# the named error. Fixture guard first: if the sed misses, the leg
	@# would pass vacuously.
	@sed 's/^al 000400 \.__SQTAB_SIZE__$$/al 000200 .__SQTAB_SIZE__/' \
	    $(FP_VERIFY_LABELS) > $(FP_DIR)/shrunk.labels
	@grep -q '^al 000200 \.__SQTAB_SIZE__$$' $(FP_DIR)/shrunk.labels \
	  || (echo "FAIL: fixture did not shrink __SQTAB_SIZE__; the leg would prove nothing" && exit 1)
	@out=$$(python3 tools/check_footprint.py --archive $(FP_DIR)/lib/libx25519.a \
	    --labels $(FP_DIR)/shrunk.labels 2>&1); \
	 printf '%s\n' "$$out" | grep -q "the cfg reserves 512 bytes for the sqtab window" \
	   && echo "OK: [$(FPNEG_NAME)] the window cross-check fails when the cfg region is smaller than the declared table" \
	   || (echo "FAIL: an undersized sqtab region did not trip the window cross-check:" && printf '%s\n' "$$out" | tail -5 && exit 1)
	@echo "--- step 2: inject 16 nops into fe25519_add (valid code, +16 B)"
	@awk '{ print } /^\.proc fe25519_add$$/ { for (i = 0; i < 16; i++) print "        nop" }' \
	    $(SRC_DIR)/fe25519.s > $(FP_DIR)/src/fe25519.s.mut
	@test $$(grep -c '^        nop$$' $(FP_DIR)/src/fe25519.s.mut) -ge 16 \
	  || (echo "FAIL: the mutation anchor '.proc fe25519_add' did not match; the leg would prove nothing" && exit 1)
	@mv $(FP_DIR)/src/fe25519.s.mut $(FP_DIR)/src/fe25519.s
	@rm -f $(FP_DIR)/fe25519.o $(FP_DIR)/lib/fe25519.o $(FP_DIR)/lib/libx25519.a \
	       $(FP_DIR)/lib/x25519.a $(FP_VERIFY_PRG) $(FP_VERIFY_LABELS)
	$(MAKE) BUILD_DIR=$(FP_DIR) LIB_DIR=$(FP_DIR)/lib SRC_DIR=$(FP_DIR)/src \
	        CA65FLAGS="$(CA65FLAGS)" CONTRACT_ZP_DEFINES="$(CONTRACT_ZP_DEFINES)" \
	        CONTRACT_DEFINES="$(CONTRACT_DEFINES) $(FPNEG_DEFINES)" \
	        X25519_PROFILE=$(FPNEG_PROFILE) lib $(FP_VERIFY_PRG) >/dev/null
	@echo "--- step 3: the derived check MUST now fail and NAME the segment"
	@out=$$(python3 tools/check_footprint.py --archive $(FP_DIR)/lib/libx25519.a \
	    --labels $(FP_VERIFY_LABELS) \
	    --baseline $(FP_DIR)/segmap.json 2>&1); \
	 printf '%s\n' "$$out" | sed 's/^/    /'; \
	 printf '%s\n' "$$out" | grep -qE "LIB_X25519_CODE in fe25519\.o: [0-9]+ -> [0-9]+ \(\+16\)" \
	   && printf '%s\n' "$$out" | grep -q "LIB_X25519_RESIDENT_BYTES declares" \
	   && echo "OK: [$(FPNEG_NAME)] the derived footprint check fails and names LIB_X25519_CODE in fe25519.o" \
	   || (echo "FAIL: [$(FPNEG_NAME)] the footprint check did not fail on a +16 B resident growth, or did not name the segment" && exit 1)
	@echo "--- step 4: the aggregate gate (lib-verify) must fail on it too"
	@out=$$($(MAKE) BUILD_DIR=$(FP_DIR) LIB_DIR=$(FP_DIR)/lib SRC_DIR=$(FP_DIR)/src \
	        CA65FLAGS="$(CA65FLAGS)" CONTRACT_ZP_DEFINES="$(CONTRACT_ZP_DEFINES)" \
	        CONTRACT_DEFINES="$(CONTRACT_DEFINES) $(FPNEG_DEFINES)" \
	        X25519_PROFILE=$(FPNEG_PROFILE) lib-verify 2>&1); \
	 printf '%s\n' "$$out" | grep -q "LIB_X25519_RESIDENT_BYTES declares" \
	   && echo "OK: [$(FPNEG_NAME)] lib-verify now rejects the stale footprint (it exited 0 before this check existed)" \
	   || (echo "FAIL: lib-verify still passes with a 16-byte-stale footprint:" && printf '%s\n' "$$out" | tail -5 && exit 1)
	rm -rf $(FP_DIR)
	@echo "OK: [$(FPNEG_NAME)] §15.1 demonstration complete -- the footprint check is falsifiable in this profile"

# --- §8.x deferral-build linkage matrix (R6) ---------------------------------
#
# `make lib-verify-shared` proves each c64-lib-contract SHARED_*
# deferral build of libx25519.a actually LINKS in a composed-consumer
# shape: the stub link adds shared_provider_stub.s as a stand-in for
# the canonical provider the deferral trusts, and lib-verify asserts
# the deferred x25519-own exports are absent + the §8.0 conditional
# mask dropped the right bits. This is the R6 regression gate: the
# SHARED_REU_MUL_INIT leg used to die on four unresolved externals
# (reu_mul_init, reu_mul_tables_init, and the dangling reu_init_a/b
# ZP-alias .globals in reu_config.s).
#
# NOTE: always -D SWITCH=1 — a bare ca65 -D defines the symbol as 0,
# which .ifdef still sees as defined, but keep the idiom uniform with
# X25519_ONCHIP_MUL (where bare -D silently selects the WRONG profile).
lib-verify-shared:
	@echo "=== lib-verify-shared: SPEC §8.x deferral-build linkage matrix ==="
	rm -rf build-shared
	$(MAKE) BUILD_DIR=build-shared LIB_DIR=build-shared/lib \
	        CA65FLAGS="$(CA65FLAGS)" CONTRACT_ZP_DEFINES="$(CONTRACT_ZP_DEFINES)" \
	        CONTRACT_DEFINES="$(CONTRACT_DEFINES) -D SHARED_SQTAB_INIT=1" \
	        X25519_PROFILE=shared-sqtab lib-verify
	rm -rf build-shared
	$(MAKE) BUILD_DIR=build-shared LIB_DIR=build-shared/lib \
	        CA65FLAGS="$(CA65FLAGS)" CONTRACT_ZP_DEFINES="$(CONTRACT_ZP_DEFINES)" \
	        CONTRACT_DEFINES="$(CONTRACT_DEFINES) -D SHARED_REU_MUL_INIT=1 -D SHARED_REU_MUL_FETCH=1" \
	        X25519_PROFILE=shared-reu lib-verify
	rm -rf build-shared
	$(MAKE) BUILD_DIR=build-shared LIB_DIR=build-shared/lib \
	        CA65FLAGS="$(CA65FLAGS)" CONTRACT_ZP_DEFINES="$(CONTRACT_ZP_DEFINES)" \
	        CONTRACT_DEFINES="$(CONTRACT_DEFINES) -D SHARED_CT_MUL_8X8=1" \
	        X25519_PROFILE=shared-ct lib-verify
	rm -rf build-shared
	$(MAKE) BUILD_DIR=build-shared LIB_DIR=build-shared/lib \
	        CA65FLAGS="$(CA65FLAGS)" CONTRACT_ZP_DEFINES="$(CONTRACT_ZP_DEFINES)" \
	        CONTRACT_DEFINES="$(CONTRACT_DEFINES) -D SHARED_SQTAB_INIT=1 -D SHARED_REU_MUL_INIT=1 -D SHARED_REU_MUL_FETCH=1 -D SHARED_CT_MUL_8X8=1" \
	        X25519_PROFILE=shared-all lib-verify
	rm -rf build-shared
	@echo "--- leg 5 (link-only): onchip x full deferral"
	@echo "    The combination CI never built -- the nist#123 shape, where a"
	@echo "    profile and a deferral switch are each green alone and the"
	@echo "    intersection is not built by any target. Deliberately link-only:"
	@echo "    it asserts the combination assembles and links, and invents NO"
	@echo "    X25519_PROFILE expectation set, because the mask / CONSUMES /"
	@echo "    footprint values for this intersection would be guesses and a"
	@echo "    guessed lock is worse than no lock."
	$(MAKE) BUILD_DIR=build-shared LIB_DIR=build-shared/lib \
	        CA65FLAGS="$(CA65FLAGS)" CONTRACT_ZP_DEFINES="$(CONTRACT_ZP_DEFINES)" \
	        CONTRACT_DEFINES="$(CONTRACT_DEFINES) $(ONCHIP_DEFER_DEFINES)" \
	        lib >/dev/null
	$(CA65) $(CA65FLAGS) $(CONTRACT_DEFINES) $(ONCHIP_DEFER_DEFINES) \
	    -I $(SRC_DIR) -o build-shared/onchip_stub.o $(LIB_VERIFY_STUB)
	$(CA65) $(CA65FLAGS) $(CONTRACT_DEFINES) $(ONCHIP_DEFER_DEFINES) \
	    -I $(SRC_DIR) -o build-shared/onchip_provider.o $(LIB_VERIFY_PROVIDER)
	$(LD65) -C cfg/x25519-example.cfg -o build-shared/onchip_defer.prg \
	    build-shared/onchip_stub.o build-shared/onchip_provider.o \
	    build-shared/lib/libx25519.a
	@test -s build-shared/onchip_defer.prg \
	  || (echo "FAIL: onchip x deferral produced no linked output" && exit 1)
	@bytes=$$(wc -c < build-shared/onchip_defer.prg); \
	 echo "OK: leg 5 -- onchip x full deferral links ($$bytes bytes)"
	rm -rf build-shared
	@echo "OK: all four SHARED_* deferral profiles link and verify,"
	@echo "    plus the onchip x deferral intersection (link-only)"

# --- §6.6/§6.7 guard negative legs (contract SPEC v0.10.0) -------------------
#
# `make lib-verify-guards` proves the two placement guards FAIL when
# they should — every other verify leg asserts success, so a silently
# inert guard (the pre-v0.10.0 state) would pass the whole matrix.
#   leg A: §6.7 region-agreement — PRG build with a diverged
#          LIB_SHARED_SQTAB_BASE must die on the named lderror.
#   leg A3: §6.7 region-SIZE — PRG build against a cfg whose SQTAB
#          region is smaller than the declared sqtab table must die on
#          the named lderror (src/main.s:55). Fixture derived from
#          cfg/x25519.cfg by sed, SQTAB line only.
#   leg B: §6.6 consumer-mirror — stub link against a fixture cfg
#          whose MAIN cannot hold the declared footprint must die on
#          the named lderror. Fixture derived from the example cfg by
#          sed (no second cfg to drift).
#
# SCOPE OF LEGS A / A2 / A3 / B (SPEC v0.17.0 §15.1 — "A demonstration
# is scoped to the configuration it was performed in").
# These four are demonstrated in the DEFAULT profile only, deliberately.
# The scope carries, and here is why rather than an assertion that it does:
#
#   * All four asserts are UNGATED. src/main.s:40, :54 and :55 sit outside
#     any .if/.ifdef, and tests/lib_linkage/lib_linkage_stub.s:152 likewise,
#     so every profile assembles the identical assert with the identical
#     operator and operands. No profile knob adds, removes or re-gates any
#     of them — there is no configuration in which the check is absent, and
#     therefore no configuration in which "does it fire?" has a different
#     answer for a structural reason.
#   * A, A2 and A3 compare link-time region geometry (__MAIN_LAST__,
#     __SQTAB_START__, __SQTAB_SIZE__) against LIB_SHARED_SQTAB_BASE and the
#     declared sqtab table size. Those are properties of the cfg and the
#     image, not of any §8.x deferral or on-chip switch. All three main.s
#     asserts now have a leg: A moves the base, A2 overruns it, A3 shrinks
#     the region.
#   * B compares the DECLARED footprint pair against __MAIN_SIZE__. Its
#     operands DO vary per profile — which is exactly why leg B is not
#     re-run per profile with per-profile fixture sizes: the $2400 budget
#     in the sed fixture is sized against the default footprint (9450 B)
#     and would not trip under onchip (8394 B), so a per-profile leg B
#     would need a hand-maintained budget literal per profile — the very
#     class of debt `lib-verify-footprint` exists to remove. The per-profile
#     correctness of B's operands is instead carried by the derived
#     footprint check, which runs inside lib-verify in all seven profiles
#     and has its own negative leg (`make lib-verify-footprint-negative`).
#
# The leg C family below is the one that IS profile-shaped — it counts ca65
# invocations across a knob flip, and a knob selecting nothing is most
# plausible in the arm where the profile already removed the machinery the
# knob names — so it is parameterised and run twice. One leg family, one
# extra profile; not the 7x7 cross product.
lib-verify-guards:
	@echo "=== lib-verify-guards: SPEC v0.10.0 §6.6/§6.7 negative legs ==="
	rm -rf build-guards; mkdir -p build-guards
	@echo "--- leg A: diverged SQTAB base must fail the PRG link"
	@# Base must sit ABOVE the standalone image end (__MAIN_LAST__ = $2A82
	@# since the v0.12.0 §8.2 settle grew the PRG; was < $2A00 before) so
	@# that only the region-agreement assert fires — leg A2 owns overrun.
	@out=$$($(MAKE) BUILD_DIR=build-guards CONTRACT_DEFINES="$(CONTRACT_DEFINES) -D LIB_SHARED_SQTAB_BASE=0x2C00" all 2>&1); \
	echo "$$out" | grep -q "region base disagrees" \
	  && echo "OK: leg A fails with the named §6.7 error" \
	  || (echo "FAIL: diverged SQTAB base did not trip the §6.7 guard:" && echo "$$out" | tail -5 && exit 1)
	rm -rf build-guards; mkdir -p build-guards
	@echo "--- leg A2: overrun (base below image end) must fail — the v0.10.2"
	@echo "    constraint-3 acceptance test, in the placing configuration"
	@out=$$($(MAKE) BUILD_DIR=build-guards CONTRACT_DEFINES="$(CONTRACT_DEFINES) -D LIB_SHARED_SQTAB_BASE=0x2000" all 2>&1); \
	echo "$$out" | grep -q "image overruns the sqtab window" \
	  && echo "OK: leg A2 fails with the named overrun error" \
	  || (echo "FAIL: overrun base did not trip the §6.7 guard:" && echo "$$out" | tail -5 && exit 1)
	rm -rf build-guards; mkdir -p build-guards
	@echo "--- leg A3: an undersized SQTAB REGION must fail — src/main.s:55,"
	@echo "    the third §6.7 assert, which legs A and A2 do not reach (they"
	@echo "    move the BASE; this one shrinks the SIZE)."
	@# Edits the SQTAB line only, so the $$0400 respelling cannot land on
	@# another region that happens to share the size. Base stays $$7800, so
	@# the :40 overrun and :54 region-agreement asserts both still pass and
	@# only the size assert can fire — the point of a negative leg is to
	@# know WHICH assert reported.
	sed '/^ *SQTAB:/ s/size = \$$0400/size = \$$0200/' cfg/x25519.cfg \
	    > build-guards/small_sqtab.cfg
	@# ONE build, THREE greps against the same captured output: the size
	@# assert MUST fire and NEITHER sibling assert may. A leg that cannot
	@# tell which assert reported is not a demonstration of this one. The
	@# expected text names the equate the assert compares against, so a
	@# silent revert to a literal 1024 changes the message and fails here.
	@#
	@# Accumulates into $$fail and exits at TOP level rather than using the
	@# `|| (echo ...; exit 1)` idiom the other legs use: that idiom only
	@# propagates when the subshell is the LAST command of the recipe line,
	@# and inside a `;`-separated chain the failing subshell exits itself
	@# and the chain runs on to report OK. Braces keep $$fail in this shell.
	@out=$$($(MAKE) BUILD_DIR=build-guards CC65_CFG=build-guards/small_sqtab.cfg all 2>&1); \
	 fail=0; \
	 printf '%s\n' "$$out" | grep -q "smaller than the declared sqtab table (LIB_X25519_PRECALC_sqtab_SIZE)" \
	   || { echo "FAIL: an undersized SQTAB region did not trip src/main.s's SQTAB size assert:"; printf '%s\n' "$$out" | tail -5; fail=1; }; \
	 printf '%s\n' "$$out" | grep -q "image overruns the sqtab window" \
	   && { echo "FAIL: leg A3 also tripped the overrun assert; the fixture is not isolating the size assert"; fail=1; }; \
	 printf '%s\n' "$$out" | grep -q "region base disagrees" \
	   && { echo "FAIL: leg A3 also tripped the region-base assert; the fixture is not isolating the size assert"; fail=1; }; \
	 test "$$fail" = "0" || exit 1; \
	 echo "OK: leg A3 fails with the named §6.7 region-size error, and only that assert fired"
	rm -rf build-guards; mkdir -p build-guards
	@echo "--- leg B: undersized MAIN must fail the stub link"
	sed 's/size = \$$7800 - %S, define = yes;/size = $$2400 - %S, define = yes;/' \
	    cfg/x25519-example.cfg > build-guards/undersized.cfg
	$(MAKE) BUILD_DIR=build-guards LIB_DIR=build-guards/lib lib >/dev/null
	$(CA65) -I $(SRC_DIR) -o build-guards/stub.o $(LIB_VERIFY_STUB)
	$(CA65) -I $(SRC_DIR) -o build-guards/provider.o $(LIB_VERIFY_PROVIDER)
	@out=$$($(LD65) -C build-guards/undersized.cfg -o build-guards/neg.prg \
	    build-guards/stub.o build-guards/provider.o build-guards/lib/libx25519.a 2>&1); \
	echo "$$out" | grep -q "exceeds the MAIN budget" \
	  && echo "OK: leg B fails with the named §6.6 error" \
	  || (echo "FAIL: undersized MAIN did not trip the §6.6 mirror:" && echo "$$out" | tail -5 && exit 1)
	rm -rf build-guards
	$(MAKE) LEGC_NAME=default lib-verify-guards-legc
	$(MAKE) LEGC_NAME=onchip lib-verify-guards-legc
	@echo "OK: all guard negatives fire with named errors"

# --- leg C family: §6.3 knob-invalidation ratchet, parameterised by profile --
#
# Split out of `lib-verify-guards` so it can be RUN MORE THAN ONCE, per
# SPEC v0.17.0 §15.1 ("A demonstration is scoped to the configuration it
# was performed in"), and this family — unlike legs A/A2/B,
# whose scope argument is in the header above — is genuinely profile-shaped.
# It counts ca65 invocations across a knob flip and asserts the artifact
# changed; the arm where a knob could plausibly select nothing is the one
# where a profile has already removed the machinery the knob names. So it
# runs for `default` and for `onchip` (X25519_ONCHIP_MUL=1), which is the
# no-REU arm. Both are measured to flip 5/5 -> 0/5 on the §8.3 name set.
#
# Parameterised by a SPACE-FREE profile NAME, with the defines looked up
# from the table below rather than passed on the sub-make command line:
# GNU Make 3.81 (which is what /usr/bin/make is here) round-trips
# command-line variables to sub-makes through MAKEFLAGS, where a value
# containing a space is not reliably re-split. Passing `LEGC_NAME=onchip`
# keeps the recursion free of that hazard while `-D X25519_ONCHIP_MUL=1`
# never leaves this file.
#
# Each profile gets its OWN build-guards-<name> tree, so the two runs
# cannot alias each other's stamp or objects.
LEGC_DEFINES_default :=
LEGC_DEFINES_onchip  := -D X25519_ONCHIP_MUL=1

LEGC_NAME ?= default
LEGC_DEFINES = $(LEGC_DEFINES_$(LEGC_NAME))
LEGC_DIR = build-guards-$(LEGC_NAME)

# The §8.3 provider-surface name set leg C counts. Named once: C's baseline
# (5/5, owner archive) and C2's post-flip expectation (0/5, deferral
# archive) MUST be the same set, or the leg proves nothing about the flip.
LEGC_8X3_NAMES = "(ct_mul_8x8|poly_prod_lo|poly_prod_hi|smc_sum_a_imm|smc_diff_a_imm)"

lib-verify-guards-legc:
	@echo "--- leg C [$(LEGC_NAME)]: §6.3 knob staleness (contract#127) — a knob"
	@echo "    change MUST flip the artifact, and an UNCHANGED knob MUST NOT rebuild"
	rm -rf $(LEGC_DIR); mkdir -p $(LEGC_DIR)
	@# Leg order follows SPEC v0.11.1 §6.3's own ordering of the two
	@# properties, which is also c64-polyval's: C1 = unchanged knobs MUST
	@# NOT rebuild, C2 = the pin MUST assert the artifact flipped. (Before
	@# issue #113 this repo numbered them the other way round, so failure
	@# output could not be cross-referenced against the clause or against
	@# a sibling repo.)
	@$(MAKE) BUILD_DIR=$(LEGC_DIR) LIB_DIR=$(LEGC_DIR)/lib \
	         CONTRACT_DEFINES="$(CONTRACT_DEFINES) $(LEGC_DEFINES)" lib >/dev/null
	@own=$$(od65 --dump-exports $(LEGC_DIR)/lib/mul_8x8.o 2>/dev/null | \
	        grep -cE $(LEGC_8X3_NAMES)); \
	  test "$$own" = "5" \
	  && echo "OK: leg C [$(LEGC_NAME)] baseline is the owner archive (5/5 §8.3 names)" \
	  || (echo "FAIL: leg C [$(LEGC_NAME)] baseline is not the owner archive ($$own/5)" && exit 1)
	@# C1: re-invoking with the SAME knobs must do no work at all.
	@# Counts actual ca65 invocations rather than comparing mtimes: `ls -l`
	@# is MINUTE-granular and the object size does not change when identical
	@# source is recompiled, so the mtime form shipped in v0.11.3 could not
	@# see a rebuild inside the same minute and reported this leg OK against
	@# a stamp that wiped the tree on every invocation (issue #113).
	@out=$$($(MAKE) BUILD_DIR=$(LEGC_DIR) LIB_DIR=$(LEGC_DIR)/lib \
	         CONTRACT_DEFINES="$(CONTRACT_DEFINES) $(LEGC_DEFINES)" lib 2>&1); \
	 n=$$(printf '%s\n' "$$out" | grep -c 'ca65 ' || true); \
	 test "$$n" = "0" \
	  && echo "OK: leg C1 [$(LEGC_NAME)] — unchanged knobs recompiled 0 TUs" \
	  || (echo "FAIL: leg C1 [$(LEGC_NAME)] — unchanged invocation recompiled $$n TUs, expected 0; the guard is an unconditional rebuild wearing a stamp and incremental builds are gone" && exit 1)
	@# C2: a knob change must FLIP the artifact, not merely rebuild it.
	@$(MAKE) BUILD_DIR=$(LEGC_DIR) LIB_DIR=$(LEGC_DIR)/lib \
	         CONTRACT_DEFINES="$(CONTRACT_DEFINES) $(LEGC_DEFINES) -D SHARED_CT_MUL_8X8=1" lib >/dev/null
	@def=$$(od65 --dump-exports $(LEGC_DIR)/lib/mul_8x8.o 2>/dev/null | \
	        grep -cE $(LEGC_8X3_NAMES)); \
	  test "$$def" = "0" \
	  && echo "OK: leg C2 [$(LEGC_NAME)] — the knob change FLIPPED the artifact (0/5 §8.3 names)" \
	  || (echo "FAIL: leg C2 [$(LEGC_NAME)] — knob ignored, stale owner archive shipped ($$def/5 §8.3 names still exported)" && exit 1)
	@# C1b: the no-rebuild property must hold AFTER a knob change too, not
	@# only from a freshly-stamped baseline.
	@out=$$($(MAKE) BUILD_DIR=$(LEGC_DIR) LIB_DIR=$(LEGC_DIR)/lib \
	         CONTRACT_DEFINES="$(CONTRACT_DEFINES) $(LEGC_DEFINES) -D SHARED_CT_MUL_8X8=1" lib 2>&1); \
	 n=$$(printf '%s\n' "$$out" | grep -c 'ca65 ' || true); \
	 test "$$n" = "0" \
	  && echo "OK: leg C1b [$(LEGC_NAME)] — unchanged knobs recompiled 0 TUs after a knob change" \
	  || (echo "FAIL: leg C1b [$(LEGC_NAME)] — unchanged invocation recompiled $$n TUs after a knob change, expected 0" && exit 1)
	rm -rf $(LEGC_DIR)

# --- §6.3 app-owned variant (contract SPEC v0.9.0) ---------------------------
#
# `make lib-app-owned` produces the configuration where the CONSUMER
# APPLICATION owns every §8.x shared primitive (SPEC §8.0 APP_OWNED):
# all three deferral switches defined, so the archive imports the
# canonical mul_tables_init / reu_mul_tables_init / ct_mul_8x8
# surface from the app's own modules. Encapsulates the switch
# knowledge per §6.3 so a consumer does not have to reconstruct the
# define set from the SPEC. Masks: OWNED $0000 / CONSUMES $0007;
# manifests carry the measured deferral footprints (§6.4).
lib-app-owned:
	@echo "=== Building lib-app-owned (SPEC §6.3: all §8.x primitives app-owned) ==="
	rm -rf build-app-owned
	$(MAKE) BUILD_DIR=build-app-owned LIB_DIR=build-app-owned/lib \
	        CA65FLAGS="$(CA65FLAGS)" CONTRACT_ZP_DEFINES="$(CONTRACT_ZP_DEFINES)" \
	        CONTRACT_DEFINES="$(CONTRACT_DEFINES) -D SHARED_SQTAB_INIT=1 -D SHARED_REU_MUL_INIT=1 -D SHARED_REU_MUL_FETCH=1 -D SHARED_CT_MUL_8X8=1" \
	        X25519_PROFILE=shared-all lib-verify
	@mkdir -p build/lib
	@cp build-app-owned/lib/libx25519.a build/lib/x25519-app-owned.a
	@echo "SPEC §6.1/§6.3 archive: build/lib/x25519-app-owned.a"
	@echo "(app must provide: mul_tables_init, reu_mul_tables_init +"
	@echo " REU table population, and the §8.3 ct_mul_8x8 body surface;"
	@echo " boot order and obligations in docs/LIBRARY.md §4.6)"

# --- v0.6: 1764-targeted build variant (Group B) -----------------------------
#
# `make lib-x25519-1764` produces a library archive that omits the
# pre-doubled mul tables in REU banks 3/4/5. fe25519_sqr's hybrid
# DMA-vs-mult66 path is forced to always-mult66 (SQR_DMA_K=0), so the
# DMA dispatch never fires and the doubled tables are never read.
# reu_mul_init's @dbl_gen + doubled-stash sections are gated out at
# assemble time by the same `.if SQR_DMA_K > 0` check.
#
# Trade-off (measured, see docs/REU_USAGE_ANALYSIS.md):
#   +16.2 % scalarmult cost (15,350 jif -> 17,838 jif, ~+41 s NTSC)
#   -192 KB REU (banks 3,4,5 freed)
#   -1 init pass (-~600 ms wall-clock at cold boot)
#   minimum REU spec lowered from 512 KB (1750) to 256 KB (1764)
#
# Output goes to build-1764/ so it doesn't clobber the default build.
# Internally re-invokes `make lib lib-verify` with BUILD_DIR overridden
# and CA65FLAGS set; the override propagates to every .s -> .o rule
# via $(CA65FLAGS), and to lib_manifest.o + x25519_init.o via the
# `.if SQR_DMA_K > 0` guards in those translation units.

# --- issue #72: on-chip multiply variant (turbo hosts / no REU) --------------
#
# `make lib-x25519-onchip` produces the X25519_ONCHIP_MUL profile:
# fe25519_mul generates product rows on-chip via the CT §8.3
# ct_mul_8x8 body (constant-time, unlike nist-curves' FP_ONCHIP_MUL
# generator — x25519 has no public-input operation), SQR_DMA_K is
# forced to 0 (mult66 sqr path), and the archive contains no REU code
# or claims at all: LIB_X25519_REU_BANKS_USED = 0, no reu_mul_init,
# boot obligation is sqtab_init only. Runs on a stock expansion-less
# C64.
#
# Trade-off: slower at stock 1 MHz (DMA tables win there); on turbo
# hosts the REU row-fetch wall-clock floor (~1 MHz bus rate regardless
# of CPU clock) disappears. See docs/design/issue_72_onchip_mul.md.
# Wall-clock claims require the hardware A/B gate (16/48/64 MHz) —
# VICE numbers are cycle-exact at 1 MHz only.

lib-x25519-onchip:
	@echo "=== Building lib-x25519-onchip (issue #72: X25519_ONCHIP_MUL=1, no REU) ==="
	rm -rf build-onchip
	$(MAKE) BUILD_DIR=build-onchip LIB_DIR=build-onchip/lib \
	        CA65FLAGS="$(CA65FLAGS)" CONTRACT_ZP_DEFINES="$(CONTRACT_ZP_DEFINES)" \
	        CONTRACT_DEFINES="$(CONTRACT_DEFINES) -D X25519_ONCHIP_MUL=1" \
	        X25519_PROFILE=onchip \
	        lib lib-verify
	@mkdir -p build/lib
	@cp build-onchip/lib/libx25519.a build/lib/libx25519-onchip.a
	@cp build-onchip/lib/libx25519.a build/lib/x25519-onchip.a
	@echo "SPEC §6 archive: build/lib/libx25519-onchip.a"
	@echo "(header: the canonical build/lib/x25519.inc serves both profiles —"
	@echo " consumers of this archive assemble with -D X25519_ONCHIP_MUL=1)"
	@echo
	@echo "Manifest equates for the onchip variant:"
	@grep "LIB_X25519_\|LIB_VERSION_" build-onchip/lib_verify/stub.labels | sort
	@echo
	@echo "Segment sizes (lib .o):"
	@od65 --dump-segsize build-onchip/lib/x25519_init.o build-onchip/lib/fe25519.o build-onchip/lib/x25519.o build-onchip/lib/data.o build-onchip/lib/mul_8x8.o build-onchip/lib/util.o 2>&1 | awk '/^build-onchip|CODE:|DATA:|LIB_X25519_INIT_CODE:/'

lib-x25519-1764:
	@echo "=== Building lib-x25519-1764 (Group B: SQR_DMA_K=0, banks 0,1 only) ==="
	rm -rf build-1764
	$(MAKE) BUILD_DIR=build-1764 LIB_DIR=build-1764/lib \
	        CA65FLAGS="$(CA65FLAGS)" CONTRACT_ZP_DEFINES="$(CONTRACT_ZP_DEFINES)" \
	        CONTRACT_DEFINES="$(CONTRACT_DEFINES) -D SQR_DMA_K=0" \
	        X25519_PROFILE=1764 \
	        lib lib-verify
	@mkdir -p build/lib
	@cp build-1764/lib/libx25519.a build/lib/libx25519-1764.a
	@cp build-1764/lib/libx25519.a build/lib/x25519-1764.a
	@echo "SPEC §6 archive: build/lib/libx25519-1764.a"
	@echo
	@echo "Manifest equates for the 1764 variant:"
	@grep "LIB_X25519_\|LIB_VERSION_" build-1764/lib_verify/stub.labels | sort
	@echo
	@echo "Segment sizes (lib .o):"
	@od65 --dump-segsize build-1764/lib/x25519_init.o build-1764/lib/fe25519.o build-1764/lib/x25519.o build-1764/lib/data.o build-1764/lib/mul_8x8.o build-1764/lib/util.o 2>&1 | awk '/^build-1764|CODE:|DATA:|LIB_X25519_INIT_CODE:/'

# --- Performance history tracking --------------------------------------------
#
# `make bench-record` builds the library, runs the two bench scripts with
# JSON sidecars enabled, reads the LIB_X25519_* manifest equates out of
# build/labels.txt, and appends one row to docs/perf_history.csv tagged
# with the current git SHA + LIB_VERSION. `make perf-diff` then prints a
# markdown table of the last two rows so a release reviewer can eyeball
# the RAM-vs-perf trade.
#
# Requires VICE on PATH. The scalarmult bench takes ~5-15 min wall-clock
# at warp; the fe-ops bench is ~3 min. Both write JSON next to the CSV.
#
# Notes:
#   - The bench writes the CSV row even on uncommitted (dirty) checkouts;
#     tools/bench_record.py marks the git_sha column with a `-dirty`
#     suffix so the row is identifiable but not mistaken for an
#     authoritative release measurement.

bench-record: $(PRG)
	@set -e; \
	python3 tools/bench_record.py

perf-diff:
	@python3 tools/perf_diff.py

# --- Reproducible release tarball --------------------------------------------
#
# `make dist VERSION=v0.4.0` builds c64-x25519-<VERSION>.tar.gz from the named
# git tag, with the canonical v0.4.0+ vendoring file set, and prints byte
# size + SHA256. Deterministic: same VERSION always produces a byte-identical
# tarball (git archive is content-deterministic; gzip -n drops the timestamp).
# The recorded SHA256 in docs/RELEASE_NOTES_<VERSION>.md must match this
# script's output for that VERSION.
#
# Used at release time to produce the artifact uploaded to the GitHub Release
# page. See tools/build_release.sh for the full recipe.

dist:
	@if [ -z "$(VERSION)" ]; then \
	  echo "usage: make dist VERSION=v0.4.0" >&2; \
	  exit 1; \
	fi
	@tools/build_release.sh $(VERSION)

$(LIB_VERIFY_PRG): $(LIB_VERIFY_STUB) $(LIB_VERIFY_PROVIDER) $(LIBX25519) cfg/x25519-example.cfg | $(LIB_VERIFY_DIR)
	$(CA65) $(CA65FLAGS) $(CONTRACT_DEFINES) -I $(SRC_DIR) -o $(LIB_VERIFY_DIR)/stub.o $(LIB_VERIFY_STUB)
	$(CA65) $(CA65FLAGS) $(CONTRACT_DEFINES) -I $(SRC_DIR) -o $(LIB_VERIFY_DIR)/shared_provider.o $(LIB_VERIFY_PROVIDER)
	$(LD65) -C cfg/x25519-example.cfg -o $@ \
	    -Ln $(LIB_VERIFY_DIR)/stub.labels \
	    $(LIB_VERIFY_DIR)/stub.o $(LIB_VERIFY_DIR)/shared_provider.o $(LIBX25519)

$(LIB_VERIFY_DIR):
	mkdir -p $(LIB_VERIFY_DIR)
