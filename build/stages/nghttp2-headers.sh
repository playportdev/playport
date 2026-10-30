#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# nghttp2's public headers at the pins.lock nghttp2 commit, for what compiles
# against the libnghttp2.dll build/stages/xbox-pe.sh builds (Wine's winhttp,
# patches/wine-gdk): nghttp2.h as committed and nghttp2ver.h made from its .in
# as nghttp2's CMake makes it. Read from the cache mirror; no build.
#
#   build/stages/nghttp2-headers.sh DIR    writes DIR/nghttp2/nghttp2.h and nghttp2ver.h
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../lib.sh"
DIR=$(realpath -m "${1:?usage: nghttp2-headers.sh DIR}")/nghttp2
REV=$(pin nghttp2)
MM=$(mirror nghttp2 "$REV")
mkdir -p "$DIR"
git -C "$MM" show "$REV:lib/includes/nghttp2/nghttp2.h" > "$DIR/nghttp2.h"
# project(nghttp2 VERSION X.Y.Z ...) -> "X.Y.Z" and 0xXXYYZZ (CMakeLists.txt's HexVersion).
VER=$(git -C "$MM" show "$REV:CMakeLists.txt" | sed -n 's/^project(nghttp2 VERSION \([0-9]*\.[0-9]*\.[0-9]*\).*/\1/p')
[ -n "$VER" ] || { echo "no project version in nghttp2's CMakeLists.txt at $REV" >&2; exit 1; }
NUM=$(IFS=. read -r a b c <<< "$VER"; printf '0x%02x%02x%02x' "$a" "$b" "$c")
git -C "$MM" show "$REV:lib/includes/nghttp2/nghttp2ver.h.in" |
    sed -e "s/@PACKAGE_VERSION@/$VER/" -e "s/@PACKAGE_VERSION_NUM@/$NUM/" > "$DIR/nghttp2ver.h"
echo "nghttp2 headers $VER ($NUM) at $REV: $DIR"
