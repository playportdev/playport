#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# winegstreamer's unix side for the app: Wine's Media Foundation and DirectShow
# media sources and decoders run over GStreamer, which the app links statically
# (docs/ARCHITECTURE.md, "Media"; docs/LICENSING.md, GStreamer).
#
#   build/stages/gstreamer.sh fetch        the pinned GStreamer iOS release, unpacked into the cache;
#                                          prints its ios-arm64 directory
#   build/stages/gstreamer.sh unix ROOT    compile winegstreamer's unix sources from ROOT/wine (the
#                                          stages/unix.sh tree: wine pin + wine-port + wine-valve + wine-unix) and
#                                          prelink them with the plugin set below into
#                                          ROOT/gstreamer/libwinegstreamer_unix.a
#
# The release is GStreamer's own binary build for iOS (gstreamer.freedesktop.org,
# the pins.lock gstreamer tag), checked against its sha256 below: one static
# archive, libGStreamer.a, with GLib, every plugin and their libraries. The
# prelink (ld64 -r) takes from it only the members winegstreamer and the
# registered plugins reach, and exports one symbol, the call table
# (winegstreamer_unix_call_funcs, routed by patches/madeira-unix 0031): the
# rest, GStreamer's own GnuTLS, GMP and FFmpeg among them, is private to the
# object and cannot collide with the app's archives.
#
# The plugin set: what winegstreamer builds its pipelines from (wg_parser.c,
# wg_transform.c: decodebin, typefind, appsrc/appsink, the converters,
# deinterlace, videoflip) and the formats titles have been seen to play:
# MP4 (isomp4) with H.264 and AAC (Hollow Knight's cinematics; libav decodes
# both: VideoToolbox's vtdec is registered but ranked below it, see plugins.c),
# WebM/Matroska with VP8/VP9 and Vorbis/Opus, MPEG-1/2 video and audio (libav).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../lib.sh"

SHA256=2b1233ba3d1f8166bfa85f664709ee5ff36b81e82b9652a1d3e79c1783da9584
TAG=$(pin gstreamer)
URL=$(pin_url gstreamer)/$TAG/gstreamer-$TAG-xcframework.tar.xz
CACHE_DIR=${CACHE:-$PLAYPORT_BUILD/cache}/gstreamer-$TAG
GST=$CACHE_DIR/ios-arm64

# GST_PLUGIN_STATIC_DECLARE names (gst_plugin_<name>_register in libGStreamer.a).
PLUGINS="coreelements typefindfunctions app playback videoconvertscale audioconvert audioresample
         deinterlace videofilter autodetect isomp4 matroska audioparsers videoparsersbad
         applemedia libav vpx vorbis opus ogg"

fetch() {
    local tar=$CACHE_DIR/gstreamer-$TAG-xcframework.tar.xz
    if [ ! -f "$GST/.done" ]; then
        mkdir -p "$CACHE_DIR"
        if ! echo "$SHA256  $tar" | sha256sum -c --status 2>/dev/null; then
            curl -fsSL -o "$tar.part" "$URL"
            mv "$tar.part" "$tar"
            echo "$SHA256  $tar" | sha256sum -c --status || { echo "gstreamer: $URL is not sha256 $SHA256" >&2; exit 1; }
        fi
        rm -rf "$GST" "$CACHE_DIR/GStreamer.xcframework"
        tar -xJf "$tar" -C "$CACHE_DIR" GStreamer.xcframework/ios-arm64
        mv "$CACHE_DIR/GStreamer.xcframework/ios-arm64" "$GST"
        rm -rf "$CACHE_DIR/GStreamer.xcframework"
        touch "$GST/.done"
    fi
    echo "$GST"
}

unix() {
    local root=${1:?usage: $0 unix ROOT} out obj w m src cc
    w=$root/wine; m=$root/mythic; out=$root/gstreamer; obj=$out/obj
    fetch > /dev/null
    rm -rf "$out"; mkdir -p "$obj"
    # the plugin registration winegstreamer calls after gst_init (patches/wine-unix 0005)
    {
        echo '#include <gst/gst.h>'
        for p in $PLUGINS; do echo "GST_PLUGIN_STATIC_DECLARE($p);"; done
        echo 'void winegstreamer_register_static_plugins(void)'
        echo '{'
        for p in $PLUGINS; do echo "    GST_PLUGIN_STATIC_REGISTER($p);"; done
        # VideoToolbox's decoders hold frames back and decode asynchronously;
        # winegstreamer's parser and transforms need a decoder that returns a
        # frame per input, and Hollow Knight's cinematic stalled with vtdec_hw
        # holding the queue. Rank them below libav's software decoders, as
        # winegstreamer already refuses vaapidecodebin for the same reason.
        cat <<'C'
    {
        static const char *const async_decoders[] = {"vtdec_hw", "vtdec"};
        GstRegistry *registry = gst_registry_get();
        for (unsigned int i = 0; i < G_N_ELEMENTS(async_decoders); ++i)
        {
            GstPluginFeature *feature = gst_registry_lookup_feature(registry, async_decoders[i]);
            if (!feature) continue;
            gst_plugin_feature_set_rank(feature, GST_RANK_MARGINAL);
            gst_object_unref(feature);
        }
    }
C
        echo '}'
    } > "$out/plugins.c"
    # The flags of Madeira's compile_unixlib (build/ntdll-unix/build.sh), with
    # GStreamer's headers; the tree and the SDK are mapped out of the object.
    cc=(/usr/bin/clang --target=arm64-apple-ios17.0 -isysroot "$IOSSDK"
        -O2 -fPIC -fvisibility=hidden -fno-stack-protector -fno-strict-aliasing
        -Wno-implicit-function-declaration -Wno-int-conversion -Wno-unused-command-line-argument
        "-ffile-prefix-map=$root=unix" "-ffile-prefix-map=$DARWIN_SDK=darwin-sdk"
        "-ffile-prefix-map=$CACHE_DIR=gstreamer"
        -include "$w/build-macos/include/config.h"
        -include "$m/build/ntdll-unix/shims/wine_ios_exit.h"
        -I"$m/build/ntdll-unix/shims" -I"$w/build-macos/include" -I"$w/include" -I"$w/dlls/winegstreamer"
        -I"$GST/Headers"
        -D__WINESRC__ -D_NTSYSTEM_ -D_ACRTIMP= -DWINBASEAPI= -DWINE_UNIX_LIB -DWINE_IOS=1
        -D__wine_unix_call_funcs=winegstreamer_unix_call_funcs
        -D__wine_unix_call_wow64_funcs=winegstreamer_unix_call_wow64_funcs)
    for src in "$out/plugins.c" $(grep -l '^#pragma makedep unix' "$w"/dlls/winegstreamer/*.c); do
        "${cc[@]}" -c "$src" -o "$obj/$(basename "$src" .c).o"
    done
    # One object: winegstreamer, the registered plugins and what they reach in
    # libGStreamer.a; only the call table stays global.
    # libGStreamer.a's common symbols become definitions only in the first pass
    # (-d), after the export list was applied, so a second pass hides them too.
    # rust_eh_personality: the Rust demangler GStreamer's stack traces use names it
    # only from its unwind info, which does not pull archive members, and those
    # references are by name, so it stays global (the app's other Rust, idevice's
    # FFI, keeps its copy private to its own object: build/stages/idevice.sh;
    # StikJIT's is inside its own framework).
    "$LD64" -r -d -arch arm64 -platform_version ios 17.0 26.5 -syslibroot "$IOSSDK" -u _rust_eh_personality \
        -o "$obj/prelinked.o" "$obj"/*.o "$GST/libGStreamer.a"
    # -S: no debug map, whose entries would name each member by its path on this machine.
    "$LD64" -r -S -arch arm64 -platform_version ios 17.0 26.5 -syslibroot "$IOSSDK" \
        -exported_symbol _winegstreamer_unix_call_funcs -exported_symbol _rust_eh_personality \
        -o "$obj/winegstreamer_unix.o" "$obj/prelinked.o"
    rm "$obj/prelinked.o"
    llvm-ar rcs "$out/libwinegstreamer_unix.a" "$obj/winegstreamer_unix.o"
    llvm-nm "$obj/winegstreamer_unix.o" > "$obj/symbols.txt"
    grep -Eq '^[0-9a-f]+ [DS] _winegstreamer_unix_call_funcs$' "$obj/symbols.txt" ||
        { echo "gstreamer: winegstreamer_unix_call_funcs is not exported" >&2; exit 1; }
    [ "$(grep -Ec '^[0-9a-f]+ [A-TV-Z] ' "$obj/symbols.txt")" = 2 ] ||
        { echo "gstreamer: the object exports more than the call table and rust_eh_personality" >&2; exit 1; }
    for p in $PLUGINS; do
        grep -q " _gst_plugin_${p}_get_desc$" "$obj/symbols.txt" ||
            { echo "gstreamer: plugin $p is not in the object" >&2; exit 1; }
    done
    # what the object leaves to the app's link (the frameworks and libraries app/Package.swift names)
    grep -E '^ +U ' "$obj/symbols.txt" | awk '{print $2}' > "$out/imports.txt"
    echo "$(wc -l < "$out/imports.txt") imported symbols ($out/imports.txt)"
    printf '%s %s %s\n' "$(stat -c %s "$out/libwinegstreamer_unix.a")" \
        "$(sha256sum "$out/libwinegstreamer_unix.a" | cut -d' ' -f1)" "$out/libwinegstreamer_unix.a"
}

case ${1:-} in
fetch) fetch ;;
unix) unix "${2:-}" ;;
*) echo "usage: $0 fetch | unix ROOT" >&2; exit 1 ;;
esac
