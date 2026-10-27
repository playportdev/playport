// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * roundtrip.cpp — known ymm bytes through the ARM64EC context and back, on the
 * workstation (build/ymm-context/test.py builds and runs it; PLA-451 chunk 3).
 *
 * What is real and what is mirrored:
 *   real   fex_core_xmm.inc        FEXCore Core.cpp: ContextImpl::ReconstructXMMRegisters and
 *                                  ContextImpl::SetXMMRegistersFromState, whole, from the FEX tree
 *   real   fex_module_exception.inc ARM64EC Module.cpp: LoadStateFromECContext, ReconstructThreadState,
 *                                  StoreStateToPackedECContext, whole, from the FEX tree
 *   real   fex_ymmstate_define.inc FEX's CONTEXT_ARM64_FEX_YMMSTATE (Source/Windows/include/winnt.h)
 *   real   wine_context.c          Wine's context_arm_to_x64 / context_x64_to_arm (dlls/ntdll/unwind.h)
 *   real   FEXCore's CPUState and HostFeatures headers, Wine's winnt.h context layouts
 *   mirror the order the runtime calls them in (each step names its caller; test.py pins those
 *          call sites' text in the trees), and the small services those functions call that are
 *          not about vector state: CTX's flag/RIP helpers, CPUFeatures' AVX2 answer, the SRA
 *          mapping, IOSLoadTEB, RtlLocateExtendedFeature (Wine's algorithm for the AVX feature only).
 * The JIT itself is not here: what this proves is the state FEX keeps in memory and what the
 * contexts carry. A high half the JIT holds in a register when a fault arrives is test.py's G1 pin.
 */
#define NOMINMAX
#include <stdarg.h>
#include <stddef.h>
#include <string.h>

#include "windef.h"
#include "winbase.h"
#include "winnt.h"

#include <FEXCore/Core/CoreState.h>
#include <FEXCore/Core/HostFeatures.h>
#include <FEXCore/Core/SignalDelegator.h>

#include <cstdio>

#include "fex_ymmstate_define.inc"

extern "C" void ymm_wine_context_arm_to_x64(ARM64EC_NT_CONTEXT* ec_ctx, const ARM64_NT_CONTEXT* arm_ctx);
extern "C" void ymm_wine_context_x64_to_arm(ARM64_NT_CONTEXT* arm_ctx, const ARM64EC_NT_CONTEXT* ec_ctx);

// The arm64ec CONTEXT FEX's Module.cpp takes is the x64 one, as Wine's winnt.h gives it here,
// and Wine's ARM64EC_NT_CONTEXT overlays it: V[0..15] are the x64 Xmm registers.
static_assert(sizeof(CONTEXT) == 0x4d0);
static_assert(sizeof(ARM64EC_NT_CONTEXT) == sizeof(CONTEXT));
static_assert(offsetof(CONTEXT, FltSave.XmmRegisters) == 0x1a0);
static_assert(offsetof(ARM64EC_NT_CONTEXT, V) == 0x1a0);
static_assert(offsetof(ARM64_NT_CONTEXT, V) == 0x110 && sizeof(((ARM64_NT_CONTEXT*)0)->V) == 32 * 16);
static_assert(offsetof(XSTATE, YmmContext) == sizeof(XSAVE_AREA_HEADER));

// FEXCore's allocator, which HostFeatures' vectors free through; nothing here allocates with it.
namespace FEXCore::Allocator {
void free(void* Ptr) {
  ::free(Ptr);
}
void aligned_free(void* Ptr) {
  ::free(Ptr);
}
} // namespace FEXCore::Allocator

namespace FEXCore::Core {
struct InternalThreadState {
  CpuStateFrame* CurrentFrame;
};
} // namespace FEXCore::Core

namespace FEXCore::Context {
struct ContextImpl {
  struct {
    bool Is64BitMode = true;
  } Config;
  FEXCore::HostFeatures HostFeatures {};

  void ReconstructXMMRegisters(const FEXCore::Core::InternalThreadState* Thread, __uint128_t* XMM_Low, __uint128_t* YMM_High);
  void SetXMMRegistersFromState(FEXCore::Core::InternalThreadState* Thread, const __uint128_t* XMM_Low, const __uint128_t* YMM_High);

  // Not vector state: the flags and RIP helpers Module.cpp's functions also call.
  uint32_t ReconstructCompactedEFLAGS(FEXCore::Core::InternalThreadState*, bool, uint64_t*, uint32_t) {
    return 0x202;
  }
  void SetFlagsFromCompactedEFLAGS(FEXCore::Core::InternalThreadState*, uint32_t) {}
  uint64_t RestoreRIPFromHostPC(FEXCore::Core::InternalThreadState*, uint64_t) {
    return GuestRip;
  }
  uint64_t GuestRip = 0x140001000;
};

#include "fex_core_xmm.inc"
} // namespace FEXCore::Context

// What Module.cpp's functions reach through globals.
static FEXCore::Context::ContextImpl ContextShim;
static FEXCore::Context::ContextImpl* const CTX = &ContextShim;

struct CPUFeaturesShim {
  bool AVX2 = true; // FEX's CPUFeatures: CPUID leaf 7 EBX bit 5, (SupportsAVX() << 5) in CPUID.cpp
  bool IsFeaturePresent(uint32_t Feature) const {
    return Feature == PF_AVX2_INSTRUCTIONS_AVAILABLE && AVX2;
  }
};
static CPUFeaturesShim CPUFeaturesValue;
static CPUFeaturesShim* const CPUFeatures = &CPUFeaturesValue;

struct SignalDelegatorShim {
  FEXCore::SignalDelegatorConfig Config {};
  const FEXCore::SignalDelegatorConfig& GetConfig() const {
    return Config;
  }
};
static SignalDelegatorShim SignalDelegatorValue;
static SignalDelegatorShim* const SignalDelegator = &SignalDelegatorValue;

static uint8_t FakeTEB[0x2000];
static void* IOSLoadTEB() {
  return FakeTEB;
}

// Wine's RtlLocateExtendedFeature2 (dlls/ntdll/exception.c) for one feature, uncompacted: NULL
// unless KUSER_SHARED_DATA's XState enables it. On iOS that XState stays zero
// (dlls/ntdll/unix/system.c fills it only on x86), so the real one returns NULL for AVX.
static ULONG64 SharedXStateEnabledFeatures = 0;
static void* RtlLocateExtendedFeature(CONTEXT_EX* ContextEx, ULONG FeatureId, ULONG* Length) {
  if (Length) {
    *Length = sizeof(YMMCONTEXT);
  }
  if (FeatureId != XSTATE_AVX || !(SharedXStateEnabledFeatures & (1ULL << FeatureId))) {
    return nullptr;
  }
  auto* Xs = reinterpret_cast<XSTATE*>(reinterpret_cast<BYTE*>(ContextEx) + ContextEx->XState.Offset);
  return &Xs->YmmContext;
}

namespace Exception {
#include "fex_module_exception.inc"
} // namespace Exception

static int Failures;
#define CHECK(c)                                                    \
  do {                                                              \
    if (!(c)) {                                                     \
      printf("FAIL %s:%d %s [%s]\n", __FILE__, __LINE__, #c, Case); \
      Failures++;                                                   \
    }                                                               \
  } while (0)

static const char* Case = "";

// Known bytes: register r's 16 bytes, one tag per kind of value.
enum Tag : uint8_t {
  OLD_LOW = 0x10,  // xmm in FEX's state before the event
  LIVE_LOW = 0x30, // xmm live in v0..v15 at a fault (the SRA registers)
  JIT_TEMP = 0x50, // v16..v31 at a fault: FEX's own temporaries on ARM64EC (Arm64Emitter.cpp RAFPR)
  HIGH = 0xc0,     // the ymm high half in State.avx_high
  NEW_LOW = 0x70,  // xmm a SetThreadContext writes
  XSTATE_HIGH = 0xe0,
};
static void Fill(void* Out, uint8_t T, int Reg) {
  auto* B = static_cast<uint8_t*>(Out);
  for (int i = 0; i < 16; i++) {
    B[i] = static_cast<uint8_t>((T | Reg) ^ (i << 1));
  }
  B[15] = T;
}
static bool Is(const void* In, uint8_t T, int Reg) {
  uint8_t Want[16];
  Fill(Want, T, Reg);
  return !memcmp(In, Want, 16);
}
static bool IsZero(const void* In) {
  static const uint8_t Zero[16] {};
  return !memcmp(In, Zero, 16);
}
// Does any 16-byte window of [Base, Base+Size) hold register r's high half, at any alignment?
static bool ContainsHigh(const void* Base, size_t Size) {
  const auto* B = static_cast<const uint8_t*>(Base);
  for (int r = 0; r < 16; r++) {
    uint8_t Want[16];
    Fill(Want, HIGH, r);
    for (size_t o = 0; o + 16 <= Size; o++) {
      if (!memcmp(B + o, Want, 16)) {
        return true;
      }
    }
  }
  return false;
}

alignas(64) static FEXCore::Core::CpuStateFrame Frame;
static FEXCore::Core::InternalThreadState Thread {&Frame};
static FEXCore::Core::CPUState& State = Frame.State;

static void Reset(bool HostAVX, bool AVX2) {
  memset(&Frame.State.xmm, 0, sizeof(Frame.State.xmm));
  memset(Frame.State.avx_high, 0, sizeof(Frame.State.avx_high));
  ContextShim.HostFeatures = {};
  ContextShim.HostFeatures.SupportsAVX = HostAVX; // CPUFeatures.cpp's iOS branch: HostType != Wow64
  ContextShim.HostFeatures.SupportsSVE256 = false; // that branch never sets it: no SVE on iOS
  CPUFeaturesValue.AVX2 = AVX2;
  SharedXStateEnabledFeatures = 0;
  for (int r = 0; r < 16; r++) {
    Fill(&State.xmm.sse.data[r][0], OLD_LOW, r);
    Fill(&State.avx_high[r][0], HIGH, r);
  }
  // ARM64EC's static FPRs are v0..v15 for xmm0..15 (Arm64Emitter.cpp x64::SRAFPR, ARM64EC branch).
  SignalDelegatorValue.Config.SRAFPRCount = 16;
  SignalDelegatorValue.Config.SRAGPRCount = 0;
  for (int r = 0; r < 16; r++) {
    SignalDelegatorValue.Config.SRAFPRMapping[r] = r;
  }
}

static bool LowIs(uint8_t T) {
  for (int r = 0; r < 16; r++) {
    if (!Is(&State.xmm.sse.data[r][0], T, r)) {
      return false;
    }
  }
  return true;
}
static bool HighIs(uint8_t T) {
  for (int r = 0; r < 16; r++) {
    if (!Is(&State.avx_high[r][0], T, r)) {
      return false;
    }
  }
  return true;
}
static bool HighZero() {
  for (int r = 0; r < 16; r++) {
    if (!IsZero(&State.avx_high[r][0])) {
      return false;
    }
  }
  return true;
}

// A guest exception in JIT code that the guest's handler continues. Optionally the handler,
// guest code on the same thread, writes the ymm high halves (a vzeroupper here).
static void GuestExceptionContinued(bool HostAVX, bool HandlerZeroesUpper) {
  // The fault's native context: xmm live in v0..v15, FEX temporaries in v16..v31.
  ARM64_NT_CONTEXT Native {};
  Native.ContextFlags = CONTEXT_ARM64_FULL;
  for (int r = 0; r < 16; r++) {
    Fill(&Native.V[r], LIVE_LOW, r);
    Fill(&Native.V[16 + r], JIT_TEMP, r);
  }
  // RethrowGuestException: ReconstructThreadState, then StoreStateToPackedECContext.
  Exception::ReconstructThreadState(&Thread, Native);
  CHECK(LowIs(LIVE_LOW));
  CHECK(HighIs(HIGH)); // v16..v31 never reach avx_high
  ARM64_NT_CONTEXT Guest = Exception::StoreStateToPackedECContext(&Thread, 0, 0);
  for (int r = 0; r < 16; r++) {
    CHECK(Is(&Guest.V[r], LIVE_LOW, r));
    CHECK(HostAVX ? Is(&Guest.V[16 + r], HIGH, r) : IsZero(&Guest.V[16 + r]));
  }
  CHECK(((Guest.ContextFlags & CONTEXT_ARM64_FEX_YMMSTATE) == CONTEXT_ARM64_FEX_YMMSTATE) == CPUFeaturesValue.AVX2);

  // NtRaiseExceptionNative -> KiUserExceptionDispatcher -> prepare_exception_arm64ec:
  // context_arm_to_x64 makes the record the guest's handler gets. Room past it shows
  // nothing is written beyond the CONTEXT.
  struct {
    ARM64EC_NT_CONTEXT Ctx;
    uint8_t After[1024];
  } Record;
  memset(&Record, 0xa5, sizeof(Record));
  ymm_wine_context_arm_to_x64(&Record.Ctx, &Guest);
  const auto& X64 = reinterpret_cast<const CONTEXT&>(Record.Ctx);
  CHECK((X64.ContextFlags & CONTEXT_XSTATE) != CONTEXT_XSTATE);
  CHECK((X64.ContextFlags & CONTEXT_FLOATING_POINT) == CONTEXT_FLOATING_POINT);
  for (int r = 0; r < 16; r++) {
    CHECK(Is(&X64.FltSave.XmmRegisters[r], LIVE_LOW, r));
  }
  CHECK(!ContainsHigh(&Record, sizeof(Record))); // the high halves are not in the guest's record
  for (size_t i = 0; i < sizeof(Record.After); i++) {
    CHECK(Record.After[i] == 0xa5);
  }

  if (HandlerZeroesUpper) {
    memset(State.avx_high, 0, sizeof(State.avx_high)); // AVX128 VZEROUPPER: _ContextClear of avx_high
  }

  // The handler returns EXCEPTION_CONTINUE_EXECUTION: NtContinue -> context_x64_to_arm.
  ARM64_NT_CONTEXT Continue;
  memset(&Continue, 0x5a, sizeof(Continue));
  ymm_wine_context_x64_to_arm(&Continue, &Record.Ctx);
  for (int r = 0; r < 16; r++) {
    CHECK(Is(&Continue.V[r], LIVE_LOW, r));
    CHECK(IsZero(&Continue.V[16 + r]));
  }
  // The unix side resumes at the x86 pc: KiUserEmulationDispatcher -> dispatch_emulation:
  // context_arm_to_x64 into the CPU area's ContextAmd64 -> BeginSimulation -> SyncThreadContext
  // -> LoadStateFromECContext.
  ARM64EC_NT_CONTEXT ContextAmd64;
  ymm_wine_context_arm_to_x64(&ContextAmd64, &Continue);
  Exception::LoadStateFromECContext(&Thread, reinterpret_cast<CONTEXT&>(ContextAmd64));
  CHECK(LowIs(LIVE_LOW));
}

// FEX's syscall path (ECSyscallHandler::HandleSyscall -> KiUserExceptionDispatcher ->
// dispatch_syscall -> dispatch_emulation -> BeginSimulation).
static void Syscall(bool HostAVX) {
  ARM64_NT_CONTEXT Guest = Exception::StoreStateToPackedECContext(&Thread, 0, 0);
  for (int r = 0; r < 16; r++) {
    CHECK(HostAVX ? Is(&Guest.V[16 + r], HIGH, r) : IsZero(&Guest.V[16 + r]));
  }
  ARM64EC_NT_CONTEXT ContextAmd64;
  ymm_wine_context_arm_to_x64(&ContextAmd64, &Guest);
  CHECK(!ContainsHigh(&ContextAmd64, sizeof(ContextAmd64)));
  Exception::LoadStateFromECContext(&Thread, reinterpret_cast<CONTEXT&>(ContextAmd64));
  CHECK(LowIs(OLD_LOW));
  CHECK(HighIs(HIGH));
}

// A context with CONTEXT_XSTATE and an AVX area, which LoadStateFromECContext reads through
// RtlLocateExtendedFeature (no Wine path in this tree builds one: test.py pins that).
struct XStateContext {
  CONTEXT Ctx;
  CONTEXT_EX Ex;
  alignas(64) XSTATE Xs;
};
static void XStateLoad(XStateContext& In) {
  memset(&In, 0, sizeof(In));
  In.Ctx.ContextFlags = CONTEXT_FULL | CONTEXT_XSTATE;
  for (int r = 0; r < 16; r++) {
    Fill(&In.Ctx.FltSave.XmmRegisters[r], NEW_LOW, r);
    Fill(reinterpret_cast<M128A*>(&In.Xs.YmmContext) + r, XSTATE_HIGH, r);
  }
  In.Xs.Mask = 1ULL << XSTATE_AVX;
  In.Ex.XState.Offset = static_cast<LONG>(reinterpret_cast<BYTE*>(&In.Xs) - reinterpret_cast<BYTE*>(&In.Ex));
  In.Ex.XState.Length = sizeof(In.Xs);
  Exception::LoadStateFromECContext(&Thread, In.Ctx);
}

int main() {
  Case = "AVX host: guest exception continued";
  Reset(true, true);
  GuestExceptionContinued(true, false);
  CHECK(HighIs(HIGH)); // kept, by never being written

  Case = "AVX host: the handler's vzeroupper reaches the resumed code (G2)";
  Reset(true, true);
  GuestExceptionContinued(true, true);
  CHECK(HighZero()); // no XSTATE in the record, so nothing puts the interrupted code's halves back

  Case = "AVX host: syscall";
  Reset(true, true);
  Syscall(true);

  Case = "AVX host: SetThreadContext without CONTEXT_XSTATE";
  Reset(true, true);
  {
    CONTEXT In {};
    In.ContextFlags = CONTEXT_FULL; // CONTROL | INTEGER | FLOATING_POINT
    for (int r = 0; r < 16; r++) {
      Fill(&In.FltSave.XmmRegisters[r], NEW_LOW, r);
    }
    Exception::LoadStateFromECContext(&Thread, In);
    CHECK(LowIs(NEW_LOW));
    CHECK(HighIs(HIGH));
  }

  Case = "AVX host: CONTEXT_XSTATE, iOS's zero KUSER XState (RtlLocateExtendedFeature NULL)";
  Reset(true, true);
  {
    static XStateContext In;
    XStateLoad(In);
    CHECK(LowIs(NEW_LOW));
    CHECK(HighIs(HIGH));
  }

  Case = "AVX host: CONTEXT_XSTATE with AVX enabled";
  Reset(true, true);
  SharedXStateEnabledFeatures = 1ULL << XSTATE_AVX;
  {
    static XStateContext In;
    XStateLoad(In);
    CHECK(LowIs(NEW_LOW));
    CHECK(HighIs(XSTATE_HIGH));
  }

  Case = "AVX host: no AVX2 feature bit, no FEX_YMMSTATE flag";
  Reset(true, false);
  {
    ARM64_NT_CONTEXT Guest = Exception::StoreStateToPackedECContext(&Thread, 0, 0);
    CHECK((Guest.ContextFlags & CONTEXT_ARM64_FEX_YMMSTATE) != CONTEXT_ARM64_FEX_YMMSTATE);
    for (int r = 0; r < 16; r++) {
      CHECK(Is(&Guest.V[16 + r], HIGH, r)); // published anyway: SupportsAVX alone decides the copy
    }
  }

  Case = "Wow64 host (SupportsAVX false): guest exception continued";
  Reset(false, false);
  GuestExceptionContinued(false, false);
  CHECK(HighIs(HIGH));

  Case = "Wow64 host: syscall";
  Reset(false, false);
  Syscall(false);

  Case = "Wow64 host: CONTEXT_XSTATE with AVX enabled is ignored";
  Reset(false, false);
  SharedXStateEnabledFeatures = 1ULL << XSTATE_AVX;
  {
    static XStateContext In;
    XStateLoad(In);
    CHECK(LowIs(NEW_LOW));
    CHECK(HighIs(HIGH));
  }

  if (Failures) {
    printf("ymm context: %d failure(s)\n", Failures);
    return 1;
  }
  printf("ymm context: all cases passed\n");
  return 0;
}
