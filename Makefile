# ca65/ld65 toolchain (cc65 suite)
CA65 = ca65
LD65 = ld65
CC65_CFG = cfg/x25519.cfg

SRC_DIR = src
BUILD_DIR = build

PRG = $(BUILD_DIR)/x25519.prg
LABELS = $(BUILD_DIR)/labels.txt

# Separate compilation: each .s file produces its own .o
CA65_SRCS = $(SRC_DIR)/main.s \
            $(SRC_DIR)/constants.s \
            $(SRC_DIR)/x25519_init.s \
            $(SRC_DIR)/mul_8x8.s \
            $(SRC_DIR)/fe25519.s \
            $(SRC_DIR)/x25519.s \
            $(SRC_DIR)/data.s

CA65_OBJS = $(BUILD_DIR)/main.o \
            $(BUILD_DIR)/x25519_init.o \
            $(BUILD_DIR)/mul_8x8.o \
            $(BUILD_DIR)/fe25519.o \
            $(BUILD_DIR)/x25519.o \
            $(BUILD_DIR)/data.o

.PHONY: all clean test test-slow test-ref test-vice

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
	python3 tools/test_fe_reduce_wide_carry.py; \
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
	python3 tools/test_fe_reduce_wide_carry.py

# Reference-only self-test (no VICE, no build required).
test-ref:
	python3 tools/ref_x25519.py

# --- ca65 build ----------------------------------------------------------

# Each .s file compiles to its own .o (constants.s is .include'd, not assembled)
$(BUILD_DIR)/%.o: $(SRC_DIR)/%.s $(SRC_DIR)/constants.s | $(BUILD_DIR)
	$(CA65) -o $@ $<

$(PRG): $(CA65_OBJS) $(CC65_CFG) | $(BUILD_DIR)
	$(LD65) -C $(CC65_CFG) -o $(PRG) -Ln $(LABELS).raw $(CA65_OBJS)
	sed 's/^al \([0-9a-fA-F]\{6\}\) /al C:\1 /' $(LABELS).raw > $(LABELS)
	rm -f $(LABELS).raw

# --- directories ----------------------------------------------------------

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

clean:
	rm -f $(BUILD_DIR)/*.o $(PRG) $(LABELS) $(LABELS).raw
