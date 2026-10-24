#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build Apple ld64 (cctools-port) into a private build-area prefix. Linux
# also builds TAPI and libdispatch for the final app link; macOS needs only
# archive prelinking and uses Xcode's linker for the final app.
#
#   build/toolchain/ld64.sh [ROOT]    ROOT defaults to $PLAYPORT_BUILD/inputs/apple-linker
#
# Result: ROOT/prefix/bin/arm64-apple-darwin-ld (ld64-956.6, TAPI 1600.0.11.8).
# Nothing is installed system-wide; the binary finds its libraries through
# its rpath into ROOT/prefix/lib.
set -euo pipefail
[ "$(uname -s)" != Darwin ] || . "$(dirname "$0")/../env.sh"

ROOT="${1:-${PLAYPORT_BUILD:-$(cd "$(dirname "$0")/../.." && pwd)/.work}/inputs/apple-linker}"
PREFIX="$ROOT/prefix"
JOBS="${JOBS:-$(nproc)}"

# name, url, commit (the branch each repository had as default on 2026-09-23)
REPOS=(
    "cctools-port https://github.com/tpoechtrager/cctools-port.git 904de2a71d4da6a9b30d2efaf912a10ddc7d9ddb"         # 1030.6.3-ld64-956.6
    "apple-libtapi https://github.com/tpoechtrager/apple-libtapi.git fa9443738c1a18accef4244732ec6d6ee97a8133"       # 1600.0.11.8
    "apple-libdispatch https://github.com/tpoechtrager/apple-libdispatch.git 323b9b4e0ca05d6c56a0c2f2d7d8d47363e612b7"
)
if [ "$(uname -s)" = Darwin ]; then
    # Archive-only prelinking needs no SDK text stubs, TAPI or LTO. Final app
    # links on Mac use Xcode's linker and its current SDK support instead.
    REPOS=("${REPOS[0]}")
fi

mkdir -p "$ROOT"
for row in "${REPOS[@]}"; do
    read -r name url commit <<<"$row"
    [ -d "$ROOT/$name" ] || git clone -q "$url" "$ROOT/$name"
    git -C "$ROOT/$name" checkout -q "$commit"
done
if [ "$(uname -s)" = Darwin ]; then
    PATCHES=$(cd "$(dirname "$0")/../../patches/cctools-port" && pwd)
    while IFS= read -r patch; do
        git -C "$ROOT/cctools-port" apply --reverse --check "$PATCHES/$patch" 2>/dev/null ||
            git -C "$ROOT/cctools-port" apply "$PATCHES/$patch"
    done < "$PATCHES/series"
fi

if [ "$(uname -s)" != Darwin ]; then
echo "== libdispatch + BlocksRuntime"
cmake -S "$ROOT/apple-libdispatch" -B "$ROOT/apple-libdispatch/build" -G Ninja \
    -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" >/dev/null
ninja -C "$ROOT/apple-libdispatch/build" install >/dev/null

echo "== libtapi (builds part of LLVM; the slow step)"
(cd "$ROOT/apple-libtapi" && CC=clang CXX=clang++ NINJA=1 JOBS="$JOBS" INSTALLPREFIX="$PREFIX" ./build.sh >/dev/null && ./install.sh >/dev/null)
fi

echo "== cctools + ld64"
# ld64 is built unoptimised (the port sets no -O), and GCC 15+'s libstdc++
# then enables _GLIBCXX_ASSERTIONS by default. ld64's objc pass forms
# one-past-the-end pointers as &v[v.size()] (MethodListAtom::fixupsEnd), which
# that check aborts on as soon as the link has ObjC categories to merge.
# Apple's build has no such check; opt out of it.
(
    cd "$ROOT/cctools-port/cctools"
    if [ "$(uname -s)" = Darwin ]; then
        dependencies=(--disable-tapi-support --disable-lto-support)
        # libc++ no longer supplies these through unrelated headers.
        cxx_compat="-include cstdlib -include algorithm"
    else
        dependencies=(--with-libtapi="$PREFIX" --with-libdispatch="$PREFIX" --with-libblocksruntime="$PREFIX")
        cxx_compat=
    fi
    CC=clang CXX=clang++ \
        CFLAGS="-I$PREFIX/include" CXXFLAGS="-I$PREFIX/include -D_GLIBCXX_NO_ASSERTIONS $cxx_compat" \
        LDFLAGS="-L$PREFIX/lib -Wl,-rpath,$PREFIX/lib" \
        ./configure --prefix="$PREFIX" --target=arm64-apple-darwin \
        "${dependencies[@]}" >/dev/null
    make clean >/dev/null   # a rerun with changed flags must not reuse objects
    make -j"$JOBS" >/dev/null
    make install >/dev/null
)

"$PREFIX/bin/arm64-apple-darwin-ld" -v 2>&1 | head -5
