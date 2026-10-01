# FEX memory ordering: re-measured after the Wine plan, Proton's profiles per game, vector ordering's cost, LRCPC2

**Date:** 2026-09-28. **Plan:** [runtime risks](../plans/2026-09-27-runtime-risks.md),
item 4. **Decision:** [0021](../decisions/0021-fex-ordering-per-game.md).
**IPA:** dev, sha256
`a0add0d047db27d9110ecce0fe519d07bcae4b3fb156618a553ecb0c03109211`
(this branch: `patches/fex` 0008 and the app changes, on main `6a53077`);
section 8 plays the branch rebased onto main `78dc911`.
**Phone:** iPhone Air (`iPhone18,4`, A19 Pro), iOS 27.0, shared with other
agents' sessions between these runs. Run directories are in this worktree's
`$PLAYPORT_BUILD` (`ui-runs/fo-*`, `perf/hk-*`).

## 1. The gap still holds after the Wine plan

The [Wine-on-Proton plan](../plans/2026-09-27-wine-on-proton.md) ended as
`patches/wine-valve` ([decision 0018](../decisions/0018-valve-wine-as-a-series.md)),
which takes none of Valve's FEX or ARM64EC commits and does not touch FEX's
configuration ([its record](2026-09-28-wine-proton-rebase.md), section 4).
A Hollow Knight play on this IPA with the game's settings cleared
(`ui-runs/fo-default`, `pp ui --play app-367520 --until first-frame+10 --shot`:
JIT 3.28 s, game start +4.01 s, first frame +10.69 s) logs:

```
I 24 FEX: TSO config tso=true halfbar=true vector=false memcpyset=false rev=ml513
```

the same configuration as before the Wine plan. So the item holds and is not
struck.

## 2. Proton's FEX profiles, as data

Proton on ARM64 (ValveSoftware/Proton `bleeding-edge` `c9e0da9d736c`,
2026-09-26; `proton_11.0` `5b89db940e0e` has the same) gives FEX:

- a global configuration, `FEX_Config.json`, installed as
  `share/fex-emu/Config.json` and found through `FEX_APP_CONFIG_LOCATION`
  (added in Proton `e41d72322b`, 2025-03-28);
- a per-launch file, `FEX_APP_CONFIG`, written by `generate_fex_app_config`
  in the `proton` script: `Config` from Steam's `STEAM_FEX_TSOENABLED` and
  `STEAM_FEX_MULTIBLOCK` (or the user's `STEAM_COMPAT_FEX_CONFIG`), and
  `AppOverrides` from `fex_application_profiles` for `SteamGameId`
  (`c855778248`, fixed up in `b7a763327f`, 2026-07).

What they hold, and what this build does with each key:

| Key | Proton | This build's FEX default | Here |
| --- | --- | --- | --- |
| `TSOEnabled` | global 1 | 1 | ordering default, per-game override |
| `HalfBarrierTSOEnabled` | global 1 | 1 | ordering default, per-game override |
| `VectorTSOEnabled` | global 0 | 0 | ordering default, per-game override |
| `MemcpySetTSOEnabled` | global 0 | 0 | ordering default, per-game override |
| `X87ReducedPrecision` | global 1; The Witcher 3 (292030), `setup*`: 0 | 0 | the per-game entry is passed on; the global 1 is not taken |
| `Multiblock` | global 1 | 1 | passed on from a per-game entry (none has it) |
| `MaxInst` | global 500 | 5000 | passed on from a per-game entry (none has it); the global 500 is not taken |
| `ProfileStats` | global 1 | 0 | not taken: it writes Linux's stats shared memory |
| `STEAM_FEX_*` | Steam's own per-app data | | not public, not carried |

The four ordering values Proton ships are this build's own FEX defaults, so a
game without a profile keeps what it had. Proton's only per-game entry is for
The Witcher 3's setup programs (`setup*`); the app launches `witcher3.exe`, so
it does not apply to a Play (`FEXProfileTests` checks both cases). The
global `X87ReducedPrecision=1` and `MaxInst=500` would change every game's
code generation, and nothing here measured them; they are left for a
measurement of their own.

## 3. The per-game setting

PlayportKit `FEXProfile` holds the data above and resolves a launch: the
game's Steam app ID and executable name (matched as FEX matches
`AppOverrides`: `*` only, case-sensitive, first match), then the game's own
switches (`LaunchSettings.ordering`) over the profile. `LaunchCoordinator`
sets the result as `FEX_TSOENABLED`, `FEX_HALFBARRIERTSOENABLED`,
`FEX_VECTORTSOENABLED` and `FEX_MEMCPYSETTSOENABLED` (FEX's environment
layer, its highest), between the backend's variables and the player's own,
and logs it:

```
title: fex: ordering tso=1 halfbar=1 vector=1* memcpyset=0 (* the game's page; the rest Proton's defaults)
```

The game's page has an *x86 memory ordering* section with one picker per
switch, *Default (On/Off)* from the profile, *On* or *Off*. With
`{"ordering":{"vector":true}}` saved (`ui-runs/fo-set`, then `fo-page`):

vector on (screenshot not published)

and with the settings cleared (`fo-page-default`) every picker reads
*Default*: page-defaults.jpg (screenshot not published).

A Play with vector ordering on logs `vector=true` in FEX's own line (section 4).

## 4. Vector ordering's cost: Hollow Knight

`pp perf --secs 180 --pad first-frame+25:hk-new-game --cool 5 --cool-max 20
--shot first-frame+60`, one session, in this order:

| Run | Settings | FEX says | Battery, charger | Thermal | fps mean | frame ms | GPU ms | CPU work, all threads | main thread |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `hk-base-1` | `{}` | `vector=false`, `LRCPC2=1` | 39→36 %, no | nominal; pressure 10 from t=100 s | 99.7 | 9.88 | 7.68 | 52.6 Mi/f | 16.77 Mi/f |
| `hk-vector-1` | `{"ordering":{"vector":true}}` | `vector=true`, `LRCPC2=1` | 36→33 %, no | nominal throughout | 100.4 | 9.82 | 7.57 | 55.0 Mi/f | 17.46 Mi/f |
| `hk-nolrcpc2-1` | `FEX_HOSTFEATURES=disablelrcpc2` | `vector=false`, `LRCPC2=0` | 36→38 %, charger | nominal; pressure 10 from t=85 s | 101.9 | 9.67 | 7.41 | 53.8 Mi/f | 17.55 Mi/f |

CPU work is instructions per frame from the `[xp]` census, averaged over the
15 s samples from t=30 s (the play after the pad's New Game). Frame times are
over the whole 180 s.

- **Frame time: no cost.** From t=65 to 95 s, before either run's P cores
  were parked, all three ran at the panel's 120 Hz: 8.37, 8.34 and 8.35 ms,
  GPU 6.78, 6.78 and 6.75 ms. Hollow Knight here is held by the refresh rate
  and then by heat, not by its CPU threads, so vector ordering's barriers do
  not show in its frames.
- **CPU work: about 4 % more.** Vector ordering adds a barrier to each SSE
  load and store. All threads did 55.0 against 52.6 Mi/f (+4.6 %), the main
  thread 17.46 against 16.77 (+4.1 %). The 15 s samples of one run vary by
  about ±5 %, so with one run each this is an upper bound more than a
  measurement: the cost is small.

### The Witcher 3

`pp perf --title app-292030 --secs 200 --pad first-frame+10:witcher3-continue
--pad first-frame+50:witcher3-walk --shot first-frame+120`, launch settings
`{"screen":"720"}` with and without `"ordering":{"vector":true}`, in one
session in the order A B B A with 3 minutes' rest between runs. `--cool` was
not used: its reading had gone stale (section 6), so each run is judged by
its own start, and all four started at `nominal` (the app's own
`ProcessInfo.thermalState` at the launch), with no charger, from 80 % down
to 67 %. Every run loaded the Kaer Morhen save and walked the room (the
screenshots at first-frame+120).

| Run | FEX says | fps mean | frame ms | GPU ms | pressure 10 from | play (t=90-200 s): fps | frame ms | CPU work, all threads |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `w3-base-1` | `vector=false` | 48.9 | 20.44 | 18.62 | never | 40.2 | 25.29 | 269.0 Mi/f |
| `w3-vector-1` | `vector=true` | 47.3 | 21.15 | 18.62 | 60 s | 38.1 | 26.56 | 291.1 Mi/f |
| `w3-vector-2` | `vector=true` | 46.2 | 21.65 | 19.51 | 55 s | 38.7 | 26.14 | 286.9 Mi/f |
| `w3-base-2` | `vector=false` | 49.0 | 20.42 | 18.51 | 55 s | 39.5 | 25.62 | 279.9 Mi/f |

- **Vector ordering costs The Witcher 3 about 4 % of its frame rate.**
  Over the whole run, 21.40 against 20.43 ms a frame (+4.7 %); in the play
  after the save loads, 26.35 against 25.46 ms (+3.5 %), 38.4 against 39.9
  fps. Both vector runs are slower than both default runs, and the A B B A
  order puts the same thermal history on each side.
- **CPU work: about 5 % more.** 289.0 against 274.5 Mi/f in play (+5.3 %),
  the same share as Hollow Knight's.
- The Witcher 3 at 720p on this phone is held by its CPU threads and heat
  (the CPU at 370 % in play), so here the barriers reach the frames.
  w3-vector-play.jpg (screenshot not published) is
  `w3-vector-1` at first-frame+120.

## 5. LRCPC2 (`SupportsTSOImm9`)

`patches/fex-port` 0009 builds FEX's host features by hand, without
`SupportsTSOImm9`, and code at EL0 cannot read the ID registers on iOS.
The kernel reports the features through sysctl; `HostCPU.swift` logs them at
each launch:

```
title: fex: host FEAT_LRCPC=1 FEAT_LRCPC2=1 FEAT_LRCPC3=- FEAT_LSE2=1 FEAT_AFP=1; FEX_HOSTFEATURES enablelrcpc2
I 24 FEX: iOS host AFP=1 LRCPC2=1 (FEX_HOSTFEATURES=256)
```

- The A19 Pro has FEAT_LRCPC2. It is an Armv8.4 feature, and the plan's "A17
  and later" is not a limit the app needs: the app sets it from the kernel's
  answer on whatever chip it runs on, with no chip list.
- With it FEX emits a TSO load or store with an offset of -256 to 255 as one
  `LDAPUR`/`STLUR` instead of an address add and `LDAPR`/`STLR`
  (`Addressing.cpp`), and FEX's unaligned-access handler already backpatches
  both.
- Hollow Knight plays with it (every run above, and `fo-default`). Without it
  (`hk-nolrcpc2-1`) the main thread did 17.55 Mi/f against 16.77 (+4.7 %)
  and all threads 53.8 against 52.6 (+2.3 %): fewer instructions with it, as
  the code shape says, within the same noise as section 4. Frame time is the
  same.

So it is on wherever the kernel reports it (decision 0021).

## 6. Left open

- **`pp perf --cool` read a stale level.** A first attempt at The Witcher 3's
  pair waited in `pp perf`'s cooling loop on a pressure level of 20 from
  `thermal-follow.log`, whose follower had exited an hour earlier (it lives
  `FOLLOW_S`, 3600 s, after a run), and was stopped; the game never
  launched. Once the follower has exited, its last level is unknown, not
  current. That is not changed here; the pair above was run without
  `--cool`.
- Proton's global `X87ReducedPrecision=1` and `MaxInst=500` (section 2).

## 7. Tests

`pp test` (host, including `FEXProfileTests` and the `ordering` cases of
`LaunchSettingsTests`), `pp names` and `pp secrets` pass. The release variant
builds (`verify-ipa`: 70 checks).

## 8. The rebased head

The branch was then rebased onto main `78dc911`, which sets Steam's game ID
for a Steam game's launch; `LaunchCoordinator` now layers the `FEX_*`
variables together with that environment. The rebased head `ec5a32b` (dev IPA,
sha256 `a71090798c2ff98f50ed5f16cce5b7839773eeff99d2aa890157f53981ec5c6e`)
plays Hollow Knight with the game's settings cleared (`ui-runs/fo-gate`,
`pp ui --settings 'app-367520:{}' --play app-367520 --until first-frame+10
--shot`: JIT 3.42 s, game start +4.05 s, first frame +9.12 s), and its log
has:

```
title: fex: ordering tso=1 halfbar=1 vector=0 memcpyset=0
FEX: iOS host AFP=1 LRCPC2=1
FEX: TSO config tso=true halfbar=true vector=false memcpyset=false
environment: Steam's SteamAppId=367520, SteamGameId=367520, STEAM_COMPAT_APP_ID=367520
```

The measurements in sections 1 to 5 are on `a0add0d0` and were not repeated.
