// SPDX-License-Identifier: GPL-3.0-or-later
// Offline scalar-memory IR inspection, NOT execution or a runtime bridge.
#include "Interface/Context/Context.h"
#include "Interface/Core/Frontend.h"
#include "Interface/Core/OpcodeDispatcher.h"
#include "Interface/Core/LookupCache.h"
#include "Interface/Core/Dispatcher/Dispatcher.h"
#include "Interface/IR/Passes.h"
#include "Interface/IR/PassManager.h"
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
static unsigned Controls;

static void require(bool condition, const char* message) {
  if (!condition) {
    throw std::runtime_error(message);
  }
}
enum class Address { Base, Displacement, SIB, Narrow16, FS, Absolute };
struct Case {
  std::vector<uint8_t> Bytes;
  Address Form;
  unsigned Width;
  bool Store;
  bool ControlWord = false;
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
  require(!ir.PostRA() && ir.GetHeader()->OriginalRIP == pc && ir.GetHeader()->NumHostInstructions == 1, "IR header");
  std::vector<uint64_t> values(ir.GetSSACount());
  std::vector<bool> valid(ir.GetSSACount());
  Registers regs = input;
  FEXCore::Core::CPUState native_state {};
  native_state.fs_cached = fs;
  native_state.FCW = 0x037f;
  require(reinterpret_cast<uintptr_t>(&native_state) > UINT32_MAX, "native CPU-state storage must stay high");
  auto read = [&](OrderedNodeWrapper ref) {
    require(!ref.IsInvalid() && !ref.IsImmediate(), "invalid SSA operand");
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
    default: throw std::runtime_error("unclassified IR operation");
    }
  }
  Registers expected = input;
  if (!test.Store) {
    auto mask = UINT32_MAX >> ((4 - test.Width) * 8);
    expected[0] = (input[0] & ~mask) | (loaded & mask);
  }
  require(regs == expected && stores == unsigned(!test.Store), "load register result");
  const unsigned expected_contexts = test.Form == Address::FS ? (test.Store ? 2 : 1) : unsigned(test.ControlWord);
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
    check_access(space, inspect(ir, pc, test, input, fs));
  }
  // Corrupt genuine generated IR AFTER normal inspection, restore every field.
  // No upstream source tree or emitted/runtime code is modified.
  for (auto [node, header] : ir.GetAllCode()) {
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
  Controls = 0;
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
  };
  for (uint32_t pc : {0x400ffeU, 0x900ffeU, 0xffff0ffeU}) {
    for (const auto& test : tests) {
      audit(context, thread, space, pc, test);
    }
  }
  assert(ByteLoans && handler.Queries && Controls == 75);
  std::printf("PASS: scalar memory IR granule=%zu 3 PCs/17 forms/128 inputs; guest address/width/value, native context classification, "
              "checked C adapter and corrupted-IR controls; NO JIT execution\n",
              granule);
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
  assert(!std::getenv("MADEIRA_NO_DFE"));
  cases(0);
  cases(16384);
  cases(65536);
}
