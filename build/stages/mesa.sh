#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# KosmicKrisp, Mesa's Vulkan driver on Metal 4, built for iOS (decision 0014).
# The tree is Mesa at the mesa pin with patches/mesa on it.
#
#   build/stages/mesa.sh [ROOT] [stage...]   ROOT defaults to $PLAYPORT_BUILD/run/mesa;
#                                            stages: src host hosttest ios check framework
#                                            (default all)
#
# src    a shallow fetch of the mesa pin into ROOT/mesa (Mesa's full history is
#        not needed), then patches/mesa (build/lib.sh ensure_series)
# host   the Linux shader tools the iOS build runs: mesa_clc and vtn_bindgen2
#        (OpenCL C to SPIR-V, needs the host LLVM, libclc and
#        SPIRV-LLVM-Translator) and kk_clc (KosmicKrisp's internal shaders to MSL)
# hosttest  build/mesa-host-test/run.sh: the same tree built for Linux on a mock
#        Metal bridge, driven through the Vulkan API by kk-host-test.c (device,
#        geometry/tessellation/polygon-mode pipelines, recorded draws), with
#        every MSL library checked for untranslated intrinsics. No GPU runs.
# ios    libvulkan_kosmickrisp.dylib for arm64-apple-ios26.0 (Metal 4 needs iOS 26),
#        against the darwin SDK's iPhoneOS26.5.sdk, with those tools
# check  build/check-macho-imports.py: the dylib is an iOS arm64 Mach-O whose
#        every non-weak import is exported for iOS by a library it links. The
#        driver links with -undefined dynamic_lookup, so without this check a
#        missing symbol shows only when dyld loads it on the phone.
#
# framework  the dylib as app/Staged/KosmicKrisp.xcframework (ios-arm64), which
#        the app links and embeds (app/Package.swift) and win32u dlopens by its
#        install name, @rpath/KosmicKrisp.framework/KosmicKrisp (patches/madeira-unix)
#
# Output: ROOT/out/libvulkan_kosmickrisp.dylib and app/Staged/KosmicKrisp.xcframework.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../lib.sh"
ROOT=$(realpath -m "${1:-$PLAYPORT_BUILD/run/mesa}")
shift || true
STAGES=${*:-src host hosttest ios check framework}
PIN=$(pin mesa)
JOBS=${JOBS:-$(nproc)}
TARGET=arm64-apple-ios26.0
mkdir -p "$ROOT"

# The options both builds share: KosmicKrisp and nothing else.
MESON_COMMON=(
    -Dvulkan-drivers=kosmickrisp -Dgallium-drivers= -Dopengl=false
    -Dgles1=disabled -Dgles2=disabled -Dglx=disabled -Degl=disabled -Dgbm=disabled
    -Dzstd=disabled -Dbuildtype=release -Dwrap_mode=nofallback
)

stage_src() {
    local t=$ROOT/mesa
    if ! git -C "$t" cat-file -e "$PIN^{commit}" 2>/dev/null; then
        rm -rf "$t"
        git init -q "$t"
        git -C "$t" fetch -q --depth 1 "$(pin_url mesa)" "$PIN"
    fi
    ensure_series "$t" mesa "$PIN"
}

stage_host() {
    [ -f "$ROOT/host/build.ninja" ] ||
        meson setup "$ROOT/host" "$ROOT/mesa" "${MESON_COMMON[@]}" -Dplatforms= -Dllvm=enabled
    ninja -C "$ROOT/host" -j "$JOBS" \
        src/compiler/clc/mesa_clc src/compiler/spirv/vtn_bindgen2 src/kosmickrisp/clc/kk_clc
}

stage_hosttest() {
    "$HERE/../mesa-host-test/run.sh" "$ROOT/mesa" "$ROOT/host" "$ROOT/hosttest"
}

stage_ios() {
    test -d "$IOSSDK" || { echo "no iPhoneOS SDK at $IOSSDK (DARWIN_SDK, pp setup)" >&2; exit 1; }
    # The compile maps the tree and the SDK out of the debug info and __FILE__, so
    # the dylib names no workstation path (build/verify-ipa.py).
    local cc="'--target=$TARGET', '-isysroot', '$IOSSDK', '-ffile-prefix-map=$ROOT/=', '-ffile-prefix-map=$DARWIN_SDK=darwin-sdk'"
    local ld="'--target=$TARGET', '-isysroot', '$IOSSDK', '-fuse-ld=lld'"
    cat > "$ROOT/ios.cross" <<EOF
[binaries]
c = ['clang', $cc]
cpp = ['clang++', $cc]
objc = ['clang', $cc]
c_ld = 'lld'
cpp_ld = 'lld'
objc_ld = 'lld'
ar = 'llvm-ar'
strip = 'llvm-strip'
pkg-config = 'false'

[built-in options]
c_link_args = [$ld]
cpp_link_args = [$ld]
objc_link_args = [$ld]

[properties]
needs_exe_wrapper = true

[host_machine]
system = 'darwin'
subsystem = 'ios'
kernel = 'xnu'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
EOF
    cat > "$ROOT/host-tools.native" <<EOF
[binaries]
mesa_clc = '$ROOT/host/src/compiler/clc/mesa_clc'
vtn_bindgen2 = '$ROOT/host/src/compiler/spirv/vtn_bindgen2'
kk_clc = '$ROOT/host/src/kosmickrisp/clc/kk_clc'
EOF
    [ -f "$ROOT/ios/build.ninja" ] ||
        meson setup "$ROOT/ios" "$ROOT/mesa" --cross-file "$ROOT/ios.cross" \
            --native-file "$ROOT/host-tools.native" "${MESON_COMMON[@]}" \
            -Dplatforms=macos -Dllvm=disabled -Dexpat=disabled \
            -Dmesa-clc=system -Dprecomp-compiler=system
    ninja -C "$ROOT/ios" -j "$JOBS" src/kosmickrisp/vulkan/libvulkan_kosmickrisp.dylib
    mkdir -p "$ROOT/out"
    cp "$ROOT/ios/src/kosmickrisp/vulkan/libvulkan_kosmickrisp.dylib" "$ROOT/out/"
}

stage_check() {
    python3 "$HERE/../check-macho-imports.py" --sdk "$IOSSDK" --platform ios --minos 26.0 \
        --exports vk_icdGetInstanceProcAddr,vk_icdNegotiateLoaderICDInterfaceVersion,vk_icdGetPhysicalDeviceProcAddr \
        "$ROOT/out/libvulkan_kosmickrisp.dylib"
}

stage_framework() {
    local xc=$PLAYPORT_REPO/app/Staged/KosmicKrisp.xcframework
    local fw=$xc/ios-arm64/KosmicKrisp.framework
    rm -rf "$xc"
    mkdir -p "$fw/Headers" "$fw/Modules"
    cp "$ROOT/out/libvulkan_kosmickrisp.dylib" "$fw/KosmicKrisp"
    llvm-install-name-tool -id @rpath/KosmicKrisp.framework/KosmicKrisp "$fw/KosmicKrisp"
    # SwiftPM wants a module for a binary target; nothing imports it.
    printf '/* KosmicKrisp: loaded by win32u with dlopen, not imported. */\n' > "$fw/Headers/KosmicKrisp.h"
    printf 'framework module KosmicKrisp {\n  umbrella header "KosmicKrisp.h"\n  export *\n}\n' \
        > "$fw/Modules/module.modulemap"
    # Without an Info.plist xtool's signer leaves the framework unsigned
    # (build/stages/stikjit.sh), and dyld refuses it.
    cat > "$fw/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>KosmicKrisp</string>
	<key>CFBundleIdentifier</key><string>org.freedesktop.mesa.kosmickrisp</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>KosmicKrisp</string>
	<key>CFBundlePackageType</key><string>FMWK</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>${PIN:0:12}</string>
	<key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
	<key>MinimumOSVersion</key><string>26.0</string>
</dict>
</plist>
PLIST
    cat > "$xc/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AvailableLibraries</key>
	<array>
		<dict>
			<key>BinaryPath</key><string>KosmicKrisp.framework/KosmicKrisp</string>
			<key>LibraryIdentifier</key><string>ios-arm64</string>
			<key>LibraryPath</key><string>KosmicKrisp.framework</string>
			<key>SupportedArchitectures</key><array><string>arm64</string></array>
			<key>SupportedPlatform</key><string>ios</string>
		</dict>
	</array>
	<key>CFBundlePackageType</key><string>XFWK</string>
	<key>XCFrameworkFormatVersion</key><string>1.0</string>
</dict>
</plist>
PLIST
    echo "staged KosmicKrisp ($(sha256sum "$fw/KosmicKrisp" | cut -c1-16)) at app/Staged/KosmicKrisp.xcframework"
}

for s in $STAGES; do
    case $s in
    src|host|hosttest|ios|check|framework) echo "== mesa: $s"; "stage_$s" ;;
    *) echo "no stage $s (src host hosttest ios check framework)" >&2; exit 2 ;;
    esac
done
