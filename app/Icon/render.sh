#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Render app/Icon/AppIcon.svg to the two committed 1024 px PNGs that xtool.yml's
# iconPath names: AppIcon-dev.png (with the #dev badge) for the dev app and
# AppIcon.png (without it) for the release app (build/stages/stage-artifacts.py
# release). The build does not run this; run it after editing the SVG and commit
# the PNGs with it.
#
#   app/Icon/render.sh [CHROMIUM]   a headless Chromium: $CHROMIUM, else Playwright's headless_shell
#                                 (a full chrome's --headless crops the window to its UI)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
CHROME=${1:-${CHROMIUM:-$(ls -d "${PLAYWRIGHT_BROWSERS_PATH:-/opt/pw-browsers}"/chromium_headless_shell-*/chrome-linux/headless_shell 2>/dev/null | tail -1)}}
test -x "$CHROME" || { echo "no chromium: pass its path" >&2; exit 1; }
WORK=${PLAYPORT_BUILD:-$ROOT/.work}/icon
mkdir -p "$WORK"

render() {  # render OUT DEV_DISPLAY
    local html="$WORK/$(basename "$1" .png).html"
    { printf '<!doctype html><style>html,body{margin:0;background:#000}svg{display:block}#dev{display:%s}</style>' "$2"
      cat "$HERE/AppIcon.svg"; } > "$html"
    "$CHROME" --no-sandbox --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
        --default-background-color=000000ff --window-size=1024,1024 \
        --user-data-dir="$WORK/profile" --screenshot="$1" "file://$html" 2>/dev/null
    echo "wrote $1"
}
render "$HERE/AppIcon-dev.png" inline
render "$HERE/AppIcon.png" none
