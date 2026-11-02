#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The Vulkan Direct3D backend's PE DLLs (decision 0014): DXVK (Direct3D 8 to
# 11) and vkd3d-proton (Direct3D 12) for arm64ec-windows, the architecture an
# x86-64 game's DLLs load as under Wine ARM64EC, and DXVK's Direct3D 9 to 11
# for i386-windows, what an i386 (WoW64) title such as Portal 2 (Direct3D 9) or
# Tomb Raider (Direct3D 11) loads. Each DLL is stripped of its
# DWARF (as the DXMT stage does) and marked a Wine builtin with winebuild
# --builtin: Madeira's loader ignores a DLL found through WINEDLLPATH that is
# not one. vkd3d-proton carries patches/vkd3d-proton and DXVK patches/dxvk
# (decision 0061). The app stages them under Runtime/vulkan/arm64ec-windows, where a
# launch set to Vulkan finds them before DXMT's (wine_host_init,
# PLAYPORT_DLL_OVERLAY).
#
# For a native ARM64 child (decision 0170: World of Warcraft's ARM64 client) it
# also builds vkd3d-proton (d3d12, d3d12core) and DXVK's dxgi for
# aarch64-windows, staged under Runtime/vulkan/aarch64-windows, which a launch
# set to Vulkan links over sysarm64 (wine_host.c link_wow64_farm) and puts
# first on WINEDLLPATH. The dxgi is DXVK's, not one of the aarch64 dxgi.dll
# Playport already ships: the arm64ec backend already pairs vkd3d-proton with
# DXVK's dxgi (as Proton does), whose adapters are Vulkan devices on the same
# winevulkan; DXMT's aarch64 dxgi (Runtime/aarch64-windows) enumerates Metal
# devices for DXMT's d3d11, and Wine's builtin one, which DXMT's replaces, is
# wined3d's. Only dxgi is built from DXVK here: an ARM64 child's Direct3D 9
# to 11 stay DXMT's and Wine's, which no native ARM64 game needs yet.
#
# The loader stage builds the Khronos Vulkan-Loader (vulkan-1.dll, unmodified, at
# the vulkan-loader pin with the vulkan-headers pin) for arm64ec and aarch64,
# each beside Wine's own winevulkan.json, the ICD manifest winevulkan's
# DllRegisterServer writes (decision 0131). The app stages them under
# Runtime/vulkan-loader/<arch>-windows, which a play with khronosVulkanLoader
# links over system32 (and sysarm64) after its backend's set.
# The loader has no assembler here (USE_GAS/USE_MASM off): its trampolines for
# functions it does not know are aarch64 code, not ARM64EC, and the headers it is
# built with are winevulkan's, so it knows every function winevulkan has.
#
#   build/stages/vulkan-pe.sh [ROOT] [stage...]   ROOT defaults to $PLAYPORT_BUILD/run/vulkan-pe;
#                                                  stages: src dxvk dxvk32 dxgi-aarch64 vkd3d loader
#                                                  (default all; vkd3d and loader build arm64ec and aarch64)
#
# Inputs (env): LLVM_MINGW (build/lib.sh); WINEBUILD, default the pe stage's
# $PLAYPORT_BUILD/run/pe/wine/build-tools/tools/winebuild/winebuild; WINE_SRC, the
# pe stage's Wine tree (default $PLAYPORT_BUILD/run/pe/wine), for winevulkan.json.
# Output: ROOT/pe/arm64ec-windows/*.dll, ROOT/pe/i386-windows/*.dll,
# ROOT/pe/aarch64-windows/{d3d12,d3d12core,dxgi}.dll,
# ROOT/loader/{arm64ec,aarch64}-windows/{vulkan-1.dll,winevulkan.json}. Host tools: meson, ninja,
# cmake, glslangValidator.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../lib.sh"
ROOT=$(realpath -m "${1:-$PLAYPORT_BUILD/run/vulkan-pe}")
shift || true
STAGES=${*:-src dxvk dxvk32 dxgi-aarch64 vkd3d loader}
MINGW=${LLVM_MINGW:?set LLVM_MINGW (pp setup)}
WINEBUILD=${WINEBUILD:-$PLAYPORT_BUILD/run/pe/wine/build-tools/tools/winebuild/winebuild}
WINE_SRC=${WINE_SRC:-$PLAYPORT_BUILD/run/pe/wine}
JOBS=${JOBS:-$(nproc)}
ARCH=arm64ec

# fetch NAME DIR [SERIES]: the pins.lock commit of NAME with its submodules,
# shallow, and with patches/SERIES on it when given (build/lib.sh ensure_series).
fetch() {
    local name=$1 dir=$2 series=${3:-} rev
    rev=$(pin "$name")
    if ! git -C "$dir" cat-file -e "$rev^{commit}" 2>/dev/null; then
        rm -rf "$dir"
        git init -q "$dir"
        git -C "$dir" fetch -q --depth 1 "$(pin_url "$name")" "$rev"
    fi
    if [ -n "$series" ]; then
        ensure_series "$dir" "$series" "$rev"
    elif [ "$(git -C "$dir" rev-parse HEAD)" != "$rev" ]; then
        git -c advice.detachedHead=false -C "$dir" checkout -q -f "$rev"
    fi
    git -C "$dir" submodule update -q --init --recursive --depth 1
    echo "$name $(git -C "$dir" rev-parse HEAD)"
}

# cross_file: the meson cross file for $ARCH (arm64ec or aarch64, or i686 for i386).
cross_file() {
    local family=aarch64
    [ "$ARCH" = i686 ] && family=x86
    cat > "$ROOT/cross-$ARCH.txt" <<EOF
[binaries]
c = '$MINGW/bin/$ARCH-w64-mingw32-clang'
cpp = '$MINGW/bin/$ARCH-w64-mingw32-clang++'
ar = '$MINGW/bin/llvm-ar'
strip = '$MINGW/bin/llvm-strip'
windres = '$MINGW/bin/$ARCH-w64-mingw32-windres'
widl = '$MINGW/bin/$ARCH-w64-mingw32-widl'

[built-in options]
# lld stamps each PE with its link time otherwise: no two builds would match
c_link_args = ['-Wl,--no-insert-timestamp']
cpp_link_args = ['-Wl,--no-insert-timestamp']

[properties]
needs_exe_wrapper = true

[host_machine]
system = 'windows'
cpu_family = '$family'
cpu = '$family'
endian = 'little'
EOF
}

# install_dll SRC [DIR]: strip, mark builtin, copy into DIR (default pe/<Wine arch>-windows).
install_dll() {
    local dir=${2:-$ROOT/pe/$ARCH-windows}
    [ -z "${2:-}" ] && [ "$ARCH" = i686 ] && dir=$ROOT/pe/i386-windows
    mkdir -p "$dir"
    local out=$dir/$(basename "$1")
    "$MINGW/bin/llvm-strip" --strip-debug -o "$out" "$1"
    "$WINEBUILD" --builtin "$out"
}

stage_src() {
    fetch dxvk "$ROOT/dxvk" dxvk
    fetch vkd3d-proton "$ROOT/vkd3d-proton" vkd3d-proton
    fetch vulkan-loader "$ROOT/vulkan-loader"
    fetch vulkan-headers "$ROOT/vulkan-headers"
}

stage_dxvk() {
    cross_file
    rm -rf "$ROOT/build-dxvk"
    (cd "$ROOT/dxvk" && PATH=$MINGW/bin:$PATH meson setup --cross-file "$ROOT/cross-$ARCH.txt" \
        --buildtype release -Dbuild_id=false "$ROOT/build-dxvk") > "$ROOT/meson-dxvk.log"
    PATH=$MINGW/bin:$PATH ninja -C "$ROOT/build-dxvk" -j "$JOBS" > "$ROOT/ninja-dxvk.log"
    for f in d3d8/d3d8.dll d3d9/d3d9.dll d3d10/d3d10core.dll d3d11/d3d11.dll dxgi/dxgi.dll; do
        install_dll "$ROOT/build-dxvk/src/$f"
    done
}

# DXVK's Direct3D 9, 10 and 11 for i386: an i386 title's d3d9 (Portal 2's
# shaderapidx9) or d3d11/dxgi (Tomb Raider) runs on Vulkan through winevulkan's
# WoW64 thunks. Without them Wine's i386 d3d11 is wined3d, which needs a GL iOS
# lacks. d3d8 stays Wine's.
stage_dxvk32() {
    ARCH=i686
    cross_file
    rm -rf "$ROOT/build-dxvk32"
    (cd "$ROOT/dxvk" && PATH=$MINGW/bin:$PATH meson setup --cross-file "$ROOT/cross-$ARCH.txt" \
        --buildtype release -Dbuild_id=false -Denable_d3d8=false "$ROOT/build-dxvk32") > "$ROOT/meson-dxvk32.log"
    PATH=$MINGW/bin:$PATH ninja -C "$ROOT/build-dxvk32" -j "$JOBS" > "$ROOT/ninja-dxvk32.log"
    for f in d3d9/d3d9.dll d3d10/d3d10core.dll d3d11/d3d11.dll dxgi/dxgi.dll; do
        install_dll "$ROOT/build-dxvk32/src/$f"
    done
    ARCH=arm64ec
}

# DXVK's dxgi for aarch64, the one an ARM64 child's vkd3d-proton presents through
# (the choice is explained at the top).
stage_dxgi_aarch64() {
    ARCH=aarch64
    cross_file
    rm -rf "$ROOT/build-dxvk-aarch64"
    (cd "$ROOT/dxvk" && PATH=$MINGW/bin:$PATH meson setup --cross-file "$ROOT/cross-$ARCH.txt" \
        --buildtype release -Dbuild_id=false -Denable_d3d8=false -Denable_d3d9=false -Denable_d3d10=false \
        -Denable_d3d11=false "$ROOT/build-dxvk-aarch64") > "$ROOT/meson-dxvk-aarch64.log"
    PATH=$MINGW/bin:$PATH ninja -C "$ROOT/build-dxvk-aarch64" -j "$JOBS" > "$ROOT/ninja-dxvk-aarch64.log"
    install_dll "$ROOT/build-dxvk-aarch64/src/dxgi/dxgi.dll"
    ARCH=arm64ec
}

# vkd3d-proton for arm64ec (build-vkd3d) and for aarch64 (build-vkd3d-aarch64).
stage_vkd3d() {
    local build
    for ARCH in arm64ec aarch64; do
        build=$ROOT/build-vkd3d
        [ "$ARCH" = arm64ec ] || build=$ROOT/build-vkd3d-$ARCH
        cross_file
        rm -rf "$build"
        (cd "$ROOT/vkd3d-proton" && PATH=$MINGW/bin:$PATH meson setup --cross-file "$ROOT/cross-$ARCH.txt" \
            --buildtype release -Denable_tests=false -Denable_extras=false "$build") > "$ROOT/meson-vkd3d-$ARCH.log"
        PATH=$MINGW/bin:$PATH ninja -C "$build" -j "$JOBS" > "$ROOT/ninja-vkd3d-$ARCH.log"
        install_dll "$build/libs/d3d12/d3d12.dll"
        install_dll "$build/libs/d3d12core/d3d12core.dll"
    done
    ARCH=arm64ec
}

# The Khronos loader (decision 0131): the headers installed into a prefix its CMake
# finds by path only, then the loader against them, for arm64ec (build-vulkan-loader)
# and aarch64 (build-vulkan-loader-aarch64).
stage_loader() {
    local build
    rm -rf "$ROOT/build-vulkan-headers" "$ROOT/vulkan-headers-install" "$ROOT/loader"
    cmake -S "$ROOT/vulkan-headers" -B "$ROOT/build-vulkan-headers" -G Ninja \
        -DCMAKE_INSTALL_PREFIX="$ROOT/vulkan-headers-install" > "$ROOT/cmake-vulkan-headers.log"
    cmake --install "$ROOT/build-vulkan-headers" >> "$ROOT/cmake-vulkan-headers.log"
    for ARCH in arm64ec aarch64; do
        build=$ROOT/build-vulkan-loader
        [ "$ARCH" = arm64ec ] || build=$ROOT/build-vulkan-loader-$ARCH
        rm -rf "$build"
        cat > "$ROOT/toolchain-$ARCH.cmake" <<EOF
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR $ARCH)
set(CMAKE_C_COMPILER $MINGW/bin/$ARCH-w64-mingw32-clang)
set(CMAKE_CXX_COMPILER $MINGW/bin/$ARCH-w64-mingw32-clang++)
set(CMAKE_RC_COMPILER $MINGW/bin/$ARCH-w64-mingw32-windres)
set(CMAKE_AR $MINGW/bin/llvm-ar)
set(CMAKE_RANLIB $MINGW/bin/llvm-ranlib)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
EOF
        # lld stamps each PE with its link time otherwise: no two builds would match
        cmake -S "$ROOT/vulkan-loader" -B "$build" -G Ninja \
            -DCMAKE_TOOLCHAIN_FILE="$ROOT/toolchain-$ARCH.cmake" -DCMAKE_BUILD_TYPE=Release \
            -DVulkanHeaders_DIR="$ROOT/vulkan-headers-install/share/cmake/VulkanHeaders" \
            -DUSE_GAS=OFF -DUSE_MASM=OFF -DBUILD_TESTS=OFF \
            -DCMAKE_SHARED_LINKER_FLAGS=-Wl,--no-insert-timestamp > "$ROOT/cmake-vulkan-loader-$ARCH.log" 2>&1
        ninja -C "$build" -j "$JOBS" > "$ROOT/ninja-vulkan-loader-$ARCH.log"
        install_dll "$build/loader/vulkan-1.dll" "$ROOT/loader/$ARCH-windows"
        cp "$WINE_SRC/dlls/winevulkan/winevulkan.json" "$ROOT/loader/$ARCH-windows/winevulkan.json"
    done
    ARCH=arm64ec
}

for s in $STAGES; do
    case $s in
    src|dxvk|dxvk32|dxgi-aarch64|vkd3d|loader) echo "== vulkan-pe: $s"; "stage_${s//-/_}" ;;
    *) echo "no stage $s (src dxvk dxvk32 dxgi-aarch64 vkd3d loader)" >&2; exit 2 ;;
    esac
done
(cd "$ROOT/pe" && sha256sum */*.dll)
[ ! -d "$ROOT/loader" ] || (cd "$ROOT/loader" && sha256sum */*)
