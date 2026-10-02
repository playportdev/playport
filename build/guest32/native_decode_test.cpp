// SPDX-License-Identifier: GPL-3.0-or-later
// Host-isolated real frontend test, NOT guest execution or a production bridge.
#include "Interface/Context/Context.h"
#include "Interface/Core/Frontend.h"
#include "Interface/Core/OpcodeDispatcher.h"
#include "Interface/IR/PassManager.h"
#include "Interface/Core/LookupCache.h"
#include "Interface/Core/Dispatcher/Dispatcher.h"
#include <FEXCore/Config/Config.h>
#include <FEXCore/Debug/InternalThreadState.h>
#include <FEXCore/HLE/SyscallHandler.h>
extern "C" {
#include "guest32.h"
}
#include <cassert>
#include <cstdio>
#include <cstdlib>

#include "native_audit_adapter.h"

using Decoder = FEXCore::Frontend::Decoder;
using Status = Decoder::DecodedBlockStatus;

static void cases(size_t granule) {
  g32_space* space;
  assert(g32_create(granule, &space) == G32_OK);
  assert(!ActiveSpace);
  ActiveSpace = space;
  constexpr uint32_t base = 0x400000;
  assert(g32_reserve(space, base, G32_GRANULE) == G32_OK);
  assert(g32_commit(space, base, 2 * G32_PAGE, G32_READ | G32_WRITE) == G32_OK);
  // A register-only imm32 crosses the guest page edge, even on 16/64 KiB hosts.
  constexpr uint32_t pc = base + G32_PAGE - 2;
  const uint8_t mov[] = {0xb8, 0x78, 0x56, 0x34, 0x12};
  assert(g32_write(space, pc, mov, sizeof(mov)) == G32_OK);
  assert(g32_protect(space, base, G32_PAGE, G32_EXEC) == G32_OK);

  FEXCore::HostFeatures features {};
  FEXCore::Context::ContextImpl context {features};
  Handler handler {space};
  context.SyscallHandler = &handler;
  FEXCore::Core::InternalThreadState thread {.CTX = &context};
  FEXCore::Core::CPUState::gdt_segment gdt[1] {};
  gdt[0].D = 1; // 32-bit CS (not long mode), in addition to 32-bit configuration.
  thread.CurrentFrame->State.segment_arrays[0] = gdt;
  Decoder decoder {&thread};
  auto decode = [&](uint64_t entry, uint64_t count = 1) {
    decoder.SetupDecodeInstructionsAtEntry(&thread, entry, count);
    // MUST be the guest PC, not the high backing pointer.
    decoder.DecodeLoop(reinterpret_cast<const uint8_t*>(entry));
    auto* info = decoder.GetDecodedBlockInfo();
    assert(!info->Is64BitMode);
    assert(info->Blocks.size() >= 1);
    for (const auto& block : info->Blocks) {
      assert(block.Entry <= UINT32_MAX);
      for (uint64_t i = 0; i < block.NumInstructions; ++i) {
        assert(block.DecodedInstructions[i].PC <= UINT32_MAX);
      }
    }
    decoder.DelayedDisownBuffer(); // Info remains valid until the next decode.
    return info;
  };
  auto failed = [&](uint64_t entry) {
    auto* info = decode(entry);
    assert(info->Blocks.size() == 1);
    const auto& block = info->Blocks[0];
    assert(block.Entry == entry && block.Size == 0 && block.NumInstructions == 1);
    assert(block.BlockStatus == Status::NOEXEC_INST || block.BlockStatus == Status::PARTIAL_DECODE_INST);
    assert(block.DecodedInstructions[0].PC == entry);
    assert(!block.DecodedInstructions[0].TableInfo);
    return block.BlockStatus;
  };
  auto check_mov = [&](uint32_t entry, uint64_t literal, uint8_t size, uint8_t reg) {
    auto* info = decode(entry);
    assert(info->TotalInstructionCount == 1 && info->Blocks.size() == 1);
    const auto& block = info->Blocks[0];
    assert(block.Entry == entry && block.Size == size && block.BlockStatus == Status::SUCCESS);
    const auto& inst = block.DecodedInstructions[0];
    assert(inst.PC == entry && inst.InstSize == size);
    assert(inst.Dest.IsGPR() && inst.Dest.Data.GPR.GPR == reg);
    assert(inst.Src[0].IsLiteral() && inst.Src[0].Literal() == literal);
  };

  // Native-readable neighbor must NOT satisfy executable immediate reads.
  uint8_t bytes[5];
  assert(g32_read(space, pc + 2, bytes, 3) == G32_OK);
  assert(bytes[0] == 0x56 && bytes[2] == 0x12);
  assert(failed(pc) == Status::PARTIAL_DECODE_INST);
  assert(failed(base + G32_PAGE) == Status::NOEXEC_INST);
  assert(g32_protect(space, base + G32_PAGE, G32_PAGE, G32_EXEC) == G32_OK);
  decoder.ResetExecutableRangeCache();
  check_mov(pc, 0x12345678, 5, FEXCore::X86State::REG_RAX);
  assert(g32_fetch(space, pc, bytes, 5) == G32_OK);
  assert(g32_read(space, pc, bytes, 5) == G32_ACCESS); // Execute-only is real.

  // ReadData widths 1, 2 and 4, opcode/prefix peeks, all eight 32-bit GPRs.
  assert(g32_protect(space, base, G32_PAGE, G32_WRITE | G32_EXEC) == G32_OK);
  decoder.ResetExecutableRangeCache();
  for (unsigned reg = 0; reg < 8; ++reg) {
    uint8_t code[] = {uint8_t(0xb8 + reg), 0xef, 0xcd, 0xab, 0x89};
    assert(g32_write(space, base, code, sizeof(code)) == G32_OK);
    check_mov(base, 0x89abcdef, 5, FEXCore::X86State::REG_RAX + reg);
  }
  const uint8_t narrow[] = {0x66, 0xb8, 0x34, 0x92, 0xb0, 0xfe};
  assert(g32_write(space, base, narrow, sizeof(narrow)) == G32_OK);
  check_mov(base, 0x9234, 4, FEXCore::X86State::REG_RAX);
  check_mov(base + 4, 0xfe, 2, FEXCore::X86State::REG_RAX);

  // Conditional branch explores both successors using guest, not backing PCs.
  const uint8_t branch[] = {0x75, 0x06, 0xb8, 1, 0, 0, 0, 0xc3, 0xb9, 2, 0, 0, 0, 0xc3};
  assert(g32_write(space, base, branch, sizeof(branch)) == G32_OK);
  auto* info = decode(base, 16);
  assert(info->Blocks.size() == 3 && info->TotalInstructionCount == 5);
  assert(info->Blocks[0].Entry == base && info->Blocks[0].Size == 2);
  assert(info->Blocks[1].Entry == base + 2 && info->Blocks[1].Size == 6);
  assert(info->Blocks[2].Entry == base + 8 && info->Blocks[2].Size == 6);
  for (const auto& block : info->Blocks) {
    assert(block.BlockStatus == Status::SUCCESS);
  }
  assert(info->Blocks[1].DecodedInstructions[0].Src[0].Literal() == 1);
  assert(info->Blocks[2].DecodedInstructions[0].Src[0].Literal() == 2);

  // Warm the range cache, revoke EXEC, then explicitly reset before decoding.
  check_mov(pc, 0x12345678, 5, FEXCore::X86State::REG_RAX);
  unsigned queries = handler.Queries;
  assert(g32_protect(space, base, G32_PAGE, G32_READ) == G32_OK);
  decoder.ResetExecutableRangeCache();
  assert(failed(pc) == Status::NOEXEC_INST);
  assert(handler.Queries > queries);
  assert(g32_protect(space, base, G32_PAGE, G32_EXEC) == G32_OK);
  decoder.ResetExecutableRangeCache();
  check_mov(pc, 0x12345678, 5, FEXCore::X86State::REG_RAX);
  assert(g32_decommit(space, base + G32_PAGE, G32_PAGE) == G32_OK);
  decoder.ResetExecutableRangeCache();
  assert(failed(pc) == Status::PARTIAL_DECODE_INST);
  assert(failed(base + G32_PAGE) == Status::NOEXEC_INST);
  assert(g32_release(space, base) == G32_OK);
  decoder.ResetExecutableRangeCache();
  assert(failed(pc) == Status::NOEXEC_INST);
  assert(failed(0) == Status::NOEXEC_INST);

  // Last byte: no wrapping the immediate read to guest zero or past the backing.
  assert(g32_reserve(space, 0xffff0000, G32_GRANULE) == G32_OK);
  assert(g32_commit(space, 0xfffff000, G32_PAGE, G32_WRITE) == G32_OK);
  const uint8_t opcode = 0xb8;
  assert(g32_write(space, UINT32_MAX, &opcode, 1) == G32_OK);
  assert(g32_protect(space, 0xfffff000, G32_PAGE, G32_EXEC) == G32_OK);
  decoder.ResetExecutableRangeCache();
  assert(failed(UINT32_MAX) == Status::PARTIAL_DECODE_INST);
  decoder.ValidateDisownedOrFree();
  assert(ByteLoans > 0);
  std::printf("PASS: real 32-bit decoder granule=%zu operands/multiblock/NOEXEC/immediates/cache reset/end-of-space\n", granule);
  ActiveSpace = nullptr;
  g32_destroy(space);
}

int main() {
  FEXCore::Config::Initialize();
  FEXCore::Config::Load();
  FEXCore::Config::Set(FEXCore::Config::ConfigOption::CONFIG_IS64BIT_MODE, "0");
  FEXCore::Config::Set(FEXCore::Config::ConfigOption::CONFIG_MULTIBLOCK, "1");
  FEXCore::Config::Set(FEXCore::Config::ConfigOption::CONFIG_ENABLECODECACHEVALIDATION, "0");
  FEXCore::Config::Set(FEXCore::Config::ConfigOption::CONFIG_SMCCHECKS, "0");
  cases(0);
  cases(16384);
  cases(65536);
}
