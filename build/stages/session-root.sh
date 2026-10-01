#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The session root (decision 0027): app/SessionRoot/playport-session.c compiled
# with llvm-mingw for x86-64 into OUT/playport-session.exe, which
# stage-artifacts.py records and stages as Runtime/arm64ec-windows/playport-session.exe
# (so the prefix's system32 has it) in both variants. Freestanding: kernel32
# and user32 only, no C runtime, no timestamp and no debug info, so the output is the same
# for the same source and toolchain and names no path.
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
echo "$(sha256sum "$OUT/playport-session.exe" | cut -c1-16)  playport-session.exe ($(stat -c %s "$OUT/playport-session.exe") bytes)"
