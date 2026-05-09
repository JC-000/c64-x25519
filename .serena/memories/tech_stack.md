# Tech Stack

## Target hardware
- **CPU:** 6502 (stock Commodore 64)
- **REU:** 1750 or equivalent; minimum 512 KB (library touches 6 banks
  = 384 KB)
- **RAM layout:** BASIC ROM banked out at startup; library owns
  specific ZP ($14–$7F, $FB–$FE) and RAM regions

## Build toolchain
- **Assembler/linker:** `ca65` and `ld65` from the cc65 suite
- **Archiver:** `ar65` (for `make lib`)
- Build driven by `Makefile` — no CMake, no autotools

## Test / dev toolchain
- **Python 3** (harness and differential tests)
- **VICE emulator** — for `make test-slow` / `make test-vice`
- **pyca/cryptography** — external oracle for differential tests
- `c64-test-harness` Python package — drives VICE from Python

## Languages in repo
- ca65 6502 assembly: `src/*.s`, `src/x25519.inc` (header),
  `tests/lib_linkage/*.s`
- Python 3: `tools/*.py`, `test/vector2_ladder_ref.py`
- Make: top-level `Makefile`
- ca65 linker config: `cfg/x25519.cfg`, `cfg/x25519-example.cfg`

## External data
- `test/rfc7748_vectors.json` — RFC 7748 test vectors
- `test/vector2_ladder_checkpoints.json` — ladder-state checkpoints for
  replay-style differential debugging
