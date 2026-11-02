#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The compatibility probes: small Windows programs that check one runtime path
# on the phone, built with llvm-mingw into $PLAYPORT_BUILD/compat/probes/<name>/,
# a folder to put in the dev app's Documents/Import and add with
# `pp ui --action import:Import/<name>` (docs/ARCHITECTURE.md, OpenGL).
#
#   gl21   x86-64 OpenGL 2.1 through WGL: the pointer-path checks, clear, a
#          fixed-function and a GLSL 1.20 triangle, SwapBuffers; `stress`
#          measures 20,000 vertices a frame (gl21.c)
#   gl21-i386  the same for i386 (WoW64): gl21-i386.exe
#   wgl    x86-64 WGL behaviours games rely on: a dummy window, pixel formats
#          (depth/stencil, sRGB, MSAA), pbuffers, shared contexts, swap
#          interval, resize, a mode change, read back where it can (wgl.c)
#   childabort-i386  i386 (WoW64): a dxdiag child, crashing children and
#          terminated threads while busy workers allocate and translate code;
#          the workers must keep going and terminated ones stop; a crash that
#          starts the AeDebug debugger must still end (childabort.c, PLA-117,
#          PLA-120, PLA-200, PLA-173); killwait and crashwait end threads
#          parked in in-process waits, alone and in crashed children (PLA-229,
#          PLA-230)
#   childabort  the same for x86-64 (ARM64EC): childabort.exe (PLA-226); its
#          rwx phase frees and allocates RWX pages across threads (PLA-228)
#          (both) the noflush phase rewrites code without FlushInstructionCache,
#          also beside writable pages in one 16 KiB host page (PLA-206); the
#          flush phase does the same with FlushInstructionCache (PLA-325)
#   x87m64-i386  i386 (WoW64): 64-bit integers through fild/fistp must come
#          back exactly at 64-bit x87 precision, also with a branch between
#          them as in Delphi's Move (x87m64.c, PLA-202, PLA-235)
#   protect  x86-64: the cost of one-page VirtualProtect calls (data, RX, the
#          image's own pages, write-protect-call) and a user shared data
#          read from x86 code (protect.c, PLA-118); `purge` (named) commits,
#          releases and recommits 1.5 GiB five times and decommits a region:
#          every recommitted page must read zero (the dev donor pool's whole-
#          object purge, PLA-363)
#   machine  x86-64: the machine values wineboot writes (environment, CPU keys,
#          computer name, Volatile Environment), xaudio2_9redist.dll by
#          LoadLibrary and by a child that imports it (xaudio2redist.exe), the
#          CurrentControlSet link and stdole2's typelib (machine.c, PLA-168,
#          PLA-167, PLA-166) and the CPUID brand string on every
#          processor (PLA-220)
#   machine-i386  the same for i386 (WoW64): machine-i386.exe
#   splitlock  x86-64: the cost and the results of lock xadd, lock cmpxchg
#          and xchg on slots across a 16-byte and a 64-byte boundary (guest
#          split locks), single-threaded and contended (splitlock.c, PLA-242)
#   splitlock-i386  the same for i386 (WoW64), 4-byte slots only
#   threadctx  x86-64: GetThreadContext of another thread before it starts,
#          spinning in a guest loop and blocked in a wait, and
#          SetThreadContext on it, and a counting thread suspended again
#          (threadctx.c, PLA-245, PLA-302, PLA-304)
#   threadctx-i386  the same for i386 (WoW64)
#   shmap  x86-64: two writable views of a small section, and one through a
#          duplicated handle, pagefile and file backed, 0x14 to 0x5000 bytes,
#          must map and alias (shmap.c, PLA-307)
#   shmap-i386  the same for i386 (WoW64)
#   poolstress  x86-64 and i386 (both in one folder): children started one
#          after another, x86-64 and i386, each calling into the DLLs it loads
#          and into code it writes; the pool's head must not grow with every
#          child (poolstress.c, PLA-213)
#   console  x86-64, the one console-subsystem probe (no -mwindows): the
#          conhost kernelbase starts for it, cmd /c echo into a pipe and
#          cmd /c exit 7 in a new console (console.c, PLA-390)
#   cputopo  x86-64: the processor count and topology a guest is told by
#          GetSystemInfo, CPUID (leaves 1, 4, 0xB, 0x1F, 0x80000008) and
#          GetLogicalProcessorInformationEx, and a timed spin on every
#          processor, which tells the fast cluster from the slow one
#          (cputopo.c, PLA-392)
#   cputopo-i386  the same for i386 (WoW64): cputopo-i386.exe
#   arm64  a plain ARM64 program (aarch64), started as a native ARM64 child
#          with no FEX: its machine, a sysarm64 DLL, code it writes (RWX and
#          RW made executable), 800 RWX blocks of 1.3 MB run and freed (the
#          pool must get them back), system32's ntdll read into RWX memory
#          and its NtProtectVirtualMemory export called there, a thread and
#          an ARM64 child of its own; exit 42 when every check passes
#          (arm64.c, PLA-512, PLA-514, decision 0170); with `x18` as its
#          arguments it then reports whether x18 survives kernel entries,
#          a context switch, Wine calls and an exception, plain and with
#          the custom x18 ABI bit set, without changing the exit code (PLA-516)
#   arm64-fault  the same program writing through a null pointer: the play
#          must end as a failed one (arm64-fault.exe)
#   arm64-min  aarch64 with no C runtime: kernel32 only, ExitProcess(42)
#          (arm64-min.exe, a loader-only start)
#   arm64-x86_64  arm64.c for x86-64, to check the program itself under
#          desktop Wine (not a phone probe)
#   d3d12  aarch64 Direct3D 12 for a native ARM64 child: DXGI, a device, a
#          swap chain on a window, a triangle from embedded Shader Model 5.0
#          bytecode and 24 quads each sampling a texture (BC1/2/3/7,
#          8-bit and 16-bit formats, sRGB views, mips, placed, custom-heap
#          WriteToSubresource, copy queue, heap samplers) presented for 5
#          seconds, the last frame read back and every quad's colour
#          checked; logs to d3d12.log, exit 0 (d3d12.c, PLA-518, PLA-516;
#          shaders: d3d12.hlsl, d3d12-shaders.sh). `skip I,J` leaves checks out
#   d3d12-x86_64  d3d12.c for x86-64, to check the program under desktop
#          Wine (not a phone probe)
#   ymmctx  x86-64: the ymm registers' high halves through an exception the
#          guest handles (int3, a continued access violation, RaiseException,
#          a vectored and a frame handler that overwrite ymm, a handler that
#          reads and writes the context's XSTATE), an APC and a thread's
#          Get/SetThreadContext, and what the guest is told about AVX; `noavx`
#          expects no AVX (FEX_HOSTFEATURES' disableavx) (ymmctx.c, PLA-516)
#   exchook  x86-64: x64 KiUserExceptionDispatcher's code and its
#          Wow64PrepareForException hook as x64 Windows has them: the hook
#          called first, in x64 code, with rsp+8 the context, the record at
#          context+0x4f0 and a machine frame; int3 and access violation
#          values; its context changes reach the handlers and the resumed
#          code; RtlRestoreContext and NtContinue from the hook; another
#          thread (exchook.c, PLA-516, PLA-514)
#
#   tools/compat/probes/build.sh
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../../../build/lib.sh"
CC=${LLVM_MINGW:?set LLVM_MINGW (pp setup)}/bin/x86_64-w64-mingw32-clang
CC32=$LLVM_MINGW/bin/i686-w64-mingw32-clang
CCA64=$LLVM_MINGW/bin/aarch64-w64-mingw32-clang
OUT=$PLAYPORT_BUILD/compat/probes

mkdir -p "$OUT/gl21" "$OUT/gl21-i386"
"$CC" -O2 -Wall -Wextra -Werror -Wno-unused-parameter -mwindows -Wl,--no-insert-timestamp \
    -o "$OUT/gl21/gl21.exe" "$HERE/gl21.c" -lopengl32 -lgdi32 -luser32
"$CC32" -O2 -Wall -Wextra -Werror -Wno-unused-parameter -mwindows -Wl,--no-insert-timestamp \
    -o "$OUT/gl21-i386/gl21-i386.exe" "$HERE/gl21.c" -lopengl32 -lgdi32 -luser32
mkdir -p "$OUT/wgl"
"$CC" -O2 -Wall -Wextra -Werror -Wno-unused-parameter -mwindows -Wl,--no-insert-timestamp \
    -o "$OUT/wgl/wgl.exe" "$HERE/wgl.c" -lopengl32 -lgdi32 -luser32
mkdir -p "$OUT/childabort" "$OUT/childabort-i386"
"$CC" -O2 -Wall -Wextra -Werror -Wno-unused-parameter -mwindows -Wl,--no-insert-timestamp \
    -o "$OUT/childabort/childabort.exe" "$HERE/childabort.c"
"$CC32" -O2 -Wall -Wextra -Werror -Wno-unused-parameter -mwindows -Wl,--no-insert-timestamp \
    -o "$OUT/childabort-i386/childabort-i386.exe" "$HERE/childabort.c"
mkdir -p "$OUT/x87m64-i386"
"$CC32" -O2 -Wall -Wextra -Werror -Wno-unused-parameter -mwindows -Wl,--no-insert-timestamp \
    -o "$OUT/x87m64-i386/x87m64-i386.exe" "$HERE/x87m64.c"
mkdir -p "$OUT/protect"
"$CC" -O2 -Wall -Wextra -Werror -Wno-unused-parameter -mwindows -Wl,--no-insert-timestamp \
    -o "$OUT/protect/protect.exe" "$HERE/protect.c"
mkdir -p "$OUT/splitlock" "$OUT/splitlock-i386"
"$CC" -O2 -Wall -Wextra -Werror -Wno-unused-parameter -mwindows -Wl,--no-insert-timestamp \
    -o "$OUT/splitlock/splitlock.exe" "$HERE/splitlock.c"
"$CC32" -O2 -Wall -Wextra -Werror -Wno-unused-parameter -mwindows -Wl,--no-insert-timestamp \
    -o "$OUT/splitlock-i386/splitlock-i386.exe" "$HERE/splitlock.c"
mkdir -p "$OUT/threadctx" "$OUT/threadctx-i386"
"$CC" -O2 -Wall -Wextra -Werror -Wno-unused-parameter -mwindows -Wl,--no-insert-timestamp \
    -o "$OUT/threadctx/threadctx.exe" "$HERE/threadctx.c"
"$CC32" -O2 -Wall -Wextra -Werror -Wno-unused-parameter -mwindows -Wl,--no-insert-timestamp \
    -o "$OUT/threadctx-i386/threadctx-i386.exe" "$HERE/threadctx.c"
mkdir -p "$OUT/shmap" "$OUT/shmap-i386"
"$CC" -O2 -Wall -Wextra -Werror -Wno-unused-parameter -mwindows -Wl,--no-insert-timestamp \
    -o "$OUT/shmap/shmap.exe" "$HERE/shmap.c"
"$CC32" -O2 -Wall -Wextra -Werror -Wno-unused-parameter -mwindows -Wl,--no-insert-timestamp \
    -o "$OUT/shmap-i386/shmap-i386.exe" "$HERE/shmap.c"
mkdir -p "$OUT/poolstress"
"$CC" -O2 -Wall -Wextra -Werror -Wno-unused-parameter -mwindows -Wl,--no-insert-timestamp \
    -o "$OUT/poolstress/poolstress.exe" "$HERE/poolstress.c" -lole32 -ladvapi32 -luser32
"$CC32" -O2 -Wall -Wextra -Werror -Wno-unused-parameter -mwindows -Wl,--no-insert-timestamp \
    -o "$OUT/poolstress/poolstress-i386.exe" "$HERE/poolstress.c" -lole32 -ladvapi32 -luser32
mkdir -p "$OUT/console"
"$CC" -O2 -Wall -Wextra -Werror -Wno-unused-parameter -Wl,--no-insert-timestamp \
    -o "$OUT/console/console.exe" "$HERE/console.c"
mkdir -p "$OUT/cputopo" "$OUT/cputopo-i386"
"$CC" -O2 -Wall -Wextra -Werror -Wno-unused-parameter -mwindows -Wl,--no-insert-timestamp \
    -o "$OUT/cputopo/cputopo.exe" "$HERE/cputopo.c"
"$CC32" -O2 -Wall -Wextra -Werror -Wno-unused-parameter -mwindows -Wl,--no-insert-timestamp \
    -o "$OUT/cputopo-i386/cputopo-i386.exe" "$HERE/cputopo.c"
mkdir -p "$OUT/arm64" "$OUT/arm64-fault" "$OUT/arm64-min" "$OUT/arm64-x86_64"
"$CCA64" -O2 -Wall -Wextra -Werror -Wno-unused-parameter -mwindows -Wl,--no-insert-timestamp \
    -o "$OUT/arm64/arm64.exe" "$HERE/arm64.c"
"$CCA64" -O2 -Wall -Wextra -Werror -Wno-unused-parameter -mwindows -Wl,--no-insert-timestamp -DPROBE_FAULT \
    -o "$OUT/arm64-fault/arm64-fault.exe" "$HERE/arm64.c"
"$CCA64" -O2 -Wall -Wextra -Werror -Wno-unused-parameter -mwindows -Wl,--no-insert-timestamp -DPROBE_MIN \
    -nostdlib -Wl,-e,entry -o "$OUT/arm64-min/arm64-min.exe" "$HERE/arm64.c" -lkernel32
"$CC" -O2 -Wall -Wextra -Werror -Wno-unused-parameter -mwindows -Wl,--no-insert-timestamp \
    -o "$OUT/arm64-x86_64/arm64-x86_64.exe" "$HERE/arm64.c"
mkdir -p "$OUT/d3d12" "$OUT/d3d12-x86_64"
"$CCA64" -O2 -Wall -Wextra -Werror -Wno-unused-parameter -mwindows -Wl,--no-insert-timestamp \
    -o "$OUT/d3d12/d3d12.exe" "$HERE/d3d12.c" -ld3d12 -ldxgi
"$CC" -O2 -Wall -Wextra -Werror -Wno-unused-parameter -mwindows -Wl,--no-insert-timestamp \
    -o "$OUT/d3d12-x86_64/d3d12-x86_64.exe" "$HERE/d3d12.c" -ld3d12 -ldxgi
mkdir -p "$OUT/ymmctx"
"$CC" -O2 -Wall -Wextra -Werror -Wno-unused-parameter -mwindows -Wl,--no-insert-timestamp \
    -o "$OUT/ymmctx/ymmctx.exe" "$HERE/ymmctx.c"
mkdir -p "$OUT/exchook"
"$CC" -O2 -Wall -Wextra -Werror -Wno-unused-parameter -mwindows -Wl,--no-insert-timestamp \
    -o "$OUT/exchook/exchook.exe" "$HERE/exchook.c"
# xaudio2_9redist.dll's import library: llvm-mingw has none (the EOS SDK
# links Microsoft's), so it is made from its one export here.
DLLTOOL=$LLVM_MINGW/bin/llvm-dlltool
mkdir -p "$OUT/machine" "$OUT/machine-i386" "$OUT/lib"
printf 'LIBRARY xaudio2_9redist.dll\nEXPORTS\nXAudio2Create\n' > "$OUT/lib/xaudio2_9redist-x64.def"
printf 'LIBRARY xaudio2_9redist.dll\nEXPORTS\nXAudio2Create@12\n' > "$OUT/lib/xaudio2_9redist-x86.def"
"$DLLTOOL" -m i386:x86-64 -d "$OUT/lib/xaudio2_9redist-x64.def" -l "$OUT/lib/libxaudio2_9redist-x64.a"
"$DLLTOOL" -m i386 -k -d "$OUT/lib/xaudio2_9redist-x86.def" -l "$OUT/lib/libxaudio2_9redist-x86.a"
"$CC" -O2 -Wall -Wextra -Werror -Wno-unused-parameter -mwindows -Wl,--no-insert-timestamp \
    -o "$OUT/machine/machine.exe" "$HERE/machine.c" -loleaut32 -lole32 -ladvapi32 -lpowrprof
"$CC" -O2 -Wall -Wextra -Werror -Wno-unused-parameter -mwindows -Wl,--no-insert-timestamp -DXAUDIO2_IMPORT \
    -o "$OUT/machine/xaudio2redist.exe" "$HERE/machine.c" "$OUT/lib/libxaudio2_9redist-x64.a"
"$CC32" -O2 -Wall -Wextra -Werror -Wno-unused-parameter -mwindows -Wl,--no-insert-timestamp \
    -o "$OUT/machine-i386/machine-i386.exe" "$HERE/machine.c" -loleaut32 -lole32 -ladvapi32 -lpowrprof
"$CC32" -O2 -Wall -Wextra -Werror -Wno-unused-parameter -mwindows -Wl,--no-insert-timestamp -DXAUDIO2_IMPORT \
    -o "$OUT/machine-i386/xaudio2redist.exe" "$HERE/machine.c" "$OUT/lib/libxaudio2_9redist-x86.a"
# The child again in redist/, where a title's own xaudio2_9redist.dll may be put by hand.
for probe in machine machine-i386; do
    mkdir -p "$OUT/$probe/redist"
    cp "$OUT/$probe/xaudio2redist.exe" "$OUT/$probe/redist/"
done
for probe in gl21 gl21-i386 wgl childabort childabort-i386 x87m64-i386 protect machine machine-i386 splitlock splitlock-i386 threadctx threadctx-i386 shmap shmap-i386 poolstress console cputopo cputopo-i386 arm64 arm64-fault arm64-min arm64-x86_64 d3d12 d3d12-x86_64 ymmctx exchook; do
    echo "$(sha256sum "$OUT/$probe/$probe.exe" | cut -c1-16)  $probe.exe ($(stat -c %s "$OUT/$probe/$probe.exe") bytes) in $OUT/$probe"
done
