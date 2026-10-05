// SPDX-License-Identifier: GPL-3.0-or-later
// Window coverage: every guest memory access FEX generates for an i386 guest
// in a host window must address the window. Decodes and translates i386
// instructions with the real FEX frontend, dispatcher and default IR passes (no
// code emission or execution) and checks each memory operation's address operand.
#include "Interface/Context/Context.h"
#include "Interface/Core/CPUBackend.h"
#include "Interface/Core/Dispatcher/Dispatcher.h"
#include "Interface/Core/Frontend.h"
#include "Interface/Core/LookupCache.h"
#include "Interface/Core/OpcodeDispatcher.h"
#include "Interface/IR/IR.h"
#include "Interface/IR/Passes.h"
#include "Interface/IR/PassManager.h"
#include "Interface/IR/Passes/RegisterAllocationPass.h"
#include "Interface/Core/ArchHelpers/Arm64Emitter.h"
#include <FEXCore/Config/Config.h>
#include <FEXCore/Debug/InternalThreadState.h>
#include <FEXCore/HLE/SyscallHandler.h>
#include <FEXCore/Utils/LogManager.h>
#include "Interface/IR/RegisterAllocationData.h"
#include <array>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <sys/mman.h>
#include <vector>

using namespace FEXCore::IR;

namespace {
// The phone's window base from the step 3 run; any base above 4 GiB works.
constexpr uint64_t WindowBase = 0x7038010000;
constexpr uint64_t WindowSize = 1ULL << 32;
constexpr uint32_t CodePC = 0x00400000;
constexpr size_t CodeSize = 0x1000;

struct Case {
  std::string Text;
  std::vector<uint8_t> Bytes;
};

// The arm64 backend's register file, which the backend gives the RA pass.
class RegisterFile final : public FEXCore::CPU::Arm64Emitter {
public:
  explicit RegisterFile(FEXCore::Context::ContextImpl& Context)
    : Arm64Emitter(&Context) {}
  void Configure(RegisterAllocationPass& RA) const {
    RA.AddRegisters(RegClass::GPR, GeneralRegisters.size());
    RA.AddRegisters(RegClass::GPRFixed, StaticRegisters.size());
    RA.AddRegisters(RegClass::FPR, GeneralFPRegisters.size());
    RA.AddRegisters(RegClass::FPRFixed, StaticFPRegisters.size());
    RA.SetNumPairRegs(PairRegisters);
  }
};

struct Handler final : FEXCore::HLE::SyscallHandler {
  void HandleSyscall(FEXCore::Core::CpuStateFrame*) override {
    std::abort();
  }
  FEXCore::HLE::ExecutableRangeInfo QueryGuestExecutableRange(FEXCore::Core::InternalThreadState*, uint64_t Address) override {
    if (Address >= CodePC && Address < CodePC + CodeSize) {
      return {CodePC, CodeSize, false};
    }
    return {Address, 0, false};
  }
  std::optional<FEXCore::ExecutableFileSectionInfo> LookupExecutableFileSection(FEXCore::Core::InternalThreadState*, uint64_t) override {
    return std::nullopt;
  }
};

const IRListView* FailingIR;

[[noreturn]] void Fail(const Case& Test, const char* Config, const char* Op, const char* Why) {
  std::fprintf(stderr, "FAIL [%s] %s: %s %s\n", Config, Test.Text.c_str(), Op, Why);
  if (FailingIR) {
    fextl::ostringstream Out;
    Dump(&Out, FailingIR);
    std::fprintf(stderr, "%s\n", Out.str().c_str());
  }
  std::exit(1);
}

// Checks the IR after register allocation, as the JIT receives it. Arguments are
// then physical registers, so each argument resolves to the node that last wrote
// its register, in program order; a register no node wrote (a static guest
// register such as EBX) resolves to nothing: guest data, never a window address.
class Checker {
public:
  Checker(const IRListView& IR, const Case& Test, const char* Config)
    : IR {IR}
    , Test {Test}
    , Config {Config} {
    std::array<const IROp_Header*, 256> RegisterDef {};
    for (auto [Node, Header] : IR.GetAllCode()) {
      auto& Defs = ArgDefs[Header];
      for (uint8_t i = 0; i < GetArgs(Header->Op); ++i) {
        const auto Arg = Header->Args[i];
        if (Arg.IsInvalid()) {
          Defs.push_back(nullptr);
        } else if (Arg.IsImmediate()) {
          Defs.push_back(RegisterDef[PhysicalRegister(Arg).Raw]);
        } else {
          Defs.push_back(IR.GetOp<IROp_Header>(Arg));
        }
      }
      if (!PhysicalRegister(Node).IsInvalid()) {
        RegisterDef[PhysicalRegister(Node).Raw] = Header;
      }
    }
  }

  // Counts of checked guest accesses by IR op name.
  std::map<std::string, unsigned> Run() {
    std::map<std::string, unsigned> Counts;
    for (auto [Node, Header] : IR.GetAllCode()) {
      const char* Name = GetName(Header->Op).data();
      if (CheckNode(Header, Name)) {
        ++Counts[Name];
      }
    }
    return Counts;
  }

private:
  const IRListView& IR;
  const Case& Test;
  const char* Config;
  std::map<const IROp_Header*, std::vector<const IROp_Header*>> ArgDefs;

  const IROp_Header* Def(const IROp_Header* User, size_t Index) const {
    auto& Defs = ArgDefs.at(User);
    return Index < Defs.size() ? Defs[Index] : nullptr;
  }

  static bool IsBaseConstant(const IROp_Header* Op) {
    return Op && Op->Op == OP_CONSTANT && static_cast<uint64_t>(Op->C<IROp_Constant>()->Constant) == WindowBase;
  }

  static bool IsSmallConstant(const IROp_Header* Op) {
    int64_t Value;
    if (!Op) {
      return false;
    } else if (Op->Op == OP_CONSTANT) {
      Value = Op->C<IROp_Constant>()->Constant;
    } else if (Op->Op == OP_INLINECONSTANT) {
      Value = Op->C<IROp_InlineConstant>()->Constant;
    } else {
      return false;
    }
    return Value > -4096 && Value < 4096;
  }

  // B + zext32(x), that plus a small constant (a split access), or a constant inside the window.
  bool IsWindowAddress(const IROp_Header* Op) const {
    if (!Op) {
      return false;
    }
    if (Op->Op == OP_CONSTANT) {
      const auto Value = static_cast<uint64_t>(Op->C<IROp_Constant>()->Constant);
      return Value - WindowBase < WindowSize;
    }
    if (Op->Op != OP_ADD || Op->Size != OpSize::i64Bit) {
      return false;
    }
    for (auto [Base, Other] : {std::pair {0, 1}, std::pair {1, 0}}) {
      if (IsSmallConstant(Def(Op, Other)) && Def(Op, Base) != Op && IsWindowAddress(Def(Op, Base))) {
        return true;
      }
      auto* Zext = Def(Op, Other);
      if (IsBaseConstant(Def(Op, Base)) && Zext && Zext->Op == OP_BFE && Zext->Size == OpSize::i64Bit &&
          Zext->C<IROp_Bfe>()->Width == 32 && Zext->C<IROp_Bfe>()->lsb == 0) {
        return true;
      }
    }
    return false;
  }

  // Host state that is not guest memory: FEX's context and the GDT it points to.
  static bool IsHostState(const IROp_Header* Op) {
    return Op && (Op->Op == OP_FORMCONTEXTADDRESS || Op->Op == OP_LOADCONTEXTINDEXED);
  }

  // [xB, wEA, uxtw], or [B + zext32(EA), #imm]. Returns false for host state.
  template<typename T>
  bool RequireLoadStoreForm(const IROp_Header* Header, const char* Name) const {
    auto* Op = Header->C<T>();
    auto* Addr = Def(Header, T::Addr_Index);
    auto* Offset = Def(Header, T::Offset_Index);
    if (IsHostState(Addr)) {
      return false;
    }
    if (IsBaseConstant(Addr) && !Op->Offset.IsInvalid() && Op->OffsetType == MemOffsetType::UXTW && Op->OffsetScale == 1 &&
        !IsSmallConstant(Offset)) {
      return true;
    }
    if (IsWindowAddress(Addr) && (Op->Offset.IsInvalid() || IsSmallConstant(Offset))) {
      return true;
    }
    Fail(Test, Config, Name, "address is not in the window");
  }

  template<typename T>
  bool RequireWindow(const IROp_Header* Header, const char* Name, size_t Index = T::Addr_Index) const {
    if (!IsWindowAddress(Def(Header, Index))) {
      Fail(Test, Config, Name, "address is not B + zext32(EA)");
    }
    return true;
  }

  // Returns true when the node is a checked guest access.
  bool CheckNode(const IROp_Header* Header, const char* Name) const {
    switch (Header->Op) {
    case OP_LOADMEM: return RequireLoadStoreForm<IROp_LoadMem>(Header, Name);
    case OP_STOREMEM: return RequireLoadStoreForm<IROp_StoreMem>(Header, Name);
    case OP_LOADMEMTSO: return RequireLoadStoreForm<IROp_LoadMemTSO>(Header, Name);
    case OP_STOREMEMTSO: return RequireLoadStoreForm<IROp_StoreMemTSO>(Header, Name);
    case OP_PREFETCH: return RequireLoadStoreForm<IROp_Prefetch>(Header, Name);
    case OP_VLOADVECTORMASKED: return RequireLoadStoreForm<IROp_VLoadVectorMasked>(Header, Name);
    case OP_VSTOREVECTORMASKED: return RequireLoadStoreForm<IROp_VStoreVectorMasked>(Header, Name);
    case OP_STORESTACKMEM: return RequireLoadStoreForm<IROp_StoreStackMem>(Header, Name);
    case OP_LOADMEMPAIR: return RequireWindow<IROp_LoadMemPair>(Header, Name);
    case OP_STOREMEMPAIR: return RequireWindow<IROp_StoreMemPair>(Header, Name);
    case OP_LOADMEMX87SVEOPTPREDICATE: return RequireWindow<IROp_LoadMemX87SVEOptPredicate>(Header, Name);
    case OP_STOREMEMX87SVEOPTPREDICATE: return RequireWindow<IROp_StoreMemX87SVEOptPredicate>(Header, Name);
    case OP_VLOADVECTORELEMENT: return RequireWindow<IROp_VLoadVectorElement>(Header, Name);
    case OP_VSTOREVECTORELEMENT: return RequireWindow<IROp_VStoreVectorElement>(Header, Name);
    case OP_VBROADCASTFROMMEM: return RequireWindow<IROp_VBroadcastFromMem>(Header, Name, IROp_VBroadcastFromMem::Address_Index);
    case OP_VLOADNONTEMPORAL: return RequireWindow<IROp_VLoadNonTemporal>(Header, Name);
    case OP_VSTORENONTEMPORAL: return RequireWindow<IROp_VStoreNonTemporal>(Header, Name);
    case OP_VSTORENONTEMPORALPAIR: return RequireWindow<IROp_VStoreNonTemporalPair>(Header, Name);
    case OP_CACHELINECLEAR: return RequireWindow<IROp_CacheLineClear>(Header, Name);
    case OP_CACHELINECLEAN: return RequireWindow<IROp_CacheLineClean>(Header, Name);
    case OP_CACHELINEZERO: return RequireWindow<IROp_CacheLineZero>(Header, Name);
    case OP_MONOBACKPATCHERWRITE: return RequireWindow<IROp_MonoBackpatcherWrite>(Header, Name);
    case OP_VALIDATECODE: return RequireWindow<IROp_ValidateCode>(Header, Name, IROp_ValidateCode::Address_Index);
    case OP_CAS: return RequireWindow<IROp_CAS>(Header, Name);
    case OP_CASPAIR: return RequireWindow<IROp_CASPair>(Header, Name);
    case OP_ATOMICSWAP: return RequireWindow<IROp_AtomicSwap>(Header, Name);
    case OP_ATOMICFETCHADD: return RequireWindow<IROp_AtomicFetchAdd>(Header, Name);
    case OP_ATOMICFETCHSUB: return RequireWindow<IROp_AtomicFetchSub>(Header, Name);
    case OP_ATOMICFETCHAND: return RequireWindow<IROp_AtomicFetchAnd>(Header, Name);
    case OP_ATOMICFETCHCLR: return RequireWindow<IROp_AtomicFetchCLR>(Header, Name);
    case OP_ATOMICFETCHOR: return RequireWindow<IROp_AtomicFetchOr>(Header, Name);
    case OP_ATOMICFETCHXOR: return RequireWindow<IROp_AtomicFetchXor>(Header, Name);
    case OP_ATOMICFETCHNEG: return RequireWindow<IROp_AtomicFetchNeg>(Header, Name);
    case OP_MEMCPY:
      RequireWindow<IROp_MemCpy>(Header, Name, IROp_MemCpy::Dest_Index);
      return RequireWindow<IROp_MemCpy>(Header, Name, IROp_MemCpy::Src_Index);
    case OP_MEMSET: {
      // The base joins the segment prefix; the address operand stays guest.
      auto* Prefix = Def(Header, IROp_MemSet::Prefix_Index);
      const bool BasePlusSegment =
        Prefix && Prefix->Op == OP_ADD && (IsBaseConstant(Def(Prefix, 0)) || IsBaseConstant(Def(Prefix, 1)));
      if (!IsBaseConstant(Prefix) && !BasePlusSegment) {
        Fail(Test, Config, Name, "prefix is not the window base");
      }
      return true;
    }
    // Stack ops address the guest stack pointer directly: never in a window.
    case OP_PUSH:
    case OP_PUSHTWO:
    case OP_POP:
    case OP_POPTWO:
    // Gathers form their addresses from vector lanes; not translated (AVX2 only).
    case OP_VLOADVECTORGATHERMASKED:
    case OP_VLOADVECTORGATHERMASKEDQPS: Fail(Test, Config, Name, "cannot address the window");
    default: return false;
    }
  }
};

std::vector<Case> ReadCorpus(const char* Path) {
  std::ifstream File(Path);
  std::vector<Case> Cases;
  std::string Line;
  while (std::getline(File, Line)) {
    const auto Tab = Line.find('\t');
    if (Line.empty() || Tab == std::string::npos) {
      continue;
    }
    Case Test {.Text = Line.substr(Tab + 1)};
    std::istringstream Hex(Line.substr(0, Tab));
    unsigned Byte;
    while (Hex >> std::hex >> Byte) {
      Test.Bytes.push_back(static_cast<uint8_t>(Byte));
    }
    Cases.push_back(std::move(Test));
  }
  return Cases;
}

void* MapFixed(uint64_t Address) {
  void* Result = mmap(reinterpret_cast<void*>(Address), CodeSize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE, -1, 0);
  if (Result != reinterpret_cast<void*>(Address)) {
    std::fprintf(stderr, "FAIL cannot map %#llx\n", static_cast<unsigned long long>(Address));
    std::exit(1);
  }
  return Result;
}

// FEX's diagnostics stay quiet; an assertion names itself before it stops the test.
void Log(LogMan::DebugLevels, const char*) {}
void Assertion(const char* Message) {
  std::fprintf(stderr, "FEX assertion: %s\n", Message);
}

struct Variant {
  const char* Name;
  bool TSO;
  bool FullSMC;
  bool ReducedX87;
};
} // namespace

int main(int argc, char** argv) {
  // --control translates without a window: the checker must reject the result.
  const bool Control = argc == 3 && std::strcmp(argv[2], "--control") == 0;
  if (argc != 2 && !Control) {
    std::fprintf(stderr, "usage: %s CORPUS [--control]\n", argv[0]);
    return 2;
  }
  const auto Cases = ReadCorpus(argv[1]);
  if (Cases.empty()) {
    std::fprintf(stderr, "FAIL empty corpus\n");
    return 1;
  }
  LogMan::Msg::InstallHandler(Log);
  LogMan::Throw::InstallHandler(Assertion);
  // The decoder reads guest code at its guest address; FEX's full SMC check reads it
  // through the window. Both copies hold the instruction under test.
  auto* GuestCode = static_cast<uint8_t*>(MapFixed(CodePC));
  auto* WindowCode = static_cast<uint8_t*>(MapFixed(WindowBase + CodePC));

  FEXCore::Config::Initialize();
  FEXCore::Config::Load();
  FEXCore::Config::Set(FEXCore::Config::ConfigOption::CONFIG_IS64BIT_MODE, "0");
  FEXCore::Config::Set(FEXCore::Config::ConfigOption::CONFIG_MULTIBLOCK, "0");

  const Variant Variants[] = {
    {"tso", true, false, false},
    {"no-tso", false, false, false},
    {"tso,full-smc", true, true, false},
    {"no-tso,x87-reduced", false, false, true},
  };
  std::map<std::string, unsigned> Total;
  unsigned Translated = 0;
  for (const auto& V : Variants) {
    FEXCore::Config::Set(FEXCore::Config::ConfigOption::CONFIG_SMCCHECKS,
                         std::to_string(V.FullSMC ? FEXCore::Config::CONFIG_SMC_FULL : FEXCore::Config::CONFIG_SMC_MTRACK));
    FEXCore::Config::Set(FEXCore::Config::ConfigOption::CONFIG_X87REDUCEDPRECISION, V.ReducedX87 ? "1" : "0");
    FEXCore::HostFeatures Features {};
    FEXCore::Context::ContextImpl Context {Features};
    // Hardware TSO turns the atomic TSO emulation off.
    Context.SetHardwareTSOSupport(!V.TSO);
    if (Context.IsAtomicTSOEnabled() != V.TSO) {
      std::fprintf(stderr, "FAIL [%s] TSO configuration did not apply\n", V.Name);
      return 1;
    }
    Handler Syscalls;
    Context.SyscallHandler = &Syscalls;
    FEXCore::Core::InternalThreadState Thread {.CTX = &Context};
    FEXCore::Core::CPUState::gdt_segment GDT[1] {};
    GDT[0].D = 1;
    Thread.CurrentFrame->State.segment_arrays[0] = GDT;
    Thread.OpDispatcher = fextl::make_unique<OpDispatchBuilder>(&Context, &Thread);
    Thread.FrontendDecoder = fextl::make_unique<FEXCore::Frontend::Decoder>(&Thread);
    // FEX's default pipeline (x87 lowering, flag elimination, RA, validation), as the JIT runs it.
    Thread.PassManager = fextl::make_unique<PassManager>(&Context);
    RegisterFile(Context).Configure(*Thread.PassManager->GetPass<RegisterAllocationPass>("RA"));
    Thread.PassManager->Finalize();
    Thread.OpDispatcher->SetGuestWindowBase(Control ? 0 : WindowBase);

    for (const auto& Test : Cases) {
      std::memset(GuestCode, 0xcc, CodeSize);
      std::memcpy(GuestCode, Test.Bytes.data(), Test.Bytes.size());
      std::memcpy(WindowCode, GuestCode, CodeSize);
      Thread.FrontendDecoder->SetupDecodeInstructionsAtEntry(&Thread, CodePC, 1);
      auto Result = Context.GenerateIR(&Thread, CodePC, false, 1);
      if (!Result.IRView || Result.TotalInstructions != 1 || Result.TotalInstructionsLength != Test.Bytes.size()) {
        Fail(Test, V.Name, "decode", "did not translate exactly this instruction");
      }
      FailingIR = &*Result.IRView;
      auto Counts = Checker(*Result.IRView, Test, V.Name).Run();
      FailingIR = nullptr;
      unsigned Accesses = 0;
      for (auto& [Name, Count] : Counts) {
        Total[Name] += Count;
        Accesses += Count;
      }
      if (!Accesses) {
        Fail(Test, V.Name, "IR", "has no guest memory access (the corpus lists memory instructions only)");
      }
      ++Translated;
      Thread.OpDispatcher->DelayedDisownBuffer();
    }
  }
  std::printf("PASS: %zu i386 instructions x %zu configurations, every guest memory access addresses the window at %#llx\n",
              Cases.size(), std::size(Variants), static_cast<unsigned long long>(WindowBase));
  for (auto& [Name, Count] : Total) {
    std::printf("  %-28s %u\n", Name.c_str(), Count);
  }
  return Translated == Cases.size() * std::size(Variants) ? 0 : 1;
}
