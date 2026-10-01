#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The Vulkan Direct3D backend's PE DLLs (decision 0014): DXVK (Direct3D 8 to
# 11) and vkd3d-proton (Direct3D 12) for arm64ec-windows, the architecture an
# x86-64 game's DLLs load as under Wine ARM64EC. Each DLL is stripped of its
# DWARF (as the DXMT stage does) and marked a Wine builtin with winebuild
# --builtin: Madeira's loader ignores a DLL found through WINEDLLPATH that is
# not one. vkd3d-proton carries patches/vkd3d-proton; DXVK is built
# unmodified. The app stages them under Runtime/vulkan/arm64ec-windows, where a
# launch set to Vulkan finds them before DXMT's (wine_host_init,
# PLAYPORT_DLL_OVERLAY).
#
#   build/stages/vulkan-pe.sh [ROOT] [stage...]   ROOT defaults to $PLAYPORT_BUILD/run/vulkan-pe;
#                                                  stages: src dxvk vkd3d (default all)
#
# Inputs (env): LLVM_MINGW (build/lib.sh); WINEBUILD, default the pe stage's
# $PLAYPORT_BUILD/run/pe/wine/build-tools/tools/winebuild/winebuild.
# Output: ROOT/pe/arm64ec-windows/*.dll. Host tools: meson, ninja, glslangValidator.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../lib.sh"
ROOT=$(realpath -m "${1:-$PLAYPORT_BUILD/run/vulkan-pe}")
shift || true
STAGES=${*:-src dxvk vkd3d}
MINGW=${LLVM_MINGW:?set LLVM_MINGW (pp setup)}
WINEBUILD=${WINEBUILD:-$PLAYPORT_BUILD/run/pe/wine/build-tools/tools/winebuild/winebuild}
JOBS=${JOBS:-$(nproc)}
ARCH=arm64ec
mkdir -p "$ROOT/pe/$ARCH-windows"

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

cross_file() {
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
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
EOF
}

# install_dll SRC: strip, mark builtin, copy into pe/.
install_dll() {
    local out=$ROOT/pe/$ARCH-windows/$(basename "$1")
    "$MINGW/bin/llvm-strip" --strip-debug -o "$out" "$1"
    "$WINEBUILD" --builtin "$out"
}

stage_src() {
    fetch dxvk "$ROOT/dxvk"
    fetch vkd3d-proton "$ROOT/vkd3d-proton" vkd3d-proton
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

stage_vkd3d() {
    cross_file
    rm -rf "$ROOT/build-vkd3d"
    (cd "$ROOT/vkd3d-proton" && PATH=$MINGW/bin:$PATH meson setup --cross-file "$ROOT/cross-$ARCH.txt" \
        --buildtype release -Denable_tests=false -Denable_extras=false "$ROOT/build-vkd3d") > "$ROOT/meson-vkd3d.log"
    PATH=$MINGW/bin:$PATH ninja -C "$ROOT/build-vkd3d" -j "$JOBS" > "$ROOT/ninja-vkd3d.log"
    install_dll "$ROOT/build-vkd3d/libs/d3d12/d3d12.dll"
    install_dll "$ROOT/build-vkd3d/libs/d3d12core/d3d12core.dll"
}

for s in $STAGES; do
    case $s in
    src|dxvk|vkd3d) echo "== vulkan-pe: $s"; "stage_$s" ;;
    *) echo "no stage $s (src dxvk vkd3d)" >&2; exit 2 ;;
    esac
done
(cd "$ROOT/pe" && sha256sum */*.dll)
