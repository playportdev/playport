#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Real source-local helper; no Vulkan execution, Wine or phone is needed.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
TREE=$(realpath "${1:-$REPO/.work/run/vulkan-pe/dxvk}")
OUT=$(realpath -m "${2:-$REPO/.work/run/dxvk-descriptor-test}")
mkdir -p "$OUT"
"${CXX:-c++}" -std=c++17 -O2 -g -Wall -Wextra -Werror -pthread \
  -I "$TREE/src/dxvk" "$HERE/descriptor-stats-test.cpp" "$TREE/src/dxvk/dxvk_descriptor_stats.cpp" -o "$OUT/descriptor-stats-test"
timeout --kill-after=5s 30s "$OUT/descriptor-stats-test"
"${CXX:-c++}" -std=c++17 -O2 -Wall -Wextra -Werror -I "$TREE/src/dxvk" \
  -c "$HERE/disabled-path.cpp" -o "$OUT/disabled-path.o"
"${OBJDUMP:-objdump}" -drC "$OUT/disabled-path.o" > "$OUT/disabled-path.asm"
