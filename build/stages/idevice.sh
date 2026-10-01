#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# idevice's C FFI for the app (decision 0029): the pins.lock idevice commit,
# built for aarch64-apple-ios with the pins.lock Rust (build/toolchain/rust.sh)
# and prelinked into one object that exports only the calls declared by
# app/Sources/Relaunch (restart and on-device pairing; decision 0033). With them the app opens the RemotePairing tunnel
# to the phone over LocalDevVPN, with the pairing file its JIT section keeps,
# and asks CoreDevice to launch its own bundle with terminateExisting: Playport
# restarts itself after a game (docs/ARCHITECTURE.md, "Restarting after a game").
#
#   build/stages/idevice.sh OUT
#
# Writes OUT/libidevice_ffi.a (one object), OUT/imports.txt (what it leaves to
# the app's link), OUT/crates.tsv (resolved normal target graph with versions,
# licences and source directories, for build/notices-assemble.sh; not actual
# linked members or the build/proc-macro/native dependency graph).
#
# - Features: only what that chain needs (ring for TLS: its C and assembly build
#   with the host clang for iOS; no CMake or Go, which aws-lc would need).
# - The build runs in a copy of the checkout: idevice's build.rs writes its
#   generated header into the source tree.
# - Paths: the Rust sources, the crates and the checkout are remapped, and the
#   C is built with -ffile-prefix-map, so no path on this machine is in the
#   object (verify-ipa.py fails the IPA otherwise).
# - One object: the Rust standard library comes with it, and its unmangled
#   rust_eh_personality would clash with the copy in libwinegstreamer_unix.a
#   (build/stages/gstreamer.sh). Prelinking with an export list makes that, and
#   everything else but the declared calls, private to the object.
set -euo pipefail
. "$(dirname "$0")/../lib.sh"

OUT=$(realpath -m "${1:?usage: idevice.sh OUT}")
CRATES=$PLAYPORT_REPO/build/idevice-crates.py
TARGET=$(python3 "$CRATES" target)
FEATURES=$(python3 "$CRATES" features)
EXPORTS=(_rp_pairing_file_from_bytes _tunnel_create_rppairing _app_service_connect_rsd _app_service_launch_app
    _pairable_host_accept_bonjour _pairable_host_cancel_new _pairable_host_cancel_signal _pairable_host_cancel_free _idevice_error_free)
LICENSE_SHA256=131488ce7e302b9f62e3236793e57c86a208d3dfaf03e6d7d03ddc0fc82392ed
commit=$(pin idevice)
cache=$PLAYPORT_BUILD/cache/idevice-$commit

export RUSTUP_HOME=$RUST_ROOT/rustup CARGO_HOME=$RUST_ROOT/cargo
export PATH=$CARGO_HOME/bin:$PATH
case $(rustc --version 2>/dev/null) in
"rustc $(pin rust) "*) ;;
*) echo "idevice: no Rust $(pin rust) in $RUST_ROOT (build/toolchain/rust.sh)" >&2; exit 1 ;;
esac

# The pinned checkout, shared with build/stages/stikjit.sh (the notice of StikJIT's copy).
if [ "$(git -C "$cache" rev-parse HEAD 2>/dev/null)" != "$commit" ]; then
    tmp=$(mktemp -d "$cache.XXXXXX")
    trap 'rm -rf "$tmp"' EXIT
    git init -q "$tmp"
    git -C "$tmp" fetch -q --depth 1 "$(pin_url idevice)" "$commit"
    git -c advice.detachedHead=false -C "$tmp" checkout -q FETCH_HEAD
    [ "$(git -C "$tmp" rev-parse HEAD)" = "$commit" ] || { echo "idevice: fetched tree is not $commit" >&2; exit 1; }
    rm -rf "$cache"
    mv "$tmp" "$cache"
    trap - EXIT
fi
echo "$LICENSE_SHA256  $cache/LICENSE.txt" | sha256sum -c --status ||
    { echo "idevice: LICENSE.txt is not sha256 $LICENSE_SHA256" >&2; exit 1; }

src=$OUT/src
mkdir -p "$OUT"
rsync -a --delete "$cache/" "$src/"
ensure_series "$src" idevice "$commit"

export SDKROOT=$IOSSDK IPHONEOS_DEPLOYMENT_TARGET=17.0
export CC_aarch64_apple_ios=clang AR_aarch64_apple_ios=llvm-ar
export CFLAGS_aarch64_apple_ios="-target arm64-apple-ios17.0 -isysroot $IOSSDK -ffile-prefix-map=$src=idevice -ffile-prefix-map=$CARGO_HOME=cargo -ffile-prefix-map=$DARWIN_SDK=darwin-sdk"
# plist_ffi, a dependency, also builds a cdylib: cargo needs a linker for the target.
export CARGO_TARGET_AARCH64_APPLE_IOS_LINKER=clang
export CARGO_TARGET_AARCH64_APPLE_IOS_RUSTFLAGS="-C link-arg=-target -C link-arg=arm64-apple-ios17.0 -C link-arg=-isysroot -C link-arg=$IOSSDK -C link-arg=-fuse-ld=lld --remap-path-prefix=$CARGO_HOME=cargo --remap-path-prefix=$RUSTUP_HOME=rustup --remap-path-prefix=$src=idevice"
export CARGO_TARGET_DIR=$OUT/target
(cd "$src/ffi" && cargo fetch --locked -q &&
    cargo rustc --locked --offline --release --target "$TARGET" --no-default-features --features "$FEATURES" \
        --crate-type staticlib)
lib=$CARGO_TARGET_DIR/$TARGET/release/libidevice_ffi.a

# One object, only the declared calls exported (build/stages/gstreamer.sh does the same;
# -S: no debug map naming each member by its path here).
obj=$OUT/obj
rm -rf "$obj"; mkdir -p "$obj"
exports=()
for s in "${EXPORTS[@]}"; do exports+=(-exported_symbol "$s"); done
# ld64 -r takes the archive's members as objects, in the archive's order (it does
# not load a lone archive's members for -r).
mkdir -p "$obj/members"
(cd "$obj/members" && llvm-ar x "$lib")
mapfile -t members < <(llvm-ar t "$lib")
[ "${#members[@]}" = "$(find "$obj/members" -type f | wc -l)" ] ||
    { echo "idevice: the archive has members with the same name" >&2; exit 1; }
"$LD64" -r -arch arm64 -platform_version ios 17.0 26.5 -syslibroot "$IOSSDK" \
    -o "$obj/prelinked.o" "${members[@]/#/$obj/members/}"
"$LD64" -r -S -arch arm64 -platform_version ios 17.0 26.5 -syslibroot "$IOSSDK" "${exports[@]}" \
    -o "$obj/idevice_ffi.o" "$obj/prelinked.o"
rm -rf "$obj/prelinked.o" "$obj/members" "$OUT/libidevice_ffi.a"
llvm-ar rcsD "$OUT/libidevice_ffi.a" "$obj/idevice_ffi.o"
llvm-nm "$obj/idevice_ffi.o" > "$obj/symbols.txt"
for s in "${EXPORTS[@]}"; do
    grep -Eq "^[0-9a-f]+ T $s\$" "$obj/symbols.txt" || { echo "idevice: $s is not exported" >&2; exit 1; }
done
[ "$(grep -Ec '^[0-9a-f]+ [A-TV-Z] ' "$obj/symbols.txt")" = "${#EXPORTS[@]}" ] ||
    { echo "idevice: the object exports more than ${EXPORTS[*]}" >&2; exit 1; }
if grep -aq -e "$HOME/" -e "$PLAYPORT_REPO/" "$OUT/libidevice_ffi.a"; then
    echo "idevice: a path on this machine is in the object" >&2; exit 1
fi
grep -E '^ +U ' "$obj/symbols.txt" | awk '{print $2}' > "$OUT/imports.txt"

# Normal dependencies for the exact target/features above (not a link-member
# audit). Notice verification regenerates this inventory with the same helper.
python3 "$CRATES" inventory "$src" "$RUST_ROOT" "$(pin rust)" > "$OUT/crates.tsv"
echo "$(wc -l < "$OUT/crates.tsv") crates ($OUT/crates.tsv), $(wc -l < "$OUT/imports.txt") imported symbols"
printf '%s %s %s\n' "$(stat -c %s "$OUT/libidevice_ffi.a")" \
    "$(sha256sum "$OUT/libidevice_ffi.a" | cut -d' ' -f1)" "$OUT/libidevice_ffi.a"
