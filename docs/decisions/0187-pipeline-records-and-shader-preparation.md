# 0187: Pipeline records, and shader preparation at every Play

**Status:** accepted, 2026-11-13, by the owner (grilling session on cold shader compiles; spec [PLA-852](https://linear.app/playportdev/issue/PLA-852)). Not
built yet. Evidence: [cold shader compiles](../evidence/2026-11-13-cold-shader-compiles.md).
Companion records: [0185](0185-kosmickrisp-builds-cheaper-msl-under-one-compile-budget.md) and
[0186](0186-dxvk-skips-a-draw-whose-pipeline-is-still-compiling.md). Implements decision
[0012](0012-the-ui-is-the-only-entry-point.md)'s rule for the new control. Amended by
[0190](0190-kosmickrisp-writes-air.md): an entry holds the form it was compiled to (a metallib on
the AIR path), keyed by its final NIR and the AIR generation.

## Context

- **Apple's Metal cache makes a pipeline cheap, and Playport does not own it.** It lives in
  `Library/Caches`, which iOS purges under storage pressure, and an iOS update may invalidate it.
  - In October a KosmicKrisp rebuild cost about 10 ms a pipeline, because that cache still hit.
  - After the 10–11 Nov purge and update, the same MSL cost 145–412 ms.
- **Mesa's disk cache does not help.** A hit there saves only NIR to MSL, about 10 ms a pipeline,
  and its key changes with every KosmicKrisp build.
- **Playport can keep what a game compiled.** A record of a game's pipelines, kept where iOS
  does not purge it, can be compiled again through Metal ahead of the game. Apple's cache is then
  warm when the game asks.
- **A first play has no record.** Shipping records would mean distributing derivatives of games'
  shaders, so a first play relies on 0185 and 0186.

## Decision

- **A pipeline record per game.**
  - KosmicKrisp records each pipeline it compiles for a game: the stages' MSL, the Metal compile
    options and the Metal pipeline descriptor's fields, compute pipelines included.
  - The app keeps the record in `Library/Application Support`, excluded from backup.
  - It is capped per game (256 MB) and in total (1 GB).
  - Settings › Storage counts it and its Clear removes it; removing the game removes its record.
  - Dev and release alike.
- **Stale records are dropped.**
  - A record carries KosmicKrisp's MSL generation, a stamp that every MSL-changing patch moves.
  - A record of another generation is dropped and recorded afresh at the next Play.
  - After such an update the next play relies on 0185 and 0186.
- **Shader preparation at every Play.**
  - When a game starts, the app replays its record in the background, natively through Metal: no
    Wine and no Vulkan. It runs under KosmicKrisp's compile budget, behind the game's own builds
    (0185).
  - A warm replay takes seconds; a cold one runs ahead of the game.
- **Prepare shaders.**
  - The game page offers Prepare shaders when a record exists. It runs while Playport is in front
    and no game runs, and shows its progress.
  - It stops when the app leaves the front, and continues at the next press or Play.
  - The dev build's UI driver reaches it by a semantic `pp ui` path.
- **Nothing shipped.** No pipeline record is shipped with the app or downloaded.
- **Storage notice.** Home and Settings › Storage show a notice when free space falls below 2 GB
  (`pp install`'s threshold), saying iOS may delete shader caches below it.

## Why

- **Replay can only warm caches,** never render wrong. The game's pipelines are still built by its
  own path.
- **Recording at the Metal level** covers every API at once (DXVK, vkd3d-proton, native Vulkan,
  Zink). Replay needs nothing but Metal.
- **Replaying at every Play** needs no detector for a cold cache, and costs only seconds when
  everything hits.
- **Dropping a record on an MSL change** keeps replays from warming entries nothing will ask for.

## Costs

- **Phone storage:** up to 1 GB that iOS cannot reclaim. Clear is the way out.
- **More Metal work at every Play,** competing with the game for the compiler service. The budget
  puts the game first.
- **No help for a first play,** nor for the first play after an MSL-changing update.
