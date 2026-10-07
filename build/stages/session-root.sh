#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The session root (decision 0027): app/SessionRoot/playport-session.c compiled
# with llvm-mingw for x86-64 into OUT/playport-session.exe, which
# stage-artifacts.py records and stages as Runtime/arm64ec-windows/playport-session.exe
# (so the prefix's system32 has it) in both variants. Freestanding: kernel32
# and user32 only, no C runtime, no timestamp and no debug info, so the output is the same
# for the same source and toolchain and names no path.
#
# The same flags build Playport's URL opener (decision 0064):
# app/UrlOpener/playport-url-opener.c into OUT/playport-url-opener.exe, the
# prefix's http and https handler, staged beside the session root (P9-url-opener).
#
#   build/stages/session-root.sh OUT
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../lib.sh"
OUT=$(realpath -m "${1:?output directory}")
CC=${LLVM_MINGW:?set LLVM_MINGW (pp setup)}/bin/x86_64-w64-mingw32-clang

mkdir -p "$OUT"
"$CC" -O2 -Wall -Wextra -Werror -ffreestanding -fno-builtin -nostdlib -mwindows \
    -Wl,--entry,entry -Wl,--no-insert-timestamp -o "$OUT/playport-session.exe" \
    "$PLAYPORT_REPO/app/SessionRoot/playport-session.c" -lkernel32 -luser32
"$CC" -O2 -Wall -Wextra -Werror -ffreestanding -fno-builtin -nostdlib -mwindows \
    -Wl,--entry,entry -Wl,--no-insert-timestamp -o "$OUT/playport-url-opener.exe" \
    "$PLAYPORT_REPO/app/UrlOpener/playport-url-opener.c" -lkernel32
for exe in playport-url-opener.exe playport-session.exe; do
    echo "$(sha256sum "$OUT/$exe" | cut -c1-16)  $exe ($(stat -c %s "$OUT/$exe") bytes)"
done
