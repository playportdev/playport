#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Separate, multi-hour CEF build; never invoked by pp build.
set -euo pipefail
if [[ $# -lt 1 || $# -gt 2 || ! $1 =~ ^[a-zA-Z0-9_-]+$ || ! ${2:-12} =~ ^[1-9][0-9]*$ ]]; then
    echo "usage: $0 TAG [JOBS]" >&2
    exit 2
fi
source "$(dirname "$0")/env-win.sh"
tag="$1"; jobs="${2:-12}"
trap 'rc=$?; printf "%s\n" "$rc" > "$CEF_WORK/logs/lowva-$tag.exit"' EXIT
cd "$CEF_WORK/src"
echo "start $(date -Iseconds) jobs=$jobs"
nice -n 15 third_party/ninja/ninja -C out/Release_GN_x64_lowva -j "$jobs" -k 50 libcef chrome_elf
echo "end $(date -Iseconds)"
