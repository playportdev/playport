# Building on an Apple silicon Mac

The pipeline (`pp build`) is written for an x86-64 Linux workstation. On a Mac
the tree stages run in an arm64 Linux container, and the app is built and
signed by Xcode instead of xtool:

| Where | What |
| --- | --- |
| Docker (`build/docker/Dockerfile`) | `pp build --to stage` (or `--to notices`): every tree, `app/Staged/`, `app/Sources/S1Probe/Runtime/`, `app/Sources/WinIOS/` |
| the Mac | `app/Xcode/project.yml` (XcodeGen): the app and its JIT helper from `app/Package.swift`, signed by the Xcode team, installed with `devicectl`; the same project builds a UI-only simulator app |

## Once

Docker Desktop with at least 12 GB of memory, Xcode 27.1 or later, and
`brew install xcodegen`.

```sh
docker build --platform linux/arm64 -t playport-build build/docker
docker volume create playport-w
docker run -d --name playport-builder -v playport-w:/w -v "$PWD":/mac:ro playport-build sleep infinity
docker exec playport-builder git clone /mac /w/playport
```

The repository and its `.work/` live on the `playport-w` volume (ext4): Wine's
tree does not build on the Mac's case-insensitive APFS through a bind mount.

**The darwin SDK** is Xcode's own: `iPhoneOS.sdk` and `MacOSX.sdk` packed into
the volume under the names `env.sh` expects (`iPhoneOS26.5.sdk`,
`MacOSX26.5.sdk`), the layout of xtool's bundle, then
`build/docker/sdk-tbd.py /w/darwin-sdk`: Xcode 27's stubs name an `arm64e.x1`
architecture that LLVM 22's linkers reject.

**llvm-mingw** is the `ubuntu-22.04-aarch64` build of the release
`docs/BUILDING.md` names, with the arm64ec CRT rebuilt:
`build/docker/llvm-mingw.sh /w/llvm-mingw`.

Then, in the container's `/w/playport`:
`./pp setup --llvm-mingw /w/llvm-mingw --darwin-sdk /w/darwin-sdk`.

## Each build

1. In the container: `XTOOL=/w/xtool-stub ./pp build --to notices` (`--to stage`
   leaves Settings › About › Licences empty). The app and verify stages are
   xtool's and do not run here; `/w/xtool-stub` is any executable naming
   `INCREASED_MEMORY_LIMIT`, which the inputs check looks for.
2. On the Mac: `app/Xcode/sync-staged.sh` copies the staged pieces out of the
   container and makes the simulator's copies (`simulator-staged.py`).
3. `cp app/Xcode/Local.xcconfig.example app/Xcode/Local.xcconfig` once, with
   the team and a bundle ID of your own; then `cd app/Xcode && xcodegen` and
   build the `Playport` scheme for the phone (Xcode, or
   `xcodebuild -allowProvisioningUpdates`), or run `app/Xcode/simulator-run.sh`
   for the simulator.
4. The release variant (`Playport.app`, decision 0009), to compile it: on the Mac,
   `python3 build/stages/stage-artifacts.py release` makes `app/.release`, then
   `cd app/.release && PLAYPORT_VARIANT=release xcodebuild -scheme Playport
   -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO build`. It is
   another app with its own container, so installing it starts from setup.

## What differs from the Linux workstation

- Host tools are arm64: `build/toolchain/rust.sh` and `build/idevice-crates.py`
  take the host's own Rust triple, and Wine's host-tools configure finds
  llvm-mingw on an aarch64 host (Wine refuses `--without-mingw` there). The
  notices stage takes the Rust documentation from that toolchain and still
  checks it against the locked x86_64 archive (the notice files are the same bytes).
- The app is linked by Xcode's linker and signed by Xcode with the team's
  Increased Memory Limit; `pp verify` and `pp install` are not run.
- The simulator build is the UI only: the device archives and frameworks are
  rewritten for the simulator platform, Mesa's drivers (Metal 4) and MetalFX are
  stand-ins, and the JIT helper is left out. No game runs in a simulator.
