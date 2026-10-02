// SPDX-License-Identifier: GPL-3.0-or-later
// Offline, fail-closed analysis of a tiny AArch64 register-only subset.
// No FEX encoder/IR evaluator is used here; this is not an execution backend.
#pragma once
#include <array>
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <span>

namespace CodeOracle {
using GuestRegisters = std::array<uint32_t, 8>;
using GuestMap = std::array<unsigned, 8>;
using AllowedRegisters = std::array<bool, 31>;

inline uint64_t mask(unsigned bits) {
  assert(bits > 0 && bits <= 64);
  return bits == 64 ? UINT64_MAX : (uint64_t {1} << bits) - 1;
}

inline GuestRegisters analyze(std::span<const uint32_t> words, const GuestRegisters& input, const GuestMap& map, const AllowedRegisters& allowed) {
  std::array<uint64_t, 31> registers {};
  std::array<bool, 31> initialized {};
  for (unsigned i = 0; i < map.size(); ++i) {
    assert(map[i] < registers.size() && allowed[map[i]] && !initialized[map[i]]);
    registers[map[i]] = input[i];
    initialized[map[i]] = true;
  }
  auto read = [&](unsigned reg) -> uint64_t {
    if (reg == 31) { // ZR only: no accepted instruction uses SP semantics.
      return 0;
    }
    assert(reg < registers.size() && allowed[reg] && initialized[reg]);
    return registers[reg];
  };
  for (uint32_t word : words) {
    const unsigned bits = (word >> 31) ? 64 : 32;
    const unsigned dest = word & 31;
    assert(dest < registers.size() && allowed[dest]);
    uint64_t value;
    if ((word & 0x1f800000) == 0x12800000) { // MOVN/MOVZ/MOVK
      const unsigned opc = (word >> 29) & 3;
      const unsigned shift = ((word >> 21) & 3) * 16;
      assert(opc != 1 && shift < bits);
      const uint64_t literal = uint64_t((word >> 5) & 0xffff) << shift;
      if (opc == 0) {
        value = ~literal;
      } else if (opc == 2) {
        value = literal;
      } else {
        value = (read(dest) & ~(uint64_t {0xffff} << shift)) | literal;
      }
    } else if ((word & 0x7fe0ffe0) == 0x2a0003e0) { // MOV alias, ORR Rd, ZR, Rm, LSL #0
      value = read((word >> 16) & 31);
    } else if ((word & 0x7f800000) == 0x32000000) { // ORR immediate, MOV bitmask alias only
      assert(((word >> 5) & 31) == 31);
      const unsigned n = (word >> 22) & 1;
      assert(bits == 64 || n == 0);
      const unsigned imms = (word >> 10) & 63;
      const unsigned encoding = (n << 6) | ((~imms) & 63);
      unsigned length = 0;
      for (unsigned i = 0; i <= 6; ++i) {
        if (encoding & (1U << i)) {
          length = i;
        }
      }
      assert(length >= 1);
      const unsigned element_bits = 1U << length;
      assert(element_bits <= bits);
      const unsigned s = imms & (element_bits - 1);
      const unsigned rotation = ((word >> 16) & 63) & (element_bits - 1);
      assert(s != element_bits - 1);
      uint64_t element = mask(s + 1);
      if (rotation) {
        element = ((element >> rotation) | (element << (element_bits - rotation))) & mask(element_bits);
      }
      value = 0;
      for (unsigned i = 0; i < bits; i += element_bits) {
        value |= element << i;
      }
    } else if ((word & 0x7f800000) == 0x33000000) { // BFM, BFI alias only
      assert(((word >> 22) & 1) == (bits == 64));
      const unsigned r = (word >> 16) & 63;
      const unsigned s = (word >> 10) & 63;
      assert(r < bits && s < bits && (s < r || r == 0));
      const unsigned lsb = (bits - r) % bits;
      const unsigned width = s + 1;
      assert(lsb + width <= bits);
      const uint64_t field = mask(width) << lsb;
      value = (read(dest) & ~field) | ((read((word >> 5) & 31) << lsb) & field);
    } else if ((word & 0x7f800000) == 0x53000000) { // UBFM, UBFX alias only
      assert(((word >> 22) & 1) == (bits == 64));
      const unsigned r = (word >> 16) & 63;
      const unsigned s = (word >> 10) & 63;
      assert(r < bits && s < bits && s >= r);
      value = (read((word >> 5) & 31) >> r) & mask(s - r + 1);
    } else {
      std::fprintf(stderr, "Unexpected ARM body instruction: %08x\n", word);
      std::abort();
    }
    registers[dest] = value & mask(bits); // W writes zero-extend.
    initialized[dest] = true;
  }
  GuestRegisters result;
  for (unsigned i = 0; i < map.size(); ++i) {
    result[i] = uint32_t(read(map[i]));
  }
  return result;
}
} // namespace CodeOracle
