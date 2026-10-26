#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Bring what the Linux build container staged (build/docker/README.md; `pp build
# --to stage` there) into this checkout, for the Xcode build (project.yml):
#
#   app/Staged/                 the archives, the xcframeworks, the licences
#   app/Sources/S1Probe/Runtime the guest files shipped at the app root
#   app/Sources/WinIOS          the display driver's sources, plus a module map
#                               (SwiftPM on a case-insensitive file system would
#                               take Winios.h alone as the WinIOS umbrella)
#
# then the simulator's copies (simulator-staged.py).
#
#   app/Xcode/sync-staged.sh [CONTAINER]    default: playport-builder
set -euo pipefail
C=${1:-playport-builder}
APP=$(cd "$(dirname "$0")/.." && pwd)
SRC=/w/playport/app

docker exec "$C" test -f "$SRC/Sources/S1Probe/Runtime/artifacts.tsv" ||
    { echo "sync-staged: nothing staged in $C ($SRC): run pp build --to stage there" >&2; exit 1; }
for d in Staged Sources/S1Probe/Runtime Sources/WinIOS; do
    rm -rf "${APP:?}/$d"
    mkdir -p "$(dirname "$APP/$d")"
    docker cp "$C:$SRC/$d" "$APP/$d"
done
# The licences come from the notices stage; a build that stopped at stage has none.
mkdir -p "$APP/Staged/Licenses"

cat > "$APP/Sources/WinIOS/include/module.modulemap" <<'EOF'
// Added on a Mac (app/Xcode/sync-staged.sh): on a case-insensitive file system
// SwiftPM would take Winios.h as WinIOS's umbrella and leave the others out.
module WinIOS {
    header "Winios.h"
    header "WiniosGamepad.h"
    header "IOSDisplayShim.h"
    export *
}
EOF

# Mesa's dylibs are linked by lld in the container, which can leave the string
# table unaligned; Xcode's linker refuses that ("mis-aligned LINKEDIT string pool").
for n in KosmicKrisp MesaEGL MesaGallium; do
    python3 "$APP/Xcode/align-strtab.py" "$APP/Staged/$n.xcframework/ios-arm64/$n.framework/$n"
done

# libwineserver.a and libntdll_unix.a both define native_machine, supported_machines,
# supported_machines_count and server_start_time. ld64 (the workstation's app link)
# merges them; Xcode 27's linker stops on them as duplicates. The unix stage's link
# test already builds the candidate that renames wineserver's four to ws_* (the
# rename build.sh does for its other symbols, build/stages/unix-gaps.sh): that one.
docker cp "$C:/w/playport/.work/run/unix/linktest/libwineserver-ws4.a" "$APP/Staged/lib/libwineserver.a"

python3 "$APP/Xcode/simulator-staged.py" "$APP/Staged"
du -sh "$APP/Staged" "$APP/Sources/S1Probe/Runtime" | sed 's/^/sync-staged: /'
