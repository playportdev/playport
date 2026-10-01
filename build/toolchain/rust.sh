#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Install the Rust toolchain build/stages/idevice.sh compiles idevice with:
# the pins.lock `rust` release with the aarch64-apple-ios standard library,
# through rustup, into a private directory in the build area. The system's
# Rust, if any, is not used: a distribution's rustc has no iOS std.
#
#   build/toolchain/rust.sh [ROOT]    ROOT defaults to $RUST_ROOT ($PLAYPORT_BUILD/inputs/rust)
#
# Result: ROOT/rustup (RUSTUP_HOME), ROOT/cargo (CARGO_HOME: cargo/bin, and the
# crates idevice's Cargo.lock names, fetched by the stage). Nothing is installed
# system-wide and no shell profile is touched (--no-modify-path).
set -euo pipefail
. "$(dirname "$0")/../lib.sh"

ROOT=${1:-$RUST_ROOT}
# rustup-init itself, by version (static.rust-lang.org/rustup/archive), checked by hash.
RUSTUP_VERSION=1.29.1
RUSTUP_SHA256=dda7234360b7f578ca8b0ddcb80145646fa61a67c1720a5abc7051b35c9fcb71
TARGET=aarch64-apple-ios
version=$(pin rust)

export RUSTUP_HOME=$ROOT/rustup CARGO_HOME=$ROOT/cargo
mkdir -p "$ROOT"
init=$ROOT/rustup-init-$RUSTUP_VERSION
if ! echo "$RUSTUP_SHA256  $init" | sha256sum -c --status 2>/dev/null; then
    part=$(mktemp "$ROOT/rustup-init.XXXXXX")
    trap 'rm -f "$part"' EXIT
    curl -fsSL -o "$part" "https://static.rust-lang.org/rustup/archive/$RUSTUP_VERSION/x86_64-unknown-linux-gnu/rustup-init"
    echo "$RUSTUP_SHA256  $part" | sha256sum -c --status ||
        { echo "toolchain-rust: rustup-init $RUSTUP_VERSION is not sha256 $RUSTUP_SHA256" >&2; exit 1; }
    chmod +x "$part"
    mv "$part" "$init"
fi
# rustup checks every component it downloads against the release's signed manifest.
"$init" -y -q --no-modify-path --no-update-default-toolchain --profile minimal \
    --default-toolchain "$version" --target "$TARGET"
"$CARGO_HOME/bin/rustup" toolchain install --profile minimal "$version" --target "$TARGET" >/dev/null 2>&1
"$CARGO_HOME/bin/rustup" default "$version" >/dev/null
got=$("$CARGO_HOME/bin/rustc" --version)
case $got in "rustc $version "*) ;; *) echo "toolchain-rust: rustc is $got, not $version" >&2; exit 1 ;; esac
[ -d "$("$CARGO_HOME/bin/rustc" --print target-libdir --target "$TARGET")" ] ||
    { echo "toolchain-rust: no $TARGET standard library" >&2; exit 1; }
echo "$got with $TARGET in $ROOT"
