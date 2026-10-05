# Resumed baseline build: verified IPA

## Result

The interrupted baseline build was resumed without a clean build, pin changes,
or source-tree resets on 2026-10-02. Unix and Wine PE were reused from their
completed stage stamps; FEX resumed in its existing Ninja build directory.
All remaining stages completed.

- Source HEAD at build: `4572cdc` (guest32 host-memory experiment).
- IPA: `.work/out/20261002-003833-c2023f0c/Playport-26.5-c2023f0c.ipa`.
- SHA256: `c2023f0c16a27a6a69076d9851c68e30e6c0cf1a076b7dd323f43eadeb204e3f`.
- `pp verify`: **70 checks passed, 0 failed**.
- `pp test` (including all three Swift packages): passed.
- `pp slots`: 150 slots, 149 calls; every call matches its slot.
- Subsequent `pp build --plan`: every tree, staging and notices unchanged;
  no trees need rebuilding.

**This is the existing x86-64 runtime, not working Portal 2 support.** The
checked guest32 memory experiment remains host-only and is not linked into the
app. The IPA has not been installed or run on the phone, so no launch, gameplay
or regression verdict is claimed. The phone's differently identified existing
app and all its data were left untouched.

## Restored inputs and records

The build used the locked inputs restored during
[the memory experiment](2026-10-02-guest32-memory.md): llvm-mingw 20260922 with
its rebuilt ARM64EC CRT, the patched xtool, Apple linker, Rust 1.98.1 and the
recorded iPhoneOS/MacOSX 26.5 SDKs. The owner approved the experimental
repo-local Windows toolchain. No pins or patch-series contents changed.
The large GStreamer archive was resumed from its partial download and verified
against its committed SHA256 before extraction.

The build regenerated `app/artifacts.tsv` and
`build/generated/wine-pe-aarch64-windows.tsv` in the default `.work/run` area.
The former has new hashes for FEX and the rebuilt DXMT/Vulkan PE DLLs, with
unchanged sizes. The latter differs only for the non-shipped `winetest.exe`;
all other Wine PE hashes, including the entire ARM64EC manifest, match the
committed baseline. These records now describe this restored build, not the
previous workstation's artifacts. This is not a claim of byte-for-byte
reproducibility across toolchain/CRT installations; the previous binaries are
not available here for a binary comparison.

The pipeline's series-content checks and IPA verification passed. The registry
seed needed no changes. The output directory retains `artifacts.tsv`,
`SHA256SUMS`, `pins.lock`, `provenance.txt` and the build/verification logs.
Full host-test output remains private in
`.work/tmp/portal2-restored-build-checks.log`.
