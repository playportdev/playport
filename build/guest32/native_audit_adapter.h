// SPDX-License-Identifier: GPL-3.0-or-later
// Serialized host-test adapter only; no shipped runtime uses this header.
#pragma once
#include <FEXCore/HLE/SyscallHandler.h>
extern "C" {
#include "guest32.h"
}
#include <cassert>
#include <cstdlib>

static g32_space* ActiveSpace;
static unsigned ByteLoans;

// Supply ONLY the opt-in byte-source seam, not a replacement FEX method.
// No platform macro changes the native context ABI. VM changes and decoding
// are serialized; loans expire on the next VM change. This is not a VM port.
extern "C" const uint8_t* FEXTestDecoderByteSource(uint64_t address) {
  assert(ActiveSpace);
  if (address > UINT32_MAX) {
    return reinterpret_cast<const uint8_t*>(address);
  }
  void* loan = nullptr;
  if (g32_translate(ActiveSpace, address, 1, G32_EXEC, &loan) != G32_OK) {
    // No native byte loan: the decoder's range check must reject before reading.
    return reinterpret_cast<const uint8_t*>(address);
  }
  ++ByteLoans;
  assert(reinterpret_cast<uintptr_t>(loan) > UINT32_MAX);
  return static_cast<const uint8_t*>(loan);
}

struct Handler final : FEXCore::HLE::SyscallHandler {
  g32_space* Space;
  unsigned Queries = 0;
  explicit Handler(g32_space* space)
    : Space {space} { }
  void HandleSyscall(FEXCore::Core::CpuStateFrame*) override {
    std::abort();
  }
  FEXCore::HLE::ExecutableRangeInfo QueryGuestExecutableRange(FEXCore::Core::InternalThreadState*, uint64_t address) override {
    ++Queries;
    if (address > UINT32_MAX) {
      return {address, 0, false};
    }
    g32_region region;
    assert(g32_query(Space, address, &region) == G32_OK);
    if (region.state != G32_REGION_COMMITTED || !(region.permissions & G32_EXEC)) {
      return {address, 0, false};
    }
    return {region.region_base, region.size, bool(region.permissions & G32_WRITE)};
  }
  std::optional<FEXCore::ExecutableFileSectionInfo> LookupExecutableFileSection(FEXCore::Core::InternalThreadState*, uint64_t) override {
    // No disk cache, relocation, SMC, diagnostic byte readers or JIT in this gate.
    std::abort();
  }
};
