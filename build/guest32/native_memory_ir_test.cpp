// SPDX-License-Identifier: GPL-3.0-or-later
// Offline scalar-memory IR inspection, NOT execution or a runtime bridge.
#include "Interface/Context/Context.h"
#include "Interface/Core/Frontend.h"
#include "Interface/Core/OpcodeDispatcher.h"
#include "Interface/Core/LookupCache.h"
#include "Interface/Core/Dispatcher/Dispatcher.h"
#include "Interface/IR/Passes.h"
#include "Interface/IR/PassManager.h"
#ifdef FEX_AUDIT_ALLOCATE
#include "Interface/IR/Passes/RegisterAllocationPass.h"
#include "Interface/Core/ArchHelpers/Arm64Emitter.h"
#endif
#include <FEXCore/Config/Config.h>
#include <FEXCore/Debug/InternalThreadState.h>
#include "native_audit_adapter.h"
#include <array>
#include <cstdio>
#include <cstring>
#include <functional>
#include <stdexcept>
#include <vector>
using namespace FEXCore::IR;
using Registers = std::array<uint32_t, 8>;
static unsigned Controls, AllocatedControls;

static void require(bool condition, const char* message) {
  if (!condition) {
    throw std::runtime_error(message);
  }
}
#ifdef FEX_AUDIT_ALLOCATE
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
  bool accepts_vector(PhysicalRegister reg) const {
    return reg.AsRegClass() == RegClass::FPR && reg.Reg < GeneralFPRegisters.size();
  }
  bool accepts(PhysicalRegister reg) const {
    return (reg.AsRegClass() == RegClass::GPR && reg.Reg < GeneralRegisters.size()) || (reg.AsRegClass() == RegClass::GPRFixed && reg.Reg < 8);
  }
};
static const RegisterBudget* ActiveBudget;
#endif
#include "native_context_ir_oracle.h"

template<typename Field>
static Field packed_read(const void* field) {
  Field value;
  std::memcpy(&value, field, sizeof(value));
  return value;
}

template<typename Field, typename Check>
static void reject_mutation(void* field, Field replacement, const char* expected_error, Check check) {
  // IROps are packed; after RA some fields are not naturally aligned. Never
  // bind them to a typed reference or dereference a pointer outside the struct.
  const auto saved = packed_read<Field>(field);
  std::memcpy(field, &replacement, sizeof(replacement));
  bool rejected = false;
  try {
    check();
  } catch (const std::runtime_error& error) {
    rejected = std::strcmp(error.what(), expected_error) == 0;
  }
  std::memcpy(field, &saved, sizeof(saved));
  require(rejected, "accepted post-RA corruption or wrong rejection");
  check(); // Prove restoration, not just rejection.
  ++AllocatedControls;
}

enum class Address { Base, Displacement, SIB, Narrow16, FS, Absolute };
struct Case {
  std::vector<uint8_t> Bytes;
  Address Form;
  unsigned Width;
  bool Store;
  bool ControlWord = false;
  bool NativeSwap = false;
};
// Independently specified x86 formulas, not derived from FEX operands/IR.
static uint32_t expected_address(const Case& test, const Registers& regs, uint32_t fs) {
  switch (test.Form) {
  case Address::Base: return regs[3];
  case Address::Displacement: return regs[3] - 16;
  case Address::SIB: return regs[3] + regs[6] * 4 - 16;
  case Address::Narrow16: return uint16_t(regs[3] + regs[6] - 16);
  case Address::FS: return regs[3] + fs;
  case Address::Absolute: return 0x200ffe;
  }
  std::abort();
}

struct Access {
  uint32_t Address;
  unsigned Width;
  bool Store;
  uint32_t Value;
};
// Pure SSA address/value inspection. Loaded guest data is a marked sentinel;
// there is no read of an IR-provided native address and no FEX interpreter.
// LoadContext denotes implicit NATIVE CPU-state storage; its loaded segment
// base/control word is guest DATA, not a native pointer to translate.
static Access inspect(const IRListView& ir, uint32_t pc, const Case& test, const Registers& input, uint32_t fs) {
  const bool allocated = ir.PostRA();
  require(ir.GetHeader()->OriginalRIP == pc && ir.GetHeader()->NumHostInstructions == 1, "IR header");
  std::vector<uint64_t> values(ir.GetSSACount());
  std::vector<bool> valid(ir.GetSSACount());
  Registers regs = input;
  FEXCore::Core::CPUState native_state {};
  native_state.fs_cached = fs;
  native_state.FCW = 0x037f;
  require(reinterpret_cast<uintptr_t>(&native_state) > UINT32_MAX, "native CPU-state storage must stay high");
  std::array<uint64_t, 256> physical {};
  std::array<bool, 256> initialized {};
  for (unsigned reg = 0; reg < input.size(); ++reg) {
    auto index = PhysicalRegister(RegClass::GPRFixed, reg).Raw;
    physical[index] = input[reg];
    initialized[index] = true;
  }
  auto physical_index = [&](PhysicalRegister reg) {
#ifdef FEX_AUDIT_ALLOCATE
    require(ActiveBudget && ActiveBudget->accepts(reg), "physical register budget");
    return reg.Raw;
#else
    (void)reg;
    throw std::runtime_error("unexpected physical register");
    return uint8_t {};
#endif
  };
  auto read = [&](OrderedNodeWrapper ref) {
    require(!ref.IsInvalid(), "invalid SSA operand");
    if (allocated && ref.IsImmediate()) {
      auto index = physical_index(PhysicalRegister(ref));
      require(initialized[index], "uninitialized physical register");
      return physical[index];
    }
    require(!ref.IsImmediate(), "unexpected immediate operand");
    auto id = ir.GetID(ir.GetNode(ref)).Value;
    require(id < values.size() && valid[id], "uninitialized SSA operand");
    return values[id];
  };
  unsigned memory = 0, contexts = 0, exits = 0, markers = 0, blocks = 0, begins = 0, ends = 0, stores = 0;
  Access access {};
  constexpr uint32_t loaded = 0x89abcdef;
  for (auto [node, header] : ir.GetAllCode()) {
    auto id = ir.GetID(node).Value;
    auto set = [&](uint64_t value) {
      require(id < values.size() && !valid[id], "SSA destination");
      values[id] = value;
      valid[id] = true;
    };
    switch (header->Op) {
    case OP_CODEBLOCK: ++blocks; break;
    case OP_BEGINBLOCK: ++begins; break;
    case OP_ENDBLOCK: ++ends; break;
    case OP_GUESTOPCODE:
      require(ir.GetOp<IROp_GuestOpcode>(node)->GuestEntryOffset == 0, "guest marker");
      ++markers;
      break;
    case OP_CONSTANT: set(ir.GetOp<IROp_Constant>(node)->Constant); break;
    case OP_INLINECONSTANT: set(ir.GetOp<IROp_InlineConstant>(node)->Constant); break;
    case OP_COPY:
      require(allocated && header->Size == OpSize::i64Bit, "register copy");
      set(read(ir.GetOp<IROp_Copy>(node)->Source));
      break;
    case OP_LOADREGISTER: {
      auto* op = ir.GetOp<IROp_LoadRegister>(node);
      require(op->Class == RegClass::GPR && op->Reg < regs.size() && header->Size == OpSize::i32Bit, "register load");
      set(regs[op->Reg]);
      break;
    }
    case OP_LOADCONTEXT: {
      auto* op = ir.GetOp<IROp_LoadContext>(node);
      require(op->Class == RegClass::GPR, "context class");
      if (test.Form == Address::FS) {
        require(op->Offset == offsetof(FEXCore::Core::CPUState, fs_cached) && header->Size == OpSize::i32Bit, "native segment context");
      } else {
        require(test.ControlWord && op->Offset == offsetof(FEXCore::Core::CPUState, FCW) && header->Size == OpSize::i16Bit, "native "
                                                                                                                            "control-word "
                                                                                                                            "context");
      }
      // This checked native offset is deliberately NOT passed to g32. The
      // contained segment/control value, unlike its storage address, is guest data.
      uint32_t native_value = 0;
      std::memcpy(&native_value, reinterpret_cast<const uint8_t*>(&native_state) + op->Offset, OpSizeToSize(header->Size));
      set(native_value);
      ++contexts;
      break;
    }
    case OP_ADD: {
      auto* op = ir.GetOp<IROp_Add>(node);
      require(header->Size == OpSize::i32Bit, "address add width");
      set(uint32_t(read(op->Src1) + read(op->Src2)));
      break;
    }
    case OP_SUB: {
      auto* op = ir.GetOp<IROp_Sub>(node);
      require(header->Size == OpSize::i32Bit, "address sub width");
      set(uint32_t(read(op->Src1) - read(op->Src2)));
      break;
    }
    case OP_ADDSHIFT: {
      auto* op = ir.GetOp<IROp_AddShift>(node);
      require(header->Size == OpSize::i32Bit && op->Shift == ShiftType::LSL && op->ShiftAmount <= 3, "address scale");
      set(uint32_t(read(op->Src1) + (read(op->Src2) << op->ShiftAmount)));
      break;
    }
    case OP_BFE: {
      auto* op = ir.GetOp<IROp_Bfe>(node);
      require(header->Size == OpSize::i32Bit && op->Width == 16 && op->lsb == 0, "16-bit address truncation");
      set(uint16_t(read(op->Src)));
      break;
    }
    case OP_BFI: {
      auto* op = ir.GetOp<IROp_Bfi>(node);
      require(header->Size == OpSize::i64Bit && (op->Width == 8 || op->Width == 16) && op->lsb == 0, "partial load insert");
      auto mask = (uint64_t {1} << op->Width) - 1;
      set((read(op->Dest) & ~mask) | (read(op->Src) & mask));
      break;
    }
    case OP_LOADMEMTSO:
    case OP_STOREMEMTSO: {
      const bool store = header->Op == OP_STOREMEMTSO;
      OrderedNodeWrapper addr, offset;
      uint32_t value = 0;
      if (store) {
        auto* op = ir.GetOp<IROp_StoreMemTSO>(node);
        require(op->Class == RegClass::GPR && op->OffsetType == MemOffsetType::SXTX && op->OffsetScale == 1, "store addressing");
        addr = op->Addr;
        offset = op->Offset;
        value = read(op->Value);
      } else {
        auto* op = ir.GetOp<IROp_LoadMemTSO>(node);
        require(op->Class == RegClass::GPR && op->OffsetType == MemOffsetType::SXTX && op->OffsetScale == 1, "load addressing");
        addr = op->Addr;
        offset = op->Offset;
        set(loaded & (UINT32_MAX >> ((4 - test.Width) * 8)));
      }
      require(offset.IsInvalid(), "unclassified memory offset");
      auto address = read(addr);
      require(address <= UINT32_MAX && address == expected_address(test, input, fs), "guest effective address");
      require(OpSizeToSize(header->Size) == test.Width && store == test.Store, "guest access width/direction");
      const auto mask = UINT32_MAX >> ((4 - test.Width) * 8);
      require(!store || (value & mask) == ((test.ControlWord ? 0x037f : input[0]) & mask), "guest store value");
      access = {uint32_t(address), test.Width, store, value & mask};
      ++memory;
      break;
    }
    case OP_STOREREGISTER: {
      auto* op = ir.GetOp<IROp_StoreRegister>(node);
      PhysicalRegister dest {node};
      require(!test.Store && dest.AsRegClass() == RegClass::GPRFixed && dest.Reg == 0 && header->Size == OpSize::i32Bit, "load "
                                                                                                                         "destination");
      regs[0] = read(op->Value);
      if (allocated) {
        physical[dest.Raw] = regs[0];
        initialized[dest.Raw] = true;
      }
      ++stores;
      break;
    }
    case OP_INLINEENTRYPOINTOFFSET: {
      auto* op = ir.GetOp<IROp_InlineEntrypointOffset>(node);
      require(header->Size == OpSize::i32Bit && op->Offset == int64_t(test.Bytes.size()), "guest exit offset");
      set(uint64_t(pc) + test.Bytes.size());
      break;
    }
    case OP_EXITFUNCTION: {
      auto* op = ir.GetOp<IROp_ExitFunction>(node);
      require(read(op->NewRIP) == uint64_t(pc) + test.Bytes.size() && header->Size == OpSize::i32Bit && op->Hint == BranchHint::None &&
                op->CallReturnAddress.IsInvalid() && op->CallReturnBlock.IsInvalid() && !op->PatchSiteAddress && !op->PatchSiteSize,
              "guest exit");
      ++exits;
      break;
    }
    default:
      std::fprintf(stderr, "unclassified IR operation: %.*s\n", int(GetName(header->Op).size()), GetName(header->Op).data());
      throw std::runtime_error("unclassified IR operation");
    }
    if (allocated && valid[id] && GetHasDest(header->Op)) {
      auto index = physical_index(PhysicalRegister(node));
      physical[index] = header->Size == OpSize::i32Bit ? uint32_t(values[id]) : values[id];
      initialized[index] = true;
      auto reg = PhysicalRegister(node);
      if (reg.AsRegClass() == RegClass::GPRFixed) {
        regs[reg.Reg] = uint32_t(physical[index]);
      }
    }
  }
  Registers expected = input;
  if (!test.Store) {
    auto mask = UINT32_MAX >> ((4 - test.Width) * 8);
    expected[0] = (input[0] & ~mask) | (loaded & mask);
  }
  require(regs == expected && (allocated || stores == unsigned(!test.Store)), "load register result");
  const unsigned expected_contexts = test.Form == Address::FS ? (!allocated && test.Store ? 2 : 1) : unsigned(test.ControlWord);
  require(memory == 1 && contexts == expected_contexts && exits == 1 && markers == 1 && blocks == 1 && begins == 1 && ends == 1, "IR "
                                                                                                                                 "census");
  return access;
}

// The IR address is handed to the EXISTING checked C memory API only here,
// outside FEX. The expected denial is independently computed for this fixture.
static void check_access(g32_space* space, const Access& access) {
  constexpr uint32_t base = 0x200000;
  auto expected = G32_ACCESS;
  if (access.Address >= base && uint64_t(access.Address) + access.Width <= base + 2 * G32_PAGE) {
    expected = access.Store && uint64_t(access.Address) + access.Width > base + G32_PAGE ? G32_ACCESS : G32_OK;
  }
  if (access.Address < G32_GRANULE || uint64_t(access.Address) + access.Width > (uint64_t {1} << 32)) {
    expected = G32_RANGE;
  }
  std::array<uint8_t, 2 * G32_PAGE> before, after;
  assert(g32_read(space, base, before.data(), before.size()) == G32_OK);
  uint32_t value = 0xa5a5a5a5;
  g32_result result;
  if (access.Store) {
    value = access.Value;
    result = g32_write(space, access.Address, &value, access.Width);
  } else {
    result = g32_read(space, access.Address, &value, access.Width);
  }
  require(result == expected, "checked adapter access result");
  assert(g32_read(space, base, after.data(), after.size()) == G32_OK);
  if (result != G32_OK) {
    require(before == after && (access.Store || value == 0xa5a5a5a5), "failed access changed bytes/output");
  } else if (access.Store) {
    for (unsigned i = 0; i < access.Width; ++i) {
      before[access.Address - base + i] = access.Value >> (i * 8);
    }
    require(before == after, "store changed unrelated bytes");
  } else {
    require(before == after, "load changed bytes");
    uint32_t wanted = 0xa5a5a5a5;
    for (unsigned i = 0; i < access.Width; ++i) {
      wanted = (wanted & ~(0xffU << (i * 8))) | (uint32_t(before[access.Address - base + i]) << (i * 8));
    }
    require(value == wanted, "checked load bytes");
  }
}

static void
audit(FEXCore::Context::ContextImpl& context, FEXCore::Core::InternalThreadState& thread, g32_space* space, uint32_t pc, const Case& test) {
  const uint32_t base = pc & ~(G32_GRANULE - 1);
  assert(g32_reserve(space, base, G32_GRANULE) == G32_OK);
  assert(g32_commit(space, base, 2 * G32_PAGE, G32_WRITE) == G32_OK);
  assert(g32_write(space, pc, test.Bytes.data(), test.Bytes.size()) == G32_OK);
  assert(g32_protect(space, base, 2 * G32_PAGE, G32_EXEC) == G32_OK);
  FEXCore::Frontend::Decoder decoder {&thread};
  decoder.SetupDecodeInstructionsAtEntry(&thread, pc, 1);
  decoder.DecodeLoop(reinterpret_cast<const uint8_t*>(uintptr_t(pc)));
  const auto* info = decoder.GetDecodedBlockInfo();
  assert(!info->Is64BitMode && info->Blocks.size() == 1 && info->TotalInstructionCount == 1);
  const auto& block = info->Blocks[0];
  assert(block.BlockStatus == FEXCore::Frontend::Decoder::DecodedBlockStatus::SUCCESS);
  assert(block.Entry == pc && block.Size == test.Bytes.size());
  OpDispatchBuilder builder {&context, &thread};
  builder.ReownOrClaimBuffer();
  builder.BeginFunction(pc, &info->Blocks, 1, false, false);
  builder.SetNewBlockIfChanged(pc);
  builder.StartNewBlock();
  const auto* inst = &block.DecodedInstructions[0];
  builder.FlushRegisterCache(true);
  builder._GuestOpcode(0);
  builder.ResetHandledLock();
  builder.ResetDecodeFailure();
  std::invoke(inst->TableInfo->OpcodeDispatcher.OpDispatch, builder, inst);
  assert(!builder.HadDecodeFailure() && !builder.HasHandledLock());
  builder.FinishOp(pc + inst->InstSize, true);
  builder.Finalize();
  auto validation = Validation::CreateIRValidation();
  validation->Run(&builder);
  auto ir = builder.ViewIR();
#ifdef FEX_AUDIT_ALLOCATE
  if (test.NativeSwap) {
    unsigned exchanges = 0, memory = 0;
    for (auto [node, header] : ir.GetAllCode()) {
      (void)node;
      exchanges += header->Op == OP_F80STACKXCHANGE;
      memory += header->Op == OP_LOADMEM || header->Op == OP_STOREMEM || header->Op == OP_FORMCONTEXTADDRESS;
    }
    require(exchanges == 1 && memory == 0, "native memory must be introduced by lowering");
  }
#endif
  std::vector<std::pair<Registers, uint32_t>> inputs;
  uint32_t random = 0x1badf00d;
  constexpr std::array<uint32_t, 13> targets {0,        0xffff,   0x200000, 0x200fff,   0x201000,   0x201ffd,  0x201ffe,
                                              0x201fff, 0x202000, 0x400ffe, 0xfffffffd, 0xfffffffe, 0xffffffff};
  for (unsigned trial = 0; trial < 128; ++trial) {
    Registers input;
    for (auto& value : input) {
      random ^= random << 13;
      random ^= random >> 17;
      random ^= random << 5;
      value = random;
    }
    const uint32_t fs = trial & 1 ? 0xffff0000 : 0x12340000;
    // Also force each expression through page/null/top boundaries. Remaining
    // inputs independently exercise random address arithmetic and wraparound.
    if (trial < targets.size()) {
      uint32_t target = targets[trial];
      switch (test.Form) {
      case Address::Base: input[3] = target; break;
      case Address::Displacement: input[3] = target + 16; break;
      case Address::SIB: input[3] = target + 16 - input[6] * 4; break;
      case Address::Narrow16: input[3] = target + 16 - input[6]; break;
      case Address::FS: input[3] = target - fs; break;
      case Address::Absolute: break;
      }
    }
    if (!test.NativeSwap) {
      check_access(space, inspect(ir, pc, test, input, fs));
    }
    inputs.emplace_back(input, fs);
  }
  // Corrupt genuine generated IR AFTER normal inspection, restore every field.
  // No upstream source tree or emitted/runtime code is modified.
  for (auto [node, header] : ir.GetAllCode()) {
    if (test.NativeSwap) {
      break;
    }
    auto reject = [&](auto& field, auto replacement, const char* expected_error) {
      const auto saved = field;
      field = replacement;
      bool rejected = false;
      try {
        Registers input {0x12345678, 1, 2, 0x200ff0, 4, 5, 7, 8};
        inspect(ir, pc, test, input, 0xffff0000);
      } catch (const std::runtime_error& error) {
        rejected = std::strcmp(error.what(), expected_error) == 0;
      }
      field = saved;
      require(rejected, "accepted corrupted IR control or wrong rejection");
      ++Controls;
    };
    if (header->Op == OP_LOADREGISTER && test.Form == Address::Base && test.Width == 4) {
      auto* op = const_cast<IROp_LoadRegister*>(ir.GetOp<IROp_LoadRegister>(node));
      reject(op->Reg, uint8_t((op->Reg + 1) % 8), op->Reg == 0 ? "guest store value" : "guest effective address");
    } else if (header->Op == OP_ADDSHIFT && !test.Store) {
      auto* op = const_cast<IROp_AddShift*>(ir.GetOp<IROp_AddShift>(node));
      reject(op->ShiftAmount, uint8_t(1), "guest effective address");
    } else if (header->Op == OP_LOADCONTEXT) {
      auto* op = const_cast<IROp_LoadContext*>(ir.GetOp<IROp_LoadContext>(node));
      reject(op->Offset, uint32_t(op->Offset + 4), test.ControlWord ? "native control-word context" : "native segment context");
    } else if (header->Op == OP_LOADMEMTSO || header->Op == OP_STOREMEMTSO) {
      auto* mutable_header = const_cast<IROp_Header*>(header);
      reject(mutable_header->Size, test.Width == 4 ? OpSize::i16Bit : OpSize::i32Bit, "guest access width/direction");
    }
  }
#ifdef FEX_AUDIT_ALLOCATE
  PassManager manager {&context};
  auto* allocation = manager.GetPass<RegisterAllocationPass>("RA");
  require(allocation && manager.HasPass("IRValidation"), "real default pipeline");
  RegisterBudget budget {context};
  budget.configure(*allocation);
  ActiveBudget = &budget;
  manager.Finalize();
  manager.Run(&builder);
  auto allocated_ir = builder.ViewIR();
  require(allocated_ir.PostRA(), "pipeline must allocate");
  if (test.NativeSwap) {
    for (unsigned top = 0; top < 8; ++top) {
      for (unsigned ftw = 0; ftw < 256; ++ftw) {
        inspect_native_swap(allocated_ir, pc, top, ftw);
      }
    }
  } else {
    for (const auto& [input, fs] : inputs) {
      check_access(space, inspect(allocated_ir, pc, test, input, fs));
    }
  }
  // Mutate the allocated representation too: pre-RA controls cannot validate
  // physical operands, native pointer tags or the optimizer's new memory IR.
  for (auto [node, header] : allocated_ir.GetAllCode()) {
    auto check = [&] {
      if (test.NativeSwap) {
        inspect_native_swap(allocated_ir, pc, 7, 0x12);
      } else {
        Registers input {0x12345678, 1, 2, 0x200ff0, 4, 5, 7, 8};
        inspect(allocated_ir, pc, test, input, 0xffff0000);
      }
    };
    auto* mutable_header = const_cast<IROp_Header*>(header);
    if (header->Op == OP_LOADMEMTSO || header->Op == OP_STOREMEMTSO) {
      reject_mutation(&mutable_header->Size, test.Width == 4 ? OpSize::i16Bit : OpSize::i32Bit, "guest access width/direction", check);
      if (test.Form == Address::Base && test.Width == 4) {
        auto* addr = header->Op == OP_LOADMEMTSO ? &const_cast<IROp_LoadMemTSO*>(allocated_ir.GetOp<IROp_LoadMemTSO>(node))->Addr :
                                                   &const_cast<IROp_StoreMemTSO*>(allocated_ir.GetOp<IROp_StoreMemTSO>(node))->Addr;
        reject_mutation(addr, OrderedNodeWrapper::FromImmediate(PhysicalRegister(RegClass::GPRFixed, 2).Raw), "guest effective address", check);
      }
    } else if (header->Op == OP_LOADCONTEXT || (test.NativeSwap && header->Op == OP_STORECONTEXT)) {
      auto* offset = header->Op == OP_LOADCONTEXT ? &const_cast<IROp_LoadContext*>(allocated_ir.GetOp<IROp_LoadContext>(node))->Offset :
                                                    &const_cast<IROp_StoreContext*>(allocated_ir.GetOp<IROp_StoreContext>(node))->Offset;
      reject_mutation(offset, uint32_t(packed_read<uint32_t>(offset) + 4),
                      test.NativeSwap  ? "native stack context" :
                      test.ControlWord ? "native control-word context" :
                                         "native segment context",
                      check);
    } else if (header->Op == OP_FORMCONTEXTADDRESS) {
      auto* op = const_cast<IROp_FormContextAddress*>(allocated_ir.GetOp<IROp_FormContextAddress>(node));
      reject_mutation(reinterpret_cast<uint8_t*>(op) + offsetof(IROp_FormContextAddress, Stride), uint32_t(8), "native pointer construction", check);
    } else if (header->Op == OP_LOADMEM || header->Op == OP_STOREMEM) {
      reject_mutation(&mutable_header->Size, OpSize::i64Bit, "native stack memory width", check);
      auto* addr = header->Op == OP_LOADMEM ? &const_cast<IROp_LoadMem*>(allocated_ir.GetOp<IROp_LoadMem>(node))->Addr :
                                              &const_cast<IROp_StoreMem*>(allocated_ir.GetOp<IROp_StoreMem>(node))->Addr;
      reject_mutation(addr, OrderedNodeWrapper::FromImmediate(PhysicalRegister(RegClass::GPRFixed, 3).Raw), "native pointer provenance", check);
    } else if (header->Op == OP_INLINECONSTANT && test.NativeSwap &&
               allocated_ir.GetOp<IROp_InlineConstant>(node)->Constant == offsetof(FEXCore::Core::CPUState, mm)) {
      auto* op = const_cast<IROp_InlineConstant*>(allocated_ir.GetOp<IROp_InlineConstant>(node));
      reject_mutation(reinterpret_cast<uint8_t*>(op) + offsetof(IROp_InlineConstant, Constant), op->Constant + 16,
                      "native stack effective address", check);
    }
  }
  ActiveBudget = nullptr;
#endif
  std::vector<uint8_t> unchanged(test.Bytes.size());
  assert(g32_fetch(space, pc, unchanged.data(), unchanged.size()) == G32_OK && unchanged == test.Bytes);
  assert(g32_read(space, pc, unchanged.data(), unchanged.size()) == G32_ACCESS);
  builder.DelayedDisownBuffer();
  decoder.DelayedDisownBuffer();
  builder.ValidateDisownedOrFree();
  decoder.ValidateDisownedOrFree();
  assert(g32_release(space, base) == G32_OK);
}

static void cases(size_t granule) {
  Controls = AllocatedControls = 0;
  g32_space* space;
  assert(g32_create(granule, &space) == G32_OK);
  ActiveSpace = space;
  FEXCore::HostFeatures features {};
  FEXCore::Context::ContextImpl context {features};
  Handler handler {space};
  context.SyscallHandler = &handler;
  FEXCore::Core::InternalThreadState thread {.CTX = &context};
  FEXCore::Core::CPUState::gdt_segment gdt[1] {};
  gdt[0].D = 1;
  thread.CurrentFrame->State.segment_arrays[0] = gdt;
  assert(g32_reserve(space, 0x200000, G32_GRANULE) == G32_OK);
  assert(g32_commit(space, 0x200000, 2 * G32_PAGE, G32_READ | G32_WRITE) == G32_OK);
  std::array<uint8_t, 2 * G32_PAGE> fixture;
  for (size_t i = 0; i < fixture.size(); ++i) {
    fixture[i] = (i * 73 + 19) & 0xff;
  }
  assert(g32_write(space, 0x200000, fixture.data(), fixture.size()) == G32_OK);
  assert(g32_protect(space, 0x201000, G32_PAGE, G32_READ) == G32_OK);
  // Second guest page is native-readable in a shared 16/64 KiB host granule,
  // but guest stores across/into it must still fail transactionally.
  const std::vector<Case> tests {
    {{0x8b, 0x03}, Address::Base, 4, false},
    {{0x89, 0x03}, Address::Base, 4, true},
    {{0x8b, 0x43, 0xf0}, Address::Displacement, 4, false},
    {{0x89, 0x43, 0xf0}, Address::Displacement, 4, true},
    {{0x8b, 0x44, 0xb3, 0xf0}, Address::SIB, 4, false},
    {{0x89, 0x44, 0xb3, 0xf0}, Address::SIB, 4, true},
    {{0x67, 0x8b, 0x40, 0xf0}, Address::Narrow16, 4, false},
    {{0x67, 0x89, 0x40, 0xf0}, Address::Narrow16, 4, true},
    {{0x64, 0x8b, 0x03}, Address::FS, 4, false},
    {{0x64, 0x89, 0x03}, Address::FS, 4, true},
    {{0xa1, 0xfe, 0x0f, 0x20, 0}, Address::Absolute, 4, false},
    {{0xa3, 0xfe, 0x0f, 0x20, 0}, Address::Absolute, 4, true},
    {{0x8a, 0x03}, Address::Base, 1, false},
    {{0x88, 0x03}, Address::Base, 1, true},
    {{0x66, 0x8b, 0x03}, Address::Base, 2, false},
    {{0x66, 0x89, 0x03}, Address::Base, 2, true},
    {{0xd9, 0x3b}, Address::Base, 2, true, true}, // FNSTCW [EBX]: native context -> guest scalar store
#ifdef FEX_AUDIT_ALLOCATE
    {{0xd9, 0xc9}, Address::Base, 0, false, false, true}, // FXCH ST(1): native stack-memory counterexample
#endif
  };
  for (uint32_t pc : {0x400ffeU, 0x900ffeU, 0xffff0ffeU}) {
    for (const auto& test : tests) {
      audit(context, thread, space, pc, test);
    }
  }
  assert(ByteLoans && handler.Queries && Controls == 75);
#ifdef FEX_AUDIT_ALLOCATE
  require(AllocatedControls == 120, "allocated corruption census");
  std::printf("PASS: optimized/allocated scalar memory granule=%zu 3 PCs/17 forms/128 inputs, plus native FXCH lowering 8 TOPs/256 tags; "
              "pre/post-RA guest addresses, native pointer provenance and %u+%u corruption controls; NO JIT execution\n",
              granule, Controls, AllocatedControls);
#else
  std::printf("PASS: scalar memory IR granule=%zu 3 PCs/17 forms/128 inputs; guest address/width/value, native context classification, "
              "checked C adapter and corrupted-IR controls; NO JIT execution\n",
              granule);
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
  FEXCore::Config::Set(FEXCore::Config::ConfigOption::CONFIG_DUMPIR, "no");
  assert(!std::getenv("MADEIRA_NO_DFE"));
  cases(0);
  cases(16384);
  cases(65536);
}
