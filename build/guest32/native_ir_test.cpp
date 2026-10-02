// SPDX-License-Identifier: GPL-3.0-or-later
// Real decode/dispatch audit, optionally through RA/ARM emission. No execution.
#include "Interface/Context/Context.h"
#include "Interface/Core/Frontend.h"
#include "Interface/Core/OpcodeDispatcher.h"
#include "Interface/IR/PassManager.h"
#include "Interface/IR/Passes.h"
#ifdef FEX_AUDIT_ALLOCATE
#include "Interface/IR/Passes/RegisterAllocationPass.h"
#include "Interface/Core/ArchHelpers/Arm64Emitter.h"
#endif
#ifdef FEX_AUDIT_EMIT
#include "Interface/Core/JIT/JITClass.h"
#include "Interface/Core/JIT/DebugData.h"
#include "native_code_oracle.h"
#endif
#include "Interface/Core/LookupCache.h"
#include "Interface/Core/Dispatcher/Dispatcher.h"
#include <FEXCore/Config/Config.h>
#include <FEXCore/Debug/InternalThreadState.h>
#include "native_audit_adapter.h"
#include <array>
#include <cstdio>
#include <cstring>
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

#ifdef FEX_AUDIT_ALLOCATE
// Obtain the real native ARM backend's 32-bit register budget without creating
// a JIT, emitting code, or hardcoding counts from another platform's ABI.
class RegisterBudget final : public FEXCore::CPU::Arm64Emitter {
public:
  explicit RegisterBudget(FEXCore::Context::ContextImpl& context)
    : Arm64Emitter(&context) { }
  void configure(RegisterAllocationPass& pass) const {
    pass.AddRegisters(RegClass::GPR, GeneralRegisters.size());
    pass.AddRegisters(RegClass::GPRFixed, StaticRegisters.size());
    pass.AddRegisters(RegClass::FPR, GeneralFPRegisters.size());
    pass.AddRegisters(RegClass::FPRFixed, StaticFPRegisters.size());
    pass.SetNumPairRegs(PairRegisters);
  }
#ifdef FEX_AUDIT_EMIT
  CodeOracle::GuestMap guest_map() const {
    CodeOracle::GuestMap result;
    for (unsigned i = 0; i < result.size(); ++i) {
      result[i] = StaticRegisters[i].Idx();
    }
    return result;
  }
  CodeOracle::AllowedRegisters allowed_registers() const {
    CodeOracle::AllowedRegisters result {};
    for (auto reg : guest_map()) {
      result[reg] = true;
    }
    for (auto reg : GeneralRegisters) {
      assert(reg.Idx() < result.size());
      result[reg.Idx()] = true;
    }
    result[FEXCore::CPU::TMP1.Idx()] = true;
    assert(!result[FEXCore::CPU::STATE.Idx()]);
    return result;
  }
#endif
  bool accepts(PhysicalRegister reg) const {
    return (reg.AsRegClass() == RegClass::GPR && reg.Reg < GeneralRegisters.size()) || (reg.AsRegClass() == RegClass::GPRFixed && reg.Reg < 8);
  }
};
static const RegisterBudget* ActiveBudget;
#endif

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
  const bool allocated = ir.PostRA();
#ifndef FEX_AUDIT_ALLOCATE
  assert(!allocated);
#endif
  assert(ir.GetHeader()->OriginalRIP == pc);
  assert(ir.GetHeader()->NumHostInstructions == sequence.size());
  Registers actual = input;
  Registers expected = input;
  std::vector<uint64_t> values(ir.GetSSACount());
  std::vector<bool> valid(ir.GetSSACount());
  // SSA before RA; a bounded physical register file after RA. Fixed registers
  // start with architectural input, while temporary registers start invalid.
  std::array<uint64_t, 256> physical {};
  std::array<bool, 256> initialized {};
  for (unsigned reg = 0; reg < input.size(); ++reg) {
    auto index = PhysicalRegister(RegClass::GPRFixed, reg).Raw;
    physical[index] = input[reg];
    initialized[index] = true;
  }
  auto physical_index = [&](PhysicalRegister reg) {
#ifdef FEX_AUDIT_ALLOCATE
    assert(ActiveBudget && ActiveBudget->accepts(reg));
#else
    (void)reg;
    std::abort();
#endif
    return reg.Raw;
  };
  auto read = [&](OrderedNodeWrapper wrapper) {
    if (allocated && wrapper.IsImmediate()) {
      assert(!wrapper.IsInvalid());
      auto index = physical_index(PhysicalRegister(wrapper));
      assert(initialized[index]);
      return physical[index];
    }
    if (allocated) {
      // Inline guest-PC literals stay IR references, not physical registers.
      assert(ir.GetOp<IROp_Header>(ir.GetNode(wrapper))->Op == OP_INLINEENTRYPOINTOFFSET);
    }
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
      // RA can coalesce/hoist stores across debug markers. Check complete
      // prefixes at ExitFunction instead; retain every boundary check pre-RA.
      if (!allocated) {
        assert(actual == expected);
      }
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
      if (!allocated) {
        assert(markers && stores + 1 == markers && dest.Reg == sequence[markers - 1].Dest);
      }
      actual[dest.Reg] = static_cast<uint32_t>(read(op->Value));
      if (allocated) {
        physical[dest.Raw] = actual[dest.Reg];
        initialized[dest.Raw] = true;
      }
      ++stores;
      break;
    }
    case OP_COPY: {
      assert(allocated && header->Size == OpSize::i64Bit);
      values[id] = read(ir.GetOp<IROp_Copy>(node)->Source);
      valid[id] = true;
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
      assert(actual == expected && (allocated || stores == sequence.size()));
      ++exits;
      break;
    }
    default:
      auto name = GetName(header->Op);
      std::fprintf(stderr, "Unexpected IR op: %.*s\n", int(name.size()), name.data());
      std::abort();
    }
    if (allocated && valid[id] && GetHasDest(header->Op)) {
      auto index = physical_index(PhysicalRegister(node));
      // i32 ARM register writes zero-extend; i64 bit-inserts retain all bits.
      physical[index] = header->Size == OpSize::i32Bit ? uint32_t(values[id]) : values[id];
      initialized[index] = true;
      auto reg = PhysicalRegister(node);
      if (reg.AsRegClass() == RegClass::GPRFixed) {
        actual[reg.Reg] = uint32_t(physical[index]);
      }
    }
  }
  assert(actual == expected && markers == sequence.size() && (allocated || stores == sequence.size()));
  assert(blocks == 1 && begins == 1 && ends == 1 && exits == 1);
}

#ifdef FEX_AUDIT_EMIT
// Check the entire bounded block layout, not just its debug-marker addresses.
// The body is analyzed from machine words, independently of the IR checker.
static void verify_code(const FEXCore::Context::ContextImpl& context, const FEXCore::CPU::CPUBackend::CompiledCode& code,
                        const FEXCore::Core::DebugData& debug, uint32_t pc, const Sequence& sequence, const std::vector<Registers>& inputs,
                        const RegisterBudget& budget) {
  using Backend = FEXCore::CPU::CPUBackend;
  assert(code.BlockBegin && code.Size && code.Size % 16 == 0);
  assert(code.EntryPoints.size() == 1 && code.EntryPoints.at(pc) == code.BlockBegin + sizeof(Backend::JITCodeHeader));
  assert(debug.HostCodeSize == code.Size && debug.Subblocks.size() == 1);
  auto load = [&]<typename T>(size_t offset) {
    assert(offset <= code.Size && sizeof(T) <= code.Size - offset);
    T result;
    std::memcpy(&result, code.BlockBegin + offset, sizeof(T));
    return result;
  };
  const auto header = load.operator()<Backend::JITCodeHeader>(0);
  const auto tail = load.operator()<Backend::JITCodeTail>(header.OffsetToBlockTail);
  size_t guest_size = 0;
  for (const auto& inst : sequence) {
    guest_size += inst.Bytes.size();
  }
  assert(tail.Size == code.Size && tail.RIP == pc && tail.GuestSize == guest_size);
  assert(tail.SingleInst == (sequence.size() == 1) && tail.SpinLockFutex == 0);
  assert(tail.NumberOfRIPEntries == sequence.size() + 1 && debug.GuestOpcodes.size() == tail.NumberOfRIPEntries);
  assert(tail.OffsetToRIPEntries == sizeof(tail));
  // Native non-EC entry: ADR X0, header; STR X0, [STATE, InlineJITBlockHeader].
  // TF, interrupts and spills are deliberately absent from this bounded gate.
  const size_t entry = sizeof(header);
  assert(load.operator()<uint32_t>(entry) == 0x10ffffe0); // ADR X0, #-4
  const auto state_offset = offsetof(FEXCore::Core::CPUState, InlineJITBlockHeader);
  assert(state_offset % 8 == 0 && state_offset / 8 < 4096);
  assert(load.operator()<uint32_t>(entry + 4) == (0xf9000000U | (state_offset / 8 << 10) | (FEXCore::CPU::STATE.Idx() << 5)));
  const size_t body_begin = entry + 8;
  const auto& block = debug.Subblocks[0];
  assert(block.HostCodeOffset == entry);
  const size_t body_end = size_t(block.HostCodeOffset) + block.HostCodeSize;
  assert(body_end >= body_begin + 4 && body_end <= header.OffsetToBlockTail && body_end % 4 == 0);
  assert(debug.GuestOpcodes[0].GuestEntryOffset == 0 && debug.GuestOpcodes[0].HostEntryOffset == ptrdiff_t(entry));
  size_t guest_offset = 0;
  size_t last_host = body_begin;
  for (size_t i = 0; i < sequence.size(); ++i) {
    const auto& mark = debug.GuestOpcodes[i + 1];
    assert(mark.GuestEntryOffset == guest_offset && mark.HostEntryOffset >= ptrdiff_t(last_host));
    assert(mark.HostEntryOffset <= ptrdiff_t(body_end - 4) && mark.HostEntryOffset % 4 == 0);
    last_host = mark.HostEntryOffset;
    guest_offset += sequence[i].Bytes.size();
  }
  assert(debug.GuestOpcodes[1].HostEntryOffset == ptrdiff_t(body_begin));
  // One final B goes to the aligned unlinked exit thunk. No other body branch
  // or memory instruction is accepted by the register-word oracle below.
  const size_t branch = body_end - 4;
  const size_t thunk = (body_end + 7) & ~size_t {7};
  assert(load.operator()<uint32_t>(branch) == (0x14000000U | ((thunk - branch) / 4)));
  assert(header.OffsetToBlockTail == thunk + 48);
  if (thunk != body_end) {
    assert(thunk - body_end == 4 && load.operator()<uint32_t>(body_end) == 0); // Align padding, never executed
  }
  assert(load.operator()<uint32_t>(thunk) == 0x14000002);      // B +8
  assert(load.operator()<uint32_t>(thunk + 4) == 0xd61f0000);  // BR X0 (linked form, not taken initially)
  assert(load.operator()<uint32_t>(thunk + 8) == 0x58000100);  // LDR X0, linker literal at +32
  assert(load.operator()<uint32_t>(thunk + 12) == 0xd63f0000); // BLR X0
  assert(load.operator()<uint64_t>(thunk + 16) == 0);          // Initially unlinked HostCode
  assert(load.operator()<uint64_t>(thunk + 24) == uint64_t(pc) + guest_size);
  assert(load.operator()<int64_t>(thunk + 32) == int64_t(branch) - int64_t(thunk));
  assert(load.operator()<uint64_t>(thunk + 40) == context.Dispatcher->GetExitFunctionLinkerAddress());
  assert(context.Dispatcher->GetExitFunctionLinkerAddress() != 0);
  // Independently decode just the bounded small-delta RIP metadata formats
  // used here. Larger/unexpected encodings fail rather than being skipped.
  size_t encoded = header.OffsetToBlockTail + tail.OffsetToRIPEntries;
  size_t host_delta_sum = 0, guest_delta_sum = 0;
  for (const auto& mark : debug.GuestOpcodes) {
    const uint8_t first = load.operator()<uint8_t>(encoded++);
    if (!(first & 0x80)) {
      host_delta_sum += ((first & 15) + 1) * 4;
      guest_delta_sum += ((first >> 4) & 7) + 1;
    } else {
      assert((first & 0xc0) == 0x80 && (first & 0x20) == 0);
      const auto host = load.operator()<int8_t>(encoded++);
      assert(host >= 0);
      host_delta_sum += unsigned(host) * 4;
      guest_delta_sum += first & 63;
    }
    assert(encoded <= code.Size && host_delta_sum == size_t(mark.HostEntryOffset) && guest_delta_sum == mark.GuestEntryOffset);
  }
  std::vector<uint32_t> words;
  for (size_t offset = body_begin; offset < branch; offset += 4) {
    words.push_back(load.operator()<uint32_t>(offset));
  }
  assert(!words.empty());
  const auto map = budget.guest_map();
  const auto allowed = budget.allowed_registers();
  for (const auto& input : inputs) {
    Registers expected = input;
    for (const auto& inst : sequence) {
      expected_effect(expected, inst);
    }
    assert(CodeOracle::analyze(words, input, map, allowed) == expected);
  }
}
#endif

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
    // The same per-instruction lifecycle as ContextImpl::GenerateIR. Optional
    // RA/backend checks run separately below; no FEX method is replaced.
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
  std::vector<Registers> inputs;
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
    inputs.push_back(input);
  }
#ifdef FEX_AUDIT_ALLOCATE
  auto register_ops = [](const IRListView& view) {
    size_t count = 0;
    for (auto [node, header] : view.GetAllCode()) {
      (void)node;
      count += header->Op == OP_LOADREGISTER || header->Op == OP_STOREREGISTER;
    }
    return count;
  };
  const auto original_register_ops = register_ops(ir);
  assert(original_register_ops >= sequence.size());
#ifdef FEX_AUDIT_EMIT
  assert(thread.PassManager);
  auto& manager = *thread.PassManager;
#else
  PassManager manager {&context};
#endif
  auto* allocation = manager.GetPass<RegisterAllocationPass>("RA");
  assert(allocation && manager.HasPass("IRValidation"));
  RegisterBudget budget {context};
#ifdef FEX_AUDIT_EMIT
  // The real backend configures RA itself and retains its pass for emission.
  FEXCore::CPU::Arm64JITCore backend {&context, &thread};
#else
  budget.configure(*allocation);
#endif
  ActiveBudget = &budget;
  manager.Finalize();
  manager.Run(&builder);
  auto allocated_ir = builder.ViewIR();
  assert(allocated_ir.PostRA());
  // Every prefix must actually exercise static-register coalescing, not just
  // relabel an unchanged SSA graph as post-RA and accidentally recheck it.
  assert(register_ops(allocated_ir) < original_register_ops);
  for (const auto& input : inputs) {
    verify_ir(allocated_ir, pc, sequence, input);
  }
#ifdef FEX_AUDIT_EMIT
  FEXCore::Core::DebugData debug;
  auto code = backend.CompileCode(pc, bytes.size(), sequence.size() == 1, &allocated_ir, &debug, false);
  verify_code(context, code, debug, pc, sequence, inputs, budget);
#endif
  ActiveBudget = nullptr;
#endif
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
#ifdef FEX_AUDIT_EMIT
  context.Dispatcher = FEXCore::CPU::Dispatcher::Create(&context);
#endif
  FEXCore::Core::InternalThreadState thread {.CTX = &context};
#ifdef FEX_AUDIT_EMIT
  thread.LookupCache = fextl::make_unique<FEXCore::LookupCache>(&context);
  // NonMovableUniquePtr assignment does not release a previous object. Own one
  // manager per thread, as the runtime does, rather than overwriting per prefix.
  thread.PassManager = fextl::make_unique<PassManager>(&context);
#endif
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
    for (const auto* sequence : {&all_gprs, &partial}) {
#ifdef FEX_AUDIT_ALLOCATE
      for (size_t length = 1; length <= sequence->size(); ++length) {
        audit(context, thread, space, pc, Sequence(sequence->begin(), sequence->begin() + length));
      }
#else
      audit(context, thread, space, pc, *sequence);
#endif
    }
  }
  assert(ByteLoans > 0 && handler.Queries > 0);
#ifdef FEX_AUDIT_EMIT
  std::printf("PASS: real ARM emission granule=%zu 3 guest PCs/16 prefixes/128 inputs/machine-register-and-exit oracle\n", granule);
#elif defined(FEX_AUDIT_ALLOCATE)
  std::printf("PASS: optimized/allocated register IR granule=%zu 3 guest PCs/16 prefixes/128 inputs/pre-and-post-RA oracle\n", granule);
#else
  std::printf("PASS: register-only decode-to-IR granule=%zu 3 guest PCs/2 sequences/128 inputs/per-instruction oracle\n", granule);
#endif
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
  FEXCore::Config::Set(FEXCore::Config::ConfigOption::CONFIG_O0, "0");
  assert(!std::getenv("MADEIRA_NO_DFE"));
  cases(0);
  cases(16384);
  cases(65536);
}
