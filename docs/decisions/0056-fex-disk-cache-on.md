# 0056: FEX's disk cache: Proton's default, held off until a warm-start crash is fixed

**Status:** accepted, 2026-10-06, by the owner; **the default is held off** (below).
Item B1 of the
[Proton alignment plan](../plans/2026-10-05-proton-arm64-alignment.md); changes the
"stays off" outcome of the
[first-run stutter evidence](../evidence/2026-09-26-first-run-stutter.md). The
measurements are in the [evidence record](../evidence/2026-10-06-fex-disk-cache.md).

## Decision

- **The aim is `FEX_DISKCACHE=1` for every launch** (Proton `09d3d6e5`, experimental
  and bleeding-edge), in both variants. **Held:** every launch passes
  `FEX_DISKCACHE=0` until a warm start of Hollow Knight stops crashing (Costs);
  turning the default on is then a one-line change (`FEXProfile.defaultDiskCache`)
  and an evidence record, not a new decision. When on, FEX keeps translated code in the prefix at
  `C:\users\playport\AppData\Local\fex-emu\DiskCache` and reuses it on later starts.
- **A game's page overrides it** in a dev build (*Disk cache*: Default/On/Off,
  `LaunchSettings.diskCache`, decision 0034).
- **WoW64 processes keep it off** (`patches/fex` 0022): a 32-bit guest's code carries
  its window's host base as a constant the cache's key does not cover.
- **The cache's key includes the iOS TEB slot offset** (`patches/fex` 0021): every
  TEB read bakes it into the code, and it differs between launches; without it a
  warm start of The Witcher 3 read the wrong slot and crashed.
- **Budget: 5 GB, or 10 GB left on the phone.** Before a launch the app clears the
  whole cache when it is larger than 5 GB or the phone has under 10 GB free; FEX
  fills it again from that launch. Proton sets no total limit, and FEX itself prunes
  only on a machine-bucket change. The budget is generous because clearing costs
  every game a cold start, and a game's database grows as more of it is played.
- **Settings › Storage › Emulator cache** shows its size and clears it (decision
  0012: the UI is the way in).

## Why

Proton's direction is the default here (0049, 0055), once it is safe. A warm start reuses 99.99 % of
its blocks: The Witcher 3 reached its first frame 1.5–2 s sooner (16.1–16.5 s
against 17.6–18.5 s) in six starts with the fix. The September evidence found no
fewer hitches in Hollow Knight's play, so the gain is start time and less
compiling, not frame pacing.

## Costs

- **Why it is held.** With the cache on, every warm start of Hollow Knight crashed
  in FEX's start-up, before any cached code ran: `[rpm-avail] CORRUPT op=to_free
  bad=0x100 class=0x74` in rpmalloc inside `xtajit64.dll`, 8 of 8 warm starts on
  two TEB slots, also after clearing the cache. This is the September signature
  (`HEAP WAS ZEROED`, `page_available_to_free`); The Witcher 3's warm starts do not
  hit it. Its cause is not found.

- Disk: about 83 MB for a game's first minute per TEB slot offset (two offsets
  seen), growing with play, up to the 5 GB budget.
- A cached block is only as right as the cache's key. Two iOS-only constants were
  found baked into code (the TEB slot, the WoW64 window base); another such constant
  would show as a crash on a warm start that a cold one does not have. The page's
  *Off* and Settings' *Clear* are the way back for a game.
- Not run with the cache on yet: Hollow Knight and Portal 2 warm starts on this
  build (the evidence record says what was).
