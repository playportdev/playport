#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build the Madeira Wine unix-side layer (libntdll_unix.a, libwin32u_unix.a,
# the GnuTLS statics, libwineserver.a) on Linux by running Madeira's own
# build/*/build.sh scripts UNMODIFIED, with a shim directory that maps the
# Xcode tools they call (xcrun, ar, ranlib, nm, libtool, strip, lipo, sysctl)
# to host LLVM + the xtool slim SDK. docs/BUILDING.md, "The pipeline" (unix).
#
# usage: stages/unix.sh ROOT [stage...]
#   stages (default: all, in order): clones shims configure gnutls freetype
#                                    widl ntdll win32u report wineserver
# ROOT is a scratch directory; nothing outside it, the SDK bundle (read-only)
# and the wine mirror in $PLAYPORT_BUILD/cache is touched. The clones stage
# checks out the Madeira pin (from the upstream/madeira submodule, or GitHub
# when it is not initialised) with patches/madeira-unix, and the wine pin (a
# WineHQ commit, from the cache mirror) with patches/wine-port,
# patches/wine-valve and patches/wine-unix.
set -e

ROOT=${1:?usage: $0 ROOT [stage...]}
shift
STAGES=${*:-clones shims configure gnutls freetype widl ntdll win32u report wineserver}

. "$(dirname "$0")/../lib.sh"
MYTHIC_REV=$(pin madeira)
WINE_REV=$(pin wine)
FREETYPE_TAG=$(pin freetype)
SRC_MYTHIC=${SRC_MYTHIC:-$PLAYPORT_REPO/upstream/madeira}
SHIMS=$ROOT/shims
M=$ROOT/mythic
W=$ROOT/wine

test -d "$IOSSDK" && test -d "$MACSDK" || { echo "missing xtool SDKs under $DARWIN_SDK"; exit 1; }
mkdir -p "$ROOT"

clone_at() { # src-or-url dest rev "target..."
    test -e "$2/.git" || git clone -q --no-checkout "$1" "$2"
    # A moved pin is not in a clone made before the move.
    git -C "$2" cat-file -e "$3^{commit}" 2>/dev/null || git -C "$2" fetch -q --no-recurse-submodules "$1" "$3"
    ensure_series "$2" "$4" "$3"
}

stage_clones() {
    if test -e "$SRC_MYTHIC/.git"; then clone_at "$SRC_MYTHIC" "$M" $MYTHIC_REV madeira-unix
    else clone_at "$(pin_url madeira)" "$M" $MYTHIC_REV madeira-unix; fi
    clone_at "${SRC_WINE:-$(mirror wine "$WINE_REV")}" "$W" $WINE_REV "wine-port wine-valve wine-unix"
    # Madeira's scripts reach wine as $REPO_ROOT/wine (an uninitialised submodule).
    # A run tree copied from another checkout keeps that checkout's link, and
    # its unix side would then build from the other checkout's wine: relink it.
    if ! test -L "$M/wine"; then rmdir "$M/wine"; ln -s "$W" "$M/wine"
    elif [ "$(readlink "$M/wine")" != "$W" ]; then ln -sfn "$W" "$M/wine"; fi
    # wine-port's ntdll includes ../../../../build/madeira_cfg.h, i.e. it
    # expects to sit at <Madeira>/wine; resolve that from ROOT/wine as well.
    ln -sfn "$M/build" "$ROOT/build"
    # A moved freetype pin is not the tag of a clone made before the move.
    [ "$(git -C "$M/research/freetype" describe --tags --exact-match 2>/dev/null)" = "$FREETYPE_TAG" ] || {
        rm -rf "$M/research/freetype"
        git clone -q --depth 1 --branch $FREETYPE_TAG "$(pin_url freetype)" "$M/research/freetype"; }
    echo "mythic $(git -C "$M" rev-parse HEAD)"
    echo "wine   $(git -C "$W" rev-parse HEAD)"
    echo "freetype $(git -C "$M/research/freetype" rev-parse HEAD) ($FREETYPE_TAG)"
}

stage_shims() {
    mkdir -p "$SHIMS"
    # clang: an Apple-target compile (-arch/-miphoneos-version-min/-isysroot SDK)
    # gets --target=arm64-apple-ios and ld64.lld; anything else is the host
    # compiler (configure's CC_FOR_BUILD, which the scripts derive from `xcrun -f clang`).
    # The Apple-target compile maps ROOT and the SDK out of the debug info and
    # __FILE__, so the app binary names no workstation path (verify-ipa.py).
    cat > "$SHIMS/clang" <<EOF
#!/bin/sh
case " \$* " in
*" -arch arm64 "*|*" -miphoneos-version-min="*|*"iPhoneOS"*)
    exec /usr/bin/clang --target=arm64-apple-ios17.0 -fuse-ld=lld \\
        -Wno-unused-command-line-argument \\
        '-ffile-prefix-map=$ROOT=unix' '-ffile-prefix-map=$DARWIN_SDK=darwin-sdk' "\$@" ;;
esac
exec /usr/bin/clang "\$@"
EOF
    # clang++ also takes the SDK's libc++ headers, not the host's (build/lib.sh ios_cxx_stdlib).
    local cxxstd; cxxstd=$(ios_cxx_stdlib)
    sed "s|/usr/bin/clang |/usr/bin/clang++ |g; s|--target=arm64-apple-ios17.0 |&$cxxstd |" "$SHIMS/clang" > "$SHIMS/clang++"
    ln -sf clang "$SHIMS/cc"; ln -sf clang++ "$SHIMS/c++"   # CMake's default compiler names
    cat > "$SHIMS/xcrun" <<EOF
#!/bin/sh
# Subset of xcrun used by Madeira build/*/build.sh.
sdk=iphoneos
while [ \$# -gt 0 ]; do
    case "\$1" in
    -sdk|--sdk) sdk=\$2; shift 2 ;;
    --show-sdk-path) case \$sdk in iphoneos) echo "$IOSSDK" ;; *) echo / ;; esac; exit 0 ;;
    -f|--find) echo "$SHIMS/\$2"; exit 0 ;;
    *) tool=\$1; shift; exec "$SHIMS/\$tool" "\$@" ;;
    esac
done
EOF
    printf '#!/bin/sh\nexec /usr/bin/llvm-ar "$@"\n' > "$SHIMS/ar"
    printf '#!/bin/sh\nexec /usr/bin/llvm-ranlib "$@"\n' > "$SHIMS/ranlib"
    printf '#!/bin/sh\nexec /usr/bin/llvm-nm "$@"\n' > "$SHIMS/nm"
    printf '#!/bin/sh\nexec /usr/bin/llvm-strip "$@"\n' > "$SHIMS/strip"
    printf '#!/bin/sh\nexec /usr/bin/llvm-lipo "$@"\n' > "$SHIMS/lipo"
    printf '#!/bin/sh\nexec /usr/bin/llvm-libtool-darwin "$@"\n' > "$SHIMS/libtool"
    printf '#!/bin/sh\n[ "$*" = "-n hw.ncpu" ] && exec nproc\nexec /usr/bin/sysctl "$@"\n' > "$SHIMS/sysctl"
    chmod +x "$SHIMS"/*
}

# Every Madeira script runs with the shims first on PATH.
run() { env PATH="$SHIMS:$PATH" LC_ALL=C "$@"; }   # C collation: gen_gnutls_symtab.sh sorts

stage_configure() {
    # A darwin cross-configure of the wine tree: a host-native makedep, then
    # configure for aarch64-apple-darwin against the macOS SDK.
    local tools=$ROOT/wine-tools
    mkdir -p "$tools/tools/winebuild" "$ROOT/makedep-build"
    printf '#define __WINE_CONFIG_H 1\n#define HAVE_STDBOOL_H 1\n#define HAVE_STDINT_H 1\n#define HAVE_UNISTD_H 1\n#define SIZEOF_VOID_PTR 8\n#define SIZEOF_INT 4\n#define SIZEOF_UNSIGNED_LONG 8\n' > "$ROOT/makedep-build/config.h"
    ( cd "$W" && gcc -I"$ROOT/makedep-build" -Itools -Iinclude -D__WINESRC__ -DWINE_UNIX_LIB \
          tools/makedep.c -o "$tools/tools/makedep" )
    rm -rf "$W/build-macos"; mkdir "$W/build-macos"
    ( cd "$W/build-macos" &&
      CC="clang --target=aarch64-apple-darwin -isysroot $MACSDK" \
      CXX="clang++ --target=aarch64-apple-darwin -isysroot $MACSDK" \
      OBJC="clang -x objective-c --target=aarch64-apple-darwin -isysroot $MACSDK" \
      AR=llvm-ar RANLIB=llvm-ranlib STRIP=llvm-strip LDFLAGS="-fuse-ld=lld" \
      ../configure --host=aarch64-apple-darwin --without-x --without-freetype \
          --with-wine-tools="$tools" > "$ROOT/configure.log" 2>&1 )
    sha256sum "$W/build-macos/include/config.h"
}

stage_gnutls() {
    ( cd "$M/build/gnutls-ios/src" && sha256sum -c SHA256SUMS )
    run bash "$M/build/gnutls-ios/build.sh"
}

# The scripts expect widl-generated headers that only a full `make` of the
# darwin build tree (wine/build-macos/include: win32u-unix) or of the P2 PE build
# tree (wine/build-arm64ec/include: dwrite.h for ntdll-unix) would leave behind.
# Generate the whole set with a native widl from the same wine revision; the
# output is arch-independent. build-tools' own config.h is the Linux one and
# must not reach build-macos.
stage_widl() {
    mkdir -p "$W/build-tools" "$W/build-arm64ec/include"
    ( cd "$W/build-tools" &&
      ../configure --without-x --without-freetype --without-mingw --enable-win64 \
          > "$ROOT/tools-configure.log" 2>&1 &&
      make -j"$(nproc)" include/all > "$ROOT/widl.log" 2>&1 &&
      for h in $(cd include && ls *.h); do
          [ "$h" = config.h ] && continue
          cp "include/$h" "$W/build-macos/include/"
          cp "include/$h" "$W/build-arm64ec/include/"
      done )
    echo "$(ls "$W/build-arm64ec/include" | wc -l) generated headers"
}

stage_freetype() { run bash "$M/build/freetype-ios/build.sh" > "$ROOT/freetype.log" 2>&1; tail -1 "$ROOT/freetype.log"; }
stage_ntdll()    { run bash "$M/build/ntdll-unix/build.sh"; }
stage_win32u()   { run bash "$M/build/win32u-unix/build.sh"; }
stage_wineserver() { run bash "$M/build/wineserver/build.sh"; }

stage_report() {
    for f in "$M"/app/Madeira/lib{ntdll_unix,win32u_unix,wineserver}.a \
             "$M"/toolchains/gnutls-ios/lib/lib{gmp,nettle,hogweed,gnutls}.a \
             "$M"/build/freetype-ios/build/libfreetype.a; do
        test -f "$f" || { echo "absent  $f"; continue; }
        printf '%s %s %s\n' "$(stat -c %s "$f")" "$(sha256sum "$f" | cut -d' ' -f1)" "$f"
        # machine type = every member's Mach-O cputype + LC_BUILD_VERSION platform/minos
        llvm-objdump --macho --private-headers "$f" 2>/dev/null | awk '
            /MH_MAGIC/ {cpu=$2} /platform/ {plat=$2} /minos/ {n[cpu" "plat" "$2]++}
            END {for (k in n) print "    " n[k] " members: " k}'
    done
}

for s in $STAGES; do echo "=== stage $s"; "stage_$s"; done
