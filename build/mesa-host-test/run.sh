#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build KosmicKrisp for Linux on the mock Metal bridge and drive it with
# kk-host-test.c: device creation, pipeline builds and draw recording for the
# pipelines it lists (geometry shaders, tessellation into a geometry shader,
# polygon modes). The GPU work is not run; see make-mock-bridge.py for what
# the mock does and checks.
#
#   build/mesa-host-test/run.sh MESA_TREE HOST_TOOLS_BUILD [ROOT]
#
# MESA_TREE         a Mesa tree with patches/mesa applied (build/stages/mesa.sh src)
# HOST_TOOLS_BUILD  build/stages/mesa.sh's ROOT/host (mesa_clc, vtn_bindgen2, kk_clc)
# ROOT              scratch area, default $PLAYPORT_BUILD/run/mesa-host-test
#
# Exit status: 0 when every pipeline builds and draws with every MSL library
# fully translated.
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
    glslangValidator -V --target-env vulkan1.3 -o "$ROOT/spv/$(basename "$s").spv" "$s" >/dev/null
done
cc -O1 -g -Wall -o "$ROOT/kk-host-test" "$HERE/kk-host-test.c" -ldl

rm -rf "$ROOT/msl"; mkdir -p "$ROOT/msl"
KK_MOCK_MSL_DIR="$ROOT/msl" MESA_SHADER_CACHE_DISABLE=true \
    "$ROOT/kk-host-test" "$ROOT/build/src/kosmickrisp/vulkan/libvulkan_kosmickrisp.so" "$ROOT/spv"
echo "MSL libraries: $(ls "$ROOT/msl" | wc -l) in $ROOT/msl"
