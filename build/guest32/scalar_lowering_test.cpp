// SPDX-License-Identifier: GPL-3.0-or-later
// Closed MOV EAX,[EBX] decode/RA/emission gate, NOT a runtime memory port.
#include "Interface/Context/Context.h"
#include "Interface/Core/Frontend.h"
#include "Interface/Core/OpcodeDispatcher.h"
#include "Interface/Core/LookupCache.h"
#include "Interface/Core/Dispatcher/Dispatcher.h"
#include "Interface/Core/JIT/JITClass.h"
#include "Interface/Core/JIT/DebugData.h"
#include "Interface/IR/PassManager.h"
#include <FEXCore/Config/Config.h>
#include <FEXCore/Debug/InternalThreadState.h>
#include "native_audit_adapter.h"
#include <array>
#include <cstdio>
#include <cstring>

static uint64_t Helper;
extern "C" uint64_t FEXTestCheckedScalarLoadConfig(unsigned slot) {
  assert(slot < 3);
  return std::array<uint64_t, 3> {0x700000000, Helper, 0x500000000}[slot];
}

class Budget final : public FEXCore::CPU::Arm64Emitter {
public:
  explicit Budget(FEXCore::Context::ContextImpl& context)
    : Arm64Emitter(&context) { }
  void export_json(std::FILE* file, const FEXCore::CPU::CPUBackend::CompiledCode& code, const FEXCore::Core::DebugData& debug, uint32_t pc) const {
    using Backend = FEXCore::CPU::CPUBackend;
    using Frame = FEXCore::Core::CpuStateFrame;
    assert(code.BlockBegin && code.Size < 4096 && code.EntryPoints.size() == 1);
    const size_t entry = code.EntryPoints.at(pc) - code.BlockBegin;
    Backend::JITCodeHeader header;
    std::memcpy(&header, code.BlockBegin, sizeof(header));
    assert(entry == sizeof(header) && debug.Subblocks.size() == 1);
    const size_t end = entry + debug.Subblocks[0].HostCodeSize;
    const size_t branch = end - 4, thunk = (end + 7) & ~size_t {7};
    assert(thunk + 48 == header.OffsetToBlockTail && header.OffsetToBlockTail < code.Size);
    uint64_t next_pc, linker;
    std::memcpy(&next_pc, code.BlockBegin + thunk + 24, 8);
    std::memcpy(&linker, code.BlockBegin + thunk + 40, 8);
    assert(next_pc == uint64_t(pc) + 2 && linker);
    std::fprintf(file, "{\"pc\":%u,\"entry\":%zu,\"branch\":%zu,\"thunk\":%zu,\"code\":\"", pc, entry, branch, thunk);
    for (size_t i = 0; i < code.Size; ++i) {
      std::fprintf(file, "%02x", static_cast<unsigned char>(code.BlockBegin[i]));
    }
    std::fputs("\",\"gprs\":[", file);
    bool comma = false;
    for (auto regs : {StaticRegisters, GeneralRegisters}) {
      for (auto reg : regs) {
        std::fprintf(file, "%s%u", comma ? "," : "", reg.Idx());
        comma = true;
      }
    }
    std::fputs("],\"fprs\":[", file);
    comma = false;
    for (auto regs : {StaticFPRegisters, GeneralFPRegisters}) {
      for (auto reg : regs) {
        std::fprintf(file, "%s%u", comma ? "," : "", reg.Idx());
        comma = true;
      }
    }
    std::fprintf(file, "],\"eax\":%u,\"ebx\":%u,\"state_size\":%zu,\"spills\":[", StaticRegisters[0].Idx(), StaticRegisters[3].Idx(),
                 sizeof(Frame));
    std::fprintf(file, "[%zu,4],[%zu,8],[%zu,64],[%zu,8],[%zu,128],[%zu,8]]}\n", offsetof(Frame, State.flags[24]),
                 offsetof(Frame, State.callret_sp), offsetof(Frame, State.gregs), offsetof(Frame, State.pf_raw),
                 offsetof(Frame, State.xmm.sse.data), offsetof(Frame, State.InlineJITBlockHeader));
  }
};

static void emit(std::FILE* file, uint32_t pc) {
  using namespace FEXCore::IR;
  g32_space* space;
  assert(g32_create(0, &space) == G32_OK);
  ActiveSpace = space;
  const uint32_t base = pc & ~(G32_GRANULE - 1);
  assert(g32_reserve(space, base, G32_GRANULE) == G32_OK);
  assert(g32_commit(space, base, 2 * G32_PAGE, G32_WRITE) == G32_OK);
  constexpr std::array<uint8_t, 2> bytes {0x8b, 0x03}; // independent x86 MOV EAX,[EBX]
  assert(g32_write(space, pc, bytes.data(), bytes.size()) == G32_OK);
  assert(g32_protect(space, base, 2 * G32_PAGE, G32_EXEC) == G32_OK);
  FEXCore::HostFeatures features {};
  FEXCore::Context::ContextImpl context {features};
  Handler handler {space};
  context.SyscallHandler = &handler;
  context.Dispatcher = FEXCore::CPU::Dispatcher::Create(&context);
  FEXCore::Core::InternalThreadState thread {.CTX = &context};
  thread.LookupCache = fextl::make_unique<FEXCore::LookupCache>(&context);
  thread.PassManager = fextl::make_unique<PassManager>(&context);
  FEXCore::Core::CPUState::gdt_segment gdt[1] {};
  gdt[0].D = 1;
  thread.CurrentFrame->State.segment_arrays[0] = gdt;
  FEXCore::Frontend::Decoder decoder {&thread};
  decoder.SetupDecodeInstructionsAtEntry(&thread, pc, 1);
  decoder.DecodeLoop(reinterpret_cast<const uint8_t*>(uintptr_t(pc)));
  const auto* info = decoder.GetDecodedBlockInfo();
  assert(!info->Is64BitMode && info->Blocks.size() == 1 && info->TotalInstructionCount == 1);
  const auto& block = info->Blocks[0];
  assert(block.Entry == pc && block.Size == 2 && block.BlockStatus == FEXCore::Frontend::Decoder::DecodedBlockStatus::SUCCESS);
  OpDispatchBuilder builder {&context, &thread};
  builder.ReownOrClaimBuffer();
  builder.BeginFunction(pc, &info->Blocks, 1, false, false);
  builder.SetNewBlockIfChanged(pc);
  builder.StartNewBlock();
  builder.FlushRegisterCache(true);
  builder._GuestOpcode(0);
  builder.ResetHandledLock();
  builder.ResetDecodeFailure();
  const auto* inst = &block.DecodedInstructions[0];
  std::invoke(inst->TableInfo->OpcodeDispatcher.OpDispatch, builder, inst);
  assert(!builder.HadDecodeFailure() && !builder.HasHandledLock());
  builder.FinishOp(pc + 2, true);
  builder.Finalize();
  FEXCore::CPU::Arm64JITCore backend {&context, &thread};
  thread.PassManager->Finalize();
  thread.PassManager->Run(&builder);
  auto ir = builder.ViewIR();
  assert(ir.PostRA() && ir.GetHeader()->OriginalRIP == pc && ir.GetHeader()->NumHostInstructions == 1);
  unsigned loads = 0, writes = 0, exits = 0;
  for (auto [node, header] : ir.GetAllCode()) {
    switch (header->Op) {
    case OP_LOADMEMTSO: {
      const auto* op = ir.GetOp<IROp_LoadMemTSO>(node);
      assert(op->Class == RegClass::GPR && header->Size == OpSize::i32Bit && op->Offset.IsInvalid());
      assert(op->Addr.IsImmediate() && PhysicalRegister(op->Addr) == PhysicalRegister(RegClass::GPRFixed, 3));
      assert(PhysicalRegister(node) == PhysicalRegister(RegClass::GPRFixed, 0));
      ++loads;
      break;
    }
    case OP_EXITFUNCTION: {
      const auto* op = ir.GetOp<IROp_ExitFunction>(node);
      assert(header->Size == OpSize::i32Bit && op->Hint == BranchHint::None && op->CallReturnAddress.IsInvalid() &&
             op->CallReturnBlock.IsInvalid() && !op->PatchSiteAddress && !op->PatchSiteSize);
      assert(!op->NewRIP.IsImmediate());
      const auto* target = ir.GetOp<IROp_InlineEntrypointOffset>(ir.GetNode(op->NewRIP));
      assert(target->Header.Op == OP_INLINEENTRYPOINTOFFSET && target->Offset == 2);
      ++exits;
      break;
    }
    case OP_GUESTOPCODE: assert(ir.GetOp<IROp_GuestOpcode>(node)->GuestEntryOffset == 0); break;
    case OP_CODEBLOCK:
    case OP_BEGINBLOCK:
    case OP_ENDBLOCK: break;
    case OP_INLINEENTRYPOINTOFFSET:
      assert(header->Size == OpSize::i32Bit && ir.GetOp<IROp_InlineEntrypointOffset>(node)->Offset == 2);
      break;
    case OP_STOREREGISTER: {
      const auto* op = ir.GetOp<IROp_StoreRegister>(node);
      assert(PhysicalRegister(node) == PhysicalRegister(RegClass::GPRFixed, 0));
      assert(PhysicalRegister(op->Value) == PhysicalRegister(RegClass::GPRFixed, 0));
      ++writes;
      break;
    }
    default:
      std::fprintf(stderr, "unexpected closed graph op %u\n", unsigned(header->Op));
      assert(false && "unexpected closed checked-load graph");
    }
  }
  assert(loads == 1 && writes <= 1 && exits == 1);
  FEXCore::Core::DebugData debug;
  auto code = backend.CompileCode(pc, 2, true, &ir, &debug, false);
  Budget budget {context};
  budget.export_json(file, code, debug, pc);
  std::array<uint8_t, 2> unchanged;
  assert(g32_fetch(space, pc, unchanged.data(), 2) == G32_OK && unchanged == bytes);
  builder.DelayedDisownBuffer();
  decoder.DelayedDisownBuffer();
  builder.ValidateDisownedOrFree();
  decoder.ValidateDisownedOrFree();
  ActiveSpace = nullptr;
  g32_destroy(space);
}

int main(int argc, char** argv) {
  assert(argc == 3);
  Helper = std::strtoull(argv[1], nullptr, 0);
  FEXCore::Config::Initialize();
  FEXCore::Config::Load();
  FEXCore::Config::Set(FEXCore::Config::ConfigOption::CONFIG_IS64BIT_MODE, "0");
  FEXCore::Config::Set(FEXCore::Config::ConfigOption::CONFIG_MULTIBLOCK, "0");
  FEXCore::Config::Set(FEXCore::Config::ConfigOption::CONFIG_ENABLECODECACHEVALIDATION, "0");
  FEXCore::Config::Set(FEXCore::Config::ConfigOption::CONFIG_SMCCHECKS, "0");
  FEXCore::Config::Set(FEXCore::Config::ConfigOption::CONFIG_O0, "0");
  assert(!std::getenv("MADEIRA_NO_DFE"));
  auto* file = std::fopen(argv[2], "w");
  assert(file);
  for (uint32_t pc : {0x400fffU, 0x900fffU, 0xffff0fffU}) {
    emit(file, pc);
  }
  assert(std::fclose(file) == 0);
  std::puts("PASS real separated decoder/default RA/checked LoadMemTSO lowering: 3 guest PCs, MOV EAX,[EBX]");
}
