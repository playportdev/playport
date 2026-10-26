#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Xcode's build phase before linking the app (app/Xcode/project.yml). The
# linker searches BUILT_PRODUCTS_DIR before the package's Staged/lib, so what
# is put there replaces a staged archive of the same name.
#
#  - idevice's FFI (libidevice_ffi.a: the restart after a game, on-device
#    pairing) becomes IdeviceFFI.framework, and an empty libidevice_ffi.a stands
#    in for the archive. Its Rust keeps a private rust_eh_personality, as does
#    winegstreamer's: with Objective-C's and C++'s that is one personality
#    routine more than compact unwind encodes, which Xcode's linker refuses
#    (ld64 on the workstation falls back to DWARF unwind). A library of its own
#    is the linker's own remedy.
#  - The simulator (the UI only; no game runs there) links the device archives
#    rewritten for it (simulator-staged.py, in .work/simulator/lib) and a MetalFX
#    stand-in: the simulator has no MetalFX.
#
# The frameworks are embedded and signed after the build (project.yml).
set -euo pipefail

REPO=$(cd "$SRCROOT/../.." && pwd)
SIM=$REPO/.work/simulator
cc=(xcrun --sdk "$PLATFORM_NAME" clang -target "arm64-apple-ios${IPHONEOS_DEPLOYMENT_TARGET}${LLVM_TARGET_TRIPLE_SUFFIX:-}")

if [ "$PLATFORM_NAME" = iphonesimulator ]; then
    cp -f "$SIM"/lib/*.a "$BUILT_PRODUCTS_DIR/"
    idevice=$SIM/lib/libidevice_ffi.a
else
    idevice=$SRCROOT/../Staged/lib/libidevice_ffi.a
fi

# framework NAME SOURCES...: a dynamic framework from SOURCES in BUILT_PRODUCTS_DIR.
framework() {
    local name=$1 fw=$BUILT_PRODUCTS_DIR/$1.framework; shift
    mkdir -p "$fw"
    "${cc[@]}" -dynamiclib -install_name "@rpath/$name.framework/$name" -o "$fw/$name" "$@"
    rm -f "$fw/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $name" \
        -c "Add :CFBundleIdentifier string dev.playport.$name" \
        -c "Add :CFBundlePackageType string FMWK" \
        -c "Add :CFBundleShortVersionString string 1.0" -c "Add :CFBundleVersion string 1" \
        -c "Add :MinimumOSVersion string $IPHONEOS_DEPLOYMENT_TARGET" "$fw/Info.plist" >/dev/null
}

if [ ! -f "$BUILT_PRODUCTS_DIR/IdeviceFFI.framework/IdeviceFFI" ] || [ "$idevice" -nt "$BUILT_PRODUCTS_DIR/IdeviceFFI.framework/IdeviceFFI" ] ||
   [ "$0" -nt "$BUILT_PRODUCTS_DIR/IdeviceFFI.framework/IdeviceFFI" ]; then
    framework IdeviceFFI -Wl,-all_load "$idevice" -framework Security -framework CoreFoundation -lresolv
fi
# The package's -lidevice_ffi finds this empty archive first.
printf '!<arch>\n' > "$BUILT_PRODUCTS_DIR/libidevice_ffi.a"

if [ "$PLATFORM_NAME" = iphonesimulator ]; then
    src=$TARGET_TEMP_DIR/MetalFX-standin.m
    {
        echo '#import <Foundation/Foundation.h>'
        # The Objective-C classes DXMT's unix slice names that the simulator lacks, as
        # empty classes: MetalFX's, and Metal's shared texture handle.
        for c in MTLFXSpatialScalerDescriptor MTLFXTemporalScalerDescriptor MTLFXFrameInterpolatorDescriptor \
                 MTLFXTemporalDenoisedScalerDescriptor MTLSharedTextureHandle; do
            echo "@interface $c : NSObject @end @implementation $c @end"
        done
    } > "$src"
    framework MetalFX -fobjc-arc -framework Foundation "$src"
fi
