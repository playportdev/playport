#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build the Wine fork's PE DLL sets (i386, aarch64 and arm64ec-windows) and the
# full darwin cross build from Linux. docs/BUILDING.md, "The pipeline" (pe).
#
#   OUT=<dir> stages/wine-pe.sh
#
# OUT/wine is a clone of the wine pin in pins.lock; the script applies
# patches/wine-port, patches/wine-valve and patches/wine-pe to it when it is
# not exactly the pin plus those series. OUT/build must reach a Madeira checkout's build/
# (the wine tree includes ../../../../build/madeira_cfg.h). Inputs: LLVM_MINGW
# and DARWIN_SDK (build/lib.sh); host clang/ld64.lld/llvm-ar 22.x, gcc, bison,
# flex, msgfmt. Writes only inside OUT/wine (build-tools, build-macos,
# build-arm64ec) and OUT/*.log, OUT/manifest-*.tsv.
#
# make runs with -k: a failing target does not stop the rest. The per-tree
# exit status is printed at the end; docs/BUILDING.md lists the expected
# failures (the four ntoskrnl test drivers).
#
# A build tree configured before with the same inputs (this script, the tree's
# configure, the toolchains and GStreamer headers: .pp-configured) is kept, and
# make rebuilds what changed: a re-applied series rewrites only the files its
# patches touch. Anything else configures the tree afresh (pp build --clean
# removes them all).
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../lib.sh"
OUT=${OUT:?set OUT to the build directory holding the wine clone}
WINE=$OUT/wine
PIN=$(pin wine)
M=$LLVM_MINGW
JOBS=${JOBS:-$(nproc)}

test -x "$M/bin/clang" || { echo "missing llvm-mingw at $M"; exit 1; }
test -d "$MACSDK" || { echo "missing macOS SDK $MACSDK"; exit 1; }
test -f "$OUT/build/madeira_cfg.h" || { echo "link $OUT/build to a Madeira checkout's build/"; exit 1; }

# 1. Source patches: Madeira's Wine fork rebased (patches/wine-port), Valve's
#    commits Playport takes (patches/wine-valve), then patches/wine-pe: make it
#    configure from clean;
#    guard the arm64ec-only IAT probe so aarch64 ntdll.dll links; store each TLS
#    slot into the module's JIT-pool copy as well, walk RtlWalkFrameChain in PE
#    space and run FEX's image-map notification as a syscall callback (arm64ec
#    ntdll.dll only); guard the iOS-only srcwatch probe so the darwin win32u.so links.
ensure_series "$WINE" "wine-port wine-valve wine-pe" "$PIN"

# configured TREE: TREE was configured with KEY (below) and can be kept.
configured() { [ -f "$WINE/$1/Makefile" ] && [ "$(cat "$WINE/$1/.pp-configured" 2>/dev/null)" = "$KEY" ]; }

# 2. Native (Linux) Wine build tools: makedep, winebuild, winegcc, widl, wrc,
#    wmc, sfnt2fon, make_xftmpl. wrc resolves nls/locale.nls relative to the
#    tools tree, so create that link too.
GST=$(bash "$HERE/gstreamer.sh" fetch)
KEY=$({ sha256sum "$HERE/wine-pe.sh" "$WINE/configure"; echo "$M $MACSDK $GST"
        /usr/bin/clang --version; "$M/bin/clang" --version; } | sha256sum | cut -c1-16)
if configured build-tools; then
    echo "build-tools: configured as before; make rebuilds what changed"
else
    rm -rf "${WINE:?}/build-tools"; mkdir "$WINE/build-tools"
    ( cd "$WINE/build-tools" &&
      ../configure --enable-win64 --without-x --without-freetype --without-mingw --disable-tests \
          > "$OUT/config-build-tools.log" 2>&1 ) && echo "$KEY" > "$WINE/build-tools/.pp-configured"
fi
( cd "$WINE/build-tools" &&
  make -j"$JOBS" __tooldeps__ > "$OUT/make-build-tools.log" 2>&1 &&
  make nls/locale.nls >> "$OUT/make-build-tools.log" 2>&1 )

# 3. Two darwin-host trees: build-macos supplies i386 + aarch64-windows
#    (new WoW64), build-arm64ec supplies arm64ec-windows.
#    PE code is compiled by llvm-mingw's clang in MSVC mode (--with-mingw=clang
#    path -> -target <cpu>-windows); host code by /usr/bin/clang for darwin.
#    CROSSLDFLAGS=-Wl,-Brepro makes lld-link write a content-hash timestamp
#    instead of the link time, and CROSSCFLAGS (configure's default -g -O2)
#    maps the tree and llvm-mingw out of the debug info, so the PE checksums
#    are reproducible and name no workstation path.
export PATH="$M/bin:$PATH"
# winegstreamer.dll is built only when configure finds GStreamer. Its PE side
# needs no GStreamer at all; the darwin winegstreamer.so the trees also build
# is not shipped (the app's is build/stages/gstreamer.sh), so the iOS release's
# headers are enough and its symbols are left for a lookup that never happens.
# The one header they lack for a macOS target, gst/gstmacos.h (gst.h includes
# it there), gets its two declarations from a stand-in (GST, above), written
# only when it differs so a kept tree does not rebuild winegstreamer.
mkdir -p "$OUT/gst-macos/gst"
cat > "$OUT/gst-macos/gst/gstmacos.h.new" <<'EOF'
/* stages/wine-pe.sh: the iOS release's headers lack this macOS-only file */
#ifndef __GST_MACOS_H__
#define __GST_MACOS_H__
#include <gst/gstconfig.h>
G_BEGIN_DECLS
typedef int (*GstMainFunc) (int argc, char **argv);
typedef int (*GstMainFuncSimple) (gpointer user_data);
GST_API int gst_macos_main (GstMainFunc main_func, int argc, char *argv[], gpointer user_data);
GST_API int gst_macos_main_simple (GstMainFuncSimple main_func, gpointer user_data);
G_END_DECLS
#endif
EOF
if cmp -s "$OUT/gst-macos/gst/gstmacos.h.new" "$OUT/gst-macos/gst/gstmacos.h"; then
    rm "$OUT/gst-macos/gst/gstmacos.h.new"
else
    mv "$OUT/gst-macos/gst/gstmacos.h.new" "$OUT/gst-macos/gst/gstmacos.h"
fi
configure_tree() {
    # A kept tree's header dependencies are makedep's from when it was configured:
    # make depend rescans the sources, so a patch that adds or edits an included
    # header (wow64win's window_audited.h) rebuilds the objects that include it.
    if configured "$1"; then
        echo "$1: configured as before; make rebuilds what changed"
        ( cd "$WINE/$1" && make depend > "$OUT/depend-$1.log" 2>&1 )
        return
    fi
    rm -rf "${WINE:?}/${1:?}"; mkdir "$WINE/$1"
    ( cd "$WINE/$1" &&
      CC="/usr/bin/clang --target=aarch64-apple-darwin -isysroot $MACSDK" \
      CXX="/usr/bin/clang++ --target=aarch64-apple-darwin -isysroot $MACSDK" \
      OBJC="/usr/bin/clang -x objective-c --target=aarch64-apple-darwin -isysroot $MACSDK" \
      AR=/usr/bin/llvm-ar RANLIB=/usr/bin/llvm-ranlib STRIP=/usr/bin/llvm-strip \
      LDFLAGS="-fuse-ld=lld" CROSSLDFLAGS="-Wl,-Brepro" \
      GSTREAMER_CFLAGS="-I$OUT/gst-macos -I$GST/Headers" GSTREAMER_LIBS="-Wl,-undefined,dynamic_lookup" \
      CROSSCFLAGS="-g -O2 -ffile-prefix-map=$WINE=wine -ffile-prefix-map=$M=llvm-mingw" \
      ../configure --host=aarch64-apple-darwin --without-x --without-freetype \
          --with-wine-tools="$WINE/build-tools" \
          --with-mingw="$M/bin/clang" --enable-archs="$2" \
          > "$OUT/config-$1.log" 2>&1 ) && echo "$KEY" > "$WINE/$1/.pp-configured"
}
configure_tree build-macos i386,aarch64
configure_tree build-arm64ec arm64ec
# widl maps ARM64EC to the aarch64-windows dir when importing typelibs
# (tools.h get_arch_dir); a pure arm64ec tree has none, so point it at ours.
ln -sfn arm64ec-windows "$WINE/build-arm64ec/dlls/stdole2.tlb/aarch64-windows"

# 4. Full make of both trees (PE sets + darwin host side).
set +e
( cd "$WINE/build-macos" && make -k -j"$JOBS" > "$OUT/make-build-macos.log" 2>&1 ); rc_mac=$?
( cd "$WINE/build-arm64ec" && make -k -j"$JOBS" > "$OUT/make-build-arm64ec.log" 2>&1 ); rc_ec=$?
echo "make build-macos exit=$rc_mac; make build-arm64ec exit=$rc_ec"
grep -h '\*\*\*' "$OUT/make-build-macos.log" "$OUT/make-build-arm64ec.log" || true
set -e
# New WoW64 must not silently ship a partial set. Only the four documented
# ARM64EC test-driver failures are allowed; every other make failure stops PE.
[ "$rc_mac" = 0 ] || { echo "build-macos failed (see make-build-macos.log)"; exit 1; }
if [ "$rc_ec" != 0 ]; then
    errors=$(grep '\*\*\*' "$OUT/make-build-arm64ec.log" || true)
    unexpected=$(printf '%s\n' "$errors" | grep -vE '^make(\[[0-9]+\])?: \*\*\* \[.*dlls/ntoskrnl.exe/tests/arm64ec-windows/driver(2|3|_netio)?\.dll\] Error [0-9]+$' || true)
    [ -n "$errors" ] && [ -z "$unexpected" ] ||
        { echo "unexpected ARM64EC make failure: $unexpected"; exit 1; }
fi

# 5. Manifests + machine check.
python3 "$HERE/wine-pe-manifest.py" "$WINE/build-macos" i386-windows "$M/bin/llvm-readobj" > "$OUT/manifest-i386.tsv"; echo "i386 machine check exit=$?"
python3 "$HERE/wine-pe-manifest.py" "$WINE/build-macos" aarch64-windows "$M/bin/llvm-readobj" > "$OUT/manifest-aarch64.tsv"; echo "aarch64 machine check exit=$?"
python3 "$HERE/wine-pe-manifest.py" "$WINE/build-arm64ec" arm64ec-windows "$M/bin/llvm-readobj" > "$OUT/manifest-arm64ec.tsv"; echo "arm64ec machine check exit=$?"
sha256sum "$WINE/build-macos/include/config.h"

# 6. Darwin host-side outputs of the full cross build (macOS-targeted Mach-O).
for t in build-macos build-arm64ec; do
    ( cd "$WINE/$t" && for f in $(find dlls -name '*.so' -type f | sort) loader/wine server/wineserver; do
          printf '%s\t%s\t%s\t%s\n' "$f" "$(stat -c %s "$f")" "$(sha256sum "$f" | cut -d' ' -f1)" "$(file -b "$f" | cut -d, -f1)"
      done ) > "$OUT/manifest-darwin-$t.tsv"
    echo "$t darwin outputs: $(wc -l < "$OUT/manifest-darwin-$t.tsv")"
done
