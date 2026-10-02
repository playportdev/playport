// SPDX-License-Identifier: GPL-3.0-or-later
// Host-only call-ABI fixture. Uses real FEX spill/fill emission, NOT IR lowering.
#include "Interface/Context/Context.h"
#include "Interface/Core/ArchHelpers/Arm64Emitter.h"
#include "Interface/Core/Dispatcher/Dispatcher.h"
#include <FEXCore/Config/Config.h>
#include <FEXCore/Core/CoreState.h>
#include <array>
#include <cassert>
#include <cstdio>
#include <cstdlib>

using namespace ARMEmitter;
using namespace FEXCore::CPU;
constexpr uint64_t Descriptor = 0x700000000;
constexpr uint64_t Capture = 0x500000000;
constexpr uint32_t GuestPC = 0x401234;

class CallFixture final : public Arm64Emitter {
public:
  CallFixture(FEXCore::Context::ContextImpl& ctx, void* buffer, size_t size)
    : Arm64Emitter(&ctx, buffer, size) { }

  void emit(uint64_t helper, unsigned mutation) {
    // Ordinary AAPCS64, not preserve_all. No SVE/AFP in this bounded fixture.
    if (mutation != 1) {
      SpillStaticRegs(TMP1, {.FPRs = mutation != 3});
    }
    if (mutation != 2) {
      PushDynamicRegs(TMP1);
    }
    LoadConstant(Size::i64Bit, TMP4, Descriptor);
    ldp<IndexType::OFFSET>(XReg::x0, XReg::x1, TMP4, 0);
    ldp<IndexType::OFFSET>(WReg::w2, WReg::w3, TMP4, 16);
    LoadConstant(Size::i64Bit, Reg::r16, helper); // pushed dynamic register, not an argument
    blr(Reg::r16);
    LoadConstant(Size::i64Bit, TMP2, Descriptor);
    str(XReg::x0, TMP2, 24);
    // x3 is FEX's temporary documented to survive spill boundaries.
    mov(Size::i64Bit, TMP4, TMP1);
    if (mutation == 4) {
      mov(Size::i32Bit, StaticRegisters[0], TMP4);
    }
    if (mutation != 2) {
      PopDynamicRegs();
    }
    FillStaticRegs({.FPRs = mutation != 3, .NZCV = mutation != 5});
    lsr(Size::i64Bit, TMP1, TMP4, 32);
    ARMEmitter::ForwardLabel fault;
    if (mutation != 6) {
      assert(cbnz(Size::i64Bit, TMP1, &fault) == BranchEncodeSucceeded::Success);
    }
    if (mutation != 4) {
      mov(Size::i32Bit, StaticRegisters[0], TMP4);
    }
    LoadConstant(Size::i64Bit, TMP2, Descriptor);
    mov(Size::i64Bit, TMP1, 1);
    str(TMP1, TMP2, 40); // explicit success-continuation marker
    LoadConstant(Size::i64Bit, TMP1, Capture);
    br(TMP1);
    assert(Bind(&fault));
    LoadConstant(Size::i64Bit, TMP2, Descriptor);
    LoadConstant(Size::i64Bit, TMP1, mutation == 7 ? GuestPC + 1 : GuestPC);
    str(TMP1, TMP2, 32); // test-only fault record, NOT a guest exception
    LoadConstant(Size::i64Bit, TMP1, Capture);
    br(TMP1);
  }

  void export_json(std::FILE* file, unsigned mutation, const uint8_t* bytes, size_t size) const {
    std::fprintf(file, "{\"mutation\":%u,\"code\":\"", mutation);
    for (size_t i = 0; i < size; ++i) {
      std::fprintf(file, "%02x", bytes[i]);
    }
    std::fprintf(file, "\",\"gprs\":[");
    bool comma = false;
    for (auto regs : {StaticRegisters, GeneralRegisters}) {
      for (auto reg : regs) {
        std::fprintf(file, "%s%u", comma ? "," : "", reg.Idx());
        comma = true;
      }
    }
    std::fprintf(file, "],\"fprs\":[");
    comma = false;
    for (auto regs : {StaticFPRegisters, GeneralFPRegisters}) {
      for (auto reg : regs) {
        std::fprintf(file, "%s%u", comma ? "," : "", reg.Idx());
        comma = true;
      }
    }
    std::fprintf(file, "],\"eax\":%u,\"state_size\":%zu,\"spills\":[", StaticRegisters[0].Idx(), sizeof(FEXCore::Core::CpuStateFrame));
    using Frame = FEXCore::Core::CpuStateFrame;
    std::fprintf(file, "[%zu,4],[%zu,8],[%zu,64],[%zu,8],[%zu,128]]}\n", offsetof(Frame, State.flags[24]), offsetof(Frame, State.callret_sp),
                 offsetof(Frame, State.gregs), offsetof(Frame, State.pf_raw), offsetof(Frame, State.xmm.sse.data));
  }
};

int main(int argc, char** argv) {
  assert(argc == 3);
  FEXCore::Config::Initialize();
  FEXCore::Config::Load();
  FEXCore::Config::Set(FEXCore::Config::ConfigOption::CONFIG_IS64BIT_MODE, "0");
  FEXCore::Config::Set(FEXCore::Config::ConfigOption::CONFIG_ENABLECODECACHEVALIDATION, "0");
  FEXCore::HostFeatures features {};
  FEXCore::Context::ContextImpl context {features};
  auto* file = std::fopen(argv[2], "w");
  assert(file);
  for (unsigned mutation = 0; mutation < 8; ++mutation) {
    alignas(16) std::array<uint8_t, 4096> buffer {};
    CallFixture emitter {context, buffer.data(), buffer.size()};
    emitter.emit(std::strtoull(argv[1], nullptr, 0), mutation);
    const auto size = emitter.GetCursorAddress<uint8_t*>() - buffer.data();
    assert(size > 0 && size < 4096 && size % 4 == 0);
    emitter.export_json(file, mutation, buffer.data(), size);
  }
  assert(std::fclose(file) == 0);
}
