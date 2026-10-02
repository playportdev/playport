// SPDX-License-Identifier: GPL-3.0-or-later
// Real decode/dispatch audit BEFORE optimization/RA. No JIT or guest execution.
#include "Interface/Context/Context.h"
#include "Interface/Core/Frontend.h"
#include "Interface/Core/OpcodeDispatcher.h"
#include "Interface/IR/PassManager.h"
#include "Interface/IR/Passes.h"
#include "Interface/Core/LookupCache.h"
#include "Interface/Core/Dispatcher/Dispatcher.h"
#include <FEXCore/Config/Config.h>
#include <FEXCore/Debug/InternalThreadState.h>
#include "native_audit_adapter.h"
#include <array>
#include <cstdio>
#include <functional>
#include <vector>

using namespace FEXCore::IR;
using Registers = std::array<uint32_t, 8>;

enum class Effect { Immediate32, Immediate16, ImmediateLow8, ImmediateHigh8, Copy32, High8ZeroExtend };
struct Instruction {
  std::vector<uint8_t> Bytes;
  Effect Change;
  unsigned Dest;
  uint32_t Value; // Independently specified literal or source-register index.
};
using Sequence = std::vector<Instruction>;

// An independent x86 register oracle, NOT a decoder or FEX implementation.
static void expected_effect(Registers& regs, const Instruction& inst) {
  assert(inst.Dest < regs.size());
  auto& dest = regs[inst.Dest];
  switch (inst.Change) {
  case Effect::Immediate32: dest = inst.Value; break;
  case Effect::Immediate16: dest = (dest & 0xffff0000) | inst.Value; break;
  case Effect::ImmediateLow8: dest = (dest & 0xffffff00) | inst.Value; break;
  case Effect::ImmediateHigh8: dest = (dest & 0xffff00ff) | (inst.Value << 8); break;
  case Effect::Copy32:
    assert(inst.Value < regs.size());
    dest = regs[inst.Value];
    break;
  case Effect::High8ZeroExtend:
    assert(inst.Value < 4);
    dest = (regs[inst.Value] >> 8) & 0xff;
    break;
  }
}

// Bounded, offline checking of the emitted SSA graph. Only these pure value,
// guest-PC metadata and fixed-register operations are accepted. In particular,
// no memory, flags, helper, syscall, branch or native pointer operation is
// silently ignored. This is NOT a FEX interpreter or guest execution backend.
static void verify_ir(const IRListView& ir, uint32_t pc, const Sequence& sequence, const Registers& input) {
  assert(!ir.PostRA());
  assert(ir.GetHeader()->OriginalRIP == pc);
  assert(ir.GetHeader()->NumHostInstructions == sequence.size());
  Registers actual = input;
  Registers expected = input;
  std::vector<uint64_t> values(ir.GetSSACount());
  std::vector<bool> valid(ir.GetSSACount());
  auto read = [&](OrderedNodeWrapper wrapper) {
    auto id = ir.GetID(ir.GetNode(wrapper)).Value;
    assert(id < values.size() && valid[id]);
    return values[id];
  };
  size_t markers = 0, stores = 0, exits = 0, blocks = 0, begins = 0, ends = 0, offset = 0;
  for (auto [node, header] : ir.GetAllCode()) {
    const auto id = ir.GetID(node).Value;
    assert(id < values.size() && !valid[id]);
    switch (header->Op) {
    case OP_CODEBLOCK: ++blocks; break;
    case OP_BEGINBLOCK: ++begins; break;
    case OP_ENDBLOCK: ++ends; break;
    case OP_GUESTOPCODE: {
      assert(actual == expected); // Every previous instruction, not just final registers.
      assert(markers < sequence.size());
      const auto* op = ir.GetOp<IROp_GuestOpcode>(node);
      assert(op->GuestEntryOffset == offset);
      expected_effect(expected, sequence[markers]);
      offset += sequence[markers++].Bytes.size();
      break;
    }
    case OP_CONSTANT: {
      const auto* op = ir.GetOp<IROp_Constant>(node);
      assert(header->Size == OpSize::i64Bit && op->Constant >= 0 && uint64_t(op->Constant) <= UINT32_MAX);
      values[id] = op->Constant;
      valid[id] = true;
      break;
    }
    case OP_LOADREGISTER: {
      const auto* op = ir.GetOp<IROp_LoadRegister>(node);
      assert(op->Class == RegClass::GPR && op->Reg < actual.size());
      assert(header->Size == OpSize::i32Bit);
      values[id] = actual[op->Reg];
      valid[id] = true;
      break;
    }
    case OP_STOREREGISTER: {
      const auto* op = ir.GetOp<IROp_StoreRegister>(node);
      PhysicalRegister dest {node};
      assert(dest.AsRegClass() == RegClass::GPRFixed && dest.Reg < actual.size());
      assert(header->Size == OpSize::i32Bit);
      assert(markers && stores + 1 == markers && dest.Reg == sequence[markers - 1].Dest);
      actual[dest.Reg] = static_cast<uint32_t>(read(op->Value));
      ++stores;
      break;
    }
    case OP_BFI: {
      const auto* op = ir.GetOp<IROp_Bfi>(node);
      assert(header->Size == OpSize::i64Bit);
      assert((op->Width == 8 || op->Width == 16) && (op->lsb == 0 || op->lsb == 8));
      const uint64_t mask = ((uint64_t {1} << op->Width) - 1) << op->lsb;
      values[id] = (read(op->Dest) & ~mask) | ((read(op->Src) << op->lsb) & mask);
      valid[id] = true;
      break;
    }
    case OP_BFE: {
      const auto* op = ir.GetOp<IROp_Bfe>(node);
      assert(header->Size == OpSize::i32Bit && op->Width == 8 && op->lsb == 8);
      values[id] = (read(op->Src) >> op->lsb) & 0xff;
      valid[id] = true;
      break;
    }
    case OP_INLINEENTRYPOINTOFFSET: {
      const auto* op = ir.GetOp<IROp_InlineEntrypointOffset>(node);
      assert(header->Size == OpSize::i32Bit && op->Offset == static_cast<int64_t>(offset));
      assert(markers == sequence.size());
      values[id] = uint64_t(pc) + offset;
      assert(values[id] <= UINT32_MAX);
      valid[id] = true;
      break;
    }
    case OP_EXITFUNCTION: {
      const auto* op = ir.GetOp<IROp_ExitFunction>(node);
      assert(header->Size == OpSize::i32Bit && read(op->NewRIP) == uint64_t(pc) + offset);
      assert(op->Hint == BranchHint::None && op->CallReturnAddress.IsInvalid() && op->CallReturnBlock.IsInvalid());
      assert(op->PatchSiteAddress == 0 && op->PatchSiteSize == 0);
      assert(actual == expected && stores == sequence.size());
      ++exits;
      break;
    }
    default:
      auto name = GetName(header->Op);
      std::fprintf(stderr, "Unexpected IR op: %.*s\n", int(name.size()), name.data());
      std::abort();
    }
  }
  assert(actual == expected && markers == sequence.size() && stores == sequence.size());
  assert(blocks == 1 && begins == 1 && ends == 1 && exits == 1);
}

static void audit(FEXCore::Context::ContextImpl& context, FEXCore::Core::InternalThreadState& thread, g32_space* space, uint32_t pc,
                  const Sequence& sequence) {
  const uint32_t base = pc & ~(G32_GRANULE - 1);
  assert(g32_reserve(space, base, G32_GRANULE) == G32_OK);
  assert(g32_commit(space, base, 2 * G32_PAGE, G32_WRITE) == G32_OK);
  std::vector<uint8_t> bytes;
  for (const auto& inst : sequence) {
    bytes.insert(bytes.end(), inst.Bytes.begin(), inst.Bytes.end());
  }
  assert(g32_write(space, pc, bytes.data(), bytes.size()) == G32_OK);
  assert(g32_protect(space, base, 2 * G32_PAGE, G32_EXEC) == G32_OK);
  FEXCore::Frontend::Decoder decoder {&thread};
  decoder.SetupDecodeInstructionsAtEntry(&thread, pc, sequence.size());
  decoder.DecodeLoop(reinterpret_cast<const uint8_t*>(uintptr_t(pc)));
  const auto* info = decoder.GetDecodedBlockInfo();
  assert(!info->Is64BitMode && info->Blocks.size() == 1 && info->TotalInstructionCount == sequence.size());
  const auto& block = info->Blocks[0];
  assert(block.BlockStatus == FEXCore::Frontend::Decoder::DecodedBlockStatus::SUCCESS);
  assert(block.Entry == pc && block.Size == bytes.size() && block.NumInstructions == sequence.size());
  OpDispatchBuilder builder {&context, &thread};
  builder.ReownOrClaimBuffer();
  builder.BeginFunction(pc, &info->Blocks, info->TotalInstructionCount, false, false);
  builder.SetNewBlockIfChanged(pc);
  builder.StartNewBlock();
  uint64_t offset = 0;
  for (uint64_t i = 0; i < block.NumInstructions; ++i) {
    const auto* inst = &block.DecodedInstructions[i];
    assert(inst->PC == uint64_t(pc) + offset && inst->InstSize == sequence[i].Bytes.size());
    assert(inst->TableInfo && inst->TableInfo->OpcodeDispatcher.OpDispatch);
    // The same per-instruction lifecycle as ContextImpl::GenerateIR, but stop
    // before its optimizer/RA/backend pipeline. No FEX method is replaced.
    builder.FlushRegisterCache(true);
    builder._GuestOpcode(inst->PC - pc);
    builder.ResetHandledLock();
    builder.ResetDecodeFailure();
    std::invoke(inst->TableInfo->OpcodeDispatcher.OpDispatch, builder, inst);
    assert(!builder.HadDecodeFailure() && !builder.HasHandledLock());
    builder.FinishOp(inst->PC + inst->InstSize, i + 1 == block.NumInstructions);
    offset += inst->InstSize;
  }
  builder.Finalize();
  auto validation = Validation::CreateIRValidation();
  validation->Run(&builder);
  auto ir = builder.ViewIR();
  uint32_t random = 0x1badf00d;
  for (unsigned trial = 0; trial < 128; ++trial) {
    Registers input;
    for (auto& value : input) {
      random ^= random << 13;
      random ^= random >> 17;
      random ^= random << 5;
      value = trial == 0 ? 0 : trial == 1 ? UINT32_MAX : random;
    }
    verify_ir(ir, pc, sequence, input);
  }
  std::vector<uint8_t> unchanged(bytes.size());
  assert(g32_fetch(space, pc, unchanged.data(), unchanged.size()) == G32_OK && bytes == unchanged);
  assert(g32_read(space, pc, unchanged.data(), unchanged.size()) == G32_ACCESS);
  builder.DelayedDisownBuffer();
  decoder.DelayedDisownBuffer();
  builder.ValidateDisownedOrFree();
  decoder.ValidateDisownedOrFree();
  assert(g32_release(space, base) == G32_OK);
}

static void cases(size_t granule) {
  g32_space* space;
  assert(g32_create(granule, &space) == G32_OK);
  assert(!ActiveSpace);
  ActiveSpace = space;
  FEXCore::HostFeatures features {};
  FEXCore::Context::ContextImpl context {features};
  Handler handler {space};
  context.SyscallHandler = &handler;
  FEXCore::Core::InternalThreadState thread {.CTX = &context};
  FEXCore::Core::CPUState::gdt_segment gdt[1] {};
  gdt[0].D = 1;
  thread.CurrentFrame->State.segment_arrays[0] = gdt;
  // All eight guest GPRs, including ESP/EBP, have no stack or memory accesses.
  const Sequence all_gprs {
    {{0xb8, 0xef, 0xcd, 0xab, 0x89}, Effect::Immediate32, 0, 0x89abcdef},
    {{0xb9, 0, 0, 0, 0}, Effect::Immediate32, 1, 0},
    {{0xba, 0xff, 0xff, 0xff, 0xff}, Effect::Immediate32, 2, UINT32_MAX},
    {{0xbb, 0x78, 0x56, 0x34, 0x12}, Effect::Immediate32, 3, 0x12345678},
    {{0xbc, 0x10, 0x32, 0x54, 0x76}, Effect::Immediate32, 4, 0x76543210},
    {{0xbd, 1, 0, 0, 0x80}, Effect::Immediate32, 5, 0x80000001},
    {{0xbe, 0xef, 0xbe, 0xad, 0xde}, Effect::Immediate32, 6, 0xdeadbeef},
    {{0xbf, 0x98, 0xba, 0xdc, 0xfe}, Effect::Immediate32, 7, 0xfedcba98},
    {{0x89, 0xc1}, Effect::Copy32, 1, 0},
  };
  // Input-dependent partial writes and extraction check untouched register bits.
  const Sequence partial {
    {{0x66, 0xb8, 0x34, 0x12}, Effect::Immediate16, 0, 0x1234},
    {{0xb0, 0xfe}, Effect::ImmediateLow8, 0, 0xfe},
    {{0xb4, 0x76}, Effect::ImmediateHigh8, 0, 0x76},
    {{0x89, 0xc1}, Effect::Copy32, 1, 0},
    {{0x0f, 0xb6, 0xd4}, Effect::High8ZeroExtend, 2, 0},
    {{0x89, 0xf7}, Effect::Copy32, 7, 6},
    {{0x66, 0xbd, 0xcd, 0xab}, Effect::Immediate16, 5, 0xabcd},
  };
  for (uint32_t pc : {0x400ffeU, 0x900ffeU, 0xffff0ffeU}) {
    audit(context, thread, space, pc, all_gprs);
    audit(context, thread, space, pc, partial);
  }
  assert(ByteLoans > 0 && handler.Queries > 0);
  std::printf("PASS: register-only decode-to-IR granule=%zu 3 guest PCs/2 sequences/128 inputs/per-instruction oracle\n", granule);
  ActiveSpace = nullptr;
  g32_destroy(space);
}

int main() {
  FEXCore::Config::Initialize();
  FEXCore::Config::Load();
  FEXCore::Config::Set(FEXCore::Config::ConfigOption::CONFIG_IS64BIT_MODE, "0");
  FEXCore::Config::Set(FEXCore::Config::ConfigOption::CONFIG_MULTIBLOCK, "0");
  FEXCore::Config::Set(FEXCore::Config::ConfigOption::CONFIG_ENABLECODECACHEVALIDATION, "0");
  FEXCore::Config::Set(FEXCore::Config::ConfigOption::CONFIG_SMCCHECKS, "0");
  cases(0);
  cases(16384);
  cases(65536);
}
