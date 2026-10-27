#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The ymm high halves through the ARM64EC context, checked against the trees the IPA is built from.

Since patches/fex-port 0064 the iOS ARM64EC host sets SupportsAVX with SupportsSVE256 false
(AVX128): FEX keeps each ymm register's high 128 bits in CPUState.avx_high, and the ARM64EC
context has no field of its own for them. This check establishes, in both directions, what
the context carries and what FEX keeps (PLA-451 chunk 3):

- roundtrip.cpp compiles the real FEX and Wine functions, cut from $PLAYPORT_RUN/fex and
  $PLAYPORT_RUN/pe/wine: Core.cpp's ReconstructXMMRegisters/SetXMMRegistersFromState,
  ARM64EC Module.cpp's ReconstructThreadState/StoreStateToPackedECContext/
  LoadStateFromECContext, Wine unwind.h's context_arm_to_x64/context_x64_to_arm. It mirrors
  only the order the runtime calls them in, and the services they call that are not vector
  state, and puts known ymm bytes through a guest exception that is continued, FEX's syscall
  path, a SetThreadContext without CONTEXT_XSTATE, and a context with one.
- PINS hold the call sites that order comes from, and the code a mirror cannot run (the JIT's
  register cache, Wine's lack of any XSTATE path), verbatim. A changed line fails this check:
  re-establish the convention below against the new code, then update the pin and this text.

The convention it proves: State.avx_high is the only copy of the high halves. FEX publishes it
in V[16..31] (flagged CONTEXT_ARM64_FEX_YMMSTATE); Wine drops V[16..31] in both conversions
and never sets CONTEXT_XSTATE, so the guest's handler never sees the high halves and
LoadStateFromECContext never writes them: they survive a round trip by not being touched.

Residual risk (G1, open): with the per-instruction register-cache flush covering only the
GPR and XMM static registers, the guest's in-memory avx_high can be stale at a mid-block
guest-visible fault that is CONTINUEd, so a re-executed AVX128 instruction can read an old
high half — silent corruption of the same class as MMX/x87, not a new class. And (G2, open):
no XSTATE reaches a handler, so a handler's own AVX writes (a vzeroupper) reach the
interrupted code when it resumes, and a handler cannot read or set the high halves.

Exit status 0 passed, 1 failed, 77 skipped (no FEX or Wine PE tree here: a CI checkout).
"""
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

REPO = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BUILD = Path(os.environ.get("PLAYPORT_BUILD") or REPO / ".work")
RUN = Path(os.environ.get("PLAYPORT_RUN") or BUILD / "run")
FEX = RUN / "fex"
WINE = RUN / "pe" / "wine"
SKIPPED = 77

CORE = "FEXCore/Source/Interface/Core/Core.cpp"
MODULE = "Source/Windows/ARM64EC/Module.cpp"
MODULE_S = "Source/Windows/ARM64EC/Module.S"
WOW64_MODULE = "Source/Windows/WOW64/Module.cpp"
FEX_WINNT = "Source/Windows/include/winnt.h"
CPUFEATURES = "Source/Windows/Common/CPUFeatures.cpp"
CPUID = "FEXCore/Source/Interface/Core/CPUID.cpp"
DISPATCH_H = "FEXCore/Source/Interface/Core/OpcodeDispatcher.h"
AVX128 = "FEXCore/Source/Interface/Core/OpcodeDispatcher/AVX_128.cpp"
UNWIND = "dlls/ntdll/unwind.h"
SIGNAL_EC = "dlls/ntdll/signal_arm64ec.c"

# (tree, path, text, times): text must occur exactly that many times.
PINS = [
    # The copy condition, both directions (also compiled whole by roundtrip.cpp).
    (FEX, CORE, "  if (YMM_High != nullptr && HostFeatures.SupportsAVX) {\n", 2),
    # The iOS host's answer: AVX for the ARM64EC host, never SVE256 (no SVE on iOS).
    (FEX, CPUFEATURES, "  HostFeatures.SupportsAVX = HostType != FEXCore::HostFeatures::HostTypeEnum::Wow64;\n", 1),
    # CPUID reports AVX2 (CPUFeatures' PF_AVX2, which decides CONTEXT_ARM64_FEX_YMMSTATE) and XCR0's AVX
    # bit from SupportsAVX alone.
    (FEX, CPUID, "              (SupportsAVX() << 5) |           // AVX2 support\n", 1),
    (FEX, CPUID, "  if (CTX->HostFeatures.SupportsAVX) {\n    XCR0 |= XCR0_AVX;\n", 1),
    # Who calls the copies on Windows: these and no others.
    (FEX, MODULE, "CTX->ReconstructXMMRegisters(", 2),
    (FEX, MODULE, "CTX->SetXMMRegistersFromState(", 2),
    (FEX, WOW64_MODULE, "  CTX->SetXMMRegistersFromState(Thread, reinterpret_cast<const __uint128_t*>(XSave->XmmRegisters), nullptr);\n", 1),
    (FEX, WOW64_MODULE, "  CTX->ReconstructXMMRegisters(Thread, reinterpret_cast<__uint128_t*>(XSave->XmmRegisters), nullptr);\n", 1),
    (FEX, WOW64_MODULE, "CTX->ReconstructXMMRegisters(", 1),
    (FEX, WOW64_MODULE, "CTX->SetXMMRegistersFromState(", 1),
    # Another thread's GetThreadContext on iOS (BTCpu64IosGuestContext) publishes the same way.
    (FEX, MODULE, "  CTX->ReconstructXMMRegisters(Thread, reinterpret_cast<__uint128_t*>(&Out.V[0]), reinterpret_cast<__uint128_t*>(&Out.V[16]));\n", 1),
    # The guest-exception path: reconstruct from the fault, then pack (RethrowGuestException).
    (FEX, MODULE, "  if (!IsDispatcherAddress(Context.Pc)) {\n    ReconstructThreadState(Thread, Context);\n  }\n"
                  "  ARM64_NT_CONTEXT GuestContext = StoreStateToPackedECContext(Thread, Context.Fpcr, Context.Fpsr);\n", 1),
    (FEX, MODULE, "  NtRaiseExceptionNative(&GuestRec, &GuestContext, FirstChance);\n", 1),
    # The syscall path and the suspend doorbell pack the same way.
    (FEX, MODULE, "      .Context = StoreStateToPackedECContext(Thread, static_cast<uint32_t>(FPCR), static_cast<uint32_t>(FPSR)),\n", 1),
    (FEX, MODULE, "    Exception::ReconstructThreadState(Thread, *NativeContext);\n"
                  "    *NativeContext = Exception::StoreStateToPackedECContext(Thread, NativeContext->Fpcr, NativeContext->Fpsr);\n", 1),
    # Back into the JIT: BeginSimulation hands the CPU area's ContextAmd64 to SyncThreadContext,
    # which loads it.
    (FEX, MODULE_S, "  ldr x0, [x17, #0x18] // ChpeV2CpuAreaInfo->ContextAmd64\n#ifdef FEX_IOS_HOST\n"
                    "  // llvm-mingw arm64ec emits extern \"C\" funcs as plain (unprefixed) symbols.\n  bl SyncThreadContext\n", 1),
    (FEX, MODULE, "  Exception::LoadStateFromECContext(Thread, *Context);\n", 1),
    # G1. Guest -> host calls and block ends flush the register cache, so avx_high is in memory
    # there; within a block a high-half write stays in RegCache, because the flush before each
    # instruction covers only the GPR and XMM static registers.
    (FEX, DISPATCH_H, "  IRPair<IROp_ExitFunction> ExitFunction(Ref NewRIP, BranchHint Hint = BranchHint::None) {\n"
                      "    FlushRegisterCache();\n", 1),
    (FEX, CORE, "        Thread->OpDispatcher->FlushRegisterCache(true);\n", 1),
    (FEX, DISPATCH_H, "      Mask &= (GPRMask | FPRMask);\n", 1),
    (FEX, DISPATCH_H, "  static const int FPR15Index = 47;\n  static const int AVXHigh0Index = 48;\n", 1),
    (FEX, AVX128, "    StoreContext(AVXHigh0Index + XMM, Src);\n", 1),
    # Wine: an exception's record (prepare_exception_arm64ec), NtContinue, the resume into x86 code
    # (dispatch_emulation), Get/SetThreadContext: each one of unwind.h's conversions.
    (WINE, SIGNAL_EC, "    if (rec->ExceptionCode == STATUS_EMULATION_SYSCALL) dispatch_syscall( arm_ctx );\n"
                      "    context_arm_to_x64( context, arm_ctx );\n", 1),
    (WINE, SIGNAL_EC, "NTSTATUS SYSCALL_API NtContinue( CONTEXT *context, BOOLEAN alertable )\n{\n    ARM64_NT_CONTEXT arm_ctx;\n\n"
                      "    context_x64_to_arm( &arm_ctx, (ARM64EC_NT_CONTEXT *)context );\n", 1),
    (WINE, SIGNAL_EC, "    context_arm_to_x64( get_arm64ec_cpu_area()->ContextAmd64, arm_ctx );\n    pBeginSimulation();\n", 1),
    (WINE, SIGNAL_EC, "    context_x64_to_arm( &arm_ctx, (ARM64EC_NT_CONTEXT *)context );\n"
                      "    return syscall_NtSetContextThread( handle, &arm_ctx );\n", 1),
    (WINE, SIGNAL_EC, "        context_arm_to_x64( (ARM64EC_NT_CONTEXT *)context, &arm_ctx );\n", 1),
    # G2. Wine has no XSTATE path for an x64 guest on ARM64EC: its unwind dispatch clears the flag,
    # and nothing reads FEX's CONTEXT_ARM64_FEX_YMMSTATE or locates the AVX feature.
    (WINE, SIGNAL_EC, "    context.ContextFlags &= ~0x40; /* Clear xstate flag. */\n", 1),
    (WINE, SIGNAL_EC, "FEX_YMMSTATE", 0),
    (WINE, SIGNAL_EC, "XSTATE_AVX", 0),
    (WINE, UNWIND, "FEX_YMMSTATE", 0),
    (WINE, UNWIND, "XSTATE", 0),
]


def source(tree, path):
    return (tree / path).read_text(errors="replace")


def function(text, signature):
    """One whole function: from the line holding SIGNATURE to its closing brace."""
    if text.count(signature) != 1:
        raise SystemExit(f"build/ymm-context/test.py: {signature!r} found {text.count(signature)} times")
    start = text.rindex("\n", 0, text.index(signature)) + 1
    end = text.index("{", text.index(signature)) + 1
    depth = 1
    while depth:
        depth += {"{": 1, "}": -1}.get(text[end], 0)
        end += 1
    return text[start:end] + "\n"


def between(text, first, last):
    """FIRST's line through LAST, each found once."""
    for marker in (first, last):
        if text.count(marker) != 1:
            raise SystemExit(f"build/ymm-context/test.py: {marker!r} found {text.count(marker)} times")
    start = text.index(first)
    return text[start:text.index(last, start) + len(last)] + "\n"


def check_pins():
    failed = 0
    for tree, path, text, times in PINS:
        found = source(tree, path).count(text)
        if found != times:
            print(f"PIN {tree.name}/{path}: {found} (want {times}) of:\n{text}", flush=True)
            failed += 1
    # The iOS branch of FetchHostFeatures never claims SVE256.
    ios = between(source(FEX, CPUFEATURES), "#ifdef FEX_IOS_HOST\n  /* iOS-Madeira: registry", "  return HostFeatures;\n#else")
    if re.search(r"SupportsSVE\w*\s*=", ios):
        print("PIN CPUFeatures.cpp: the iOS branch now sets an SVE feature; roundtrip.cpp assumes SupportsSVE256 false", flush=True)
        failed += 1
    return failed


def generate(gen):
    core = source(FEX, CORE)
    (gen / "fex_core_xmm.inc").write_text(
        f"// Cut from {CORE} by build/ymm-context/test.py.\n"
        + function(core, "void ContextImpl::ReconstructXMMRegisters(")
        + function(core, "void ContextImpl::SetXMMRegistersFromState("))
    module = source(FEX, MODULE)
    (gen / "fex_module_exception.inc").write_text(
        f"// Cut from {MODULE} by build/ymm-context/test.py.\n"
        + function(module, "static void LoadStateFromECContext(")
        + function(module, "static void ReconstructThreadState(")
        + function(module, "static ARM64_NT_CONTEXT StoreStateToPackedECContext("))
    define = "#define CONTEXT_ARM64_FEX_YMMSTATE (CONTEXT_ARM64 | 0x00000040)\n"
    if source(FEX, FEX_WINNT).count(define) != 1:
        raise SystemExit(f"build/ymm-context/test.py: {FEX_WINNT} no longer defines {define.strip()!r}")
    (gen / "fex_ymmstate_define.inc").write_text(f"// From {FEX_WINNT}.\n{define}")
    (gen / "wine_unwind_conversions.inc").write_text(
        f"/* Cut from {UNWIND} by build/ymm-context/test.py. */\n"
        + between(source(WINE, UNWIND), "static const ULONG exception_flags_mask",
                  "    memcpy( ec_ctx->V, arm_ctx->V, sizeof(ec_ctx->V) );\n}"))


def main():
    missing = [str(p) for p in (FEX / CORE, FEX / MODULE, WINE / UNWIND, WINE / SIGNAL_EC) if not p.is_file()]
    if missing:
        print(f"build/ymm-context/test.py: skipped (no tree: {', '.join(missing)})", flush=True)
        return SKIPPED
    failed = check_pins()
    scratch = BUILD / "c-test"
    scratch.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="ymm-context-", dir=scratch) as tmp:
        gen = Path(tmp)
        generate(gen)
        env = dict(os.environ, TMPDIR=str(gen))
        wine_obj = gen / "wine_context.o"
        exe = gen / "ymm-context"
        subprocess.run(["clang", "-std=c11", "-O1", "-Wall", "-Wextra", "-Werror", "-c",
                        "-I", str(gen), "-isystem", str(WINE / "include"),
                        str(HERE / "wine_context.c"), "-o", str(wine_obj)], check=True, env=env)
        subprocess.run(["clang++", "-std=c++20", "-O1", "-Wall", "-Wextra", "-Werror", "-DFEX_IOS_HOST",
                        "-fsanitize=address,undefined", "-fno-sanitize-recover=all",
                        "-I", str(gen), "-isystem", str(WINE / "include"), "-isystem", str(FEX / "FEXCore/include"),
                        str(HERE / "roundtrip.cpp"), str(wine_obj), "-o", str(exe)], check=True, env=env)
        run = subprocess.run([str(exe)], env=env)
        failed += run.returncode != 0
    print("build/ymm-context/test.py: " + ("passed" if not failed else "FAILED"), flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
