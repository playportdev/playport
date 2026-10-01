#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build libdxmt_combined.a, the DXMT unix slice the app links, as Madeira's
# build/dxmt-ios/README.md does: the 23 libdxmt_unix.a objects plus the LLVM
# 15.0.7 static libraries cross-built for iOS arm64, combined by Apple's
# libtool into one archive. airconv, in that slice, calls into LLVM, so
# libdxmt_unix.a alone leaves the app link with ~208 undefined llvm:: symbols.
#
#   build/stages/dxmt-combined.sh ROOT
#
# Inputs (env):
#   DXMT_UNIX  obj/*.o and the llvm-project link: stages/dxmt-patched.sh ROOT
#              after `unix`
#   TBLGEN     LLVM 15.0.7 host llvm-tblgen (air-helper-port.sh `llvm`)
#   LLVM_IOS   the LLVM iOS build directory, version-keyed and reused across
#              runs (default $PLAYPORT_BUILD/cache/llvm-ios-15.0.7)
#   LD64       build/lib.sh; CMake's link checks need a Mach-O linker.
#              LIBTOOL: the cctools libtool next to it.
#
# LLVM is configured like the airconv objects' headers (stages/dxmt-base.sh
# `llvm`): assertions on, so LLVM_ENABLE_ABI_BREAKING_CHECKS is 1 on both
# sides, no targets, no tools. Only the libLLVM*.a targets are built: the
# in-tree llvm-tblgen executable would link with --gc-sections, which ld64
# refuses. Result: ROOT/libdxmt_combined.a (deterministic: ZERO_AR_DATE,
# prefix maps).
set -euo pipefail

ROOT=$(realpath -m "${1:?usage: $0 ROOT}")
. "$(dirname "$0")/../lib.sh"
DXMT_UNIX=$(realpath "${DXMT_UNIX:?set DXMT_UNIX to a stages/dxmt-patched.sh ROOT}")
TBLGEN=${TBLGEN:?set TBLGEN to an LLVM 15.0.7 llvm-tblgen}
LLVM_TAG=$(pin llvm-project)
# resolved: a cache/ reached through a symlink must configure the same build
# directory, or CMake re-records it and ninja rebuilds it all
LLVM_IOS=$(realpath -m "${LLVM_IOS:-$PLAYPORT_BUILD/cache/llvm-ios-${LLVM_TAG#llvmorg-}}")
LIBTOOL=${LIBTOOL:-$(dirname "$LD64")/arm64-apple-darwin-libtool}
SDK=$IOSSDK
TARGET=arm64-apple-ios18.0   # the slice's own target (stages/dxmt-base.sh unix)
LLVM_PROJECT=$(realpath "$DXMT_UNIX/llvm-project")
# assertion strings embed __FILE__: map both trees so the bytes do not depend on them
MAP="-ffile-prefix-map=$LLVM_IOS/= -ffile-prefix-map=$LLVM_PROJECT/=llvm-project/"

test "$(ls "$DXMT_UNIX"/obj/*.o | wc -l)" = 23
"$TBLGEN" --version | grep -q 'LLVM version 15.0.7'
mkdir -p "$ROOT" "$(dirname "$LLVM_IOS")"

echo "== llvm-ios (LLVM 15.0.7 static libraries for $TARGET)"
cmake -G Ninja -S "$LLVM_PROJECT/llvm" -B "$LLVM_IOS" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$SDK" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=18.0 \
    -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
    -DCMAKE_C_COMPILER_TARGET=$TARGET -DCMAKE_CXX_COMPILER_TARGET=$TARGET -DCMAKE_ASM_COMPILER_TARGET=$TARGET \
    -DCMAKE_AR="$(command -v llvm-ar)" -DCMAKE_RANLIB="$(command -v llvm-ranlib)" \
    -DCMAKE_EXE_LINKER_FLAGS="--ld-path=$LD64" -DCMAKE_SHARED_LINKER_FLAGS="--ld-path=$LD64" \
    -DCMAKE_C_FLAGS="$MAP" -DCMAKE_CXX_FLAGS="$MAP" \
    -DLLVM_HOST_TRIPLE=$TARGET -DLLVM_TABLEGEN="$TBLGEN" \
    -DLLVM_TARGETS_TO_BUILD="" -DLLVM_ENABLE_ASSERTIONS=On \
    -DLLVM_ENABLE_ZSTD=Off -DLLVM_ENABLE_ZLIB=Off -DLLVM_ENABLE_TERMINFO=Off -DLLVM_ENABLE_LIBXML2=Off \
    -DLLVM_ENABLE_LIBEDIT=Off -DLLVM_ENABLE_LIBPFM=Off -DLLVM_ENABLE_FFI=Off \
    -DLLVM_BUILD_TOOLS=Off -DLLVM_BUILD_UTILS=Off -DLLVM_INCLUDE_TOOLS=Off -DLLVM_INCLUDE_UTILS=Off \
    -DLLVM_INCLUDE_TESTS=Off -DLLVM_INCLUDE_BENCHMARKS=Off -DLLVM_INCLUDE_EXAMPLES=Off \
    -DLLVM_INCLUDE_DOCS=Off -DLLVM_INCLUDE_RUNTIMES=Off \
    > "$LLVM_IOS.configure.log"
ninja -C "$LLVM_IOS" -j "${JOBS:-$(nproc)}" $(ninja -C "$LLVM_IOS" -t targets all | grep -oE '^lib/libLLVM[A-Za-z0-9]+\.a' | sort -u) \
    > "$LLVM_IOS.build.log"

echo "== libdxmt_combined.a"
rm -f "$ROOT/libdxmt_combined.a"
ZERO_AR_DATE=1 "$LIBTOOL" -static -no_warning_for_no_symbols -o "$ROOT/libdxmt_combined.a" \
    "$DXMT_UNIX"/obj/*.o "$LLVM_IOS"/lib/*.a
sha256sum "$DXMT_UNIX/libdxmt_unix.a" "$ROOT/libdxmt_combined.a"
