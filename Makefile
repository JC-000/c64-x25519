ACME = acme

# ca65/ld65 toolchain (cc65 suite)
CA65 = ca65
LD65 = ld65
CC65_CFG = cfg/x25519.cfg

SRC_DIR = src
BUILD_DIR = build

PRG = $(BUILD_DIR)/x25519.prg
LABELS = $(BUILD_DIR)/labels.txt

# ca65 build outputs
CA65_BUILD = $(BUILD_DIR)/ca65
CA65_PRG = $(CA65_BUILD)/x25519.prg
CA65_LABELS = $(CA65_BUILD)/labels.txt

ASM_SRCS = $(wildcard $(SRC_DIR)/*.asm)
# Phase C .include model: main.s includes all other .s files, so only
# main.s is assembled into a single .o.  (Phase E will split into modules.)
CA65_MAIN = $(SRC_DIR)/main.s
CA65_SRCS = $(wildcard $(SRC_DIR)/*.s)
CA65_OBJS = $(CA65_BUILD)/main.o

.PHONY: all clean test test-slow test-ref ca65 compare

all: $(PRG)

# Fast test suite: Python-only checks that do not launch VICE.
# This is what CI should run by default — it exits non-zero on any failure.
# VICE-dependent scripts are intentionally NOT in the default target because
# a single fe_mul test run takes minutes and a full ladder run takes hours.
# They are still runnable via "make test-slow" or directly as scripts.
test:
	@set -e; \
	python3 tools/ref_x25519.py

# Slow test suite: full RFC 7748 vector cross-check and ladder checkpoint
# replay. Requires a built .prg and a working VICE install; each scalarmult
# takes on the order of hours under VICE warp. Run manually, not in CI.
test-slow: $(PRG)
	@set -e; \
	python3 tools/ref_x25519.py; \
	python3 tools/test_fe25519.py; \
	python3 tools/test_fe_mul_stress.py; \
	python3 tools/test_fe_sqr_stress.py; \
	python3 tools/test_opt_sqr.py; \
	python3 tools/test_opt_karatsuba.py; \
	python3 tools/test_opt_fast_mul.py; \
	python3 tools/test_opt_vic_reduce38.py; \
	python3 tools/test_mul38_tables.py; \
	python3 tools/test_x25519.py --slow; \
	python3 tools/test_ladder_checkpoint.py --start 0 --count 255

# Reference-only self-test (no VICE, no build required).
test-ref:
	python3 tools/ref_x25519.py


$(PRG): $(ASM_SRCS) | $(BUILD_DIR)
	cd $(SRC_DIR) && $(ACME) -f cbm -o ../$(PRG) --vicelabels ../$(LABELS) main.asm

# --- ca65 build ----------------------------------------------------------

ca65: $(CA65_PRG)

# .include model: main.o depends on every .s file (main.s includes the rest)
$(CA65_BUILD)/main.o: $(CA65_SRCS) | $(CA65_BUILD)
	$(CA65) -o $@ $(CA65_MAIN)

$(CA65_PRG): $(CA65_OBJS) $(CC65_CFG) | $(CA65_BUILD)
	$(LD65) -C $(CC65_CFG) -o $(CA65_PRG) -Ln $(CA65_LABELS) $(CA65_OBJS)

# --- compare convenience target ------------------------------------------

compare: $(PRG) $(CA65_PRG)
	@echo "=== ACME PRG ===" && xxd $(PRG) | head -4
	@echo "=== ca65 PRG ===" && xxd $(CA65_PRG) | head -4
	@xxd $(PRG) > /tmp/acme_xxd.txt && xxd $(CA65_PRG) > /tmp/ca65_xxd.txt && diff /tmp/acme_xxd.txt /tmp/ca65_xxd.txt || true

# --- directories ----------------------------------------------------------

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(CA65_BUILD):
	mkdir -p $(CA65_BUILD)

clean:
	rm -f $(BUILD_DIR)/x25519.prg $(BUILD_DIR)/labels.txt
	rm -rf $(CA65_BUILD)
