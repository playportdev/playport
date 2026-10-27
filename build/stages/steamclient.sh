#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Playport's Steam client for a game's genuine steam_api (decision 0115):
# app/SteamClientShim/steamclient.c compiled with llvm-mingw twice, for x86-64 into
# OUT/steamclient64.dll and for i386 into OUT/steamclient.dll, which
# stage-artifacts.py records and stages as Runtime/steamclient/x86_64-windows/
# steamclient64.dll and Runtime/steamclient/i386-windows/steamclient.dll
# (P9-steamclient); the app copies both to the prefix's C:\Program Files (x86)\Steam\
# for a play in client mode. Native DLLs (not Wine builtins), freestanding: kernel32
# only, no C runtime (i386 adds compiler-rt's builtins for 64-bit division), no
# timestamp and no debug info.
#
# Its slot table (app/SteamClientShim/steamclient_slots.h) is generated from the
# public Steamworks SDK headers pinned as gbe's sdk/ and its getters' version strings
# (D3); when that tree is here (the steamapi stage's), the committed table is checked
# against it first.
#
#   build/stages/steamclient.sh OUT [SDK_DIR]
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../lib.sh"
OUT=$(realpath -m "${1:?output directory}")
SDK=${2:-}
MINGW=${LLVM_MINGW:?set LLVM_MINGW (pp setup)}
SRC=$PLAYPORT_REPO/app/SteamClientShim

mkdir -p "$OUT"
if [ -n "$SDK" ] && [ -d "$SDK/steam" ]; then
    python3 "$HERE/../steamclient-vtables.py" "$MINGW/bin/clang" "$SDK" "$OUT/vtables" "$SRC/steamclient_slots.h" --check
else
    echo "steamclient vtables: no SDK tree at '${SDK:-none}'; the committed table is used unchecked"
fi
build() {   # build ARCH ENTRY NAME [LIBS...]
    local arch=$1 entry=$2 name=$3
    shift 3
    "$MINGW/bin/$arch-w64-mingw32-clang" -O2 -Wall -Wextra -Werror -ffreestanding -fno-builtin -nostdlib -shared \
        -Wl,--entry,"$entry" -Wl,--no-insert-timestamp -o "$OUT/$name" "$SRC/steamclient.c" -lkernel32 "$@"
    echo "$(sha256sum "$OUT/$name" | cut -c1-16)  $name ($(stat -c %s "$OUT/$name") bytes)"
}
build x86_64 DllEntry steamclient64.dll
build i686 _DllEntry@12 steamclient.dll "$("$MINGW/bin/i686-w64-mingw32-clang" -print-libgcc-file-name)"
