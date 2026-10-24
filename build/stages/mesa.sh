#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# KosmicKrisp, Mesa's Vulkan driver on Metal 4, built for iOS (decision 0014),
# and from the same tree Mesa's EGL, OpenGL frontend and Zink over KosmicKrisp
# (PLA-162, docs/plans/2026-10-11-opengl-zink.md). The tree is Mesa at the
# mesa pin with patches/mesa on it.
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
#        every MSL library checked for untranslated intrinsics; then Zink and
#        EGL on the same mock (zink-host-test.c: GL context, fixed-function
#        and GLSL 1.20 draws, a blit). No GPU runs.
# ios    libvulkan_kosmickrisp.dylib for arm64-apple-ios26.0 (Metal 4 needs iOS 26),
#        against the darwin SDK's iPhoneOS26.5.sdk, with those tools; and in a
#        second build directory (ROOT/ios-gl) libEGL and libgallium_dri (Zink
#        only, the OpenGL frontend, no GLES/GLX/GBM), renamed MesaEGL and
#        MesaGallium with their framework install names
# check  build/check-macho-imports.py: each dylib is an iOS arm64 Mach-O whose
#        every non-weak import is exported for iOS by a library it links
#        (MesaEGL's from MesaGallium by --with). The libraries link with
#        -undefined dynamic_lookup, so without this check a missing symbol
#        shows only when dyld loads them on the phone.
#
# framework  the dylibs as app/Staged/KosmicKrisp.xcframework, MesaEGL.xcframework
#        and MesaGallium.xcframework (ios-arm64), which the app links and embeds
#        (app/Package.swift). win32u dlopens KosmicKrisp by its install name,
#        @rpath/KosmicKrisp.framework/KosmicKrisp (patches/madeira-unix), and so
#        does Zink; MesaEGL is win32u's EGL (SONAME_LIBEGL) and links MesaGallium.
#
# Output: ROOT/out/{libvulkan_kosmickrisp.dylib,MesaEGL,MesaGallium} and the
# three xcframeworks in app/Staged/.
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
# The OpenGL build for iOS: Zink as the one Gallium driver, desktop OpenGL
# through EGL (surfaceless, with Metal window surfaces: patches/mesa), no
# Vulkan driver (Zink loads KosmicKrisp's framework), no video codecs. Zink
# finds KosmicKrisp through @rpath without the Vulkan-loader rpath.
MESON_GL=(
    -Dvulkan-drivers= -Dgallium-drivers=zink -Dopengl=true -Degl=enabled
    -Dgles1=disabled -Dgles2=disabled -Dglx=disabled -Dgbm=disabled -Dglvnd=disabled
    -Dzstd=disabled -Dllvm=disabled -Dexpat=disabled -Dvideo-codecs=
    -Dvulkan-loader-rpath= -Dunversion-libgallium=true
    -Dplatforms=macos -Dbuildtype=release -Dwrap_mode=nofallback
)
# The OpenGL frameworks: MesaEGL (libEGL) links MesaGallium (libgallium_dri).
EGL_ID=@rpath/MesaEGL.framework/MesaEGL
GALLIUM_ID=@rpath/MesaGallium.framework/MesaGallium

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
    # C++ takes the SDK's libc++ headers, not the host's (stages/dxmt-base.sh, PLA-5).
    local cxx="'-stdlib++-isystem', '$IOSSDK/usr/include/c++/v1'"
    local linker=lld
    [ "$(uname -s)" != Darwin ] || linker=$LD64
    local ld="'--target=$TARGET', '-isysroot', '$IOSSDK', '-fuse-ld=$linker'"
    cat > "$ROOT/ios.cross" <<EOF
[binaries]
c = ['clang', $cc]
cpp = ['clang++', $cc, $cxx]
objc = ['clang', $cc]
c_ld = '$linker'
cpp_ld = '$linker'
objc_ld = '$linker'
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

    [ -f "$ROOT/ios-gl/build.ninja" ] ||
        meson setup "$ROOT/ios-gl" "$ROOT/mesa" --cross-file "$ROOT/ios.cross" "${MESON_GL[@]}"
    ninja -C "$ROOT/ios-gl" -j "$JOBS" src/egl/libEGL.1.dylib src/gallium/targets/dri/libgallium_dri.dylib
    cp "$ROOT/ios-gl/src/egl/libEGL.1.dylib" "$ROOT/out/MesaEGL"
    cp "$ROOT/ios-gl/src/gallium/targets/dri/libgallium_dri.dylib" "$ROOT/out/MesaGallium"
    llvm-install-name-tool -id "$EGL_ID" -change @rpath/libgallium_dri.dylib "$GALLIUM_ID" "$ROOT/out/MesaEGL"
    llvm-install-name-tool -id "$GALLIUM_ID" "$ROOT/out/MesaGallium"
}

stage_check() {
    local check=(python3 "$HERE/../check-macho-imports.py" --sdk "$IOSSDK" --platform ios --minos 26.0)
    "${check[@]}" \
        --exports vk_icdGetInstanceProcAddr,vk_icdNegotiateLoaderICDInterfaceVersion,vk_icdGetPhysicalDeviceProcAddr \
        "$ROOT/out/libvulkan_kosmickrisp.dylib"
    "${check[@]}" "$ROOT/out/MesaGallium"
    # What win32u's EGL backend needs (dlls/win32u/opengl.c egl_init).
    "${check[@]}" --with "$ROOT/out/MesaGallium" \
        --exports eglGetProcAddress,eglGetPlatformDisplay,eglInitialize,eglCreateContext,eglCreateWindowSurface,eglSwapBuffers \
        "$ROOT/out/MesaEGL"
}

# stage_xcframework NAME BINARY BUNDLE-ID WHAT: BINARY as app/Staged/NAME.xcframework
# (ios-arm64), with the install name @rpath/NAME.framework/NAME.
stage_xcframework() {
    local name=$1 binary=$2 bundle_id=$3 what=$4
    local xc=$PLAYPORT_REPO/app/Staged/$name.xcframework
    local fw=$xc/ios-arm64/$name.framework
    rm -rf "$xc"
    mkdir -p "$fw/Headers" "$fw/Modules"
    cp "$binary" "$fw/$name"
    llvm-install-name-tool -id "@rpath/$name.framework/$name" "$fw/$name"
    # SwiftPM wants a module for a binary target; nothing imports it.
    printf '/* %s, not imported. */\n' "$what" > "$fw/Headers/$name.h"
    printf 'framework module %s {\n  umbrella header "%s.h"\n  export *\n}\n' "$name" "$name" \
        > "$fw/Modules/module.modulemap"
    # Without an Info.plist xtool's signer leaves the framework unsigned
    # (build/stages/stikjit.sh), and dyld refuses it.
    cat > "$fw/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>$name</string>
	<key>CFBundleIdentifier</key><string>$bundle_id</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>$name</string>
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
			<key>BinaryPath</key><string>$name.framework/$name</string>
			<key>LibraryIdentifier</key><string>ios-arm64</string>
			<key>LibraryPath</key><string>$name.framework</string>
			<key>SupportedArchitectures</key><array><string>arm64</string></array>
			<key>SupportedPlatform</key><string>ios</string>
		</dict>
	</array>
	<key>CFBundlePackageType</key><string>XFWK</string>
	<key>XCFrameworkFormatVersion</key><string>1.0</string>
</dict>
</plist>
PLIST
    echo "staged $name ($(sha256sum "$fw/$name" | cut -c1-16), $(stat -c %s "$fw/$name") bytes) at app/Staged/$name.xcframework"
}

stage_framework() {
    stage_xcframework KosmicKrisp "$ROOT/out/libvulkan_kosmickrisp.dylib" org.freedesktop.mesa.kosmickrisp \
        "KosmicKrisp: loaded by win32u with dlopen"
    stage_xcframework MesaGallium "$ROOT/out/MesaGallium" org.freedesktop.mesa.gallium \
        "MesaGallium: Mesa's OpenGL frontend and Zink, linked by MesaEGL"
    stage_xcframework MesaEGL "$ROOT/out/MesaEGL" org.freedesktop.mesa.egl \
        "MesaEGL: Mesa's EGL, loaded by win32u with dlopen"
}

for s in $STAGES; do
    case $s in
    src|host|hosttest|ios|check|framework) echo "== mesa: $s"; "stage_$s" ;;
    *) echo "no stage $s (src host hosttest ios check framework)" >&2; exit 2 ;;
    esac
done
