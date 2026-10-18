#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Playport's Steam client for a game's genuine steam_api (decision 0115):
# app/SteamClientShim/steamclient.c compiled with llvm-mingw for x86-64 into
# OUT/steamclient64.dll, which stage-artifacts.py records and stages as
# Runtime/steamclient/x86_64-windows/steamclient64.dll (P9-steamclient); the app
# copies it to the prefix's C:\Program Files (x86)\Steam\ for a play in client
# mode. A native DLL (not a Wine builtin), freestanding: kernel32 only, no C
# runtime, no timestamp and no debug info.
#
# Its slot table (app/SteamClientShim/steamclient_slots.h) is generated from the
# public Steamworks SDK headers pinned as gbe's sdk/ (D3); when that tree is
# here (the steamapi stage's), the committed table is checked against it first.
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
"$MINGW/bin/x86_64-w64-mingw32-clang" -O2 -Wall -Wextra -Werror -ffreestanding -fno-builtin -nostdlib -shared \
    -Wl,--entry,DllEntry -Wl,--no-insert-timestamp -o "$OUT/steamclient64.dll" \
    "$SRC/steamclient.c" -lkernel32
echo "$(sha256sum "$OUT/steamclient64.dll" | cut -c1-16)  steamclient64.dll ($(stat -c %s "$OUT/steamclient64.dll") bytes)"
