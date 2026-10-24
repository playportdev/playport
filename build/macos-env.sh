# SPDX-License-Identifier: GPL-3.0-or-later
# Sourced only on Darwin by env.sh. Keep GNU build recipes shared with Linux;
# use Homebrew's native tools and Xcode's SDK/linker, without changing system files.
_brew=$(command -v brew || true)
if [ -n "$_brew" ]; then
    _prefix=$("$_brew" --prefix)
    for _tool in coreutils gnu-sed gnu-tar findutils make gawk; do
        PATH="$_prefix/opt/$_tool/libexec/gnubin:$PATH"
    done
    for _tool in llvm lld bison flex gettext; do
        PATH="$_prefix/opt/$_tool/bin:$PATH"
    done
    # Mesa's host compiler tools need the matching LLVM/libclc/translator.
    export CMAKE_PREFIX_PATH="$_prefix/opt/llvm${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
    export PKG_CONFIG_PATH="$_prefix/opt/spirv-llvm-translator/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
fi
export PATH
: "${DARWIN_SDK:=$(xcode-select -p)}"
export DEVELOPER_DIR="$DARWIN_SDK"
: "${LD64:=$(xcrun --find ld)}"
# Current Xcode ld removed -d. The classic linker is used only for archive
# prelinking, which must allocate common symbols before making them private.
: "${PRELINK_LD64:=$PLAYPORT_BUILD/inputs/apple-linker/prefix/bin/arm64-apple-darwin-ld}"
: "${LIBTOOL:=$(xcrun --find libtool)}"
: "${PLAYPORT_USBMUX_SOCKET:=/var/run/usbmuxd}"
# Never let llvm-mingw's clang (added by PE stages) compile host code.
: "${HOST_CLANG:=$(command -v clang)}"
: "${HOST_CLANGXX:=$(command -v clang++)}"
: "${HOST_LLVM_BIN:=$(dirname "$HOST_CLANG")}"
export LIBTOOL HOST_CLANG HOST_CLANGXX HOST_LLVM_BIN PRELINK_LD64
unset _brew _prefix _tool
