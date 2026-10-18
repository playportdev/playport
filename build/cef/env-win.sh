# SPDX-License-Identifier: GPL-3.0-or-later
# Source in Bash. Only the owner supplies the CRT/SDK; this downloads nothing.
_CEF_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${PLAYPORT_BUILD:=$_CEF_REPO/.work}"
PLAYPORT_BUILD="$(cd "$PLAYPORT_BUILD" && pwd)"
export PLAYPORT_BUILD CEF_WORK="$PLAYPORT_BUILD/cef-src"
export TMPDIR="$PLAYPORT_BUILD/tmp"
export HOME="$CEF_WORK/home" XDG_CACHE_HOME="$CEF_WORK/cache"
export CIPD_CACHE_DIR="$CEF_WORK/cache/cipd"
export VPYTHON_VIRTUALENV_ROOT="$CEF_WORK/cache/vpython"
export DEPOT_TOOLS_WIN_TOOLCHAIN=0 DEPOT_TOOLS_UPDATE=0
# Isolated Python lets Chromium's vendored protobuf win over system packages.
# gperf 3.1 is built separately; see README.md.
export PATH="$CEF_WORK/tools/py-venv/bin:$CEF_WORK/tools/gperf/bin:$CEF_WORK/src/buildtools/linux64:$CEF_WORK/depot_tools:$PATH"
export CEF_TARGET_OS=win
mkdir -p "$TMPDIR" "$HOME" "$XDG_CACHE_HOME" "$CEF_WORK/logs"
unset _CEF_REPO
