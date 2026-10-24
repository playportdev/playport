#!/usr/bin/env bash
# Real production C helper, deterministic injection only in the host test process.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
TREE=$(realpath "${1:-$REPO/.work/run/vulkan-pe/vkd3d-proton}")
OUT=$(realpath -m "${2:-$REPO/.work/run/vkd3d-descriptor-test}")
mkdir -p "$OUT"
CC=${CC:-cc}
FLAGS=(-std=c11 -D_POSIX_C_SOURCE=200809L -O2 -g -Wall -Wextra -Werror -pthread -I "$TREE/libs/vkd3d")
"$CC" "${FLAGS[@]}" "$HERE/descriptor-stats-test.c" "$TREE/libs/vkd3d/vkd3d_descriptor_stats.c" -o "$OUT/descriptor-stats-test"
timeout --kill-after=5s 30s "$OUT/descriptor-stats-test"
"$CC" "${FLAGS[@]}" -c "$HERE/disabled-path.c" -o "$OUT/disabled-path.o"
"${OBJDUMP:-objdump}" -dr "$OUT/disabled-path.o" > "$OUT/disabled-path.asm"
