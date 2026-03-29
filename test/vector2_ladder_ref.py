#!/usr/bin/env python3
"""
Compute all 255 intermediate Montgomery ladder states for RFC 7748 test vector 2.
Saves checkpoints to vector2_ladder_checkpoints.json.
"""

import json

P = 2**255 - 19
a24 = 121665

# RFC 7748 section 6.1 test vector 2
scalar_hex = "4b66e9d4d1b4673c5ad22691957d6af5c11b6421e0ea01d42ca4169e7918ba0d"
u_hex = "e5210f12786811d3f4b7959d0538ae2c31dbe7106fc03c3efc4cd549c715a493"
expected_hex = "95cbde9476e8907d7aade45cb4b873f88b595a68799fa152e6f8f7647aac7957"

# Decode as little-endian
scalar_bytes = bytearray.fromhex(scalar_hex)
u_bytes = bytes.fromhex(u_hex)

# Clamp scalar
scalar_bytes[0] &= 0xF8
scalar_bytes[31] = (scalar_bytes[31] & 0x7F) | 0x40

# Convert to integer (little-endian)
scalar = int.from_bytes(scalar_bytes, 'little')
u = int.from_bytes(u_bytes, 'little')

# Mask u to 255 bits (clear top bit) per RFC 7748
u = u & ((1 << 255) - 1)

def get_bit(s, i):
    return (s >> i) & 1

# Montgomery ladder
x2, z2 = 1, 0
x3, z3 = u, 1

checkpoints = []
prev_bit = 0

for step, i in enumerate(range(254, -1, -1)):
    bit = get_bit(scalar, i)
    swap = bit ^ prev_bit

    # cswap
    if swap:
        x2, x3 = x3, x2
        z2, z3 = z3, z2

    # ladder step
    A = (x2 + z2) % P
    B = (x2 - z2) % P
    AA = (A * A) % P
    BB = (B * B) % P
    E = (AA - BB) % P
    C = (x3 + z3) % P
    D = (x3 - z3) % P
    DA = (D * A) % P
    CB = (C * B) % P
    x3 = pow(DA + CB, 2, P)
    z3 = (u * pow(DA - CB, 2, P)) % P
    x2 = (AA * BB) % P
    z2 = (E * ((AA + a24 * E) % P)) % P

    prev_bit = bit

    checkpoints.append({
        "step": step,
        "bit_index": i,
        "bit": bit,
        "x2": hex(x2),
        "z2": hex(z2),
        "x3": hex(x3),
        "z3": hex(z3),
    })

# Final cswap
if prev_bit:
    x2, x3 = x3, x2
    z2, z3 = z3, z2

# Compute result
result = (x2 * pow(z2, P - 2, P)) % P
result_bytes = result.to_bytes(32, 'little')
result_hex = result_bytes.hex()

# Final state after cswap
output = {
    "scalar_hex": scalar_hex,
    "u_hex": u_hex,
    "scalar_clamped": hex(scalar),
    "u_value": hex(u),
    "checkpoints": checkpoints,
    "final_state": {
        "x2": hex(x2),
        "z2": hex(z2),
        "x3": hex(x3),
        "z3": hex(z3),
    },
    "result_hex": result_hex,
    "expected_hex": expected_hex,
    "match": result_hex == expected_hex,
}

out_path = "/home/someone/c64-x25519/test/vector2_ladder_checkpoints.json"
with open(out_path, 'w') as f:
    json.dump(output, f, indent=2)

print(f"Total steps: {len(checkpoints)}")
print(f"Result:   {result_hex}")
print(f"Expected: {expected_hex}")
print(f"Match: {result_hex == expected_hex}")
print(f"Saved to: {out_path}")
