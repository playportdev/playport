#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The Xbox runtime's PE DLLs (the Xbox plan, docs/plans/2026-10-30-xbox-game-pass.md):
# nexus-xgameruntime's xgameruntime.dll, the GDK runtime an Xbox title loads,
# at the pins.lock xgameruntime commit with patches/xgameruntime, and nghttp2's
# libnghttp2.dll (library only, at the nghttp2 pin, unmodified), the HTTP/2
# library Wine's winhttp loads (patches/wine-gdk). Both for arm64ec-windows,
# the architecture an x86-64 game's DLLs load as under Wine ARM64EC, with
# -D_WIN32_WINNT=0x0A00 as the upstream's own ARM64 build (llvm-mingw's
# default hides Windows 10 APIs such as BCryptHash). Each is stripped of its
# DWARF and marked a Wine builtin with winebuild --builtin, as vulkan-pe.sh's
# DLLs are: Madeira's loader ignores a DLL found through WINEDLLPATH that is
# not one. The app stages them with Wine's own arm64ec set.
#
# xgameruntime compiles libxml2 (libs/xml2, the files its Makefile.in lists)
# and the WinRT JSON header (include/windows.data.json.idl) from the pe stage's
# Wine tree, Playport's Wine pin with its series, which the source bundle packs
# (docs/LICENSING.md, "Xbox"); its own IDL goes through that tree's widl. It
# links the C++ runtime statically, as its CMake asks. googletest (tests only)
# is not checked out.
#
#   build/stages/xbox-pe.sh [ROOT] [stage...]   ROOT defaults to $PLAYPORT_BUILD/run/xbox;
#                                                stages: src nghttp2 xgameruntime (default all)
#
# Inputs (env): LLVM_MINGW (build/lib.sh); WINE_SRC, the pe stage's Wine tree
# (default $PLAYPORT_BUILD/run/pe/wine), with its build-tools winebuild and widl.
# Output: ROOT/pe/arm64ec-windows/{xgameruntime.dll,libnghttp2.dll}. Host tools: cmake, ninja.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../lib.sh"
ROOT=$(realpath -m "${1:-$PLAYPORT_BUILD/run/xbox}")
shift || true
STAGES=${*:-src nghttp2 xgameruntime}
MINGW=${LLVM_MINGW:?set LLVM_MINGW (pp setup)}
WINE_SRC=$(realpath -m "${WINE_SRC:-$PLAYPORT_BUILD/run/pe/wine}")
WINEBUILD=$WINE_SRC/build-tools/tools/winebuild/winebuild
WIDL=$WINE_SRC/build-tools/tools/widl/widl
JOBS=${JOBS:-$(nproc)}
ARCH=arm64ec
# No build path in the DLLs (verify-ipa's path check; both keep __FILE__ in asserts and logs).
FLAGS="-D_WIN32_WINNT=0x0A00 -ffile-prefix-map=$ROOT=xbox -ffile-prefix-map=$WINE_SRC=wine -ffile-prefix-map=$MINGW=llvm-mingw"
mkdir -p "$ROOT"

# fetch NAME DIR [SERIES]: the pins.lock commit of NAME from the cache mirror,
# without submodules, with patches/SERIES on it when given (build/lib.sh ensure_series).
fetch() {
    local name=$1 dir=$2 series=${3:-} rev m
    rev=$(pin "$name")
    m=$(mirror "$name" "$rev")
    [ -e "$dir/.git" ] || git clone -q --no-checkout "$m" "$dir"
    git -C "$dir" cat-file -e "$rev^{commit}" 2>/dev/null || git -C "$dir" fetch -q "$m" "$rev"
    if [ -n "$series" ]; then
        ensure_series "$dir" "$series" "$rev"
    elif [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" != "$rev" ] || ! git -C "$dir" diff --quiet HEAD; then
        git -c advice.detachedHead=false -C "$dir" checkout -q -f "$rev"
    fi
    echo "$name $(git -C "$dir" rev-parse HEAD)${series:+ ($(series "$series" | wc -l) patches on $rev)}"
}

toolchain_file() {
    cat > "$ROOT/toolchain-$ARCH.cmake" <<EOF
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR $ARCH)
set(CMAKE_C_COMPILER $MINGW/bin/$ARCH-w64-mingw32-clang)
set(CMAKE_CXX_COMPILER $MINGW/bin/$ARCH-w64-mingw32-clang++)
set(CMAKE_RC_COMPILER $MINGW/bin/$ARCH-w64-mingw32-windres)
set(CMAKE_AR $MINGW/bin/llvm-ar)
set(CMAKE_RANLIB $MINGW/bin/llvm-ranlib)
set(CMAKE_FIND_ROOT_PATH $MINGW/$ARCH-w64-mingw32)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
EOF
}

# cmake_build NAME SRC CMAKE-ARGS...: a clean Release build of SRC in ROOT/build-NAME.
# lld stamps each PE with its link time otherwise: no two builds would match.
cmake_build() {
    local name=$1 src=$2; shift 2
    toolchain_file
    rm -rf "$ROOT/build-$name"
    cmake -S "$src" -B "$ROOT/build-$name" -G Ninja -DCMAKE_TOOLCHAIN_FILE="$ROOT/toolchain-$ARCH.cmake" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_FLAGS="$FLAGS" -DCMAKE_CXX_FLAGS="$FLAGS" \
        -DCMAKE_SHARED_LINKER_FLAGS=-Wl,--no-insert-timestamp "$@" > "$ROOT/cmake-$name.log" 2>&1
    ninja -C "$ROOT/build-$name" -j "$JOBS" > "$ROOT/ninja-$name.log"
}

# install_dll SRC: strip, mark builtin, copy into pe/arm64ec-windows.
install_dll() {
    local dir=$ROOT/pe/$ARCH-windows out
    mkdir -p "$dir"
    out=$dir/$(basename "$1")
    "$MINGW/bin/llvm-strip" --strip-debug -o "$out" "$1"
    "$WINEBUILD" --builtin "$out"
}

stage_src() {
    fetch xgameruntime "$ROOT/xgameruntime" xgameruntime
    fetch nghttp2 "$ROOT/nghttp2"
}

stage_nghttp2() {
    cmake_build nghttp2 "$ROOT/nghttp2" -DENABLE_LIB_ONLY=ON -DBUILD_SHARED_LIBS=ON -DBUILD_STATIC_LIBS=OFF \
        -DENABLE_DOC=OFF -DENABLE_APP=OFF -DENABLE_EXAMPLES=OFF -DENABLE_FAILMALLOC=OFF -DBUILD_TESTING=OFF
    install_dll "$ROOT/build-nghttp2/lib/libnghttp2.dll"
}

stage_xgameruntime() {
    [ -x "$WINEBUILD" ] && [ -x "$WIDL" ] && [ -f "$WINE_SRC/libs/xml2/Makefile.in" ] ||
        { echo "no built Wine tree at $WINE_SRC (the pe stage)" >&2; exit 1; }
    # NEXUS_WINE_SOURCE_LOCK=OFF (patches/xgameruntime 0001): the tree is Playport's
    # Wine pin with its series, not the Valve commit cmake/*.lock.json names.
    cmake_build xgameruntime "$ROOT/xgameruntime" -DENABLE_TESTS=OFF -DNEXUS_WINE_SOURCE="$WINE_SRC" \
        -DNEXUS_WINE_SOURCE_LOCK=OFF -DWIDL="$WIDL"
    install_dll "$ROOT/build-xgameruntime/bin/xgameruntime.dll"
}

for s in $STAGES; do
    case $s in
    src|nghttp2|xgameruntime) echo "== xbox-pe: $s"; "stage_$s" ;;
    *) echo "no stage $s (src nghttp2 xgameruntime)" >&2; exit 2 ;;
    esac
done
(cd "$ROOT/pe" && sha256sum */*.dll)
