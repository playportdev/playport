#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build Apple ld64 for Linux (cctools-port) with its TAPI and libdispatch
# dependencies, into a private prefix in the build area. The app link
# uses it through build/ld64/swift-build (docs/BUILDING.md, "Linking").
#
#   build/toolchain/ld64.sh [ROOT]    ROOT defaults to $PLAYPORT_BUILD/inputs/apple-linker
#
# Result: ROOT/prefix/bin/arm64-apple-darwin-ld (ld64-956.6, TAPI 1600.0.11.8).
# Nothing is installed system-wide; the binary finds its libraries through
# its rpath into ROOT/prefix/lib.
set -euo pipefail

ROOT="${1:-${PLAYPORT_BUILD:-$(cd "$(dirname "$0")/../.." && pwd)/.work}/inputs/apple-linker}"
PREFIX="$ROOT/prefix"
JOBS="${JOBS:-$(nproc)}"

# name, url, commit (the branch each repository had as default on 2026-09-23)
REPOS=(
    "cctools-port https://github.com/tpoechtrager/cctools-port.git 904de2a71d4da6a9b30d2efaf912a10ddc7d9ddb"         # 1030.6.3-ld64-956.6
    "apple-libtapi https://github.com/tpoechtrager/apple-libtapi.git fa9443738c1a18accef4244732ec6d6ee97a8133"       # 1600.0.11.8
    "apple-libdispatch https://github.com/tpoechtrager/apple-libdispatch.git 323b9b4e0ca05d6c56a0c2f2d7d8d47363e612b7"
)

mkdir -p "$ROOT"
for row in "${REPOS[@]}"; do
    read -r name url commit <<<"$row"
    [ -d "$ROOT/$name" ] || git clone -q "$url" "$ROOT/$name"
    git -C "$ROOT/$name" checkout -q "$commit"
done

echo "== libdispatch + BlocksRuntime"
cmake -S "$ROOT/apple-libdispatch" -B "$ROOT/apple-libdispatch/build" -G Ninja \
    -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" >/dev/null
ninja -C "$ROOT/apple-libdispatch/build" install >/dev/null

echo "== libtapi (builds part of LLVM; the slow step)"
(cd "$ROOT/apple-libtapi" && CC=clang CXX=clang++ NINJA=1 JOBS="$JOBS" INSTALLPREFIX="$PREFIX" ./build.sh >/dev/null && ./install.sh >/dev/null)

echo "== cctools + ld64"
# ld64 is built unoptimised (the port sets no -O), and GCC 15+'s libstdc++
# then enables _GLIBCXX_ASSERTIONS by default. ld64's objc pass forms
# one-past-the-end pointers as &v[v.size()] (MethodListAtom::fixupsEnd), which
# that check aborts on as soon as the link has ObjC categories to merge.
# Apple's build has no such check; opt out of it.
(
    cd "$ROOT/cctools-port/cctools"
    CC=clang CXX=clang++ \
        CFLAGS="-I$PREFIX/include" CXXFLAGS="-I$PREFIX/include -D_GLIBCXX_NO_ASSERTIONS" \
        LDFLAGS="-L$PREFIX/lib -Wl,-rpath,$PREFIX/lib" \
        ./configure --prefix="$PREFIX" --target=arm64-apple-darwin \
        --with-libtapi="$PREFIX" --with-libdispatch="$PREFIX" --with-libblocksruntime="$PREFIX" >/dev/null
    make clean >/dev/null   # a rerun with changed flags must not reuse objects
    make -j"$JOBS" >/dev/null
    make install >/dev/null
)

"$PREFIX/bin/arm64-apple-darwin-ld" -v 2>&1 | head -5
