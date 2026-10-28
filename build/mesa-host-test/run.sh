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
#   build/mesa-host-test/run.sh MESA_TREE HOST_TOOLS_BUILD [ROOT] [--msl40-only]
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
MSL40_ONLY=false
case ${4:-} in
    "") ;;
    --msl40-only) MSL40_ONLY=true ;;
    *) echo "unknown option: $4" >&2; exit 2 ;;
esac

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
python3 "$HERE/run-cmd-pool-test.py" "$ROOT/build"
python3 "$HERE/run-nir-tests.py" "$ROOT/build"

mkdir -p "$ROOT/spv"
for s in "$HERE"/shaders/*; do
    case $s in
    # Hand-written SPIR-V, for what GLSL cannot say (an undefined image).
    *.spvasm) spirv-as --target-env vulkan1.3 -o "$ROOT/spv/$(basename "$s" .spvasm).spv" "$s" ;;
    *) glslangValidator -V --target-env vulkan1.3 -o "$ROOT/spv/$(basename "$s").spv" "$s" >/dev/null ;;
    esac
done
cc -O1 -g -Wall -pthread -o "$ROOT/kk-host-test" "$HERE/kk-host-test.c" -ldl

rm -rf "$ROOT/msl" "$ROOT/msl-versions"; mkdir -p "$ROOT/msl"
KK_MOCK_MSL_DIR="$ROOT/msl" KK_MOCK_MSL_VERSIONS="$ROOT/msl-versions" MESA_SHADER_CACHE_DISABLE=true \
    "$ROOT/kk-host-test" "$ROOT/build/src/kosmickrisp/vulkan/libvulkan_kosmickrisp.so" "$ROOT/spv"
echo "MSL libraries: $(ls "$ROOT/msl" | wc -l) in $ROOT/msl"

# MSL 4.0 (PLA-437): every library above is MSL 4.0 (0x40000); with
# MESA_KK_EXPERIMENTAL=msl41 the mock, iOS 27, gives 4.1 (0x40001) to every
# one, with the same MSL, and kk-host-test checks shaderSharedFloat32AtomicAdd
# is on only then.
if ! "$MSL40_ONLY"; then
rm -rf "$ROOT/msl-msl41" "$ROOT/msl41-versions"; mkdir -p "$ROOT/msl-msl41"
MESA_KK_EXPERIMENTAL=msl41 KK_MOCK_MSL_DIR="$ROOT/msl-msl41" KK_MOCK_MSL_VERSIONS="$ROOT/msl41-versions" \
    MESA_SHADER_CACHE_DISABLE=true \
    "$ROOT/kk-host-test" "$ROOT/build/src/kosmickrisp/vulkan/libvulkan_kosmickrisp.so" "$ROOT/spv" \
    >"$ROOT/msl41.log" 2>&1 || { cat "$ROOT/msl41.log" >&2; exit 1; }
[ "$(sort -u "$ROOT/msl-versions")" = 0x40000 ] && [ "$(sort -u "$ROOT/msl41-versions")" = 0x40001 ] &&
    [ "$(wc -l <"$ROOT/msl41-versions")" = "$(wc -l <"$ROOT/msl-versions")" ] ||
    { echo "MSL language versions $(sort -u "$ROOT/msl-versions" | tr '\n' ' ')by default, $(sort -u "$ROOT/msl41-versions" | tr '\n' ' ')with MESA_KK_EXPERIMENTAL=msl41" >&2; exit 1; }
diff -rq "$ROOT/msl" "$ROOT/msl-msl41" >/dev/null ||
    { echo "MESA_KK_EXPERIMENTAL=msl41: not the MSL made without it" >&2; exit 1; }
echo "MSL 4.0: $(wc -l <"$ROOT/msl-versions") libraries, as 4.1 with MESA_KK_EXPERIMENTAL=msl41 with the same MSL"

else
    [ "$(sort -u "$ROOT/msl-versions")" = 0x40000 ]
    echo "MSL 4.0 only: MSL 4.1 arm explicitly skipped"
fi

# Float maths and root table loads (PLA-72), each behind a switch:
# dxvk-fp.frag is a fragment shader as DXVK's dxbc-spirv gives KosmicKrisp,
# with SignedZeroInfNanPreserve and precise (NoContraction) operations, and
# kk-host-test logs how many multiplications its pipeline's MSL guards
# (workaround 14), how many math mode blocks it has and how many root table
# loads go through buf0.
fp_run() {
    local name=$1; shift
    rm -rf "$ROOT/msl-$name"; mkdir -p "$ROOT/msl-$name"
    env "$@" KK_MOCK_MSL_DIR="$ROOT/msl-$name" MESA_SHADER_CACHE_DISABLE=true \
        "$ROOT/kk-host-test" "$ROOT/build/src/kosmickrisp/vulkan/libvulkan_kosmickrisp.so" "$ROOT/spv" \
        >"$ROOT/$name.log" 2>&1 || { cat "$ROOT/$name.log" >&2; exit 1; }
    diff -rq "$ROOT/msl" "$ROOT/msl-$name" | grep -c . || true
}
# Lines of the MSL libraries in DIR but math mode blocks' braces and
# pragmas, file by file
fp_unblocked() { for f in "$1"/*.metal; do grep -v '^ *\({\|}\|#pragma METAL fp math_mode(.*)\)$' "$f" | md5sum; done; }
fp_line() { sed -n 's/^dxvk-fp: //p' "$ROOT/$1.log"; }
# Without a switch: the guards and blocks are there, and no root table load
# goes through buf0. kk-host-test checks float controls 2 and NaN and Inf
# preservation are reported.
[ "$(fp_run fp-default)" = 0 ] || { echo "PLA-72: the MSL of a second run is not the first's" >&2; exit 1; }
default_fp=$(fp_line fp-default)
case $default_fp in
"fmul_guards="[1-9]*" math_modes="[1-9]*" root_table_loads=0") ;;
*) echo "PLA-72: dxvk-fp without a switch: $default_fp" >&2; exit 1 ;;
esac
# no_fp_preserve: kk-host-test checks they are not reported; the MSL of the
# same SPIR-V is the same.
[ "$(fp_run fp-no-preserve MESA_KK_EXPERIMENTAL=no_fp_preserve)" = 0 ] ||
    { echo "MESA_KK_EXPERIMENTAL=no_fp_preserve: not the MSL made without it" >&2; exit 1; }
# fp_precise_only: dxvk-fp's MSL guards no multiplication and has fewer math
# mode blocks; every other library differs only in its blocks.
fp_run fp-precise-only MESA_KK_EXPERIMENTAL=fp_precise_only >/dev/null
precise_fp=$(fp_line fp-precise-only)
case $precise_fp in
"fmul_guards=0 math_modes="[1-9]*" root_table_loads=0") ;;
*) echo "MESA_KK_EXPERIMENTAL=fp_precise_only: dxvk-fp: $precise_fp" >&2; exit 1 ;;
esac
blocks() { echo "$1" | sed 's/.* math_modes=\([0-9]*\) .*/\1/'; }
[ "$(blocks "$precise_fp")" -lt "$(blocks "$default_fp")" ] ||
    { echo "MESA_KK_EXPERIMENTAL=fp_precise_only: $(blocks "$precise_fp") math mode blocks, not fewer than $(blocks "$default_fp")" >&2; exit 1; }
other=$(diff <(fp_unblocked "$ROOT/msl") <(fp_unblocked "$ROOT/msl-fp-precise-only") | grep -c '^>' || true)
[ "$other" = 1 ] ||
    { echo "MESA_KK_EXPERIMENTAL=fp_precise_only: $other libraries differ in more than math mode blocks, not dxvk-fp's alone" >&2; exit 1; }
# root_table_loads: root table and per-draw loads go through their buffer
# arguments, and only the libraries that have such loads change.
fp_run fp-root MESA_KK_EXPERIMENTAL=root_table_loads >/dev/null
root_pat='(constant uchar \*)&\(buf0\|per_draw\)\.contents\[0\] +'
root_loads=$(cat "$ROOT/msl-fp-root/"*.metal | grep -c "$root_pat" || true)
root_other=0
for f in "$ROOT/msl/"*.metal; do
    g=$ROOT/msl-fp-root/${f##*/}
    cmp -s "$f" "$g" || grep -q "$root_pat" "$g" || root_other=$((root_other + 1))
done
[ "$root_loads" -gt 0 ] && [ "$root_other" = 0 ] ||
    { echo "MESA_KK_EXPERIMENTAL=root_table_loads: $root_loads loads through buf0 or per_draw, $root_other other libraries changed" >&2; exit 1; }
# ubo_unbounded and const_offset_loads, on the GPL run's libraries with every
# buffer robust (MESA_KK_DEBUG=force_robustness), where gpl-ubo.frag's uniform
# buffer reads are bounds-checked: ubo_unbounded drops every check;
# const_offset_loads reads descriptor sets from the constant address space
# and changes nothing else.
ubo_run() {
    local name=$1; shift
    rm -rf "$ROOT/msl-$name"; mkdir -p "$ROOT/msl-$name"
    env "$@" MESA_KK_DEBUG=force_robustness KK_MOCK_MSL_DIR="$ROOT/msl-$name" MESA_SHADER_CACHE_DISABLE=true \
        "$ROOT/kk-host-test" "$ROOT/build/src/kosmickrisp/vulkan/libvulkan_kosmickrisp.so" "$ROOT/spv" \
        >"$ROOT/$name.log" 2>&1 || { cat "$ROOT/$name.log" >&2; exit 1; }
    cat "$ROOT/msl-$name/"*.metal | grep -c '< t[0-9]* ? \*(constant' || true
}
ubo_spaces() { for f in "$1"/*.metal; do sed 's/(device packed_/(constant packed_/g' "$f" | md5sum; done; }
bounded=$(ubo_run ubo-robust MESA_KK_EXPERIMENTAL=gpl)
# A named request without independent consent must preserve the actual MSL.
no_consent=$(ubo_run ubo-no-consent MESA_KK_EXPERIMENTAL=gpl,ubo_unbounded MESA_KK_UNSAFE=)
[ "$no_consent" = "$bounded" ] &&
    diff -rq "$ROOT/msl-ubo-robust" "$ROOT/msl-ubo-no-consent" >/dev/null ||
    { echo "ubo_unbounded without unsafe consent changed robust MSL" >&2; exit 1; }
unbounded=$(ubo_run ubo-unbounded MESA_KK_EXPERIMENTAL=gpl,ubo_unbounded MESA_KK_UNSAFE=ubo_unbounded)
const_bounded=$(ubo_run ubo-const MESA_KK_EXPERIMENTAL=gpl,const_offset_loads)
const_changed=$(diff -rq "$ROOT/msl-ubo-robust" "$ROOT/msl-ubo-const" | grep -c . || true)
[ "$bounded" -gt 0 ] && [ "$unbounded" = 0 ] && [ "$const_bounded" = "$bounded" ] && [ "$const_changed" -gt 0 ] &&
    [ "$(ubo_spaces "$ROOT/msl-ubo-robust")" = "$(ubo_spaces "$ROOT/msl-ubo-const")" ] ||
    { echo "PLA-72: $bounded bounds-checked uniform buffer reads, $unbounded with ubo_unbounded, $const_bounded with const_offset_loads, which changed $const_changed libraries (only to the constant address space?)" >&2; exit 1; }
echo "PLA-72: dxvk-fp $default_fp by default, $precise_fp with fp_precise_only; no_fp_preserve keeps the MSL; root_table_loads: $root_loads loads through buf0 or per_draw; ubo_unbounded: $bounded bounds-checked uniform buffer reads to 0; const_offset_loads: $const_changed libraries read descriptor sets from constant space"
# ubo_vec4_bounds, on the same robust run: the bounds-checked scalar reads of
# one 16-byte chunk become one checked vector read (gpl-ubo.frag's tint), and
# only libraries with bounds-checked reads change.
vec_scalar=$(ubo_run ubo-vec4 MESA_KK_EXPERIMENTAL=gpl,ubo_vec4_bounds)
vec_pat='< t[0-9]* ? [a-z]*[234](\*(constant packed_'
vec_loads=$(cat "$ROOT/msl-ubo-vec4/"*.metal | grep -c "$vec_pat" || true)
vec_other=0
for f in "$ROOT/msl-ubo-robust/"*.metal; do
    g=$ROOT/msl-ubo-vec4/${f##*/}
    cmp -s "$f" "$g" || grep -q '< t[0-9]* ? \*(constant' "$f" || vec_other=$((vec_other + 1))
done
[ "$vec_loads" -gt 0 ] && [ "$vec_scalar" -lt "$bounded" ] && [ "$vec_other" = 0 ] ||
    { echo "MESA_KK_EXPERIMENTAL=ubo_vec4_bounds: $bounded checked scalar reads to $vec_scalar, $vec_loads checked vector reads, $vec_other libraries without checked reads changed" >&2; exit 1; }
echo "PLA-72: ubo_vec4_bounds: $bounded checked scalar uniform buffer reads to $vec_scalar and $vec_loads checked vector reads"


# The same run with MESA_KK_EXPERIMENTAL=narrow_barriers,ds_dont_care (mesa
# 0114, 0115; check_pass_rules checks the barriers and stores they encode):
# every pipeline still builds and draws, with the same MSL.
rm -rf "$ROOT/msl-pass-rules"; mkdir -p "$ROOT/msl-pass-rules"
MESA_KK_EXPERIMENTAL=narrow_barriers,ds_dont_care KK_MOCK_MSL_DIR="$ROOT/msl-pass-rules" \
    MESA_SHADER_CACHE_DISABLE=true \
    "$ROOT/kk-host-test" "$ROOT/build/src/kosmickrisp/vulkan/libvulkan_kosmickrisp.so" "$ROOT/spv" \
    >"$ROOT/pass-rules.log" 2>&1 || { cat "$ROOT/pass-rules.log" >&2; exit 1; }
diff -rq "$ROOT/msl" "$ROOT/msl-pass-rules" >/dev/null ||
    { echo "MESA_KK_EXPERIMENTAL=narrow_barriers,ds_dont_care: not the MSL made without them" >&2; exit 1; }
echo "MESA_KK_EXPERIMENTAL=narrow_barriers,ds_dont_care: every pipeline builds and draws, the same MSL"

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
# A fragment library that only queries float textures' size, levels and
# samples names them texture2d<float> and texture2d_ms<float>, no int type
# (PLA-437).
grep -q '^ok gpl query-texture-type$' "$ROOT/gpl.log" ||
    { echo "MESA_KK_EXPERIMENTAL=gpl: the query-texture-type library did not run" >&2; exit 1; }
for f in "$ROOT/msl/"*.metal; do
    cmp -s "$f" "$ROOT/msl-gpl/${f##*/}" ||
        { echo "MESA_KK_EXPERIMENTAL=gpl: ${f##*/} is not the MSL made without it" >&2; exit 1; }
done
gpl_lines() { grep -c "^\[kk-compile\] $1" "$ROOT/gpl.log" || true; }
[ "$(gpl_lines 'gpl vertex built ')" = 5 ] && [ "$(gpl_lines 'gpl empty-fragment built ')" = 2 ] &&
    [ "$(gpl_lines 'gpl fragment built ')" = 8 ] && [ "$(gpl_lines 'gpl fragment \(full\|at-link\)=')" = 0 ] &&
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
      echo "MESA_KK_EXPERIMENTAL=gpl: not 4 + 1 vertex and 1 + 6 + 1 + 1 + 1 fragment libraries, 1 + 1 from the cache, 10 + 1 separate links (one for both blend constants), a point-fill, a sample-mask, a point-size-layer and 1 + 2 logic-op fallbacks, the second device's totals and counts back to zero" >&2; exit 1; }
grep '^\(ok \)\?gpl\|^\[kk-compile\] \(gpl\|link\)\|^\[kk-mem\] gpl' "$ROOT/gpl.log"

# MESA_KK_DEBUG=vertex_stats (PLA-72), on the GPL run, whose second device
# draws and goes: its final [kk-vertex] line counts the draws, their
# vertices, primitives and vertex output slots, with the same MSL; no line
# without the flag.
rm -rf "$ROOT/msl-vertex-stats"; mkdir -p "$ROOT/msl-vertex-stats"
MESA_KK_EXPERIMENTAL=gpl MESA_KK_DEBUG=vertex_stats KK_MOCK_MSL_DIR="$ROOT/msl-vertex-stats" \
    MESA_SHADER_CACHE_DISABLE=true \
    "$ROOT/kk-host-test" "$ROOT/build/src/kosmickrisp/vulkan/libvulkan_kosmickrisp.so" "$ROOT/spv" \
    >"$ROOT/vertex-stats.log" 2>&1 || { cat "$ROOT/vertex-stats.log" >&2; exit 1; }
diff -rq "$ROOT/msl-gpl" "$ROOT/msl-vertex-stats" >/dev/null ||
    { echo "MESA_KK_DEBUG=vertex_stats: not the MSL made without it" >&2; exit 1; }
vertex_line=$(grep -m1 '^\[kk-vertex\] .* final: .* draws=[1-9]' "$ROOT/vertex-stats.log" || true)
case $vertex_line in
*" draws="[1-9]*" vertices="[1-9]*" prims="[1-9]*" out-slots="[1-9]*" | per frame:"*" | out-slots/vertex="[1-9]*) ;;
*) echo "MESA_KK_DEBUG=vertex_stats: no final [kk-vertex] line with draws, vertices, primitives and output slots: $vertex_line" >&2; exit 1 ;;
esac
! grep -q '^\[kk-vertex\]' "$ROOT/gpl.log" ||
    { echo "PLA-72: a [kk-vertex] line without MESA_KK_DEBUG=vertex_stats" >&2; exit 1; }
echo "MESA_KK_DEBUG=vertex_stats: ${vertex_line%% | per frame:*}"

# Each of those 17 library builds is followed by its phases (PLA-437): NIR
# lowering, the rest of the NIR passes, nir_to_msl, the Metal library, and the
# builds in flight. With MESA_KK_DEBUG=serial_libraries too, one Metal library
# builds at a time, the vertex and fragment ones of a pipeline included
# (parallel_stages), and every pipeline still builds with the same MSL.
phases=$(grep -c '^\[kk-compile\] gpl-phases [a-z-]* \(built\|deserialized\) lower_ms=[0-9.]* nir_ms=[0-9.-]* msl_ms=[0-9.]* wait_ms=0\.0 library_ms=[0-9.]* libraries_inflight=1 pipelines_inflight=0 bytes=[0-9]* ' "$ROOT/gpl.log" || true)
[ "$phases" = 17 ] || { echo "MESA_KK_DEBUG=compile: $phases gpl-phases lines, not 17" >&2; exit 1; }
rm -rf "$ROOT/msl-serial"; mkdir -p "$ROOT/msl-serial"
MESA_KK_EXPERIMENTAL=gpl,parallel_stages MESA_KK_DEBUG=compile,serial_libraries KK_MOCK_MSL_DIR="$ROOT/msl-serial" \
    MESA_SHADER_CACHE_DISABLE=true \
    "$ROOT/kk-host-test" "$ROOT/build/src/kosmickrisp/vulkan/libvulkan_kosmickrisp.so" "$ROOT/spv" \
    >"$ROOT/serial.log" 2>&1 || { cat "$ROOT/serial.log" >&2; exit 1; }
# parallel_stages builds a pipeline's two libraries on two threads, which take
# the serial lock in either order: the same MSL, in any order.
msl_sums() { for f in "$ROOT/msl/"*.metal; do md5sum <"$1/${f##*/}"; done | sort; }
[ "$(msl_sums "$ROOT/msl")" = "$(msl_sums "$ROOT/msl-serial")" ] ||
    { echo "MESA_KK_DEBUG=serial_libraries: not the MSL made without it" >&2; exit 1; }
serial=$(grep -c '^\[kk-compile\] gpl-phases .* libraries_inflight=1 ' "$ROOT/serial.log" || true)
[ "$serial" = 17 ] || { echo "MESA_KK_DEBUG=serial_libraries: $serial of 17 gpl-phases lines with one library in flight" >&2; exit 1; }
echo "MESA_KK_DEBUG=compile,serial_libraries: 17 gpl-phases lines, the same MSL"
# VK_EXT_memory_priority and VK_EXT_pageable_device_local_memory (PLA-431):
# exposed, with their features, only with MESA_KK_EXPERIMENTAL=memory_priority
# (the runs above check they are not exposed, and that the device has no
# vkSetDeviceMemoryPriorityEXT, without it). With it, an allocation with a
# priority and two vkSetDeviceMemoryPriorityEXT calls are accepted and counted
# in the [kk-mem] line (the forked checks' lines count none), and every
# pipeline builds the same MSL: a priority changes nothing.
rm -rf "$ROOT/msl-memory-priority"; mkdir -p "$ROOT/msl-memory-priority"
MESA_KK_EXPERIMENTAL=memory_priority MESA_KK_DEBUG=memory KK_MOCK_MSL_DIR="$ROOT/msl-memory-priority" \
    MESA_SHADER_CACHE_DISABLE=true \
    "$ROOT/kk-host-test" "$ROOT/build/src/kosmickrisp/vulkan/libvulkan_kosmickrisp.so" "$ROOT/spv" \
    >"$ROOT/memory-priority.log" 2>&1 || { cat "$ROOT/memory-priority.log" >&2; exit 1; }
grep -q '^ok memory_priority: ' "$ROOT/memory-priority.log" ||
    { echo "MESA_KK_EXPERIMENTAL=memory_priority: the memory priority case did not run" >&2; exit 1; }
grep -q '^\[kk-mem\] .* | priority allocations=1 sets=2$' "$ROOT/memory-priority.log" ||
    { grep '^\[kk-mem\] ' "$ROOT/memory-priority.log" >&2
      echo "MESA_KK_EXPERIMENTAL=memory_priority: no [kk-mem] line counts 1 allocation and 2 calls" >&2; exit 1; }
[ "$(ls "$ROOT/msl-memory-priority" | wc -l)" = "$(ls "$ROOT/msl" | wc -l)" ] ||
    { echo "MESA_KK_EXPERIMENTAL=memory_priority: not as many MSL libraries as without it" >&2; exit 1; }
for f in "$ROOT/msl/"*.metal; do
    cmp -s "$f" "$ROOT/msl-memory-priority/${f##*/}" ||
        { echo "MESA_KK_EXPERIMENTAL=memory_priority: ${f##*/} is not the MSL made without it" >&2; exit 1; }
done
grep '^ok memory_priority: ' "$ROOT/memory-priority.log"
grep -m1 '^\[kk-mem\] .* | priority allocations=1 sets=2$' "$ROOT/memory-priority.log"
echo "MESA_KK_EXPERIMENTAL=memory_priority: $(ls "$ROOT/msl-memory-priority" | wc -l) MSL libraries, each the one made without it"

# VK_EXT_shader_module_identifier (PLA-431): exposed, with its feature, only
# with MESA_KK_EXPERIMENTAL=module_identifier (the runs above check it is not,
# and that the device has no vkGetShaderModuleIdentifierEXT, without it; the
# algorithm UUID is MESA-BLAKE3 either way). With it, identifiers are the
# SPIR-V's; a pipeline from an identifier fails with
# VK_PIPELINE_COMPILE_REQUIRED unless a pipeline cache has its shader, and is
# made from one, also on a second device; with gpl as well, a vertex shader
# library from an identifier, linked fast and drawn. Every pipeline above
# builds the same MSL; the identifier checks' own libraries come after them.
for flags in module_identifier gpl,module_identifier; do
    case $flags in
    gpl,*) name=module-identifier-gpl like=msl-gpl ;;
    *) name=module-identifier like=msl ;;
    esac
    rm -rf "$ROOT/msl-$name"; mkdir -p "$ROOT/msl-$name"
    MESA_KK_EXPERIMENTAL=$flags KK_MOCK_MSL_DIR="$ROOT/msl-$name" MESA_SHADER_CACHE_DISABLE=true \
        "$ROOT/kk-host-test" "$ROOT/build/src/kosmickrisp/vulkan/libvulkan_kosmickrisp.so" "$ROOT/spv" \
        >"$ROOT/$name.log" 2>&1 || { cat "$ROOT/$name.log" >&2; exit 1; }
    grep -q '^ok module_identifier: ' "$ROOT/$name.log" ||
        { echo "MESA_KK_EXPERIMENTAL=$flags: the module identifier case did not run" >&2; exit 1; }
    [ "$flags" = module_identifier ] || grep -q '^ok module_identifier gpl: ' "$ROOT/$name.log" ||
        { echo "MESA_KK_EXPERIMENTAL=$flags: the module identifier library case did not run" >&2; exit 1; }
    for f in "$ROOT/$like/"*.metal; do
        cmp -s "$f" "$ROOT/msl-$name/${f##*/}" ||
            { echo "MESA_KK_EXPERIMENTAL=$flags: ${f##*/} is not the MSL made without it" >&2; exit 1; }
    done
    grep '^ok module_identifier' "$ROOT/$name.log"
    echo "MESA_KK_EXPERIMENTAL=$flags: $(ls "$ROOT/$like" | wc -l) MSL libraries, each the one made without it, then $(( $(ls "$ROOT/msl-$name" | wc -l) - $(ls "$ROOT/$like" | wc -l) )) of the identifier checks"
done

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

# With MESA_KK_EXPERIMENTAL=gpl each pipeline library's MSL is dumped too
# (kind gpl), with its SPIR-V (PLA-437).
rm -rf "$ROOT/dump-gpl"; mkdir -p "$ROOT/dump-gpl/kosmickrisp"
MESA_SHADER_CACHE_DIR="$ROOT/dump-gpl/kosmickrisp" MESA_KK_DUMP_MSL_MIN_KB=0 MESA_KK_EXPERIMENTAL=gpl \
    MESA_SHADER_CACHE_DISABLE=true \
    "$ROOT/kk-host-test" "$ROOT/build/src/kosmickrisp/vulkan/libvulkan_kosmickrisp.so" "$ROOT/spv" \
    >"$ROOT/dump-gpl.log" 2>&1 || { cat "$ROOT/dump-gpl.log" >&2; exit 1; }
gpl_dumps=$(grep -l '^kind gpl$' "$ROOT/dump-gpl/kk-dump/"*.txt | wc -l)
gpl_vert=$(grep -l '^stage vert .* spirv_bytes ' $(grep -l '^kind gpl$' "$ROOT/dump-gpl/kk-dump/"*.txt) | wc -l)
gpl_frag=$(grep -l '^stage frag .* spirv_bytes ' $(grep -l '^kind gpl$' "$ROOT/dump-gpl/kk-dump/"*.txt) | wc -l)
[ "$gpl_vert" -gt 0 ] && [ "$gpl_frag" -gt 0 ] ||
    { echo "MESA_KK_DUMP_MSL_MIN_KB with gpl: $gpl_dumps library dumps, $gpl_vert vertex and $gpl_frag fragment with SPIR-V" >&2; exit 1; }
echo "MESA_KK_DUMP_MSL_MIN_KB with gpl: $gpl_dumps pipeline libraries dumped ($gpl_vert vertex, $gpl_frag fragment)"

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

# PLA-431: diagnostics never renumber the established MSL prefix. The extra
# devices and failure/rollback tests run only after all existing flag checks.
for mode in off on; do
    debug=; [ "$mode" = off ] || debug=descriptor_stats,vertex_stats
    rm -rf "$ROOT/msl-descriptor-$mode"; mkdir -p "$ROOT/msl-descriptor-$mode"
    # Truncate once; the real emitter requires an O_APPEND regular-file sink.
    : >"$ROOT/descriptor-$mode.log"
    KK_HOST_DESCRIPTOR_TEST=1 MESA_KK_DEBUG="$debug" \
        KK_MOCK_MSL_DIR="$ROOT/msl-descriptor-$mode" MESA_SHADER_CACHE_DISABLE=true \
        timeout --kill-after=5s 90s "$ROOT/kk-host-test" "$ROOT/build/src/kosmickrisp/vulkan/libvulkan_kosmickrisp.so" "$ROOT/spv" \
        >>"$ROOT/descriptor-$mode.log" 2>&1 || { tail -60 "$ROOT/descriptor-$mode.log" >&2; exit 1; }
    for f in "$ROOT/msl/"*.metal; do
        cmp -s "$f" "$ROOT/msl-descriptor-$mode/${f##*/}" ||
            { echo "descriptor-$mode changed ${f##*/}" >&2; exit 1; }
    done
done
! grep -q '^\[kk-descriptor\]' "$ROOT/descriptor-off.log"
grep -q '^\[kk-vertex\]' "$ROOT/descriptor-on.log"
diff -rq "$ROOT/msl-descriptor-off" "$ROOT/msl-descriptor-on" >/dev/null
python3 - "$ROOT" "$HERE" <<'PY'
import json, pathlib, shlex, subprocess, sys
root, here = map(pathlib.Path, sys.argv[1:])
build = root / 'build'
entry = next(e for e in json.loads((build / 'compile_commands.json').read_text())
             if e['file'].endswith('/kk_debug.c'))
args = shlex.split(entry['command'])
args = args[:args.index('-MD')]
obj = root / 'kk-descriptor-stats-test.o'
subprocess.run(args + ['-O2', '-UNDEBUG', '-c', str(here / 'kk-descriptor-stats-test.c'),
                      '-o', str(obj)], cwd=build, check=True)
exe = root / 'kk-descriptor-stats-test'
subprocess.run(['cc', '-pthread', '-Wl,--gc-sections', '-o', str(exe), str(obj),
                str(build / entry['output']),
                str(build / 'src/c11/impl/libmesa_util_c11.a')], check=True)
helper_log = root / 'descriptor-helper.log'
helper_log.write_text('')
with helper_log.open('a') as log:
    subprocess.run([str(exe)], stdout=log, stderr=log, check=True)

# Exercise the generated mock itself. The old inline completion fails the
# committing assertion; timeout also bounds future synchronization regressions.
mock_exe = root / 'kk-mock-feedback-test'
bridge = build / 'src/kosmickrisp/bridge/libmtl_bridge.a.p'
subprocess.run(['cc', '-UNDEBUG', '-I' + str(root / 'mesa/src'),
                '-o', str(mock_exe), str(here / 'kk-mock-feedback-test.c'),
                str(bridge / 'stubs_mtl_command_queue.c.o'),
                str(bridge / 'stubs_mtl_bridge.c.o'),
                str(bridge / 'stubs_mtl_sync.c.o')], check=True)
with (root / 'mock-feedback.log').open('w') as log:
    subprocess.run([str(mock_exe)], stdout=log, stderr=log, check=True, timeout=10)

# This is a known-count fixture assertion, NOT the future interval parser.
text = (root / 'descriptor-on.log').read_text().split('descriptor-fixture begin\n')[1].split('descriptor-fixture end\n')[0]
rows = [dict(token.split('=', 1) for token in line.split()[1:])
        for line in text.splitlines() if line.startswith('[kk-descriptor] ')]
enabled = [r for r in rows if r['kind'] == 'enabled']
assert len(enabled) == 3, enabled # initialized failure + two live devices
assert len({r['device'] for r in enabled}) == 3
finals = [r for r in rows if r['kind'] == 'snapshot' and r['final'] == '1']
assert len(finals) == 30
expected = {
    'pool_create': dict(calls=3, sets=5, pool_entries=7, pool_elements=4104, pool_bytes=64, failures=1),
    'allocate': dict(calls=3, sets=5, failures=1),
    'free': dict(calls=1, sets=1),
    'pool_reset': dict(calls=1, sets=1),
    'pool_destroy': dict(calls=2, sets=1),
    'update': dict(calls=2001, write_records=3, write_elements=2, write_bytes=16,
                   copy_records=2, copy_elements=1, copy_bytes=16),
    'template_update': dict(calls=1, write_records=2, write_elements=1, write_bytes=16),
    'bind': dict(calls=1, sets=1, dynamic_offsets=1),
    'push': dict(calls=1, write_records=1, write_elements=1),
    'push_template': dict(calls=1, write_records=1, write_elements=1),
}
for row in finals:
    assert row['v'] == '1' and row['component'] == 'kk'
    assert row['clock_ok'] == row['quiescent'] == '1' and row['overflow'] == row['active'] == '0'
    assert int(row['ts_end']) >= int(row['ts_begin']) > 0
    assert row['timed_calls'] == row['calls'] and row['clock_errors'] == '0'
    assert int(row['elapsed_ticks']) >= int(row['max_ticks'])
    assert row['entered_before'] == row['completed_before'] == row['entered_after'] == row['completed_after']
    if row['device'] != enabled[1]['device']:
        assert row['calls'] == '0', row # init failure and second device cannot inherit counts
        continue
    want = expected[row['op']]
    for field in ('calls', 'sets', 'write_records', 'write_elements', 'write_bytes',
                  'copy_records', 'copy_elements', 'copy_bytes', 'dynamic_offsets',
                  'pool_entries', 'pool_elements', 'pool_bytes', 'failures'):
        assert int(row[field]) == want.get(field, 0), (row, field, want)
assert len([r for r in rows if r['kind'] == 'calibration']) == 48
for r in rows:
    if r['kind'] == 'calibration':
        assert r['adjacent_ok'] == r['empty_ok'] == '1' and r['reads'] == '6'
helper = (root / 'descriptor-helper.log').read_text()
assert 'quiescent=0' in helper and 'active=1' in helper and 'overflow=1' in helper
assert 'clock_errors=3' in helper and 'ok descriptor helper:' in helper
assert 'clock_ok=0 report_clock_errors=3' in helper
# Completed logs only: each phase is bracketed after idle and contains the
# normal native reporter's ten rows, not synthetic test counter copies.
replay = (root / 'descriptor-on.log').read_text().split('descriptor-replay begin\n')[1]
phases = [('secondary-recorded', 0), ('secondary-executed-once', 1),
          ('secondary-executed-twice', 2), ('secondary-primary-submitted', 2),
          ('reusable-recorded', 3), ('reusable-submit-1', 3),
          ('reusable-submit-2', 4), ('reusable-submit-3', 5)]
previous = None
identity = None
for phase, calls in phases:
    section = replay.split(f'descriptor-replay phase={phase} begin\n')[1].split(
        f'descriptor-replay phase={phase} end\n')[0]
    snapshot = [dict(token.split('=', 1) for token in line.split()[1:])
                for line in section.splitlines() if line.startswith('[kk-descriptor] ')]
    assert len(snapshot) == 10 and {r['op'] for r in snapshot} == set(expected), (phase, snapshot)
    for field in ('snapshot', 'ts_begin', 'ts_end', 'hz', 'frames',
                  'entered_before', 'completed_before', 'entered_after', 'completed_after'):
        assert len({r[field] for r in snapshot}) == 1, (phase, field)
    assert snapshot[0]['hz'] == '1000000000' and snapshot[0]['frames'] == '0'
    current_identity = {(r['pid'], r['device'], r['init_ticks']) for r in snapshot}
    assert len(current_identity) == 1
    assert all(r['device'] not in {e['device'] for e in enabled} for r in snapshot)
    if identity is not None:
        assert current_identity == identity
    identity = current_identity
    current = {r['op']: r for r in snapshot}
    for op, row in current.items():
        assert row['kind'] == 'snapshot' and row['v'] == '1' and row['component'] == 'kk'
        assert row['final'] == row['active'] == row['overflow'] == row['clock_errors'] == row['report_clock_errors'] == '0'
        assert row['clock_ok'] == row['quiescent'] == '1'
        assert int(row['ts_end']) >= int(row['ts_begin']) > 0
        assert row['entered_before'] == row['completed_before'] == row['entered_after'] == row['completed_after']
        assert row['timed_calls'] == row['calls'] and int(row['elapsed_ticks']) >= int(row['max_ticks'])
        if previous:
            assert int(row['snapshot']) > int(previous[op]['snapshot'])
            for field in ('calls', 'timed_calls', 'elapsed_ticks', 'max_ticks'):
                assert int(row[field]) >= int(previous[op][field]), (phase, row)
        want = {}
        if op == 'bind':
            want = dict(calls=calls, sets=calls)
        elif op in ('push', 'push_template'):
            want = dict(calls=calls, write_records=calls, write_elements=calls)
        elif op == 'pool_create':
            want = dict(calls=1, sets=1, pool_entries=1, pool_elements=1)
        elif op == 'allocate':
            want = dict(calls=1, sets=1)
        elif op == 'update':
            want = dict(calls=1, write_records=1, write_elements=1)
        for field in ('calls', 'sets', 'write_records', 'write_elements', 'write_bytes',
                      'copy_records', 'copy_elements', 'copy_bytes', 'dynamic_offsets',
                      'pool_entries', 'pool_elements', 'pool_bytes', 'failures'):
            assert int(row[field]) == want.get(field, 0), (phase, op, field, row, want)
    previous = current
print('descriptor replay: secondary recorded/executed1/executed2/submitted=0/1/2/2; '
      'reusable recorded/submit1/submit2/submit3=3/3/4/5 (bind, push, push_template each)')
print(f'descriptor MSL: {len(list((root / "msl-descriptor-on").glob("*.metal")))} off/on identical files')
print('descriptor_stats: exact 10-operation counts, two-device/init-failure separation, rollback, threads, clock errors and overflow; MSL off/on identical')
PY

# Compile the actual emitter, not a printf model. Independent raw appenders,
# strict schema/interval checks and bounded fault injection need no GPU mock.
SERVER_SOURCE=${KK_DESCRIPTOR_SERVER_SOURCE:-$PLAYPORT_BUILD/run/unix/mythic/build/wineserver/fd_ios.c}
EMISSION_ARGS=()
if [ -f "$SERVER_SOURCE" ]; then
    EMISSION_ARGS+=(--server-source "$SERVER_SOURCE")
else
    echo "descriptor SCM_RIGHTS regression: skipped (set KK_DESCRIPTOR_SERVER_SOURCE to patched fd_ios.c)"
fi
python3 "$HERE/kk-descriptor-emission-test.py" "${EMISSION_ARGS[@]}" "$ROOT/build" \
    "$TREE/src/kosmickrisp/vulkan/kk_debug.c" "$ROOT/descriptor-emission"
# Linux cannot perform Darwin F_GETPATH. Simulate only that query, retaining
# actual fd2/open/dup2/fstat/getfl/write and the production formatter/latch.
python3 "$HERE/kk-descriptor-emission-test.py" --getpath-seam "$ROOT/build" \
    "$TREE/src/kosmickrisp/vulkan/kk_debug.c" "$ROOT/descriptor-emission-path" \
    nonappend path-short path-max path-error

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
