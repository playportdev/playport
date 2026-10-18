# Steam's per-game FEX settings: where they come from, what 620 and 367520 carry (source and PICS reading)

**Date:** 2026-10-17. **Linear:** [PLA-76](https://linear.app/playportdev/issue/PLA-76),
alignment item B6. **Kind:** a reading of public data and source. There was no build,
no install and no phone run, and nothing at runtime changed: this was done in a
host-only side copy (decision 0069). **Read:**
- ValveSoftware/Proton bleeding-edge 47c39230, the `proton` script.
- The desktop Steam client installed on this workstation, read-only: its
  `appcache/appinfo.vdf` and the `steamui` JavaScript bundle (`sp.js`, English
  localization). No owner sign-in was used and no Steam file was changed.
- Public PICS records fetched with `steamcmd +login anonymous +app_info_print <id>`
  (2026-10-17 22:45 UTC). steamcmd ran from the side copy's build area, with `HOME` set
  inside it.
- Playport at a9d0b95: `app/SteamClient`.

## 1. What Proton reads

`generate_fex_app_config` (`proton`, bleeding-edge, about line 1695) writes the
per-launch file that `FEX_APP_CONFIG` names. Its comment says "appinfo based environment
variable as default". The commit that added it is bc654648, "proton: Add support for
Steam appdata and user FEX config", from 2025-03.

The file's `Config` is built in this order, each step overriding the one before:
1. `STEAM_FEX_TSOENABLED` gives `TSOEnabled`, and `STEAM_FEX_MULTIBLOCK` gives
   `Multiblock`. Each value is copied as given, and only when it is set.
2. `STEAM_COMPAT_FEX_CONFIG`, the user's override, sets both keys from a
   `Key:0|1,…` string. Any key the string does not hold as `:1` becomes `"0"`.
3. Proton's `fex_application_profiles` entry for `SteamGameId` goes in as
   `AppOverrides`.

## 2. Where Steam gets them

**TSO: an appinfo key, `appinfo/common/steam_frame_compatibility/configuration/tso_enable`.**
- The key sits in the Steam Frame review block, next to `category`, `tests`,
  `recommended_runtime`, `fdm_debug` and `rpo_debug`.
- The desktop client's UI shows it under a game's properties as *ARM Translation Memory
  Ordering* ("Enable TSO compatibility mode"). There are three options:

  | Value | Option |
  | --- | --- |
  | 0 | Auto |
  | 1 | Force On |
  | 2 | Force Off |

  The enum is in `sp.js`, in the module that defines the three options.
- The UI reads two values:
  - `deckDerivedProperties.tso_enable`, the appinfo value, which defaults to Auto;
  - the user's own `eTSOEnable`, saved with `SteamClient.Apps.SetTSOEnable`.

  It marks the setting as changed when the two differ.
- Which value becomes `STEAM_FEX_TSOENABLED`, and how, is not visible here. The
  variable's name is not in the x86 client's binaries. It would be in the ARM64 client,
  which this workstation does not have. The likely mapping is inferred, not read: Auto
  sets nothing (FEX keeps `TSOEnabled=1` from Proton's `FEX_Config.json`), Force On sets
  `1` and Force Off sets `0`.

**Multiblock: no appinfo key.**
- None of the records read here has a key for it (the search covered `fex`,
  `multiblock` and `tso` over every key path).
- The only Multiblock in the client is the per-user *Override ARM Translation Options*
  switch. Its defaults are `ThunksDB_GL:0,ThunksDB_Vulkan:0,Multiblock:1`, and it is
  saved with `SpecifyCompatExperiment`. Its string form is the format that Proton's
  `STEAM_COMPAT_FEX_CONFIG` parses.
- What feeds `STEAM_FEX_MULTIBLOCK` is not known.

## 3. What the apps carry

The values were read through steamcmd's anonymous session. The desktop client's cache
gave the same for every app it holds. In the `category` column, 1 means unsupported,
2 playable and 3 verified, as on the Deck.

| App | `steam_frame_compatibility` | `category` | `tso_enable` |
| --- | --- | --- | --- |
| Portal 2 (620) | present | 3 | 0 (Auto) |
| Hollow Knight (367520) | **absent** (not reviewed) | none | none |
| The Witcher 3 (292030) | present | 1 | 0 |
| Red Dead Redemption 2 (1174180) | present | 1 | 0 |
| Cyberpunk 2077 (1091500) | present | 2 | 0 |
| Baldur's Gate 3, Sekiro, Dark Souls III, HITMAN WoA, Phasmophobia | present | 1 | 0 |
| BioShock Infinite, Hades, Hades II, Celeste, Dead Cells, Cuphead, Balatro, Factorio, Dave the Diver, Hollow Knight: Silksong | present | 3 | 0 |
| Vampire Survivors, RimWorld | present | 2 | 0 |
| FlatOut 2, Crimson Desert Enhanced (desktop cache only) | present | 2, 1 | 0 |
| ELDEN RING, Stardew Valley, Terraria, Dota 2 and 88 other titles read | absent | none | none |

- 115 public records were read (one more app ID returned none). 21 carry the block, and every
  `tso_enable` among them is 0 (Auto). None is
  Force On or Force Off.
- Steam's ARM64 tool list (app 3043620, *Steam Frame ARM64 Compat List*) names Proton
  Experimental (ARM64), Proton 11.0-2 (ARM64), `fex` and Steam Linux Runtime 4.0 arm64.
  It carries no FEX settings.

## 4. What Playport's PICS client keeps

- **Received:** the full text record of each app.
  - `SteamSession.productInfo` sends `CMsgClientPICSProductInfoRequest` with
    `metaDataOnly` false (`Wire/Schemas.swift:412-430`). It parses each app's buffer
    whole, as text KeyValues (`Content/Library.swift:177-215`, the `parseText` call
    at :195).
  - `appRecords` returns those records (`Library.swift:279-289`). The anonymous
    fallback in `SteamService.appInfo` reaches the same public records
    (`Service/SteamService.swift:545-561`).
  - `common/steam_frame_compatibility/…/tso_enable` is therefore in the `KeyValue`
    that Playport holds.
- **Not kept:** `SteamAppInfo.parse` (`Service/SteamApp.swift:80-112`) reads `common`
  name, type, oslist, osarch, associations, art and `controller_support`, and
  `config` installdir and launch. It reads nothing from `steam_frame_compatibility`.
  `SteamAppInfo`, the struct that is cached as JSON, has no field for it
  (`SteamApp.swift:7-44`). The raw record is dropped after parsing.
- **Test:** none was added. No PICS record fixture holds the block. The tests' inline
  records (`CloudTests.swift`, `InstallTests.swift`) carry only the keys their code
  reads.

## 5. Conclusion

There is nothing to carry today.
- The one public per-game FEX value, `tso_enable`, is 0 (Auto) for every reviewed
  title, Portal 2 included. Auto is the setting that leaves FEX at Proton's global
  `TSOEnabled=1`, which Playport already uses by default (decision 0021).
- Hollow Knight has no Frame review block.
- No appinfo key for Multiblock exists.

Decision 0021 says Steam's values are "not public". That is now only half true: the TSO
value is public PICS data, and the Multiblock value is still not found. The decision is
unchanged, because nothing is carried.

**When to reopen:** a played title's record has `tso_enable` 1 or 2, or a Multiblock
key appears. The design then:
1. `SteamAppInfo` reads the path into an optional field (`frameTSOEnable`), cached like
   `controllerSupport`.
2. `LibraryModel` passes it to `FEXProfile.launch` as a layer between Proton's
   `fex_application_profiles` entry and the game page's picker. Force On or Force Off
   sets the `TSOEnabled` default; Auto leaves it unchanged; the page and a player's
   `FEX_*` variable still win. Shown on the game's page as the default's source.
3. If B4 is implemented by then, it goes in the same `FEX_APP_CONFIG` file.
4. A decision record amending 0021 (remote data feeding a launch default), with host
   tests on a fixture record and a Hollow Knight first frame+10 gate.
