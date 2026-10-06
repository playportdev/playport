#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build DXMT's three AIR helper modules (air_msad, air_samplepos,
# air_tessellation) from the hand-written LLVM IR in this directory, with no
# Apple tool. How the port works: README.md in this directory.
#
#   air-helper-port.sh ROOT [stage...]
#   stages (default: llvm air): llvm air host
#
# llvm     LLVM 15.0.7 (the fork's pin) for the host: llvm-as, llvm-dis, llc,
#          and the static libraries a host airconv links against
# air      air_*.ll -> air_*.air (llvm-as -opaque-pointers=0) -> air_*.h
#          (xxd -i, as the fork's meson does) in ROOT/shader-headers. This is
#          the whole build route.
# host     airconv built for x86_64 Linux with these helpers, as `scan-port`
#          (probe/airconv_scan.cpp), for probe/title_shaders.py
#
# DXMT_BUILD_ROOT is a build/stages/dxmt-base.sh ROOT whose `clones`
# and `llvm` stages have run (the fork at the dxmt pin, llvm-project at
# llvmorg-15.0.7, remote-metal headers). Default: ROOT/dxmt-build, created on
# first use. Nothing is installed; all output stays under ROOT.
set -euo pipefail

ROOT=$(realpath -m "${1:?usage: $0 ROOT [stage...]}")
shift
STAGES=${*:-llvm air}
HERE=$(dirname "$(realpath "$0")")
PROBE=$HERE/probe
. "$HERE/../lib.sh"
DXB=${DXMT_BUILD_ROOT:-$ROOT/dxmt-build}
B=$ROOT/llvm15/bin
HELPERS="air_msad air_samplepos air_tessellation"
mkdir -p "$ROOT"
cd "$ROOT"

need_dxb() {
    if [ ! -d "$DXB/dxmt/.git" ] || [ ! -f "$DXB/llvm-host-build/include/llvm/IR/IntrinsicEnums.inc" ]; then
        bash "$HERE/../stages/dxmt-base.sh" "$DXB" clones llvm
    fi
}

stage_llvm() {
    # The cache is shared by every checkout and worktree of this repository (.work/cache),
    # and CMake refuses a build directory configured from another source path. The tools
    # come from the one pinned LLVM 15 whichever checkout configured them, and stage_air
    # checks what they produce (air.sha256): a complete set is used as it is.
    local t ok=1
    for t in llvm-as llvm-dis llvm-link llc opt; do [ -x "$B/$t" ] || ok=; done
    if [ -n "$ok" ]; then echo "llvm15: tools present, not reconfigured"; return 0; fi
    need_dxb
    cmake -G Ninja -B "$ROOT/llvm15" -S "$DXB/llvm-project/llvm" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ -DCMAKE_CXX_FLAGS="-include cstdint" \
        -DLLVM_TARGETS_TO_BUILD=X86 -DLLVM_ENABLE_ASSERTIONS=On \
        -DLLVM_ENABLE_ZSTD=Off -DLLVM_ENABLE_ZLIB=Off -DLLVM_ENABLE_TERMINFO=Off -DLLVM_ENABLE_LIBXML2=Off \
        -DLLVM_INCLUDE_TESTS=Off -DLLVM_INCLUDE_BENCHMARKS=Off -DLLVM_INCLUDE_EXAMPLES=Off \
        > "$ROOT/llvm15-configure.log" 2>&1
    ninja -C "$ROOT/llvm15" -j "${JOBS:-$(nproc)}" llvm-as llvm-dis llvm-link llc opt > "$ROOT/llvm15-build.log"
}

stage_air() {
    mkdir -p "$ROOT/air" "$ROOT/shader-headers"
    for s in $HELPERS; do
        # Typed pointers: airconv parses the helpers into a context with
        # opaque pointers off, and LLVM 15 otherwise writes a module that has
        # no pointer types (air_msad) in opaque mode, which that context
        # rejects: linkShader() prints an error and, with LLVM assertions on,
        # aborts on the unchecked Expected (README.md, "Typed pointers").
        "$B/llvm-as" -opaque-pointers=0 "$HERE/$s.ll" -o "$ROOT/air/$s.air"
        (cd "$ROOT/air" && xxd -n "$s" -i "$s.air" "$ROOT/shader-headers/$s.h")
    done
    (cd "$ROOT/air" && sha256sum *.air) | tee "$ROOT/air.sha256"
    (cd "$ROOT/shader-headers" && sha256sum *.h) | tee "$ROOT/shader-headers.sha256"
}

# airconv for x86_64 Linux, from a copy of the fork's sources. Only literal
# suffixes change: `0ull` is unsigned long long, which is uint64_t on Apple
# platforms but not on LP64 Linux, where IRBuilder overloads become
# ambiguous. The copy spells them uint64_t(0): the same code on Apple.
stage_host() {
    need_dxb
    local H=$ROOT/host D=$DXB/dxmt L=$DXB/llvm-project/llvm
    mkdir -p "$H/obj"
    rm -rf "$H/airconv" && cp -r "$D/src/airconv" "$H/airconv"
    find "$H/airconv" -name '*.cpp' -o -name '*.hpp' | xargs sed -i -E 's/\b(0x[0-9a-fA-F]+|[0-9]+)ull\b/uint64_t(\1)/g'
    local flags="-O2 -std=c++20 -fno-exceptions -fno-rtti -funwind-tables -Wno-everything -include cstdint -include optional -include string
        -I$D/include -I$D/libs -I$D/src/winemetal -I$H/airconv -I$D/include/native/directx -I$D/include/native/windows
        -I$ROOT/llvm15/include -I$L/include -D_FILE_OFFSET_BITS=64 -D__STDC_CONSTANT_MACROS -D__STDC_FORMAT_MACROS -D__STDC_LIMIT_MACROS"
    local p
    for p in air_type air_signature air_operations dxbc_converter dxbc_converter_gs dxbc_converter_ts \
             dxbc_converter_basicblock dxbc_converter_cfg dxbc_instructions dxbc_signature metallib_writer \
             nt/air_builder nt/dxbc_converter_base transforms/lower_16bit_texread \
             dxbc_binding_rootsig dxbc_binding_sm50 transforms/simdgroup_implicit_membarrier; do
        clang++ $flags -c "$H/airconv/$p.cpp" -o "$H/obj/$(basename $p).o" &
    done
    for p in BlobContainer DXBCUtils ShaderBinary; do
        clang++ -O2 -std=c++20 -fno-rtti -Wno-everything -I$D/include -I$D/libs -I$D/include/native/directx \
            -I$D/include/native/windows -c "$D/libs/DXBCParser/$p.cpp" -o "$H/obj/dxbc_$p.o" &
    done
    wait
    test "$(ls "$H"/obj/*.o | wc -l)" = 20
    mkdir -p "$H/hdr-port"
    for s in $HELPERS; do cp "$ROOT/shader-headers/$s.h" "$H/hdr-port/"; done
    clang++ $flags -c "$PROBE/airconv_scan.cpp" -o "$H/scan.o"
    local libs="-lLLVMPasses -lLLVMTarget -lLLVMObjCARCOpts -lLLVMCoroutines -lLLVMipo -lLLVMInstrumentation
        -lLLVMVectorize -lLLVMLinker -lLLVMIRReader -lLLVMAsmParser -lLLVMFrontendOpenMP -lLLVMScalarOpts
        -lLLVMInstCombine -lLLVMAggressiveInstCombine -lLLVMTransformUtils -lLLVMBitWriter -lLLVMAnalysis
        -lLLVMProfileData -lLLVMSymbolize -lLLVMDebugInfoPDB -lLLVMDebugInfoMSF -lLLVMDebugInfoDWARF -lLLVMObject
        -lLLVMTextAPI -lLLVMMCParser -lLLVMMC -lLLVMDebugInfoCodeView -lLLVMBitReader -lLLVMCore -lLLVMRemarks
        -lLLVMBitstreamReader -lLLVMBinaryFormat -lLLVMSupport -lLLVMDemangle"
    clang++ $flags -I"$H/hdr-port" -c "$H/airconv/airconv_context.cpp" -o "$H/ctx-port.o"
    clang++ -o "$H/scan-port" "$H/scan.o" "$H/ctx-port.o" "$H"/obj/*.o -L"$ROOT/llvm15/lib" $libs -lpthread
}

for s in $STAGES; do echo "== stage $s"; stage_$s; done
