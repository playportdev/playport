#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build the xtool the app is signed with: xtool at the pins.lock tag plus
# build/toolchain/xtool-1.20.1-increased-memory-limit.diff. Stock xtool drops the
# increased-memory-limit entitlement for a free team; the build still
# succeeds, and FEX then gets no JIT arena on the device.
#
#   build/toolchain/xtool.sh [ROOT]   ROOT defaults to $PLAYPORT_BUILD/inputs/xtool-src
#
# Result: ROOT/.build/release/xtool (XTOOL in build/lib.sh).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../lib.sh"
ROOT=${1:-$PLAYPORT_BUILD/inputs/xtool-src}
TAG=$(pin xtool)
test -d "$ROOT/.git" || git clone -q "$(pin_url xtool)" "$ROOT"
git -C "$ROOT" -c advice.detachedHead=false checkout -q "$TAG"
git -C "$ROOT" apply --reverse --check "$HERE/xtool-1.20.1-increased-memory-limit.diff" 2>/dev/null ||
    git -C "$ROOT" apply "$HERE/xtool-1.20.1-increased-memory-limit.diff"
# The default build system cannot find the host's macro plugins.
(cd "$ROOT" && swift build -c release --build-system native --product xtool)
"$ROOT/.build/release/xtool" --version
