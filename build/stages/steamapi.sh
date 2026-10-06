#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The Steam API emulator a game loads in place of its own steam_api(64).dll
# (docs/plans/finished.md#steam-for-games, phase 1): gbe_fork's regular
# steam_api build (premake project api_regular) at the pins.lock gbe commit
# with patches/gbe, for x86-64 (steam_api64.dll) and i386 (steam_api.dll).
# These are native DLLs: the app copies one into a game's folder at launch
# (SteamClientKit SteamAPISwap), so they are not marked Wine builtins.
#
#   build/stages/steamapi.sh [ROOT] [stage...]   ROOT defaults to $PLAYPORT_BUILD/run/steamapi;
#                                                 stages: src protoc deps api (default all)
#
# gbe_fork builds its static dependencies (libssq, zlib, mbedtls, curl,
# protobuf with abseil, opus, portaudio, SDL3) from the archives on its
# third-party/deps/common branch with CMake (premake5-deps.lua); here each
# arch gets them from llvm-mingw through a CMake toolchain file. Its
# generated protobuf sources need a protoc of the same protobuf release, so
# one is built for the host from that same archive. Protobuf builds Abseil
# from source, the release its cmake/dependencies.cmake names: the pins.lock
# abseil-cpp tag, from a cache mirror, never a download during the build
# (FETCHCONTENT_FULLY_DISCONNECTED). The in-game overlay (ingame_overlay,
# api_experimental, steamclient) is not built.
#
# Inputs (env): LLVM_MINGW (build/lib.sh). Host tools: cmake, ninja, make, 7za
# (the deps script's extractor). premake5 is gbe_fork's own, from its
# third-party/common/linux branch at the pinned gitlink.
# Output: ROOT/pe/x86_64-windows/steam_api64.dll, ROOT/pe/i386-windows/steam_api.dll.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../lib.sh"
ROOT=$(realpath -m "${1:-$PLAYPORT_BUILD/run/steamapi}")
shift || true
STAGES=${*:-src protoc deps api}
MINGW=${LLVM_MINGW:?set LLVM_MINGW (pp setup)}
JOBS=${JOBS:-$(nproc)}
G=$ROOT/gbe
PIN=$(pin gbe)
ABSL=$ROOT/abseil-cpp
# premake arch, llvm-mingw triple arch, Playport arch dir, DLL name, deps flag
ARCHES=("x64 x86_64 x86_64 steam_api64.dll 64" "x86 i686 i386 steam_api.dll 32")
# The dependencies api_regular links (premake5-deps.lua --build-* names).
DEPS="ssq zlib mbedtls curl protobuf opus portaudio sdl"
mkdir -p "$ROOT"
# No build path in the DLLs (verify-ipa's path check; abseil and protobuf keep __FILE__):
# CMake takes these as its initial flags, and the premake Makefiles append them.
export CFLAGS="-ffile-prefix-map=$ROOT=steamapi" CXXFLAGS="-ffile-prefix-map=$ROOT=steamapi"

premake() { (cd "$G" && "$ROOT/tools/premake5" --os=windows "$@"); }

stage_src() {
    local m
    m=$(mirror gbe "$PIN")
    [ -e "$G/.git" ] || git clone -q --no-checkout "$m" "$G"
    git -C "$G" cat-file -e "$PIN^{commit}" 2>/dev/null || git -C "$G" fetch -q "$m" "$PIN"
    ensure_series "$G" gbe "$PIN"
    # The two branches the build reads: the dependency archives and premake.
    # Their .gitmodules URL is ./ (branches of the same repository): the mirror.
    git -C "$G" config submodule.third-party/deps/common.url "$m"
    git -C "$G" config submodule.third-party/common/linux.url "$m"
    git -C "$G" -c protocol.file.allow=always submodule update -q --init third-party/deps/common third-party/common/linux
    # A copy, so the chmod leaves the submodule clean (ensure_series checks the tree).
    mkdir -p "$ROOT/tools"
    install -m 755 "$G/third-party/common/linux/premake/premake5" "$ROOT/tools/premake5"
    echo "gbe $(git -C "$G" rev-parse HEAD) ($(series gbe | wc -l) patches on $PIN)"
    # The Abseil release the protobuf archive asks for.
    local want tag
    tag=$(pin abseil-cpp)
    want=$(tar -xzOf "$G/third-party/deps/common/protobuf/protobuf.tar.gz" protobuf/cmake/dependencies.cmake | tr -d '\r' |
        sed -n 's/^set(abseil-cpp-version "\(.*\)")$/\1/p')
    [ "$want" = "$tag" ] || { echo "gbe's protobuf needs abseil-cpp $want; pins.lock has $tag" >&2; exit 1; }
    m=$(mirror abseil-cpp "$tag")
    if [ "$(git -C "$ABSL" rev-parse HEAD 2>/dev/null)" != "$(git -C "$m" rev-parse "$tag^{commit}")" ]; then
        rm -rf "$ABSL"
        git clone -q --no-checkout "$m" "$ABSL"
        git -c advice.detachedHead=false -C "$ABSL" checkout -q "$tag"
    fi
    echo "abseil-cpp $(git -C "$ABSL" rev-parse HEAD) ($tag)"
}

# A host protoc of the protobuf release the generated sources are compiled against.
stage_protoc() {
    local d=$ROOT/host-protoc
    rm -rf "$d"
    mkdir -p "$d"
    tar -xzf "$G/third-party/deps/common/protobuf/protobuf.tar.gz" -C "$d"
    cmake -G Ninja -S "$d/protobuf" -B "$d/build" -DCMAKE_BUILD_TYPE=Release -Dprotobuf_BUILD_TESTS=OFF \
        -Dprotobuf_FORCE_FETCH_DEPENDENCIES=ON -DFETCHCONTENT_SOURCE_DIR_ABSL="$ABSL" \
        -DFETCHCONTENT_FULLY_DISCONNECTED=ON -Dprotobuf_WITH_ZLIB=OFF > "$ROOT/cmake-host-protoc.log"
    ninja -C "$d/build" -j "$JOBS" protoc > "$ROOT/ninja-host-protoc.log"
    "$d/build/protoc" --version
}

toolchain_file() {
    cat > "$ROOT/toolchain-$1.cmake" <<EOF
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR $1)
set(CMAKE_C_COMPILER $MINGW/bin/$1-w64-mingw32-clang)
set(CMAKE_CXX_COMPILER $MINGW/bin/$1-w64-mingw32-clang++)
set(CMAKE_RC_COMPILER $MINGW/bin/$1-w64-mingw32-windres)
set(CMAKE_AR $MINGW/bin/llvm-ar)
set(CMAKE_RANLIB $MINGW/bin/llvm-ranlib)
set(CMAKE_FIND_ROOT_PATH $MINGW/$1-w64-mingw32)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
# Protobuf's Abseil: the pinned checkout, built as part of protobuf; no download.
set(protobuf_FORCE_FETCH_DEPENDENCIES ON CACHE BOOL "")
set(FETCHCONTENT_SOURCE_DIR_ABSL $ABSL CACHE PATH "")
set(FETCHCONTENT_FULLY_DISCONNECTED ON CACHE BOOL "")
EOF
}

stage_deps() {
    local a p t bits d flags=()
    for d in $DEPS; do flags+=("--build-$d"); done
    rm -rf "$ROOT/deps"
    # Extracted once; each arch builds into its own install32/install64 beside the sources.
    premake --file=premake5-deps.lua --all-ext --custom-extractor="$(command -v 7za)" \
        --custom-cmake="$(command -v cmake)" --deps-dir="$ROOT/deps" gmake > "$ROOT/deps-extract.log"
    for a in "${ARCHES[@]}"; do
        read -r p t _ _ bits <<< "$a"
        toolchain_file "$t"
        CMAKE_GENERATOR=Ninja premake --file=premake5-deps.lua "${flags[@]}" "--$bits-build" --j="$JOBS" \
            --custom-extractor="$(command -v 7za)" --custom-cmake="$(command -v cmake)" \
            --cmake-toolchain="$ROOT/toolchain-$t.cmake" --deps-dir="$ROOT/deps" gmake > "$ROOT/deps-$p.log"
        echo "deps $p: $(ls "$ROOT"/deps/*/install"$bits"/lib/*.a | wc -l) static libraries"
    done
}

stage_api() {
    local a p t dir dll protoc=$ROOT/host-protoc/build/protoc inc=$ROOT/host-protoc/protobuf/src
    # premake5.lua --genproto, with the host protoc (it would run protoc.exe under wine).
    rm -rf "$G/proto_gen/win"
    mkdir -p "$G/proto_gen/win/tf2"
    (cd "$G" &&
        "$protoc" -I"$inc" dll/gc_steam/steammessages.proto -I./dll/gc_steam --cpp_out=proto_gen/win &&
        "$protoc" -I"$inc" dll/gc_tf2/*.proto -I./dll/gc_steam -I./dll/gc_tf2 --cpp_out=proto_gen/win/tf2 2> /dev/null &&
        "$protoc" -I"$inc" dll/net.proto -I./dll/ --cpp_out=proto_gen/win)
    # Games call the interfaces through MSVC's vtables (gbe 0004, 0005): check
    # the MinGW layouts match before building.
    python3 "$HERE/../steamapi-vtables.py" "$MINGW/bin/clang++" "$G/sdk" "$ROOT/vtables"
    rm -rf "$ROOT/out"
    # A fixed build string: the default is the build time, which the DLL reports.
    premake --deps-dir="$ROOT/deps" --build-dir="$ROOT/out" --emubuild="playport-$(git -C "$G" rev-parse --short=12 "$PIN")" \
        gmake > "$ROOT/premake.log"
    for a in "${ARCHES[@]}"; do
        read -r p t dir dll _ <<< "$a"
        make -C "$G/build/project/gmake/win/api_regular" "config=release_$p" -j "$JOBS" \
            CC="$MINGW/bin/$t-w64-mingw32-clang" CXX="$MINGW/bin/$t-w64-mingw32-clang++" AR="$MINGW/bin/llvm-ar" \
            RESCOMP="$MINGW/bin/$t-w64-mingw32-windres" LDFLAGS=-Wl,--no-insert-timestamp > "$ROOT/make-api-$p.log"
        mkdir -p "$ROOT/pe/$dir-windows"
        cp "$ROOT/out/win/gmake/release/regular/$p/$dll" "$ROOT/pe/$dir-windows/$dll"
    done
}

for s in $STAGES; do
    case $s in
    src|protoc|deps|api) echo "== steamapi: $s"; "stage_$s" ;;
    *) echo "no stage $s (src protoc deps api)" >&2; exit 2 ;;
    esac
done
(cd "$ROOT/pe" && sha256sum */*.dll)
