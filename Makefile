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

PRG = $(BUILD_DIR)/x25519.prg
LABELS = $(BUILD_DIR)/labels.txt

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
        lib-verify-shared lib-app-owned lib-verify-guards dist \
        bench-record perf-diff lib-x25519-1764 lib-x25519-onchip

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
	python3 tools/test_ladder_checkpoint.py --start 0 --count 255

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
	mkdir -p $(LIB_DIR) $(LIB_DIR)/cfg

clean:
	rm -f $(BUILD_DIR)/*.o $(PRG) $(LABELS) $(LABELS).raw
	rm -rf $(LIB_DIR)

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

$(LIB_DIR)/cfg/x25519-example.cfg: cfg/x25519-example.cfg | $(LIB_DIR)
	cp $< $@

# --- Library linkage smoke test ----------------------------------------------
#
# `make lib-verify` assembles a tiny downstream stub, links it against
# libx25519.a via the example config, and asserts the resulting binary is
# non-zero and contains all the expected public symbols. This proves the
# archive is actually usable, not just a pile of .o files in a tarball.

LIB_VERIFY_DIR = $(BUILD_DIR)/lib_verify
LIB_VERIFY_PRG = $(LIB_VERIFY_DIR)/lib_linkage_stub.prg
LIB_VERIFY_STUB = tests/lib_linkage/lib_linkage_stub.s
LIB_VERIFY_PROVIDER = tests/lib_linkage/shared_provider_stub.s

# Profile selector for lib-verify's symbol expectations. The onchip
# profile (issue #72) ships no REU surface, so its expected-symbol set
# both DROPS the reu_* / §8.2 names and ASSERTS their absence (a
# present-but-should-be-gone symbol is as much a bug as a missing one).
# The shared-* profiles (R6 / `make lib-verify-shared`) verify the
# §8.x SHARED_* deferral builds link against a provider stand-in
# (tests/lib_linkage/shared_provider_stub.s) with the deferred
# x25519-own names absent. Default `make lib-verify` is unchanged.
X25519_PROFILE ?= default

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
ifeq ($(X25519_PROFILE),onchip)
LIB_VERIFY_SYMS_EXPECT = $(LIB_VERIFY_SYMS_SQTAB_OWN) $(LIB_VERIFY_SYMS_COMMON) \
	$(LIB_VERIFY_SYMS_CT_CANON) $(LIB_VERIFY_SYMS_CT_OWN)
LIB_VERIFY_SYMS_ABSENT = $(LIB_VERIFY_SYMS_REU) $(LIB_VERIFY_SYMS_DOUBLED)
LIB_VERIFY_MASK_EXPECT = 000005
LIB_VERIFY_CONSUMES_EXPECT = 000005
LIB_VERIFY_BANKS_EXPECT = 000000
LIB_VERIFY_RESIDENT_EXPECT = 00200F
LIB_VERIFY_COLD_EXPECT = 0000A0
else ifeq ($(X25519_PROFILE),1764)
LIB_VERIFY_SYMS_EXPECT = $(LIB_VERIFY_SYMS_SQTAB_OWN) $(LIB_VERIFY_SYMS_COMMON) \
	$(LIB_VERIFY_SYMS_CT_CANON) $(LIB_VERIFY_SYMS_CT_OWN) \
	$(LIB_VERIFY_SYMS_REU)
LIB_VERIFY_SYMS_ABSENT = $(LIB_VERIFY_SYMS_DOUBLED)
LIB_VERIFY_MASK_EXPECT = 000007
LIB_VERIFY_CONSUMES_EXPECT = 000007
LIB_VERIFY_BANKS_EXPECT = 000003
LIB_VERIFY_RESIDENT_EXPECT = 002037
LIB_VERIFY_COLD_EXPECT = 000288
else ifeq ($(X25519_PROFILE),shared-sqtab)
LIB_VERIFY_SYMS_EXPECT = $(LIB_VERIFY_SYMS_COMMON) \
	$(LIB_VERIFY_SYMS_CT_CANON) $(LIB_VERIFY_SYMS_CT_OWN) \
	$(LIB_VERIFY_SYMS_REU)
LIB_VERIFY_SYMS_ABSENT = $(LIB_VERIFY_SYMS_SQTAB_OWN)
LIB_VERIFY_MASK_EXPECT = 000006
LIB_VERIFY_CONSUMES_EXPECT = 000007
LIB_VERIFY_BANKS_EXPECT = 00003B
LIB_VERIFY_RESIDENT_EXPECT = 0020BF
LIB_VERIFY_COLD_EXPECT = 00029A
else ifeq ($(X25519_PROFILE),shared-reu)
LIB_VERIFY_SYMS_EXPECT = $(LIB_VERIFY_SYMS_SQTAB_OWN) $(LIB_VERIFY_SYMS_COMMON) \
	$(LIB_VERIFY_SYMS_CT_CANON) $(LIB_VERIFY_SYMS_CT_OWN) \
	$(LIB_VERIFY_SYMS_REU_CANON) $(LIB_VERIFY_SYMS_REU_SURFACE)
LIB_VERIFY_SYMS_ABSENT = $(LIB_VERIFY_SYMS_REU_OWN)
LIB_VERIFY_MASK_EXPECT = 000005
LIB_VERIFY_CONSUMES_EXPECT = 000007
LIB_VERIFY_BANKS_EXPECT = 00003B
LIB_VERIFY_RESIDENT_EXPECT = 0020AB
LIB_VERIFY_COLD_EXPECT = 0001CE
else ifeq ($(X25519_PROFILE),shared-ct)
LIB_VERIFY_SYMS_EXPECT = $(LIB_VERIFY_SYMS_SQTAB_OWN) $(LIB_VERIFY_SYMS_COMMON) \
	$(LIB_VERIFY_SYMS_CT_CANON) $(LIB_VERIFY_SYMS_REU)
LIB_VERIFY_SYMS_ABSENT = $(LIB_VERIFY_SYMS_CT_OWN)
LIB_VERIFY_MASK_EXPECT = 000003
LIB_VERIFY_CONSUMES_EXPECT = 000007
LIB_VERIFY_BANKS_EXPECT = 00003B
LIB_VERIFY_RESIDENT_EXPECT = 002080
LIB_VERIFY_COLD_EXPECT = 00033A
else ifeq ($(X25519_PROFILE),shared-all)
LIB_VERIFY_SYMS_EXPECT = $(LIB_VERIFY_SYMS_COMMON) \
	$(LIB_VERIFY_SYMS_CT_CANON) \
	$(LIB_VERIFY_SYMS_REU_CANON) $(LIB_VERIFY_SYMS_REU_SURFACE)
LIB_VERIFY_SYMS_ABSENT = $(LIB_VERIFY_SYMS_CT_OWN) $(LIB_VERIFY_SYMS_REU_OWN) \
	$(LIB_VERIFY_SYMS_SQTAB_OWN)
LIB_VERIFY_MASK_EXPECT = 000000
LIB_VERIFY_CONSUMES_EXPECT = 000007
LIB_VERIFY_BANKS_EXPECT = 00003B
LIB_VERIFY_RESIDENT_EXPECT = 00206C
LIB_VERIFY_COLD_EXPECT = 00012E
else
LIB_VERIFY_SYMS_EXPECT = $(LIB_VERIFY_SYMS_SQTAB_OWN) $(LIB_VERIFY_SYMS_COMMON) \
	$(LIB_VERIFY_SYMS_CT_CANON) $(LIB_VERIFY_SYMS_CT_OWN) \
	$(LIB_VERIFY_SYMS_REU) $(LIB_VERIFY_SYMS_DOUBLED)
LIB_VERIFY_SYMS_ABSENT =
LIB_VERIFY_MASK_EXPECT = 000007
LIB_VERIFY_CONSUMES_EXPECT = 000007
LIB_VERIFY_BANKS_EXPECT = 00003B
LIB_VERIFY_RESIDENT_EXPECT = 0020BF
LIB_VERIFY_COLD_EXPECT = 00033A
endif

lib-verify: lib $(LIB_VERIFY_PRG)
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
	bytes=$$(wc -c < $(LIB_VERIFY_PRG)); \
	echo "OK: $(LIB_VERIFY_PRG) is $$bytes bytes, $(X25519_PROFILE)-profile symbol surface verified (mask \$$$(LIB_VERIFY_MASK_EXPECT))"

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
	@echo "OK: all four SHARED_* deferral profiles link and verify"

# --- §6.6/§6.7 guard negative legs (contract SPEC v0.10.0) -------------------
#
# `make lib-verify-guards` proves the two placement guards FAIL when
# they should — every other verify leg asserts success, so a silently
# inert guard (the pre-v0.10.0 state) would pass the whole matrix.
#   leg A: §6.7 region-agreement — PRG build with a diverged
#          LIB_SHARED_SQTAB_BASE must die on the named lderror.
#   leg B: §6.6 consumer-mirror — stub link against a fixture cfg
#          whose MAIN cannot hold the declared footprint must die on
#          the named lderror. Fixture derived from the example cfg by
#          sed (no second cfg to drift).
lib-verify-guards:
	@echo "=== lib-verify-guards: SPEC v0.10.0 §6.6/§6.7 negative legs ==="
	rm -rf build-guards; mkdir -p build-guards
	@echo "--- leg A: diverged SQTAB base must fail the PRG link"
	@out=$$($(MAKE) BUILD_DIR=build-guards CONTRACT_DEFINES="$(CONTRACT_DEFINES) -D LIB_SHARED_SQTAB_BASE=0x2A00" all 2>&1); \
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
	@echo "OK: both guard negatives fire with named errors"

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
