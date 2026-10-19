# SPDX-License-Identifier: GPL-3.0-or-later
# Sourced by build/lib.sh (and so by every build/*.sh script): repository paths
# and the cached external inputs. Every input is an environment variable. The system
# toolchains have no default: the repository names no path outside itself, and
# `pp setup` records where they are installed in $PLAYPORT_BUILD/inputs.local
# (sourced here, never committed; an exported variable of the same name wins;
# build/inputs.py reads it for Python).
#
#   PLAYPORT_BUILD  the build area (default .work/ in the repository, gitignored): run/ is the
#                   current run's trees, cache/ the version-keyed LLVM builds,
#                   out/ the verified IPAs
#   PLAYPORT_DEVICE_DIR  the phone's lock, holder and install record (default
#                   $PLAYPORT_BUILD)
#   LLVM_MINGW      llvm-mingw 20260922 UCRT with the arm64ec CRT rebuilt
#                   (docs/BUILDING.md, "llvm-mingw")
#   DARWIN_SDK      xtool's darwin SDK bundle (iPhoneOS26.5.sdk, MacOSX26.5.sdk)
#   LD64            Apple ld64-956.6 built for Linux (build/toolchain/ld64.sh)
#   XTOOL           xtool 1.20.1 with build/toolchain/xtool-1.20.1-increased-memory-limit.diff
#   RUST_ROOT       the pins.lock rust release with the aarch64-apple-ios std, installed
#                   by build/toolchain/rust.sh (RUST_ROOT/rustup, RUST_ROOT/cargo)
#
# Host tools (clang/lld/llvm-* 22.x in /usr/bin, gcc, bison, flex, meson,
# ninja, cmake, python3, swift) are not listed: docs/BUILDING.md has the set.

PLAYPORT_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
: "${PLAYPORT_BUILD:=$PLAYPORT_REPO/.work}"
# The phone's lock and install record are the build area's (build/inputs.py computes
# the same): a pp sync candidate builds with this checkout's build area and shares them.
: "${PLAYPORT_DEVICE_DIR:=$PLAYPORT_BUILD}"
_inputs_local=$PLAYPORT_BUILD/inputs.local
if [ -f "$_inputs_local" ]; then
    _env_llvm=${LLVM_MINGW-} _env_sdk=${DARWIN_SDK-} _env_sock=${PLAYPORT_USBMUX_SOCKET-}
    # shellcheck disable=SC1090
    . "$_inputs_local"
    LLVM_MINGW=${_env_llvm:-${LLVM_MINGW-}}
    DARWIN_SDK=${_env_sdk:-${DARWIN_SDK-}}
    PLAYPORT_USBMUX_SOCKET=${_env_sock:-${PLAYPORT_USBMUX_SOCKET-}}
    unset _env_llvm _env_sdk _env_sock
fi
unset _inputs_local
: "${LLVM_MINGW:=}" "${DARWIN_SDK:=}"
: "${LD64:=$PLAYPORT_BUILD/inputs/apple-linker/prefix/bin/arm64-apple-darwin-ld}"
: "${XTOOL:=$PLAYPORT_BUILD/inputs/xtool-src/.build/release/xtool}"
: "${RUST_ROOT:=$PLAYPORT_BUILD/inputs/rust}"
IOSSDK=$DARWIN_SDK/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.5.sdk
MACSDK=$DARWIN_SDK/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk
export PLAYPORT_BUILD PLAYPORT_DEVICE_DIR LLVM_MINGW DARWIN_SDK LD64 XTOOL RUST_ROOT
