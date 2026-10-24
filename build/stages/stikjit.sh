#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds StikJIT from its pinned sources and patches/stikjit, against the
# patched idevice archive. Both the app and helper receive the security fixes;
# no upstream prebuilt framework/Rust library is linked. Source and license
# records remain in the cache for the notice assembly.
set -euo pipefail
. "$(dirname "$0")/../lib.sh"

COMMIT=32287268fa5824f9edce4cb359f5833ce0cf7b00
tag=$(pin stikjit)
cache=$PLAYPORT_BUILD/cache/stikjit-$tag
dest=$PLAYPORT_REPO/app/Staged/StikJIT.xcframework
IDEVICE_LICENSE_SHA256=131488ce7e302b9f62e3236793e57c86a208d3dfaf03e6d7d03ddc0fc82392ed
idevice=$(pin idevice)
idevice_src=$PLAYPORT_BUILD/cache/idevice-$idevice

# Every write to the cache goes to a private temporary beside its final path, then is
# moved into place: two builds (a pp sync candidate's and this checkout's) may share this cache and stage at once.
tmps=()
trap 'rm -rf "${tmps[@]}"' EXIT
mkdir -p "$cache"

if [ "$(git -C "$cache/src" rev-parse HEAD 2>/dev/null)" != "$COMMIT" ]; then
    src=$(mktemp -d "$cache/src.XXXXXX"); tmps+=("$src")
    git -c advice.detachedHead=false clone -q --depth 1 --branch "$tag" "$(pin_url stikjit)" "$src"
    [ "$(git -C "$src" rev-parse HEAD)" = "$COMMIT" ] || { echo "stage-stikjit: tag $tag is not $COMMIT" >&2; exit 1; }
    rm -rf "$cache/src"
    mv "$src" "$cache/src"
fi

if [ "$(git -C "$idevice_src" rev-parse HEAD 2>/dev/null)" != "$idevice" ]; then
    src=$(mktemp -d "$idevice_src.XXXXXX"); tmps+=("$src")
    git init -q "$src"
    git -C "$src" fetch -q --depth 1 "$(pin_url idevice)" "$idevice"
    git -c advice.detachedHead=false -C "$src" checkout -q FETCH_HEAD
    [ "$(git -C "$src" rev-parse HEAD)" = "$idevice" ] || { echo "stage-stikjit: idevice is not $idevice" >&2; exit 1; }
    rm -rf "$idevice_src"
    mv "$src" "$idevice_src"
fi
echo "$IDEVICE_LICENSE_SHA256  $idevice_src/LICENSE.txt" | sha256sum -c --status ||
    { echo "stage-stikjit: idevice LICENSE.txt is not sha256 $IDEVICE_LICENSE_SHA256" >&2; exit 1; }

# Build the pinned, patched Swift backend against the same patched idevice
# sources as the app. The upstream prebuilt carries its own unpatchable Rust copy.
run=${PLAYPORT_RUN:-$PLAYPORT_BUILD/run}
src=$run/stikjit-src
rsync -a --delete "$cache/src/" "$src/"
ensure_series "$src" stikjit "$COMMIT"
headers=$run/stikjit-headers
mkdir -p "$headers"
cp "$src/idevice/module.modulemap" "$headers/module.modulemap"
cp "$run/idevice/src/ffi/idevice.h" "$headers/idevice.h"
lib=$run/idevice/target/aarch64-apple-ios/release/libidevice_ffi.a
[ -f "$lib" ] || { echo "stage-stikjit: build idevice first" >&2; exit 1; }
linkdir=$run/stikjit-link
mkdir -p "$linkdir"
# A unique archive name prevents an accidental link of upstream's bundled .a.
ln -sfn "$lib" "$linkdir/libplayport_stikjit_idevice.a"
rm -rf "$dest"
fw=$dest/ios-arm64/StikJIT.framework
modules=$fw/Modules/StikJIT.swiftmodule
mkdir -p "$modules" "$PLAYPORT_BUILD/tmp" "$PLAYPORT_BUILD/cache/stikjit-swift"
export TMPDIR=$PLAYPORT_BUILD/tmp CLANG_MODULE_CACHE_PATH=$PLAYPORT_BUILD/cache/stikjit-swift
swiftc=$(command -v swiftc)
extra=()
if [ "$(uname -s)" = Darwin ]; then
    swiftc=$(xcrun --find swiftc)
    extra+=(-Xlinker -no_compact_unwind)
else
    # Match xtool's SwiftSDK swiftResourcesPath. A Linux compiler's default
    # resource directory contains Linux, not iPhoneOS, standard libraries.
    resources=$DARWIN_SDK/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift
    [ -d "$resources/iphoneos" ] || { echo "stage-stikjit: no iOS Swift resources in the Darwin SDK" >&2; exit 1; }
    extra+=(-resource-dir "$resources")
fi
"$swiftc" -swift-version 5 -O -parse-as-library -enable-library-evolution \
    -target arm64-apple-ios17.4 -sdk "$IOSSDK" -module-name StikJIT \
    -emit-library -emit-module -emit-module-path "$modules/arm64-apple-ios.swiftmodule" \
    -emit-module-interface-path "$modules/arm64-apple-ios.swiftinterface" \
    -file-prefix-map "$PLAYPORT_REPO=playport" -use-ld="$LD64" \
    -Xlinker -oso_prefix -Xlinker "$PLAYPORT_REPO/" \
    -I "$headers" -I "$src/iokit" -L "$linkdir" \
    -Xlinker -hidden-lplayport_stikjit_idevice -Xlinker -dead_strip \
    -Xlinker -install_name -Xlinker @rpath/StikJIT.framework/StikJIT \
    -framework JavaScriptCore -framework Network -framework Security \
    -framework CFNetwork -framework SystemConfiguration -framework IOKit \
    "${extra[@]}" "$src"/Sources/*.swift -o "$fw/StikJIT"
# IDE source-location metadata is not needed by clients or by the device.
rm -f "$modules"/*.swiftsourceinfo
cat > "$dest/Info.plist" <<'XCFRAMEWORK'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundlePackageType</key><string>XFWK</string>
<key>XCFrameworkFormatVersion</key><string>1.0</string>
<key>AvailableLibraries</key><array><dict>
<key>LibraryIdentifier</key><string>ios-arm64</string>
<key>LibraryPath</key><string>StikJIT.framework</string>
<key>SupportedArchitectures</key><array><string>arm64</string></array>
<key>SupportedPlatform</key><string>ios</string>
</dict></array></dict></plist>
XCFRAMEWORK

# The bundle identifier and versions are the ones StikJIT's project.yml gives the framework.
cat > "$fw/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>StikJIT</string>
	<key>CFBundleIdentifier</key><string>com.stik.StikJIT</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>StikJIT</string>
	<key>CFBundlePackageType</key><string>FMWK</string>
	<key>CFBundleShortVersionString</key><string>$tag</string>
	<key>CFBundleVersion</key><string>$tag</string>
	<key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
	<key>MinimumOSVersion</key><string>17.4</string>
</dict>
</plist>
PLIST

for f in "$fw"/Modules/StikJIT.swiftmodule/*.swiftinterface; do
    sed -i -E 's/\bStikJIT\.StikJIT\./StikJIT./g; s/\bStikJIT\.(DDIPaths|DeveloperDiskImageService|StikJITError)\b/\1/g' "$f"
done
# Swift 6.4 interfaces (StikJIT 1.7.0 and later) also spell names with module
# selectors (StikJIT::StikJIT.StikJIT::Configuration); those need no rewrite.
if grep -n -E '(^|[^:])\bStikJIT\.(StikJIT|DDIPaths|DeveloperDiskImageService|StikJITError)\b' "$fw"/Modules/StikJIT.swiftmodule/*.swiftinterface; then
    echo "stage-stikjit: module-qualified names left in the interface" >&2; exit 1
fi
echo "staged StikJIT $tag ($(sha256sum "$fw/StikJIT" | cut -c1-16) StikJIT) at app/Staged/StikJIT.xcframework"
