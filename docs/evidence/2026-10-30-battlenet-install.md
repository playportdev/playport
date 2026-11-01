# Battle.net store: WoW installed on the workstation (2026-10-30)

**Linear:** [PLA-517](https://linear.app/playportdev/issue/PLA-517) (spec
[PLA-516](https://linear.app/playportdev/issue/PLA-516); decision 0174 proposed). The phone's own
install, region and language changes: [2026-10-31-battlenet-store-phone.md](2026-10-31-battlenet-store-phone.md).

`BattleNetClientKit` (`app/BattleNetClient`, branch `dev/pla-517-install`) installed two products
from Blizzard's live CDN on the workstation, region us, locale enUS, through ContentKit's install
engine, with User-Agent `Playport`, at most 8 requests in flight, and the 429 back-off. Each run is
the env-gated live test; the install root is the shared folder the desktop Wine baseline (PLA-509)
uses, under the integration worktree's build area (`.work/worktrees/battlenet/.work/wow-install/`
in the main checkout):

```sh
BATTLENET_LIVE_INSTALL=wow_classic_era:<build area>/wow-install/wow_classic_era \
BATTLENET_LIVE_REPORT=$PLAYPORT_BUILD/live/era.md \
  ./pp test --swift BattleNetClient --filter testLiveInstall
BATTLENET_LIVE_X64=1 BATTLENET_LIVE_INSTALL=wow:<build area>/wow-install/wow \
BATTLENET_LIVE_REPORT=$PLAYPORT_BUILD/live/retail.md \
  ./pp test --swift BattleNetClient --filter testLiveInstall
```

Every config matched its name, every CDN index its name and hashes, every stored object its EKey
and block MD5s before it was written (with its local header), every product folder file its CKey.
After the install, `verify` read every journal entry's header and object back from the data
files, checked that every planned object is in a journal, and hashed every product folder file.

## WoW retail (`wow`), ARM64 and x64 clients

Installed 12:27–13:26 UTC into `wow-install/wow` (the folder PLA-509 runs `Wow.exe` from), with
the x64 client beside the ARM64 one (`BATTLENET_LIVE_X64=1`; see the notes). It completed and
verified intact:

| | |
|---|---|
| product | `wow` 12.1.5.70575 (build 70575), region us, enUS, regions kept: us eu kr tw |
| machines | arm64 + x86_64 |
| stored objects | 1,568,882, 132.53 GB (132,530,388,007 B) in 125 data files |
| product folder files | 44, 0.43 GB (427,427,364 B): 35 ARM64, 39 x64, 30 names shared |
| CDN reads | 78,743 planned (132.93 GB, 0.3% more than stored); 78,868 chunks written (with the 125 data files' heads), 133.00 GB |
| HTTP answers | 6,930 × 200 (configs, manifests, 1,483 indexes, loose objects), 73,306 × 206 (ranged archive reads); no 429, no other status |
| install attempts | 1 (no interruption, so no resume was needed) |
| prepare (configs, key ring, manifests, 1,483 indexes) | 33 s |
| install | 3,451 s (57.5 min, about 38 MB/s) |
| verify (every object and file read back) | 59 s: 1,568,882 objects, 132.53 GB, 44 files; intact |
| archive group built here matches its CDN name | yes |

`.build.info`:

```
Branch!STRING:0|Active!DEC:1|Build Key!HEX:16|CDN Key!HEX:16|Install Key!HEX:16|IM Size!DEC:4|CDN Path!STRING:0|CDN Hosts!STRING:0|CDN Servers!STRING:0|Tags!STRING:0|Armadillo!STRING:0|Last Activated!STRING:0|Version!STRING:0|Product!STRING:0
us|1|d718abcc42604d8efbd35aecfa5bb75b|2a6e419be5b7d7d896f7bc40395256dd|77d2e5d7fb7ea30d9361fb258ceb56c0|23106|tpr/wow|level3.blizzard.com us.cdn.blizzard.com|http://level3.blizzard.com/?maxhosts=8 http://us.cdn.blizzard.com/?maxhosts=4&fallback=1 https://level3.ssl.blizzard.com/?maxhosts=4&fallback=1 https://us.cdn.blizzard.com/?maxhosts=4&fallback=1|Windows arm64 x86_64 US? enUS speech?:Windows arm64 x86_64 US? enUS text?|||12.1.5.70575|wow
```

Layout (files per directory):

```
.build.info  689 B
Data/  1628 files, 132.90 GB
  config/2a/6e/  1 files      the CDN config
  config/3c/a5/  1 files      the key ring
  config/d7/18/  1 files      the build config
  data/  141 files            data.000–data.124 and 16 journals (generation 1)
  indices/  1484 files        as in era (the four products share the CDN config)
_retail_/  45 files, 0.43 GB
  ./  8 files                 Wow-ARM64.exe, Wow.exe, wow_loader.dll, libxell.dll,
                              GFSDK_Aftermath_Lib.x64.dll, BlizzardError.exe, icudt78l.dat,
                              .flavor.info
  D3D12/  2 files             the x64 Agility SDK
  D3D12_ARM64/  2 files       the ARM64 Agility SDK
  Utils/  20 files
  Utils/LOCALES/  11 files
  Utils/swiftshader/  2 files
```

## WoW Classic Era (`wow_classic_era`), the quick end-to-end check

Installed 12:23–12:27 UTC into `wow-install/wow_classic_era`, ARM64 only:

| | |
|---|---|
| product | `wow_classic_era` 1.15.9.70576 (build 70576), region us, enUS, regions kept: us eu kr tw |
| stored objects | 145,682, 4.77 GB (4,767,915,577 B) in 5 data files: PLA-510's us selection (145,431) plus the 7 `EU`-only objects plus root, encoding, install, download, size, the patch index and 240 `vfs-*` manifests |
| product folder files | 31, 0.23 GB (227,286,648 B) |
| CDN reads | 8,568 planned (4.91 GB, 3% more than stored: the gaps ranged reads span); 8,573 chunks written (with the 5 data files' heads), 5.00 GB |
| HTTP answers | 1,810 × 200 (configs, manifests, 1,483 indexes, loose objects), 8,250 × 206 (ranged archive reads); no 429, no other status |
| install attempts | 1 (no interruption) |
| prepare (configs, manifests, 1,483 indexes) | 26 s |
| install | 186 s (about 26 MB/s) |
| verify (every object and file read back) | 12 s: 145,682 objects, 4.77 GB, 31 files; intact |
| archive group built here matches its CDN name | yes |

`.build.info`:

```
Branch!STRING:0|Active!DEC:1|Build Key!HEX:16|CDN Key!HEX:16|Install Key!HEX:16|IM Size!DEC:4|CDN Path!STRING:0|CDN Hosts!STRING:0|CDN Servers!STRING:0|Tags!STRING:0|Armadillo!STRING:0|Last Activated!STRING:0|Version!STRING:0|Product!STRING:0
us|1|5604ce35a8644bdcf0e26c1daf979c15|2a6e419be5b7d7d896f7bc40395256dd|cd12613e3f4b2948db868e05eaa495ba|23234|tpr/wow|level3.blizzard.com us.cdn.blizzard.com|http://level3.blizzard.com/?maxhosts=8 http://us.cdn.blizzard.com/?maxhosts=4&fallback=1 https://level3.ssl.blizzard.com/?maxhosts=4&fallback=1 https://us.cdn.blizzard.com/?maxhosts=4&fallback=1|Windows arm64 US? enUS speech?:Windows arm64 US? enUS text?|||1.15.9.70576|wow_classic_era
```

Layout (files per directory):

```
.build.info  687 B
Data/  1507 files, 5.06 GB
  config/2a/6e/  1 files      the CDN config
  config/56/04/  1 files      the build config
  data/  21 files             data.000–data.004 and 16 journals (00…0f, generation 1)
  indices/  1484 files        1,402 archive indexes, 81 patch-archive indexes, the file index,
                              the patch file index and the archive group
_classic_era_/  32 files, 0.23 GB
  ./  3 files                 WowClassic-arm64.exe, BlizzardError.exe, .flavor.info
  Utils/  16 files
  Utils/LOCALES/  11 files
  Utils/swiftshader/  2 files
```

## Notes

- **The archive group** this client builds (every archive index's entries merged by key, each
  with its archive's place in the CDN config's list, in the index format with 6-byte offsets)
  hashes to the name the CDN config gives it, so it is byte for byte the one Blizzard's installer
  builds; it is written to `Data/indices`.
- **Region-tagged data for all four regions** is in the store, so a region change (PLA-520) is
  a `.build.info` rewrite only: the store has the us selection plus the 7 (era) objects tagged
  `EU` only, as PLA-510's sizes predicted.
- **Stored objects beyond the download manifest:** root, encoding, install, download, size, the
  patch index and every `vfs-*` manifest (240 in era). The patch manifest is not stored: its
  name is not the MD5 of its bytes (checked live on era's), so nothing checks it, and the game
  fetches it itself.
- **The x64 client in the retail product folder** (for PLA-509): the x64 and ARM64 clients share
  names under `Utils` with different builds of the file (retail: `BlizzardBrowser.exe`,
  `chrome_elf.dll`, `discord_partner_sdk.dll`, `libcef.dll`, `libEGL.dll`, `libGLESv2.dll`,
  `snapshot_blob.bin`, `v8_context_snapshot.bin`, `vivoxsdk.dll`, `WowVoiceProxy.exe`). With
  `x64Client` the x64 file is kept, so `Wow.exe` has its helpers and `Wow-ARM64.exe` is present
  but its in-game browser and voice helpers are the x64 builds. A phone install selects ARM64
  only and has no such collision.
- **Not yet checked by the game** (PLA-509 decides): the `.build.info` column set (14 columns,
  no `KeyRing`), the `Tags` value, the data files' sixteen header-only entries (their keys and
  flags), and the journals' update section (zeros after a 4 KiB boundary, at least 0x30000
  bytes). `.patch.result` is not written.
- **Hosts:** the client ranks the `cdns` row's HTTPS servers first (the phone's transport
  security refuses plain HTTP), and those are `fallback=1` today, so it asks
  `https://level3.ssl.blizzard.com` first. A single 100 MB ranged read (curl) measured 19 MB/s
  from it against 64 MB/s from `https://us.cdn.blizzard.com`; the installs ran at 26–38 MB/s with
  8 requests in flight, likely bound by that host [inference: the runs do not record which host
  answered].
