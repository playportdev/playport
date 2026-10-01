# 0002: A Linux-only build

**Status:** accepted, 2026-09-24; the paired-host-at-every-launch statements are superseded by [0010](0010-jit-without-a-host.md)

## Decision

Playport builds, links, signs and verifies its IPA on one x86-64 Linux
workstation. No Mac, no Xcode installation and no Apple tool runs in the
pipeline. The inputs are host LLVM, llvm-mingw, xtool's SDK bundle made from
an `Xcode.xip`, Apple ld64 built for Linux, and a patched xtool
([BUILDING.md](../BUILDING.md)).

## Why

- The maintainer's only workstation is Linux, and the phone is paired with
  it for every JIT activation anyway.
- Every step is scriptable and reproducible on that host, so one command can
  build from pins, which the update tooling needs.

## Costs

- **Madeira's Xcode build is not used.** Its `build/*/build.sh` scripts run
  through `xcrun`/`clang` shims, and the reference app's link is reproduced
  with ld64 built from cctools-port, because the SDK's lld refuses the
  duplicate symbols Apple's linker merges.
- **No Metal compiler.** The three AIR helpers are hand-ported LLVM IR with an
  equivalence proof against Apple's output, and `dxmt_command.metal` is
  compiled on the device through an added winemetal slot. Both are Playport
  patches and code to maintain.
- **Carried patches.** Several patches exist only because of the Linux host
  (`Class: linux-build`), plus an llvm-mingw CRT rebuild for arm64ec.
- **SDK pin.** xtool's SDK comes from Xcode 26.6 (iOS 26.5), which caps the
  deployment target at iOS 26.5 until an iOS 27 SDK is used.
- **Checks without Xcode.** Signing and bundle structure are verified by
  `build/verify-ipa.py` instead of Apple's tools.

## What a Mac would remove

Madeira's own build scripts and link would run as written, the `linux-build`
patches, the ld64 port and the shims would not be needed, and the Metal
shaders could be compiled by Apple's compiler instead of being hand-ported or
compiled on the device. None of that changes what runs on the phone, and the
debugger-assisted JIT activation would still need a paired host at every
launch.
