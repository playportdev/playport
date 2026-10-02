# Witcher 3: receipt hidden by the classic cohort pin

## Result

**The catalogue's “No executable” bug is corrected and checked on the phone.**
The installed public build is recognised as a Steam install, the game page has
Play, and Game options shows build **25646871** and
`bin\x64_dx12\witcher3.exe`. No game files were replaced or downloaded, and
Playport was upgraded in place.

**This is not a successful gameplay test.** Play now reaches the executable,
but it exits before the first frame with `0xc000001d` (illegal instruction).
The same instruction fails on DXMT and on an explicitly selected Vulkan
backend. AVX support in the current iOS FEX host is disabled; the failing game
instruction is AVX. That runtime blocker remains unfixed.

Final dev IPA: `.work/out/20261002-121049-b9ea8819/Playport-26.5-b9ea8819.ipa`

SHA256: `b9ea8819b20be3cce670a534ab1f40e230dd9a282916b691e87c83ff8be196d5`

## Cause and correction

The Steam receipt under `Library/Application Support/Playport/installs/292030.json`
records public build 25646871, 68,844,142,712 bytes, and
`redprelauncher.exe`. The folder contains `bin/x64_dx12/witcher3.exe`
(90,674,640 bytes), but **no `bin/x64` folder**.

Adoption matched the folder name `The Witcher 3` against the bundled cohort
*before* reading the receipt. It therefore advertised classic build 3280809,
41.6 GB and the classic checksum list, and looked only for
`bin\x64\witcher3.exe`. That file was correctly absent from the new build.

`app/PlayportKit/Sources/PlayportKit/Catalog.swift` now gives the receipt
precedence: the actual build, depots, branch and size win, and verification
uses the installed Steam manifests, not classic's checksum list. Launch
arguments and runtime keys from the cohort apply only to a staged pin or a
receipt for the exact pinned app and build (preserving Hollow Knight's log
argument and classic Witcher 3's reservation requirement).

Steam's REDprelauncher is also skipped in receipt resolution and executable
discovery. It starts the game as another process, which this runtime cannot
run; discovery selects the nested game executable instead. A launcher alone
never makes the title playable. No cohort pin was moved.

## Checks

- `./pp test`: all passed, including 110 PlayportKit tests. The regression
  covers modern and classic receipts, case-insensitive matching, the actual
  depot and size metadata, dropped stale verification, preserved play history,
  old receipts without an executable, and a missing game with only a launcher.
- `./pp install`: verified dev IPA (71 IPA checks), upgraded in place. The
  initial build reran DXMT and refreshed its two `d3d11.dll` hashes in
  `app/artifacts.tsv`; Wine PE manifest records stayed unchanged.
- `.work/witcher-diagnosis/before`: UI reproduced “No executable” on the
  previously installed IPA, SHA256
  `5da2c674ba011b1f595fe94e3e3f37d24f3d7bec69902cee42aeeb80688646ca`.
- `.work/witcher-diagnosis/final-ui`: `open:app-292030` and
  `open:app-292030#developer`, with screenshots after each. The page shows
  **The Witcher 3: Wild Hunt — Remastered**, Play and 68.8 GB. The developer
  section shows build 25646871 and the nested DX12 executable. The library
  logs `[Ready]` (executable found, not a compatibility verdict).
- `.work/witcher-diagnosis/hk-regression`: Hollow Knight, scripted controller,
  `first-frame+10`, passed; first frame at 10.19 s, no pool exhaustion.
- `.work/witcher-diagnosis/final-play-vulkan`: Witcher 3, scripted controller,
  Vulkan selected through Game options for this session only, requested
  `first-frame+10`. Runtime started at 4.63 s, game started at 4.77 s,
  exited at 5.56 s with `0xc000001d`; **no first frame**. JIT and self-check
  passed, no pool exhaustion. The temporary graphics setting was restored
  at the automatic restart. The earlier DXMT play in
  `.work/witcher-diagnosis/play` failed at the same game RVA.

The Vulkan run's log identifies `witcher3.exe+0x27ebd9f` as the failing
instruction and records bytes `c5 f8 29 74 24 50`:
`vmovaps [rsp+0x50], xmm6` (128-bit VEX/AVX store). FEX reports “Invalid
instruction in entry block”; `Source/Windows/Common/CPUFeatures.cpp` in the
patched FEX tree sets `SupportsAVX = false` for the iOS host. Enabling or
implementing the required AVX path needs its own runtime change and phone
validation; executable discovery does not establish that the latest game
build can run.

Screenshots and raw logs stay under `.work/witcher-diagnosis/`.
