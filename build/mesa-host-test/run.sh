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

# The same run with MESA_KK_BATCH2=1 (mesa 0091, 0092, 0094, 0095): the
# used-prefix root upload, Metal's own mapping for a vkMapMemory that is not
# placed, the residency commit only after a change, command allocators reset
# once without users, no default vertex amplification call and a pass's query
# writes in one dispatch, all six on and named in the log; then without map
# and residency.
MESA_KK_BATCH2=1 MESA_SHADER_CACHE_DISABLE=true \
    "$ROOT/kk-host-test" "$ROOT/build/src/kosmickrisp/vulkan/libvulkan_kosmickrisp.so" "$ROOT/spv" \
    >"$ROOT/batch2.log" 2>&1 || { cat "$ROOT/batch2.log" >&2; exit 1; }
grep -q '^\[kk-batch2\] items=0x3f ' "$ROOT/batch2.log" ||
    { echo "MESA_KK_BATCH2=1: no [kk-batch2] items=0x3f line" >&2; exit 1; }
MESA_KK_BATCH2=1 MESA_KK_BATCH2_SKIP=map,residency MESA_SHADER_CACHE_DISABLE=true \
    "$ROOT/kk-host-test" "$ROOT/build/src/kosmickrisp/vulkan/libvulkan_kosmickrisp.so" "$ROOT/spv" \
    >"$ROOT/batch2-skip.log" 2>&1 || { cat "$ROOT/batch2-skip.log" >&2; exit 1; }
grep -q '^\[kk-batch2\] items=0x39 ' "$ROOT/batch2-skip.log" ||
    { echo "MESA_KK_BATCH2_SKIP=map,residency: not items=0x39" >&2; exit 1; }
echo "MESA_KK_BATCH2: the host test passes with all items and without map and residency"

# VK_EXT_graphics_pipeline_library (PLA-424): exposed only with
# MESA_KK_EXPERIMENTAL=gpl (the runs above check it is not exposed without);
# with it, every pipeline above still builds and draws, with the same MSL,
# and DXVK-style libraries link fast and optimized and draw. Each vertex and
# fragment shader library is built on its own, and an empty fragment shader
# with the first vertex shader; fast links only build the Metal pipeline from
# them, but four, which fall back for VK_POLYGON_MODE_POINT, a logic op, a
# sample mask without every one of four samples and a vertex shader that
# writes a layer (the pipeline without rasterization above, with transform
# feedback, falls back too); a sample mask of 0x1 at one sample, as DXVK
# gives it, and a point list link fast, and two draws that differ only in
# their dynamic blend constants share one link (PLA-428). The mock refuses a pipeline whose
# vertex function writes a point size, as every vertex library's does, with
# the line or triangle topology class, as Metal does. A device of its own
# takes a vertex and a fragment shader library
# through a pipeline cache: from the cache their Metal libraries are built
# again from the same MSL, a fast link compiles nothing and a logic op link
# compiles the same whole pipeline as before, and when the device goes its
# link totals are logged and its counts of library shaders, Metal libraries
# and links (MESA_KK_DEBUG=memory) are back to zero.
rm -rf "$ROOT/msl-gpl"; mkdir -p "$ROOT/msl-gpl"
MESA_KK_EXPERIMENTAL=gpl MESA_KK_DEBUG=compile,memory KK_MOCK_MSL_DIR="$ROOT/msl-gpl" MESA_SHADER_CACHE_DISABLE=true \
    "$ROOT/kk-host-test" "$ROOT/build/src/kosmickrisp/vulkan/libvulkan_kosmickrisp.so" "$ROOT/spv" \
    >"$ROOT/gpl.log" 2>&1 || { cat "$ROOT/gpl.log" >&2; exit 1; }
grep -q '^ok gpl: libraries, fast and optimized links drawn' "$ROOT/gpl.log" ||
    { echo "MESA_KK_EXPERIMENTAL=gpl: the GPL cases did not run" >&2; exit 1; }
for f in "$ROOT/msl/"*.metal; do
    cmp -s "$f" "$ROOT/msl-gpl/${f##*/}" ||
        { echo "MESA_KK_EXPERIMENTAL=gpl: ${f##*/} is not the MSL made without it" >&2; exit 1; }
done
gpl_lines() { grep -c "^\[kk-compile\] $1" "$ROOT/gpl.log" || true; }
[ "$(gpl_lines 'gpl vertex built ')" = 5 ] && [ "$(gpl_lines 'gpl empty-fragment built ')" = 2 ] &&
    [ "$(gpl_lines 'gpl fragment built ')" = 7 ] && [ "$(gpl_lines 'gpl fragment \(full\|at-link\)=')" = 0 ] &&
    [ "$(gpl_lines 'gpl vertex deserialized ')" = 1 ] && [ "$(gpl_lines 'gpl fragment deserialized ')" = 1 ] &&
    [ "$(gpl_lines 'link separate ')" = 11 ] && [ "$(gpl_lines 'link separate-vertex ')" = 0 ] &&
    [ "$(gpl_lines 'link full fallback=point-fill count=1 ')" = 1 ] &&
    [ "$(gpl_lines 'link full fallback=logic-op count=1 ')" = 2 ] &&
    [ "$(gpl_lines 'link full fallback=sample-mask count=1 ')" = 1 ] &&
    [ "$(gpl_lines 'link full fallback=point-size-layer count=1 ')" = 1 ] &&
    [ "$(gpl_lines 'link full fallback=logic-op count=2 ')" = 1 ] &&
    [ "$(gpl_lines 'link FAIL ')" = 0 ] &&
    [ "$(gpl_lines 'link totals links=3 separate=1 separate-vertex=0 full=2 failed=0 fallbacks=logic-op:2$')" = 1 ] &&
    [ "$(grep -c '^\[kk-mem\] gpl device finish: live sources=0 shaders=1 libraries=1 links=0, after sources=0 shaders=0 libraries=0 links=0$' "$ROOT/gpl.log")" = 1 ] ||
    { grep '^\[kk-compile\] \(gpl\|link\)\|^\[kk-mem\] gpl' "$ROOT/gpl.log" >&2
      echo "MESA_KK_EXPERIMENTAL=gpl: not 4 + 1 vertex and 1 + 6 + 1 + 1 fragment libraries, 1 + 1 from the cache, 10 + 1 separate links (one for both blend constants), a point-fill, a sample-mask, a point-size-layer and 1 + 2 logic-op fallbacks, the second device's totals and counts back to zero" >&2; exit 1; }
grep '^\(ok \)\?gpl\|^\[kk-compile\] \(gpl\|link\)\|^\[kk-mem\] gpl' "$ROOT/gpl.log"

# Each of those 16 library builds is followed by its phases (PLA-437): NIR
# lowering, the rest of the NIR passes, nir_to_msl, the Metal library, and the
# builds in flight. With MESA_KK_DEBUG=serial_libraries too, one Metal library
# builds at a time, the vertex and fragment ones of a pipeline included
# (parallel_stages), and every pipeline still builds with the same MSL.
phases=$(grep -c '^\[kk-compile\] gpl-phases [a-z-]* \(built\|deserialized\) lower_ms=[0-9.]* nir_ms=[0-9.-]* msl_ms=[0-9.]* wait_ms=0\.0 library_ms=[0-9.]* libraries_inflight=1 pipelines_inflight=0 bytes=[0-9]* ' "$ROOT/gpl.log" || true)
[ "$phases" = 16 ] || { echo "MESA_KK_DEBUG=compile: $phases gpl-phases lines, not 16" >&2; exit 1; }
rm -rf "$ROOT/msl-serial"; mkdir -p "$ROOT/msl-serial"
MESA_KK_EXPERIMENTAL=gpl,parallel_stages MESA_KK_DEBUG=compile,serial_libraries KK_MOCK_MSL_DIR="$ROOT/msl-serial" \
    MESA_SHADER_CACHE_DISABLE=true \
    "$ROOT/kk-host-test" "$ROOT/build/src/kosmickrisp/vulkan/libvulkan_kosmickrisp.so" "$ROOT/spv" \
    >"$ROOT/serial.log" 2>&1 || { cat "$ROOT/serial.log" >&2; exit 1; }
for f in "$ROOT/msl/"*.metal; do
    cmp -s "$f" "$ROOT/msl-serial/${f##*/}" ||
        { echo "MESA_KK_DEBUG=serial_libraries: ${f##*/} is not the MSL made without it" >&2; exit 1; }
done
serial=$(grep -c '^\[kk-compile\] gpl-phases .* libraries_inflight=1 ' "$ROOT/serial.log" || true)
[ "$serial" = 16 ] || { echo "MESA_KK_DEBUG=serial_libraries: $serial of 16 gpl-phases lines with one library in flight" >&2; exit 1; }
echo "MESA_KK_DEBUG=compile,serial_libraries: 16 gpl-phases lines, the same MSL"

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

# MESA_KK_DUMP_MSL_MIN_KB (mesa 0061): builds over 8 KB of MSL leave their
# MSL and SPIR-V in kk-dump beside the shader cache directory, among them
# unroll-hint.frag's SPIR-V as it was given.
rm -rf "$ROOT/dump"; mkdir -p "$ROOT/dump/kosmickrisp"
MESA_SHADER_CACHE_DIR="$ROOT/dump/kosmickrisp" MESA_KK_DUMP_MSL_MIN_KB=8 MESA_SHADER_CACHE_DISABLE=true \
    "$ROOT/kk-host-test" "$ROOT/build/src/kosmickrisp/vulkan/libvulkan_kosmickrisp.so" "$ROOT/spv" \
    >"$ROOT/dump.log" 2>&1 || { cat "$ROOT/dump.log" >&2; exit 1; }
dumped=$(ls "$ROOT/dump/kk-dump" | grep -c '\.txt$' || true)
same=0
for f in "$ROOT/dump/kk-dump/"*.frag.spv; do
    cmp -s "$f" "$ROOT/spv/unroll-hint.frag.spv" && same=1
done
[ "$dumped" -gt 0 ] && [ "$same" = 1 ] ||
    { echo "MESA_KK_DUMP_MSL_MIN_KB: $dumped dumps, unroll-hint.frag's SPIR-V among them: $same" >&2; exit 1; }
echo "MESA_KK_DUMP_MSL_MIN_KB: $dumped pipelines dumped"

# The known-fail list (mesa 0062): the first build fails as interrupted in two
# launches, and the third launch skips it and fails that pipeline at once;
# MESA_KK_DEBUG=no_known_fail builds it.
rm -rf "$ROOT/known-fail"; mkdir -p "$ROOT/known-fail"
known_fail() {
    MESA_SHADER_CACHE_DIR="$ROOT/known-fail" MESA_SHADER_CACHE_DISABLE=true "$@" \
        "$ROOT/kk-host-test" "$ROOT/build/src/kosmickrisp/vulkan/libvulkan_kosmickrisp.so" "$ROOT/spv"
}
for n in 1 2; do
    if known_fail env KK_MOCK_INTERRUPT_BUILDS=1 MESA_KK_DEBUG=compile >"$ROOT/known-fail-$n.log" 2>&1; then
        echo "known-fail: launch $n built everything with an interrupted build" >&2; exit 1
    fi
done
msl=$(sed -n 's/^\[kk-compile\] render FAIL .*interrupted=1 .* msl=\([0-9a-f]*\)$/\1/p' "$ROOT/known-fail-1.log")
if known_fail env >"$ROOT/known-fail-3.log" 2>&1 ||
   ! grep -q "^\[kk-compile\] skip known-fail render msl=$msl " "$ROOT/known-fail-3.log"; then
    echo "known-fail: launch 3 did not skip msl=$msl" >&2; cat "$ROOT/known-fail-3.log" >&2; exit 1
fi
known_fail env MESA_KK_DEBUG=no_known_fail >"$ROOT/known-fail-4.log" 2>&1 ||
    { echo "known-fail: MESA_KK_DEBUG=no_known_fail did not build msl=$msl" >&2; exit 1; }
echo "known-fail list: msl=$msl skipped after 2 interrupted builds"

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
# No implicit layer from the workstation (MangoHud crashes at Zink's exit).
VK_LOADER_LAYERS_DISABLE='~implicit~' VK_DRIVER_FILES="$ROOT/kk-mock-icd.json" KK_MOCK_MSL_DIR="$ROOT/msl-zink" MESA_SHADER_CACHE_DISABLE=true \
    "$ROOT/zink-host-test"
echo "Zink MSL libraries: $(ls "$ROOT/msl-zink" | wc -l) in $ROOT/msl-zink"
