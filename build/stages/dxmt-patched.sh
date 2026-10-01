#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build both halves of the DXMT slice from ONE patched tree: the unix objects
# that go into libdxmt_combined.a (and so into the app executable) and the PE
# DLLs the app bundles. The tree is upstream DXMT at the dxmt pin with two
# series on it, in order:
#   patches/dxmt-port: Madeira's iOS port of DXMT, rebased onto the pin. It
#     appends winemetal unix slots 146-149 after upstream's 127-145, so a PE
#     DLL and a unix table from different trees call the wrong functions: the
#     two halves must never come from different trees;
#   patches/dxmt: Playport's own changes:
#     background-gpu-gate, unix side only (no slot changes): Metal commits
#       wait while the app is in the background;
#     command-library-from-source: dxmt_command.metal is compiled on the
#       device through upstream's slot 144 (MTLDevice_newLibraryWithSource);
#     madeira-cfg-sibling-include: winemetal_unix.c reaches Madeira's
#       build/madeira_cfg.h beside the fork, as it reaches remote-metal/;
#     compile-timing, both halves (no slot changes): [shader-time] lines
#       for every shader conversion and pipeline creation, [pso-wait] lines
#       for draws that wait for a pipeline;
#     encoding-context-init-order, PE side only: the encoding context's
#       device is initialized before the command contexts that use it.
#
#   build/stages/dxmt-patched.sh ROOT [stage...]   stages: fork unix pe (default all)
#
# fork  copies upstream DXMT at the dxmt pin from DXMT_BUILD_ROOT and applies both series
# unix  stages/dxmt-base.sh unix on that tree, with the hand-ported AIR helper
#       headers, then libdxmt_unix.a. Next: DXMT_UNIX=ROOT stages/dxmt-combined.sh
# pe    meson + ninja of the same tree for aarch64-windows and arm64ec-windows;
#       ROOT/pe/<arch>-windows/ gets d3d11, dxgi, winemetal and d3d10core,
#       the DXMT modules the reference app bundles per arch
#
# Inputs (env):
#   DXMT_BUILD_ROOT  stages/dxmt-base.sh ROOT after `clones llvm`
#   SHADER_HEADERS   air_*.h from build/air-helpers/air-helper-port.sh `air`
#   WINE             stages/wine-pe.sh tree: build-macos, build-arm64ec, build-tools
#   LLVM_MINGW       build/lib.sh
# Nothing is installed; all output stays under ROOT.
set -euo pipefail

ROOT=$(realpath -m "${1:?usage: $0 ROOT [stage...]}")
shift || true
STAGES=${*:-fork unix pe}
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../lib.sh"
DXB=$(realpath "${DXMT_BUILD_ROOT:?set DXMT_BUILD_ROOT to a stages/dxmt-base.sh ROOT}")
SHADER_HEADERS=${SHADER_HEADERS:?set SHADER_HEADERS to the air-helper-port.sh shader-headers/}
WINE=${WINE:?set WINE to the stages/wine-pe.sh tree}
MINGW=$LLVM_MINGW
PIN=$(pin dxmt)
mkdir -p "$ROOT"

stage_fork() {
    test "$(git -C "$DXB/dxmt" rev-parse HEAD)" = "$PIN"
    rm -rf "$ROOT/dxmt" "$ROOT/remote-metal" "$ROOT/build"
    cp -a "$DXB/dxmt" "$ROOT/dxmt"
    apply_series "$ROOT/dxmt" dxmt-port
    apply_series "$ROOT/dxmt" dxmt
    # winemetal_unix.c includes ../../../../remote-metal/protocol.h and ../../../../build/madeira_cfg.h
    cp -aL "$DXB/remote-metal" "$ROOT/remote-metal"
    cp -aL "$DXB/build" "$ROOT/build"
    echo "fork $(git -C "$ROOT/dxmt" rev-parse HEAD)" | tee "$ROOT/fork.txt"
}

stage_unix() {
    check_series "$ROOT/dxmt" "dxmt-port dxmt" "$PIN"
    for l in llvm-project llvm-host-build mythic-pin; do ln -sfn "$DXB/$l" "$ROOT/$l"; done
    rm -rf "$ROOT/shader-headers" && cp -a "$SHADER_HEADERS" "$ROOT/shader-headers"
    bash "$HERE/dxmt-base.sh" "$ROOT" unix
    rm -f "$ROOT/libdxmt_unix.a"
    llvm-ar --format=darwin rcs "$ROOT/libdxmt_unix.a" "$ROOT/obj"/*.o
    sha256sum "$ROOT/libdxmt_unix.a" "$ROOT/obj/winemetal_unix.o"
}

stage_pe() {
    if command -v xcrun metal metallib; then echo "an Apple tool is on PATH"; return 1; fi
    local arch tree
    # upstream dropped its native file (build-osx.txt) with the same content
    printf "[binaries]\nc = 'clang'\ncpp = 'clang++'\n" > "$ROOT/native-clang.txt"
    for arch in aarch64 arm64ec; do
        tree=$([ $arch = aarch64 ] && echo build-macos || echo build-arm64ec)
        # Wine's layout for -Dwine_build_path: PE libraries plus build-tools/tools
        mkdir -p "$ROOT/wine-$arch"
        for d in libs dlls include; do ln -sfn "$WINE/$tree/$d" "$ROOT/wine-$arch/$d"; done
        ln -sfn "$WINE/build-tools/tools" "$ROOT/wine-$arch/tools"
        sed "s#'@GLOBAL_SOURCE_ROOT@' / 'toolchains/llvm-mingw-20260421-ucrt-macos-universal#'$MINGW#" \
            "$ROOT/dxmt/build-$arch-win.txt" > "$ROOT/cross-$arch.txt"
        rm -rf "$ROOT/build-$arch"
        # llvm-mingw 20260922's libc++ no longer includes <iterator> and
        # <functional> transitively; lld stamps each PE with its link time
        # unless told not to, so no two builds would match
        (cd "$ROOT/dxmt" && PATH=$MINGW/bin:$PATH meson setup --cross-file "$ROOT/cross-$arch.txt" \
            --native-file "$ROOT/native-clang.txt" -Dwine_build_path="$ROOT/wine-$arch" \
            --buildtype release -Dcpp_args="-include iterator -include functional" \
            -Dc_link_args=-Wl,--no-insert-timestamp -Dcpp_link_args=-Wl,--no-insert-timestamp \
            "$ROOT/build-$arch") > "$ROOT/meson-$arch.log"
        PATH=$MINGW/bin:$PATH ninja -C "$ROOT/build-$arch" > "$ROOT/ninja-$arch.log"
        mkdir -p "$ROOT/pe/$arch-windows"
        # A release build (-O3, NDEBUG), as vulkan-pe.sh builds DXVK: meson's
        # default, the debug buildtype (-O0, asserts on), made DXMT's encode
        # thread do 1.6 times the work (docs/evidence/2026-09-27-patch-ab.md).
        # The strip stays: DWARF from a debug build (about 31 MB in
        # d3d11.dll) crashes Wine's dbghelp in dwarf2_fill_attr when a title
        # loads a module's symbols (Witcher 3 does at start-up:
        # docs/evidence/2026-09-25-witcher3-setup.md §18).
        for f in d3d11/d3d11.dll dxgi/dxgi.dll winemetal/winemetal.dll d3d10/d3d10core.dll; do
            "$MINGW/bin/llvm-strip" --strip-debug -o "$ROOT/pe/$arch-windows/$(basename "$f")" \
                "$ROOT/build-$arch/src/$f"
        done
    done
    (cd "$ROOT/pe" && sha256sum */*.dll)
}

for s in $STAGES; do echo "== $s"; stage_$s; done
