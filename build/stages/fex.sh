#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build FEX's arm64ec PE (libarm64ecfex.dll, shipped as xtajit64.dll) and
# aarch64 WoW64 PE (libwow64fex.dll, shipped as xtajit.dll) from the
# FEX pin in pins.lock (a FEX-Emu/FEX release) plus patches/fex-port (Madeira's
# FEX port, rebased) and patches/fex, with Linux llvm-mingw.
# docs/BUILDING.md, "The pipeline" (fex).
#
#   build/stages/fex.sh ROOT
#
# ROOT/fex is a clone of the FEX pin with its submodules (all but the test
# binaries). The script clones it when absent, from a mirror of FEX-Emu/FEX
# kept in $PLAYPORT_BUILD/cache (fetched only when it lacks the pin); each
# submodule comes from the upstream/madeira/FEX checkout's copy when that has
# the commit, else from its upstream. External/rpmalloc is the rpmalloc pin
# (FEX-Emu/rpmalloc, from a cache mirror) with patches/rpmalloc-port and
# patches/rpmalloc on it.
# The series are applied when the trees are still at their pins.
# Outputs: ROOT/fex/build-{arm64ec,wow64}/Bin/lib{arm64ec,wow64}fex.dll.
# The ARM64EC DLL embeds its
# pin's commit time, not the build time (SOURCE_DATE_EPOCH below).
set -euo pipefail

ROOT=$(realpath -m "${1:?usage: $0 ROOT}")
. "$(dirname "$0")/../lib.sh"
PIN=$(pin fex)
RPM=$(pin rpmalloc)
SRC_FEX=${SRC_FEX:-$PLAYPORT_REPO/upstream/madeira/FEX}
CACHE=${FEX_CACHE:-$PLAYPORT_BUILD/cache}
F=$ROOT/fex
M=$LLVM_MINGW
JOBS=${JOBS:-$(nproc)}

test -x "$M/bin/aarch64-w64-mingw32-clang" || { echo "missing llvm-mingw at $M"; exit 1; }
mkdir -p "$ROOT" "$CACHE"
if [ ! -e "$F/.git" ]; then
    git clone -q --no-checkout "$(mirror fex "$PIN")" "$F"
    git -C "$F" -c advice.detachedHead=false checkout -q "$PIN"
    for p in $(git -C "$F" config -f .gitmodules --get-regexp '^submodule\..*\.path$' | awk '{print $2}' | grep -v -- '-bins$'); do
        name=$(git -C "$F" config -f .gitmodules --get-regexp '^submodule\..*\.path$' | awk -v p="$p" '$2 == p {print $1}' | sed 's/^submodule\.//; s/\.path$//')
        want=$(git -C "$F" ls-tree HEAD "$p" | awk '{print $3}')
        if [ "$p" = External/rpmalloc ]; then
            git -C "$F" config "submodule.$name.url" "$(mirror rpmalloc "$RPM")"
        elif test -e "$SRC_FEX/$p/.git" && git -C "$SRC_FEX/$p" cat-file -e "$want^{commit}" 2>/dev/null; then
            git -C "$F" config "submodule.$name.url" "$SRC_FEX/$p"
        fi
        git -C "$F" -c protocol.file.allow=always submodule update --init -q -- "$p"
    done
fi
test "$(git -C "$F" ls-tree "$PIN" External/rpmalloc | awk '{print $3}')" = "$RPM" ||
    { echo "the fex pin's External/rpmalloc gitlink is not the rpmalloc pin"; exit 1; }
ensure_series "$F" "fex-port fex" "$PIN" External/rpmalloc
ensure_series "$F/External/rpmalloc" "rpmalloc-port rpmalloc" "$RPM"

# -stdlib=libc++ is mandatory: the -gnu driver default (-lstdc++) does not
# exist in llvm-mingw. FEX_IOS_HOST selects the iOS host-process code paths.
# MAP takes the tree and llvm-mingw out of __FILE__ and the debug info.
MAP="-ffile-prefix-map=$F=fex -ffile-prefix-map=$M=llvm-mingw"
# Reproducible: the [build-id] line's __DATE__/__TIME__ (Module.cpp) take the
# pin's commit time, and lld leaves the PE header's link time out.
# The epoch is in the flags too, so objects built before it are compiled again.
export SOURCE_DATE_EPOCH=$(git -C "$F" log -1 --format=%ct "$PIN")
MAP="$MAP -DPLAYPORT_SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH"
for mode in arm64ec wow64; do
    target=arm64ec; dllname=arm64ecfex; machine=ARM64EC; ios_flags=-DFEX_IOS_HOST=1
    # Build-only WoW64 scaffolding. Its module does not yet supply the iOS
    # JIT/mono/arena bindings shared FEXCore needs: milestone 1 step 3 ports
    # those before enabling FEX_IOS_HOST here. Do not link no-op bindings.
    if [ "$mode" = wow64 ]; then target=aarch64; dllname=wow64fex; machine=ARM64; ios_flags=; fi
cmake -S "$F" -B "$F/build-$mode" -G Ninja \
    -DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR="$target" \
    -DCMAKE_FIND_ROOT_PATH="$M" -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
    -DCMAKE_DLLTOOL="$M/bin/aarch64-w64-mingw32-dlltool" \
    -DCMAKE_C_COMPILER="$M/bin/aarch64-w64-mingw32-clang" \
    -DCMAKE_CXX_COMPILER="$M/bin/aarch64-w64-mingw32-clang++" \
    -DCMAKE_ASM_COMPILER="$M/bin/aarch64-w64-mingw32-clang" \
    -DCMAKE_C_COMPILER_TARGET="$target-windows-gnu" -DCMAKE_CXX_COMPILER_TARGET="$target-windows-gnu" \
    -DCMAKE_ASM_COMPILER_TARGET="$target-windows-gnu" \
    -DCMAKE_C_COMPILER_AR="$M/bin/aarch64-w64-mingw32-llvm-ar" \
    -DCMAKE_C_COMPILER_RANLIB="$M/bin/aarch64-w64-mingw32-llvm-ranlib" \
    -DCMAKE_CXX_COMPILER_AR="$M/bin/aarch64-w64-mingw32-llvm-ar" \
    -DCMAKE_CXX_COMPILER_RANLIB="$M/bin/aarch64-w64-mingw32-llvm-ranlib" \
    -DCMAKE_C_FLAGS="$ios_flags -fuse-ld=lld $MAP" \
    -DCMAKE_CXX_FLAGS="$ios_flags -fuse-ld=lld -stdlib=libc++ $MAP" \
    -DCMAKE_ASM_FLAGS="$ios_flags" \
    -DCMAKE_EXE_LINKER_FLAGS="-fuse-ld=lld" -DCMAKE_SHARED_LINKER_FLAGS="-fuse-ld=lld -Wl,--no-insert-timestamp" \
    -DFEX_IOS_HOST_BUILD=ON -DENABLE_LTO=FALSE -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_TESTING=OFF -DBUILD_FEXCONFIG=OFF \
    > "$ROOT/fex-$mode-configure.log"
# Build the module only: the aarch64 configuration also defines host tools.
cmake --build "$F/build-$mode" --target "$dllname" -j "$JOBS" > "$ROOT/fex-$mode-build.log"
dll=$F/build-$mode/Bin/lib$dllname.dll
# FEX builds without -g; the only debug info is the locally rebuilt arm64ec
# CRT's (docs/BUILDING.md, llvm-mingw), which names llvm-mingw's install path.
"$M/bin/llvm-strip" --strip-debug "$dll"
"$M/bin/llvm-readobj" --file-headers "$dll" | grep -q "Machine: IMAGE_FILE_MACHINE_$machine " ||
    { echo "$dll is not an $machine image"; exit 1; }
printf '%s %s %s\n' "$(stat -c %s "$dll")" "$(sha256sum "$dll" | cut -d' ' -f1)" "$dll"
done
