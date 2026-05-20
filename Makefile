# ca65/ld65 toolchain (cc65 suite)
CA65 = ca65
LD65 = ld65
CC65_CFG = cfg/x25519.cfg

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
            $(SRC_DIR)/zp_config.s \
            $(SRC_DIR)/reu_config.s

CA65_OBJS = $(BUILD_DIR)/main.o $(LIB_OBJS)

LIBX25519 = $(LIB_DIR)/libx25519.a

.PHONY: all clean test test-slow test-ref test-vice lib lib-verify dist

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
$(BUILD_DIR)/%.o: $(SRC_DIR)/%.s $(SRC_DIR)/constants.s $(SRC_DIR)/zp_config.s $(SRC_DIR)/reu_config.s | $(BUILD_DIR)
	$(CA65) -o $@ $<

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

lib-verify: lib $(LIB_VERIFY_PRG)
	@set -e; \
	test -s $(LIB_VERIFY_PRG) || (echo "FAIL: $(LIB_VERIFY_PRG) is empty" && exit 1); \
	for sym in x25519_clamp x25519_scalarmult x25519_base \
	           fe25519_add fe25519_sub fe25519_mul fe25519_sqr \
	           sqtab_init reu_mul_init \
	           x25_scalar x25_u x25_result \
	           vic_blank vic_unblank bench_start bench_stop \
	           bench_cycles_start bench_cycles_stop bench_cycles \
	           LIB_VERSION_MAJOR LIB_VERSION_MINOR LIB_VERSION_PATCH \
	           LIB_ABI_VERSION \
	           fe25519_src1 fe25519_src2 fe25519_dst \
	           fe_carry poly_carry \
	           X25519_REU_BANK X25519_REU_OFFSET; do \
	  grep -q "\\b$$sym\\b" $(LIB_VERIFY_DIR)/stub.labels \
	    || (echo "FAIL: expected symbol $$sym not in linked binary" && exit 1); \
	done; \
	bytes=$$(wc -c < $(LIB_VERIFY_PRG)); \
	echo "OK: $(LIB_VERIFY_PRG) is $$bytes bytes, all expected symbols present"

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

$(LIB_VERIFY_PRG): $(LIB_VERIFY_STUB) $(LIBX25519) cfg/x25519-example.cfg | $(LIB_VERIFY_DIR)
	$(CA65) -I $(SRC_DIR) -o $(LIB_VERIFY_DIR)/stub.o $(LIB_VERIFY_STUB)
	$(LD65) -C cfg/x25519-example.cfg -o $@ \
	    -Ln $(LIB_VERIFY_DIR)/stub.labels \
	    $(LIB_VERIFY_DIR)/stub.o $(LIBX25519)

$(LIB_VERIFY_DIR):
	mkdir -p $(LIB_VERIFY_DIR)
