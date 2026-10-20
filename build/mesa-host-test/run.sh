#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build KosmicKrisp for Linux on the mock Metal bridge and drive it with
# kk-host-test.c: device creation, pipeline builds and draw recording for the
# pipelines it lists (geometry shaders, tessellation into a geometry shader,
# polygon modes). Then build Zink and EGL on the same mock driver and drive
# them with zink-host-test.c: an OpenGL compatibility context, fixed-function
# and GLSL 1.20 draws and a glBlitFramebuffer. The GPU work is not run; see
# make-mock-bridge.py for what the mock does and checks.
#
#   build/mesa-host-test/run.sh MESA_TREE HOST_TOOLS_BUILD [ROOT]
#
# MESA_TREE         a Mesa tree with patches/mesa applied (build/stages/mesa.sh src)
# HOST_TOOLS_BUILD  build/stages/mesa.sh's ROOT/host (mesa_clc, vtn_bindgen2, kk_clc)
# ROOT              scratch area, default $PLAYPORT_BUILD/run/mesa-host-test
#
# Exit status: 0 when every pipeline builds and draws, and Zink draws, with
# every MSL library fully translated.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../lib.sh"
TREE=$(realpath "${1:?usage: $0 MESA_TREE HOST_TOOLS_BUILD [ROOT]}")
TOOLS=$(realpath "${2:?usage: $0 MESA_TREE HOST_TOOLS_BUILD [ROOT]}")
ROOT=$(realpath -m "${3:-$PLAYPORT_BUILD/run/mesa-host-test}")
mkdir -p "$ROOT"

# A copy of the tree with the stubs replaced by the mock.
rsync -a --delete --exclude .git "$TREE/" "$ROOT/mesa/"
python3 "$HERE/make-mock-bridge.py" "$TREE" "$ROOT/mock"
cp "$ROOT/mock/"*.c "$ROOT/mesa/src/kosmickrisp/bridge/stubs/"
# The driver takes its cache UUID from the build ID and wants 16 bytes, as a
# Mach-O LC_UUID has; GNU ld's sha1 build ID is 20.
sed -i "s/--build-id=sha1/--build-id=md5/" "$ROOT/mesa/meson.build"
# Mapping memory is a mach_vm_remap of the buffer's contents on Apple systems
# and nothing elsewhere; on the mock, map the contents directly.
python3 - "$ROOT/mesa/src/kosmickrisp/vulkan/kk_bo.c" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "   *addr = (void *)dst_addr;\n#endif /* DETECT_OS_APPLE */\n"
assert s.count(old) == 1, "kk_bo_map_placed changed upstream"
s = s.replace(old, "   *addr = (void *)dst_addr;\n#else\n   if (!*addr)\n      *addr = bo->cpu;\n#endif /* DETECT_OS_APPLE */\n")
open(p, "w").write(s)
PY

cat > "$ROOT/host-tools.native" <<NATIVE
[binaries]
mesa_clc = '$TOOLS/src/compiler/clc/mesa_clc'
vtn_bindgen2 = '$TOOLS/src/compiler/spirv/vtn_bindgen2'
kk_clc = '$TOOLS/src/kosmickrisp/clc/kk_clc'
NATIVE
[ -f "$ROOT/build/build.ninja" ] ||
    meson setup "$ROOT/build" "$ROOT/mesa" --native-file "$ROOT/host-tools.native" \
        -Dvulkan-drivers=kosmickrisp -Dgallium-drivers= -Dplatforms= -Dopengl=false \
        -Dgles1=disabled -Dgles2=disabled -Dglx=disabled -Degl=disabled -Dgbm=disabled \
        -Dllvm=disabled -Dzstd=disabled -Dbuildtype=debug -Dwrap_mode=nofallback \
        -Dmesa-clc=system -Dprecomp-compiler=system >/dev/null
ninja -C "$ROOT/build" src/kosmickrisp/vulkan/libvulkan_kosmickrisp.so >/dev/null

mkdir -p "$ROOT/spv"
for s in "$HERE"/shaders/*; do
    case $s in
    # Hand-written SPIR-V, for what GLSL cannot say (an undefined image).
    *.spvasm) spirv-as --target-env vulkan1.3 -o "$ROOT/spv/$(basename "$s" .spvasm).spv" "$s" ;;
    *) glslangValidator -V --target-env vulkan1.3 -o "$ROOT/spv/$(basename "$s").spv" "$s" >/dev/null ;;
    esac
done
cc -O1 -g -Wall -o "$ROOT/kk-host-test" "$HERE/kk-host-test.c" -ldl

rm -rf "$ROOT/msl"; mkdir -p "$ROOT/msl"
KK_MOCK_MSL_DIR="$ROOT/msl" MESA_SHADER_CACHE_DISABLE=true \
    "$ROOT/kk-host-test" "$ROOT/build/src/kosmickrisp/vulkan/libvulkan_kosmickrisp.so" "$ROOT/spv"
echo "MSL libraries: $(ls "$ROOT/msl" | wc -l) in $ROOT/msl"

# The same pipelines with the vertex and fragment libraries built at once and
# the first two library builds failing as if Metal's compiler service had
# been interrupted (KK_MOCK_INTERRUPT_BUILDS): compile_retry builds them
# again, so everything still builds, and each retry is logged (mesa 0053).
KK_MOCK_INTERRUPT_BUILDS=2 MESA_KK_EXPERIMENTAL=compile_retry,parallel_stages \
    MESA_KK_DEBUG=compile MESA_SHADER_CACHE_DISABLE=true \
    "$ROOT/kk-host-test" "$ROOT/build/src/kosmickrisp/vulkan/libvulkan_kosmickrisp.so" "$ROOT/spv" \
    >"$ROOT/retry.log" 2>&1 || { cat "$ROOT/retry.log" >&2; exit 1; }
retries=$(grep -c '^\[kk-compile\] [a-z]* retry ' "$ROOT/retry.log" || true)
[ "$retries" = 2 ] || { echo "compile_retry: $retries retries logged, not 2" >&2; exit 1; }
echo "compile_retry and parallel_stages: 2 interrupted builds retried"

# Zink and EGL on the same mock driver: a second build of the tree. Zink loads
# the Vulkan loader (libvulkan.so.1), limited to the mock by VK_DRIVER_FILES.
[ -f "$ROOT/build-gl/build.ninja" ] ||
    meson setup "$ROOT/build-gl" "$ROOT/mesa" --native-file "$ROOT/host-tools.native" \
        -Dvulkan-drivers=kosmickrisp -Dgallium-drivers=zink -Dplatforms= -Dopengl=true \
        -Dgles1=disabled -Dgles2=disabled -Dglx=disabled -Degl=enabled -Dglvnd=disabled \
        -Dgbm=disabled -Dllvm=disabled -Dzstd=disabled -Dvideo-codecs= -Dbuildtype=debug \
        -Dwrap_mode=nofallback -Dmesa-clc=system -Dprecomp-compiler=system >/dev/null
ninja -C "$ROOT/build-gl" src/egl/libEGL.so.1.0.0 src/kosmickrisp/vulkan/libvulkan_kosmickrisp.so >/dev/null
cc -O1 -g -Wall -I"$ROOT/mesa/include" -o "$ROOT/zink-host-test" "$HERE/zink-host-test.c" \
    -L"$ROOT/build-gl/src/egl" -lEGL -Wl,-rpath,"$ROOT/build-gl/src/egl"
cat > "$ROOT/kk-mock-icd.json" <<ICD
{"file_format_version": "1.0.1",
 "ICD": {"library_path": "$ROOT/build-gl/src/kosmickrisp/vulkan/libvulkan_kosmickrisp.so", "api_version": "1.3.0"}}
ICD

rm -rf "$ROOT/msl-zink"; mkdir -p "$ROOT/msl-zink"
VK_DRIVER_FILES="$ROOT/kk-mock-icd.json" KK_MOCK_MSL_DIR="$ROOT/msl-zink" MESA_SHADER_CACHE_DISABLE=true \
    "$ROOT/zink-host-test"
echo "Zink MSL libraries: $(ls "$ROOT/msl-zink" | wc -l) in $ROOT/msl-zink"
