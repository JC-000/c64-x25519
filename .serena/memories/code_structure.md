# Code Structure

```
c64-x25519/
├── Makefile              Top-level build/test driver
├── README.md
├── LICENSE               (MIT)
├── ORIGIN.txt.template   For downstream vendored copies
│
├── src/                  ca65 6502 assembly — the library
│   ├── x25519.inc        Public header (imports list + full API docs)
│   ├── main.s            BASIC stub + test-harness entry (NOT in libx25519.a)
│   ├── constants.s       .include'd by other .s files (not assembled alone)
│   ├── x25519_init.s     sqtab_init, reu_mul_init, REU helpers
│   ├── mul_8x8.s         8x8→16 multiply (quarter-square table, CT)
│   ├── fe25519.s         Field arithmetic mod p = 2^255 - 19
│   ├── x25519.s          Montgomery ladder, x25519_clamp / _scalarmult / _base
│   ├── data.s            Page-aligned static buffers (fe25519_tmp1..4,
│   │                     x25_*, fe_p, mul_dma_*, mul38/sqr tables, a24_b*)
│   └── util.s            vic_blank, vic_unblank, bench_start/stop
│
├── cfg/
│   ├── x25519.cfg              Linker config for make all (builds x25519.prg)
│   └── x25519-example.cfg      Starter config shipped to downstream users
│
├── docs/
│   ├── LIBRARY.md              Integration guide, memory map, public API
│   ├── CT_ANALYSIS.md          CT leak inventory L1–L22, threat model, phases
│   └── RELEASE_NOTES_v0.1.0.md
│
├── test/                       Test vectors + Python reference
│   ├── rfc7748_vectors.json
│   ├── vector2_ladder_checkpoints.json
│   └── vector2_ladder_ref.py
│
├── tests/                      Library-linkage smoke test
│   └── lib_linkage/
│       └── lib_linkage_stub.s
│
└── tools/                      Python test harness + benches (driven by VICE)
    ├── conftest.py
    ├── ref_x25519.py           Pure-Python reference (no VICE)
    ├── test_x25519.py          End-to-end X25519 differential tests
    ├── test_fe25519.py
    ├── test_fe_mul_stress.py
    ├── test_fe_sqr_stress.py
    ├── test_fe_reduce_wide_carry.py   Regression test for v0.1.0 prep bug
    ├── test_opt_{sqr,karatsuba,fast_mul,vic_reduce38}.py
    ├── test_mul38_tables.py
    ├── test_ladder_checkpoint.py
    ├── test_{reproduce_failure,vector2_debug,clamp_then_v2,state_leak}.py
    ├── ct_mul_brute_check.py   CT brute-force checker
    ├── bench_{x25519,fe_mul,fe_ops}.py
```

## Library object set (what ships in `libx25519.a`)
`x25519_init.o`, `mul_8x8.o`, `fe25519.o`, `x25519.o`, `data.o`,
`util.o`. **Not** shipped: `main.o` (BASIC stub, test-harness idle
loop, print helpers). Downstream users supply their own entry point.

## Module dependency sketch
```
x25519.s       → fe25519.s → mul_8x8.s
                           → x25519_init.s (REU)
                           → data.s (buffers)
util.s         (standalone: VIC-II blanking, jiffy-clock bench)
```
`constants.s` is `.include`'d directly by every `.s` that needs it and
is NOT compiled into its own `.o`.
