#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build pinned xtool plus patches/xtool and patches/zsign: preserve the memory
# entitlement and sign each app/extension with its own provisioned identity.
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
# Adopt the previous task-owned patch without discarding any other changes.
if git -C "$ROOT" apply --reverse --check "$HERE/xtool-1.20.1-increased-memory-limit.diff" 2>/dev/null &&
    [ "$(git -C "$ROOT" rev-parse HEAD)" = "$(git -C "$ROOT" rev-parse "$TAG")" ]; then
    git -C "$ROOT" apply --reverse "$HERE/xtool-1.20.1-increased-memory-limit.diff"
fi
git -C "$ROOT" diff --quiet HEAD || {
    echo "xtool: preserve uncommitted source changes before rebuilding" >&2; exit 1;
}
ensure_series "$ROOT" xtool "$TAG"
dependency=$ROOT/.build/checkouts/zsign
[ -d "$dependency/.git" ] || (cd "$ROOT" && swift package resolve)
# SwiftPM makes cached checkouts read-only; this private build copy receives
# the reviewed series, never the shared repository cache.
chmod -R u+w "$dependency"
git -C "$dependency" diff --quiet HEAD || {
    echo "xtool: preserve uncommitted signer source changes before rebuilding" >&2; exit 1;
}
ensure_series "$dependency" zsign "$(pin zsign)"
signer_tree=$(git -C "$dependency" write-tree)
# The default build system cannot find the host's macro plugins.
(cd "$ROOT" && swift build -c release --build-system native --product xtool)
[ "$(git -C "$dependency" write-tree)" = "$signer_tree" ] || {
    echo "xtool: dependency resolution changed the patched signer" >&2; exit 1;
}
check_series "$dependency" zsign "$(pin zsign)"
"$ROOT/.build/release/xtool" --version
