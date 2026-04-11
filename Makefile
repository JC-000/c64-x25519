ACME = acme

SRC_DIR = src
BUILD_DIR = build

PRG = $(BUILD_DIR)/x25519.prg
LABELS = $(BUILD_DIR)/labels.txt

ASM_SRCS = $(wildcard $(SRC_DIR)/*.asm)

.PHONY: all clean test test-slow test-ref

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

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

clean:
	rm -f $(BUILD_DIR)/x25519.prg $(BUILD_DIR)/labels.txt
