#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# llvm-mingw for the arm64 Linux build container (build/docker/README.md): the
# release docs/BUILDING.md names, its ubuntu-22.04-aarch64 build, with the
# aarch64 CRT rebuilt with arm64ec support and the builtins as libgcc, as
# docs/BUILDING.md ("llvm-mingw") describes for the x86-64 build.
#
#   build/docker/llvm-mingw.sh DIR    installs into DIR (the LLVM_MINGW for pp setup)
set -euo pipefail

DIR=$1
REL=20260922
CRT=57b595039040eaa15bece85b7cc71d952281b269   # llvm-mingw's MINGW_W64_VERSION
JOBS=${JOBS:-$(nproc)}
mkdir -p "$DIR"
if [ ! -x "$DIR/bin/aarch64-w64-mingw32-clang" ]; then
    curl -fsSL "https://github.com/mstorsjo/llvm-mingw/releases/download/$REL/llvm-mingw-$REL-ucrt-ubuntu-22.04-aarch64.tar.xz" |
        tar xJ -C "$DIR" --strip-components=1
fi
export PATH=$DIR/bin:$PATH

src=$DIR/.src/mingw-w64
if [ ! -d "$src/.git" ]; then
    git init -q "$src"
    git -C "$src" fetch -q --depth 1 https://github.com/mingw-w64/mingw-w64.git "$CRT"
    git -C "$src" checkout -q FETCH_HEAD
fi
mkdir -p "$src/mingw-w64-crt/build-aarch64"
(
    cd "$src/mingw-w64-crt/build-aarch64"
    ../configure --prefix="$DIR" --host=aarch64-w64-mingw32 \
        --disable-lib32 --disable-lib64 --enable-libarm64 --enable-arm64x \
        --with-default-msvcrt=ucrt --enable-cfguard --enable-silent-rules
    make -j"$JOBS"
    make install
)
# The mingw driver asks for -lgcc by name; the builtins resolve #__chkstk_arm64ec.
builtins=$(ls "$DIR"/lib/clang/*/lib/windows/libclang_rt.builtins-aarch64.a | head -1)
for l in libgcc.a libgcc_eh.a libgcc_s.a; do cp "$builtins" "$DIR/aarch64-w64-mingw32/lib/$l"; done
"$DIR/bin/clang" --version | head -1
