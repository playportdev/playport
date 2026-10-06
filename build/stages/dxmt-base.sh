#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build the DXMT slice (3Shain/dxmt plus Madeira's port, D3D11 -> Metal) with
# host clang + the xtool slim SDK. docs/BUILDING.md, "The pipeline" (dxmt).
#
# usage: stages/dxmt-base.sh ROOT [stage...]
#   stages (default: all, in order): clones llvm unix pe
# ROOT is a scratch directory (it needs ~1 GB; not the RAM-backed /tmp).
# Nothing outside it and the LLVM cache is written.
#
# clones: upstream DXMT at the dxmt pin (a clone kept in $PLAYPORT_BUILD/cache,
#       or $SRC_DXMT), Madeira's remote-metal/ and build/ beside it, and the
#       LLVM 15.0.7 sources (cached in $PLAYPORT_BUILD/cache, linked into ROOT).
#       The port series is applied by stages/dxmt-patched.sh, not here.
# llvm: LLVM's tablegen'd headers for airconv (cached the same way).
# unix: the 23 translation units of the unix slice: Madeira build/dxmt-ios/build.sh's
#       20 with the same flags, plus the three airconv files upstream added
#       since Madeira's base. It never archives (stages/dxmt-patched.sh does),
#       and it needs the AIR helper headers in ROOT/shader-headers.
# pe:   meson setup of the aarch64-windows PE side only; stages/dxmt-patched.sh
#       builds the PE DLLs.
set -e

ROOT=${1:?usage: $0 ROOT [stage...]}
shift
STAGES=${*:-clones llvm unix pe}

. "$(dirname "$0")/../lib.sh"
DXMT_REV=$(pin dxmt)
MYTHIC_REV=$(pin madeira)
LLVM_TAG=$(pin llvm-project)
SRC_MYTHIC=${SRC_MYTHIC:-$PLAYPORT_REPO/upstream/madeira}
SRC_DXMT=${SRC_DXMT:-}
LLVM_CACHE=${LLVM_CACHE:-$PLAYPORT_BUILD/cache}
MINGW=$LLVM_MINGW
SDK=$IOSSDK
D=$ROOT/dxmt
OBJ=$ROOT/obj

test -d "$SDK" || { echo "missing xtool iPhoneOS SDK at $SDK"; exit 1; }
CXXSTD=$(ios_cxx_stdlib)   # the SDK's libc++ headers, not the host's (build/lib.sh)
mkdir -p "$ROOT"

stage_clones() {
    # Upstream DXMT, not Madeira's fork (pins.lock). A local clone is kept in the
    # cache and fetched only when it lacks the pin.
    local mirror=${SRC_DXMT:-$LLVM_CACHE/dxmt.git}
    if ! test -n "$SRC_DXMT"; then
        test -d "$mirror" || git clone -q --bare "$(pin_url dxmt)" "$mirror"
        git -C "$mirror" cat-file -e "$DXMT_REV^{commit}" 2>/dev/null ||
            git -C "$mirror" fetch -q "$(pin_url dxmt)" "+refs/heads/*:refs/heads/*" "+refs/tags/*:refs/tags/*"
    fi
    test -d "$D/.git" || git clone -q --no-checkout "$mirror" "$D"
    test "$(git -C "$D" remote get-url origin)" = "$mirror" || git -C "$D" remote set-url origin "$mirror"
    git -C "$D" cat-file -e "$DXMT_REV^{commit}" 2>/dev/null || git -C "$D" fetch -q origin "$DXMT_REV"
    git -C "$D" -c advice.detachedHead=false checkout -q $DXMT_REV
    git -C "$D" submodule update --init --recursive --depth 1
    # Madeira research/remote-metal: winemetal_unix.c includes
    # ../../../../remote-metal/protocol.h, i.e. a sibling of the dxmt root, and
    # (with patches/dxmt's madeira-cfg-sibling-include) ../../../../build/madeira_cfg.h.
    test -e "$SRC_MYTHIC/.git" || { git clone -q --no-checkout "$(pin_url madeira)" "$ROOT/mythic-src"; SRC_MYTHIC=$ROOT/mythic-src; }
    rm -rf "$ROOT/mythic-pin"; mkdir -p "$ROOT/mythic-pin"
    git -C "$SRC_MYTHIC" archive $MYTHIC_REV research/remote-metal build/dxmt-ios build/madeira_cfg.h | tar -x -C "$ROOT/mythic-pin"
    ln -sfn mythic-pin/research/remote-metal "$ROOT/remote-metal"
    ln -sfn mythic-pin/build "$ROOT/build"
    local lp=$LLVM_CACHE/llvm-project-${LLVM_TAG#llvmorg-}
    test -d "$lp/.git" || {
        mkdir -p "$LLVM_CACHE"
        git clone -q --depth 1 --branch $LLVM_TAG --filter=blob:none --no-checkout "$(pin_url llvm-project)" "$lp"
        git -C "$lp" sparse-checkout set --no-cone /llvm/ /cmake/ /third-party/
        git -C "$lp" checkout -q
    }
    ln -sfn "$lp" "$ROOT/llvm-project"
}

# LLVM 15.0.7 headers for airconv: a host configure plus the tablegen'd
# intrinsics headers. Madeira uses an iOS-configured llvm-ios-build tree; the
# generated headers are target-independent with no LLVM targets built.
stage_llvm() {
    local hb=$LLVM_CACHE/llvm-host-${LLVM_TAG#llvmorg-}
    ln -sfn "$hb" "$ROOT/llvm-host-build"
    test -f "$hb/include/llvm/IR/IntrinsicEnums.inc" && return
    mkdir -p "$hb"
    cmake -G Ninja -B "$ROOT/llvm-host-build" -S "$ROOT/llvm-project/llvm" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
        -DCMAKE_CXX_FLAGS="-include cstdint" \
        -DLLVM_TARGETS_TO_BUILD="" -DLLVM_ENABLE_ASSERTIONS=On \
        -DLLVM_ENABLE_ZSTD=Off -DLLVM_ENABLE_ZLIB=Off -DLLVM_ENABLE_TERMINFO=Off -DLLVM_ENABLE_LIBXML2=Off \
        -DLLVM_BUILD_TOOLS=Off -DLLVM_INCLUDE_TESTS=Off -DLLVM_INCLUDE_BENCHMARKS=Off -DLLVM_INCLUDE_EXAMPLES=Off \
        > "$ROOT/llvm-host-configure.log"
    ninja -C "$ROOT/llvm-host-build" intrinsics_gen > "$ROOT/llvm-host-intrinsics.log"
}

stage_unix() {
    mkdir -p "$OBJ"
    local common="--target=arm64-apple-ios18.0 -isysroot $SDK -fblocks -O2 -ffile-prefix-map=$ROOT/= -ffile-prefix-map=$DARWIN_SDK=darwin-sdk"
    local inc="-I$D/include -I$D/libs -I$D/src/winemetal -I$D/src/airconv"
    local incdx="-I$D/include/native/directx -I$D/include/native/windows"
    local incllvm="-I$ROOT/llvm-host-build/include -I$ROOT/llvm-project/llvm/include"
    local defs="-D_FILE_OFFSET_BITS=64 -D__STDC_CONSTANT_MACROS -D__STDC_FORMAT_MACROS -D__STDC_LIMIT_MACROS"
    local ok=0 failed=""
    cc1() { # name compiler-and-flags... src
        local name=$1; shift
        if "$@" -o "$OBJ/$name.o" 2>"$OBJ/$name.err"; then ok=$((ok+1)); echo "  OK     $name"
        else failed="$failed $name"; echo "  FAILED $name: $(grep -m1 error: "$OBJ/$name.err")"; fi
    }
    for f in winemetal_unix cache; do
        cc1 $f clang $common -x objective-c $inc -c "$D/src/winemetal/unix/$f.c"
    done
    for p in airconv_context air_type air_signature air_operations dxbc_converter dxbc_converter_gs \
             dxbc_converter_ts dxbc_converter_basicblock dxbc_converter_cfg dxbc_instructions \
             dxbc_signature metallib_writer nt/air_builder nt/dxbc_converter_base transforms/lower_16bit_texread \
             dxbc_binding_sm50 dxbc_binding_rootsig transforms/simdgroup_implicit_membarrier; do
        cc1 "$(basename $p)" clang++ $common $CXXSTD -std=c++20 -fno-exceptions -fno-rtti $inc $incdx \
            -I"$ROOT/shader-headers" $incllvm $defs -c "$D/src/airconv/$p.cpp"
    done
    for c in BlobContainer DXBCUtils ShaderBinary; do
        cc1 dxbc_$c clang++ $common $CXXSTD -std=c++20 -fno-rtti $inc $incdx $defs -c "$D/libs/DXBCParser/$c.cpp"
    done
    echo "unix: $ok/23 compiled; failed:${failed:- none}"
    (cd "$OBJ" && sha256sum *.o > "$ROOT/unix-objects.sha256")
    test -z "$failed" || { echo "not archiving libdxmt_unix.a (build.sh archives only when all 23 compile)"; return 1; }
}

stage_pe() {
    sed "s#'@GLOBAL_SOURCE_ROOT@' / 'toolchains/llvm-mingw-20260421-ucrt-macos-universal#'$MINGW#" \
        "$D/build-aarch64-win.txt" > "$ROOT/cross-aarch64-win-linux.txt"
    rm -rf "$ROOT/build-pe"
    printf "[binaries]\nc = 'clang'\ncpp = 'clang++'\n" > "$ROOT/native-clang.txt"
    (cd "$D" && PATH=$MINGW/bin:$PATH meson setup --cross-file "$ROOT/cross-aarch64-win-linux.txt" \
        --native-file "$ROOT/native-clang.txt" -Dwine_build_path=../../wine/build-macos "$ROOT/build-pe")
}

for s in $STAGES; do echo "== $s"; stage_$s; done
