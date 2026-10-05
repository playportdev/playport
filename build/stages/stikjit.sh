#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Stages StikJIT's prebuilt framework (MPL-2.0, docs/LICENSING.md) for the
# app's JIT helper extension (app/Sources/PlayportJIT, docs/ARCHITECTURE.md,
# "Built-in JIT"): the release asset pins.lock names, checked against its
# sha256, unpacked to app/Staged/StikJIT.xcframework.
#
#   build/stages/stikjit.sh
#
# The zip is cached under $PLAYPORT_BUILD/cache/stikjit-<tag>/, beside a
# shallow checkout of the tag's source (src/, for build/notices-assemble.sh
# and as the MPL source record; the tag must be the commit below). The MIT
# notice of the idevice library inside the binary comes from a shallow
# checkout of the pins.lock idevice commit, cached under
# $PLAYPORT_BUILD/cache/idevice-<commit>/ (its revision is not recorded in the
# binary). The staged copy is changed only here; the binary is not touched:
#   - universal.js and legacy.js are deleted: they are resources, not code, and
#     the helper runs Playport's own script instead
#     (app/PlayportJIT/playport-universal.js, docs/LICENSING.md).
#   - Info.plist: the release framework has none, and xtool's signer (zsign)
#     then leaves the framework unsigned, which dyld refuses on the device.
#   - the swiftinterface: the module and its public enum are both `StikJIT`,
#     so `StikJIT.DDIPaths` resolves to a member of the enum and the host
#     Swift compiler cannot build the module from its interface. The rewrite
#     drops the module qualifier; every name resolves to the same declaration.
set -euo pipefail
. "$(dirname "$0")/../lib.sh"

SHA256=806664393770c68e75f2b6429955bfdd88cfaad09fec2ba70f8ed615ff90c060
COMMIT=32287268fa5824f9edce4cb359f5833ce0cf7b00
tag=$(pin stikjit)
url=$(pin_url stikjit); url=${url%.git}/releases/download/$tag/StikJIT.xcframework.zip
cache=$PLAYPORT_BUILD/cache/stikjit-$tag
zip=$cache/StikJIT.xcframework.zip
dest=$PLAYPORT_REPO/app/Staged/StikJIT.xcframework
IDEVICE_LICENSE_SHA256=131488ce7e302b9f62e3236793e57c86a208d3dfaf03e6d7d03ddc0fc82392ed
idevice=$(pin idevice)
idevice_src=$PLAYPORT_BUILD/cache/idevice-$idevice

# Every write to the cache goes to a private temporary beside its final path, then is
# moved into place: two builds (a pp sync candidate's and this checkout's) may share this cache and stage at once.
tmps=()
trap 'rm -rf "${tmps[@]}"' EXIT
mkdir -p "$cache"
if ! echo "$SHA256  $zip" | sha256sum -c --status 2>/dev/null; then
    part=$(mktemp "$cache/zip.XXXXXX"); tmps+=("$part")
    curl -fsSL -o "$part" "$url"
    echo "$SHA256  $part" | sha256sum -c --status || { echo "stage-stikjit: $url is not sha256 $SHA256" >&2; exit 1; }
    mv "$part" "$zip"
fi

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

rm -rf "$dest"
unpack=$(mktemp -d "$cache/unpack.XXXXXX"); tmps+=("$unpack")
mkdir -p "$(dirname "$dest")"
unzip -q "$zip" -d "$unpack"
mv "$unpack/StikJIT.xcframework" "$dest"
fw=$dest/ios-arm64/StikJIT.framework

rm -f "$fw/universal.js" "$fw/legacy.js"
if [ -n "$(find "$dest" -name universal.js -o -name legacy.js)" ]; then
    echo "stage-stikjit: StikJIT's universal.js or legacy.js is still staged" >&2; exit 1
fi

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
