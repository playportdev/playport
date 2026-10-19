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
# The loader stage builds the Khronos Vulkan-Loader (vulkan-1.dll, unmodified, at
# the vulkan-loader pin with the vulkan-headers pin) for arm64ec, beside Wine's
# own winevulkan.json, the ICD manifest winevulkan's DllRegisterServer writes
# (decision 0131). The app stages them under Runtime/vulkan-loader/arm64ec-windows,
# which a play with khronosVulkanLoader links over system32 after its backend's set.
# The loader has no assembler here (USE_GAS/USE_MASM off): its trampolines for
# functions it does not know are aarch64 code, not ARM64EC, and the headers it is
# built with are winevulkan's, so it knows every function winevulkan has.
#
#   build/stages/vulkan-pe.sh [ROOT] [stage...]   ROOT defaults to $PLAYPORT_BUILD/run/vulkan-pe;
#                                                  stages: src dxvk dxvk32 vkd3d loader (default all)
#
# Inputs (env): LLVM_MINGW (build/lib.sh); WINEBUILD, default the pe stage's
# $PLAYPORT_BUILD/run/pe/wine/build-tools/tools/winebuild/winebuild; WINE_SRC, the
# pe stage's Wine tree (default $PLAYPORT_BUILD/run/pe/wine), for winevulkan.json.
# Output: ROOT/pe/arm64ec-windows/*.dll, ROOT/pe/i386-windows/*.dll,
# ROOT/loader/arm64ec-windows/{vulkan-1.dll,winevulkan.json}. Host tools: meson, ninja,
# cmake, glslangValidator.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../lib.sh"
ROOT=$(realpath -m "${1:-$PLAYPORT_BUILD/run/vulkan-pe}")
shift || true
STAGES=${*:-src dxvk dxvk32 vkd3d loader}
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

# cross_file: the meson cross file for $ARCH (arm64ec, or i686 for i386).
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

stage_vkd3d() {
    cross_file
    rm -rf "$ROOT/build-vkd3d"
    (cd "$ROOT/vkd3d-proton" && PATH=$MINGW/bin:$PATH meson setup --cross-file "$ROOT/cross-$ARCH.txt" \
        --buildtype release -Denable_tests=false -Denable_extras=false "$ROOT/build-vkd3d") > "$ROOT/meson-vkd3d.log"
    PATH=$MINGW/bin:$PATH ninja -C "$ROOT/build-vkd3d" -j "$JOBS" > "$ROOT/ninja-vkd3d.log"
    install_dll "$ROOT/build-vkd3d/libs/d3d12/d3d12.dll"
    install_dll "$ROOT/build-vkd3d/libs/d3d12core/d3d12core.dll"
}

# The Khronos loader (decision 0131): the headers installed into a prefix its CMake
# finds by path only, then the loader against them, for arm64ec.
stage_loader() {
    rm -rf "$ROOT/build-vulkan-headers" "$ROOT/vulkan-headers-install" "$ROOT/build-vulkan-loader" "$ROOT/loader"
    cmake -S "$ROOT/vulkan-headers" -B "$ROOT/build-vulkan-headers" -G Ninja \
        -DCMAKE_INSTALL_PREFIX="$ROOT/vulkan-headers-install" > "$ROOT/cmake-vulkan-headers.log"
    cmake --install "$ROOT/build-vulkan-headers" >> "$ROOT/cmake-vulkan-headers.log"
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
    cmake -S "$ROOT/vulkan-loader" -B "$ROOT/build-vulkan-loader" -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE="$ROOT/toolchain-$ARCH.cmake" -DCMAKE_BUILD_TYPE=Release \
        -DVulkanHeaders_DIR="$ROOT/vulkan-headers-install/share/cmake/VulkanHeaders" \
        -DUSE_GAS=OFF -DUSE_MASM=OFF -DBUILD_TESTS=OFF \
        -DCMAKE_SHARED_LINKER_FLAGS=-Wl,--no-insert-timestamp > "$ROOT/cmake-vulkan-loader.log" 2>&1
    ninja -C "$ROOT/build-vulkan-loader" -j "$JOBS" > "$ROOT/ninja-vulkan-loader.log"
    install_dll "$ROOT/build-vulkan-loader/loader/vulkan-1.dll" "$ROOT/loader/$ARCH-windows"
    cp "$WINE_SRC/dlls/winevulkan/winevulkan.json" "$ROOT/loader/$ARCH-windows/winevulkan.json"
}

for s in $STAGES; do
    case $s in
    src|dxvk|dxvk32|vkd3d|loader) echo "== vulkan-pe: $s"; "stage_$s" ;;
    *) echo "no stage $s (src dxvk dxvk32 vkd3d loader)" >&2; exit 2 ;;
    esac
done
(cd "$ROOT/pe" && sha256sum */*.dll)
[ ! -d "$ROOT/loader" ] || (cd "$ROOT/loader" && sha256sum */*)
