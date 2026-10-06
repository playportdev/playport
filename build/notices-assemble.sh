#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copy the licence and notice files that docs/NOTICES.md lists for the app's
# IPA out of the pinned trees into OUT, with SHA256SUMS. Every file is copied
# byte for byte from its upstream location; nothing is written into the
# repository or the app bundle. This is an inventory input, not legal approval.
#
#   build/notices-assemble.sh OUT
#   build/notices-assemble.sh --prepare-rust-cache OUT
#   build/notices-assemble.sh --app NOTICES OUT   the app's Licenses/ selection (build/notices-app.py)
#
# RUST_NOTICE_CARGO_HOME selects a separate registry prepared from locked archives;
# it never changes RUST_ROOT's compiler/standard-library documentation location.
#
# Tree roots (env; the defaults are a finished pp build run in
# $PLAYPORT_RUN, default $PLAYPORT_BUILD/run): WINE FEX MYTHIC DXMT LLVM FREETYPE MESA DXVK VKD3D GBE ABSL, and STIKJIT and
# IDEVICE (the checkouts build/stages/stikjit.sh keeps under
# $PLAYPORT_BUILD/cache). Each must match its exact pin-plus-series tree.
# IDEVICE_RUN (default $RUN/idevice) is build/stages/idevice.sh's output: its
# crates.tsv lists normal target dependencies (not a link-member audit). Regenerate
# it offline and verify registry bytes against committed Cargo.lock archive hashes.
# RUST_NOTICE_DIST holds locked rustc/iOS stdlib/rust-src archives; no fetch occurs.
# MINGW_SOURCE and LLVM_MINGW_SOURCE hold exact source checkouts named by
# build/mingw-notices.lock.json; LLVM_MINGW supplies installed notice-byte checks.
# GST_NOTICE_CERBERO/GST_NOTICE_SOURCES supply the preparatory recipe/source
# archives in build/gstreamer-notices.sources.json, NOT verified IPA derivation.
# LLVM_RUNTIME_SOURCE supplies the exact source in build/llvm-runtime-notices.lock.json;
# retain its large incomplete superset in a separate, completely verified directory.
set -euo pipefail

. "$(dirname "$0")/lib.sh"
RUN=${PLAYPORT_RUN:-$PLAYPORT_BUILD/run}
IDEVICE=${IDEVICE:-$PLAYPORT_BUILD/cache/idevice-$(pin idevice)}
if [ "${1:-}" = --prepare-rust-cache ]; then
    [ "$#" = 2 ] || { echo 'usage: pp notices --prepare-rust-cache OUT' >&2; exit 1; }
    exec python3 "$PLAYPORT_REPO/build/notices-rust-cache.py" "$PLAYPORT_REPO" "$IDEVICE" \
        "$RUST_ROOT/cargo" "$PLAYPORT_BUILD/tmp" "$2"
fi
if [ "${1:-}" = --app ]; then
    [ "$#" = 3 ] || { echo 'usage: pp notices --app NOTICES OUT' >&2; exit 1; }
    exec python3 "$PLAYPORT_REPO/build/notices-app.py" select "$2" "$3"
fi
[ "$#" = 1 ] && [[ "$1" != -* ]] || { echo 'usage: pp notices OUT | --prepare-rust-cache OUT | --app NOTICES OUT' >&2; exit 1; }
OUT=$1
FINAL_OUT=$(realpath -m "$OUT")
if [ -e "$FINAL_OUT" ] || [ -L "$FINAL_OUT" ]; then
    echo "notice output already exists: $FINAL_OUT" >&2; exit 1
fi
WINE=${WINE:-$RUN/pe/wine}
FEX=${FEX:-$RUN/fex}
MYTHIC=${MYTHIC:-$RUN/unix/mythic}
DXMT=${DXMT:-$RUN/dxmt-patched/dxmt}
LLVM=${LLVM:-$RUN/dxmt-patched/llvm-project}
FREETYPE=${FREETYPE:-$RUN/unix/mythic/research/freetype}
MESA=${MESA:-$RUN/mesa/mesa}
DXVK=${DXVK:-$RUN/vulkan-pe/dxvk}
VKD3D=${VKD3D:-$RUN/vulkan-pe/vkd3d-proton}
GBE=${GBE:-$RUN/steamapi/gbe}
ABSL=${ABSL:-$RUN/steamapi/abseil-cpp}
STIKJIT=${STIKJIT:-$PLAYPORT_BUILD/cache/stikjit-$(pin stikjit)/src}
RUST_NOTICE_CARGO_HOME=${RUST_NOTICE_CARGO_HOME:-$RUST_ROOT/cargo}
export RUST_NOTICE_CARGO_HOME
IDEVICE_RUN=${IDEVICE_RUN:-$RUN/idevice}
RUST_NOTICE_DIST=${RUST_NOTICE_DIST:-$PLAYPORT_BUILD/cache/rust-dist}
RUST_DOC=$RUST_ROOT/rustup/toolchains/$(pin rust)-x86_64-unknown-linux-gnu/share/doc/rust
MINGW_SOURCE=${MINGW_SOURCE:-$PLAYPORT_BUILD/cache/mingw-w64-notices}
LLVM_MINGW_SOURCE=${LLVM_MINGW_SOURCE:-$PLAYPORT_BUILD/cache/llvm-mingw-notices}
REPO=$PLAYPORT_REPO
GST_NOTICE_CERBERO=${GST_NOTICE_CERBERO:-$PLAYPORT_BUILD/cache/gstreamer-notices/cerbero.tar.gz}
GST_NOTICE_SOURCES=${GST_NOTICE_SOURCES:-$PLAYPORT_BUILD/cache/gstreamer-notices/sources}
LLVM_RUNTIME_SOURCE=${LLVM_RUNTIME_SOURCE:-$PLAYPORT_BUILD/cache/llvm-runtime-notices}
export GST_NOTICE_CERBERO GST_NOTICE_SOURCES LLVM_RUNTIME_SOURCE LLVM_MINGW_SOURCE

# A failed collection must not leave an apparently usable notice bundle.
# Work beside the destination (same filesystem), then publish only on success.
OUT=$(mktemp -d "${FINAL_OUT}.partial.XXXXXX")
trap 'rm -rf -- "$OUT"' EXIT
export WINE FEX MYTHIC DXMT LLVM FREETYPE MESA DXVK VKD3D GBE ABSL STIKJIT IDEVICE
python3 "$REPO/build/notices-provenance.py" trees "$REPO" "$PLAYPORT_BUILD/tmp" "$OUT/tree-provenance.json"
python3 "$REPO/build/notices-rust.py" "$REPO" "$IDEVICE" "$IDEVICE_RUN" "$RUST_ROOT" \
    "$PLAYPORT_BUILD/tmp" "$OUT/rust-provenance.json" --cargo-home "$RUST_NOTICE_CARGO_HOME" --collect-notices "$OUT"
python3 "$REPO/build/notices-rust-stdlib.py" "$REPO" "$RUST_ROOT" "$RUST_NOTICE_DIST" \
    "$OUT/rust-stdlib-provenance.json" --collect-source-notices "$OUT"
python3 "$REPO/build/notices-mingw.py" "$REPO" "$MINGW_SOURCE" "$LLVM_MINGW_SOURCE" \
    "$LLVM_MINGW" "$PLAYPORT_BUILD/tmp" "$OUT"
python3 "$REPO/build/notices-gstreamer.py" "$GST_NOTICE_CERBERO" "$GST_NOTICE_SOURCES" \
    "$OUT" --repo "$REPO" --assemble
python3 "$REPO/build/notices-llvm-runtime.py" collect "$REPO" "$LLVM_RUNTIME_SOURCE" \
    "$LLVM_MINGW_SOURCE" "$OUT/llvm-runtime"
CRYPTO=$MYTHIC/build/gnutls-ios/src
(cd "$CRYPTO" && sha256sum -c --quiet SHA256SUMS)
: > "$OUT/.copy-sources.tsv"
: > "$OUT/.derived-sources.tsv"
unused_() {
    [ ! -e "$OUT/$1" ] && [ ! -L "$OUT/$1" ] || { echo "duplicate notice output: $1" >&2; exit 1; }
}
cp_() {
    unused_ "$1"
    cp "$2" "$OUT/$1"
    printf '%s\t%s\n' "$1" "$2" >> "$OUT/.copy-sources.tsv"
}
archive_() {
    unused_ "$1"
    tar -xOf "$2" "$3" >"$OUT/$1"
    printf 'archive-member\t%s\t%s\t%s\n' "$1" "$2" "$3" >> "$OUT/.derived-sources.tsv"
}
tar_() { archive_ "$1" "$CRYPTO/$2" "$3"; }
excerpt_() {
    unused_ "$1"
    sed -n "${3},${4}p" "$2" >"$OUT/$1"
    printf 'line-excerpt\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$OUT/.derived-sources.tsv"
}

# Playport and the GPL/LGPL texts
cp_ Playport-LICENSE.txt "$REPO/LICENSE"
cp_ Playport-LICENSE-EXCEPTION.md "$REPO/LICENSE-EXCEPTION.md"
# JavaSteam (MIT): the protocol schema tables in app/SteamClient
cp_ JavaSteam-LICENSE.txt "$REPO/app/SteamClient/LICENSE-JavaSteam.txt"
tar_ GPL-2.0.txt gmp-6.3.0.tar.xz gmp-6.3.0/COPYINGv2
tar_ LGPL-3.0.txt gmp-6.3.0.tar.xz gmp-6.3.0/COPYING.LESSERv3
cp_ LGPL-2.1.txt "$WINE/COPYING.LIB"
# Wine root notices and a superset of its bundled-library licence files.
# This intentionally inventories unlinked libraries too; linked-code coverage
# still needs a separate audit. Do not assume removed libraries such as
# tomcrypt, or the retired LICENSE.OLD, exist at the current pin.
python3 "$REPO/build/notices-wine.py" "$WINE" "$OUT" --tracked --origins-log "$OUT/.copy-sources.tsv"
# Wine's bundled Tahoma faces: their SFD headers carry Larry Snyder's
# attribution as well as Bitstream's (the licence is in wine-NOTICES.md).
# Inclusive ranges are reverified against committed bytes by the derived gate.
excerpt_ wine-fonts-tahoma-attribution.txt "$WINE/fonts/tahoma.sfd" 1 6
excerpt_ wine-fonts-tahomabd-attribution.txt "$WINE/fonts/tahomabd.sfd" 1 6
# FEX PE (xtajit64.dll) and what is statically inside it
cp_ FEX-LICENSE.txt "$FEX/LICENSE"
cp_ FEX-LICENSE-MADEIRA.md "$FEX/LICENSE-MADEIRA.md"
cp_ rpmalloc-LICENSE.txt "$FEX/External/rpmalloc/LICENSE"
cp_ rpmalloc-LICENSE-MADEIRA.md "$FEX/External/rpmalloc/LICENSE-MADEIRA.md"
cp_ fmt-LICENSE.txt "$FEX/External/fmt/LICENSE"
cp_ xxHash-LICENSE.txt "$FEX/External/xxhash/LICENSE"
cp_ cephes-LICENSE.txt "$FEX/External/cephes/LICENSE"
cp_ SoftFloat-3e-LICENSE.txt "$MYTHIC/LICENSES/BSD-3-SoftFloat-3e.txt"
cp_ tiny-json-LICENSE.txt "$FEX/External/tiny-json/LICENSE"
cp_ cpp-optparse-LICENSE.txt "$FEX/Source/Common/cpp-optparse/LICENSE"
cp_ unordered_dense-LICENSE.txt "$FEX/External/unordered_dense/LICENSE"
# Madeira host layer and Winios source
cp_ Madeira-LICENSE.txt "$MYTHIC/LICENSE"
cp_ Madeira-LICENSE-EXCEPTION.md "$MYTHIC/LICENSE-EXCEPTION.md"
cp_ Madeira-THIRD-PARTY-NOTICES.md "$MYTHIC/THIRD-PARTY-NOTICES.md"
# DXMT (unix slice in the executable, PE DLLs): upstream's licence files, then
# Madeira's (from patches/dxmt-port), and what the slice compiles in
cp_ DXMT-LICENSE.txt "$DXMT/LICENSE"
cp_ DXMT-COPYING.LIB.txt "$DXMT/COPYING.LIB"
cp_ DXMT-LICENSE.OLD.txt "$DXMT/LICENSE.OLD"
cp_ DXMT-LICENSE-MADEIRA.md "$DXMT/LICENSE-MADEIRA.md"
cp_ DXMT-COPYING.GPL-3.0.txt "$DXMT/COPYING.GPL-3.0"
excerpt_ DXBCParser-header.txt "$DXMT/libs/DXBCParser/ShaderBinary.cpp" 1 2   # no licence file in the directory
# ... so its MIT text comes from the Microsoft repository its files are from (build/notices-extra/sources.json)
cp_ DXBCParser-LICENSE-Microsoft.txt "$REPO/build/notices-extra/D3D12TranslationLayer-LICENSE"
cp_ mingw-directx-headers-COPYING.MinGW-w64.txt "$DXMT/include/native/directx/COPYING.MinGW-w64.txt"
# LLVM 15.0.7 iOS libraries in the executable, and the third-party code the link keeps
cp_ LLVM-LICENSE.TXT "$LLVM/llvm/LICENSE.TXT"
cp_ LLVM-Support-COPYRIGHT.regex.txt "$LLVM/llvm/lib/Support/COPYRIGHT.regex"
excerpt_ LLVM-Support-ConvertUTF-Unicode-notice.txt "$LLVM/llvm/lib/Support/ConvertUTF.cpp" 8 28
# FreeType 2.14.3 (in libwin32u_unix.a): both licence options; the choice is open
cp_ FreeType-LICENSE.TXT "$FREETYPE/LICENSE.TXT"
cp_ FreeType-FTL.TXT "$FREETYPE/docs/FTL.TXT"
cp_ FreeType-GPLv2.TXT "$FREETYPE/docs/GPLv2.TXT"
# KosmicKrisp (KosmicKrisp.framework): Mesa's licence summary and licence texts.
# Preserve vendored Vulkan/SPIR-V attribution separately, as full headers:
# generic licence texts alone do not preserve their file-specific credits.
cp_ Mesa-license.rst "$MESA/docs/license.rst"
for f in "$MESA"/licenses/* "$MESA"/licenses/exceptions/*; do
    [ -f "$f" ] && cp_ "Mesa-licenses-$(basename "$f").txt" "$f"
done
python3 "$REPO/build/notices-mesa.py" "$MESA" "$OUT"
# Khronos Vulkan/SPIR-V header notices, including nested converter copies.
# Keep root attribution summaries and all LICENSES/ texts, including non-code
# material as an explicit superset. Per-file applicability remains open.
python3 "$REPO/build/notices-khronos.py" "$DXVK" "$VKD3D" "$OUT" --origins-log "$OUT/.copy-sources.tsv"
# DXVK (Runtime/vulkan: d3d8, d3d9, d3d10core, d3d11, dxgi) and what it compiles in
cp_ DXVK-LICENSE.txt "$DXVK/LICENSE"
cp_ DXVK-libdisplay-info-LICENSE.txt "$DXVK/subprojects/libdisplay-info/LICENSE"
cp_ DXVK-dxbc-spirv-LICENSE.txt "$DXVK/subprojects/dxbc-spirv/LICENSE"
cp_ DXVK-mingw-directx-headers-COPYING.MinGW-w64.txt "$DXVK/include/native/directx/COPYING.MinGW-w64.txt"
# vkd3d-proton (Runtime/vulkan: d3d12, d3d12core) and what it compiles in
DXIL=$VKD3D/subprojects/dxil-spirv
cp_ vkd3d-proton-COPYING.txt "$VKD3D/COPYING"
cp_ vkd3d-proton-LICENSE.txt "$VKD3D/LICENSE"
cp_ vkd3d-proton-AUTHORS.txt "$VKD3D/AUTHORS"
cp_ dxil-spirv-LICENSE.MIT.txt "$DXIL/LICENSE.MIT"
cp_ dxil-spirv-dxbc-spirv-LICENSE.txt "$DXIL/subprojects/dxbc-spirv/LICENSE"
excerpt_ dxil-spirv-bc-decoder-header.txt "$DXIL/third_party/bc-decoder/llvm_decoder.cpp" 1 23   # no licence file in the directory
excerpt_ dxil-spirv-glslang-spirv-header.txt "$DXIL/third_party/glslang-spirv/SpvBuilder.cpp" 1 34
# gbe_fork (Runtime/steamapi: steam_api64.dll, steam_api.dll), the libraries in
# its tree, and the dependencies it links statically: each from the archive on
# its third-party/deps/common branch (the build's), and Abseil from its pin
cp_ gbe_fork-LICENSE.txt "$GBE/LICENSE"
for l in fifo_map gamepad json simpleini stb utfcpp; do cp_ "gbe_fork-libs-$l-SOURCE.txt" "$GBE/libs/$l/SOURCE.txt"; done
cp_ gbe_fork-libs-sha-source.txt "$GBE/libs/sha/source.txt"
DEPS=$GBE/third-party/deps/common
for f in curl/COPYING libssq/LICENSE mbedtls/LICENSE opus/COPYING portaudio/LICENSE.txt protobuf/LICENSE \
         protobuf/third_party/utf8_range/LICENSE sdl/LICENSE.txt zlib/LICENSE; do
    archive_ "gbe_fork-deps-$(echo "${f%.txt}" | tr / -).txt" "$DEPS/${f%%/*}/${f%%/*}.tar.gz" "$f"
done
cp_ abseil-cpp-LICENSE.txt "$ABSL/LICENSE"
# MoltenVK (Apache-2.0) in GStreamer's iOS release: its licence at the SDK's MoltenVK tag
# (build/notices-extra/sources.json, decision 0042)
cp_ MoltenVK-LICENSE.txt "$REPO/build/notices-extra/MoltenVK-LICENSE"
# StikJIT (MPL-2.0), unmodified in the JIT helper extension's Frameworks/
cp_ StikJIT-LICENSE.txt "$STIKJIT/LICENSE"
# idevice's pinned notice bytes (MIT), for the executable and for the idevice inside StikJIT (decision 0042)
cp_ idevice-LICENSE.txt "$IDEVICE/LICENSE.txt"
# Three locked crates ship no licence file anywhere; Playport writes their notices from
# their Cargo.toml metadata (build/notices-extra/sources.json, decision 0039)
for c in ns-keyed-archive plist-macro plist_ffi; do
    cp_ "crate-notice-from-metadata-$c.txt" "$REPO/build/notices-extra/$c-NOTICE-from-metadata"
done
# The Rust crates idevice's FFI links into the executable, each with the licence files
# its crate carries; the Rust standard library with it, from the Rust release
cp_ rust-COPYRIGHT-library.html "$RUST_DOC/COPYRIGHT-library.html"
# Keep every release licence text as a labelled superset (including compiler/docs
# options). COPYRIGHT-library.html identifies standard-library attributions.
for f in "$RUST_DOC"/licenses/*.txt; do
    cp_ "rust-licenses-$(basename "$f")" "$f"
done
# Registry notices and summaries were copied from reverified locked archives by
# notices-rust.py above; their complete payload/origin set is checked by inventory.
# Crypto statics in the executable
tar_ GnuTLS-COPYING.LESSERv2.txt gnutls-3.8.9.tar.xz gnutls-3.8.9/COPYING.LESSERv2
tar_ Nettle-COPYING.LESSERv3.txt nettle-3.10.1.tar.gz nettle-3.10.1/COPYING.LESSERv3
tar_ Nettle-COPYINGv2.txt nettle-3.10.1.tar.gz nettle-3.10.1/COPYINGv2

python3 "$REPO/build/notices-provenance.py" copies "$REPO" "$OUT/.copy-sources.tsv" "$OUT/notice-origins.json"
python3 "$REPO/build/notices-provenance.py" derived "$REPO" "$OUT/.derived-sources.tsv" "$OUT/derived-origins.json"
rm -- "$OUT/.copy-sources.tsv" "$OUT/.derived-sources.tsv"
python3 "$REPO/build/notices-provenance.py" inventory "$OUT"
# Include the separately verified LLVM directory and its own manifest/checksums;
# only the outer checksum list excludes itself. Names are validated by inventory.
(cd "$OUT" && find . -type f ! -path ./SHA256SUMS -print0 | sort -z | \
    xargs -0 sha256sum -- >SHA256SUMS && sha256sum -c --quiet SHA256SUMS)
# Refuse to replace a destination another process created during collection.
mv -T -n -- "$OUT" "$FINAL_OUT"
[ ! -d "$OUT" ] || { echo "notice output appeared during collection: $FINAL_OUT" >&2; exit 1; }
trap - EXIT
echo "$(($(wc -l <"$FINAL_OUT/SHA256SUMS"))) files in $FINAL_OUT"
echo "Notice inventory only: docs/NOTICES.md lists remaining release blockers."
