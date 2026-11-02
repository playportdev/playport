# Battle.net store on the phone: browse, install, region, language, art (2026-10-31)

**Linear:** [PLA-519](https://linear.app/playportdev/issue/PLA-519) (store, install),
[PLA-520](https://linear.app/playportdev/issue/PLA-520) (region and language),
[PLA-607](https://linear.app/playportdev/issue/PLA-607) (art); spec
[PLA-516](https://linear.app/playportdev/issue/PLA-516), decision
[0174](../decisions/0174-battle-net-store-client.md). The workstation install of the same
products: [2026-10-30-battlenet-install.md](2026-10-30-battlenet-install.md).

Main checkout, branch `dev/pla-516-battlenet`. Run directories are under `.work/ui-runs/`; the
screenshots stay there and are described here. Every run below was made on one of two IPAs:

- `2f36ea66dea1feed4c45907ea6306be5a7adbe75a7355d547911d6bada63e5d8` (branch at `31780685`;
  `30221af9` for the region and language runs, the same IPA): store, install, region, language.
- `9ee9987479c1eedfce817665aaf62f87335ee045b04afcb348e3b75991a1e32e` (branch at `326f2d43`):
  art.

## Store and product page (PLA-519)

Run `20261031T205729`, `--action open:battlenet --action open:bnet-wow_classic_era
--shot-each-action`, IPA `2f36ea66`:

- **The Battle.net chip** lists four products, all "Not installed": World of Warcraft, World of
  Warcraft Classic, World of Warcraft Classic Anniversary, World of Warcraft Classic Era, as plain
  colour tiles (no art on this IPA; PLA-607 below). Nothing else: no product without an ARM64
  client and no other Blizzard game. The chip row's Battle.net chip sat past the screen's edge
  (cut to "B"); commit `99b6df9d` scrolls the chosen chip into view, not yet run on the phone.
- **Classic Era's page** shows "Install · 4.73 GB", "Region · eu", "Needs 5.47 GB · 7.78 GB free
  · keep Playport open while it downloads", "No Battle.net account is needed to install. World of
  Warcraft asks you to sign in when it starts.", and a table: Store Battle.net, Download 4.73 GB,
  Space needed 5.47 GB, Region Europe (eu), Language enUS, Version 1.15.9.70576. Nothing asked
  for a sign-in.

## Space refusal (PLA-519)

Run `20261031T210112`, `--action set:battlenetInstallBytes=1000000000000000 --action
install:bnet-wow_classic_era --shot-each-action`, IPA `2f36ea66`. The dev setting makes the
page's space need 1,000 TB. The install was refused, and the driver's result is the page's
message: `refused: Not enough free space: 1000 TB needed, 7.78 GB free.` (log: `install
bnet-wow_classic_era: region eu, language enUS, download 4732186714, needs 1000000000000000, free
7776387196`). The run's one screenshot is Home after the setting; the refusal itself is in the
result and the log.

## Install with pause and resume (PLA-519)

Run `20261031T210327`, `--action set:battlenetInstallBytes=0 --action
pause-resume:bnet-wow_classic_era --shot-each-action`, IPA `2f36ea66`, from Blizzard's live CDN
over the phone's Wi-Fi:

```
install bnet-wow_classic_era: region eu, language enUS, download 4732186714, needs 5468028327, free 7776387196
install bnet-wow_classic_era: paused at 1.27 GB of 5.00 GB · 29.4 MB/s; phase=paused(nil) stage kept=true play=hidden
install bnet-wow_classic_era: resumed at 1.27 GB of 5.00 GB (downloading)
install bnet-wow_classic_era: Downloading 36% 1.83 GB of 5.00 GB · 14.9 MB/s
…
install bnet-wow_classic_era: in the library as bnet-wow_classic_era [Ready] version=1.15.9.70576 size=5291720744 exe=_classic_era_\WowClassic-arm64.exe machine=0xaa64 play=shown after 211 s
```

Paused, the download kept its staged data and Play was hidden; it resumed at the byte it paused
at, and Play showed only once the copy was complete. The copy is 5,291,720,744 bytes, and its
executable `WowClassic-arm64.exe` is ARM64 (PE machine `0xaa64`). The last screenshot is the
dimmed "Downloads finished" screen the app shows while it downloads untouched.

**Not run yet:** removing the installed copy, the last step of PLA-519's phone gate. The copy is
kept on the phone for PLA-514's runs.

## Region and language of the installed copy (PLA-520)

IPA `2f36ea66`, Classic Era installed (eu, enUS):

| Run | Action | Result |
| --- | --- | --- |
| `20261031T210835` | `region:bnet-wow_classic_era=us`, then `=eu` | `installed eu → us in 942 ms, no download; .build.info us/enUS`; `installed us → eu in 112 ms, no download; .build.info eu/enUS` |
| `20261031T210935` | `locale:bnet-wow_classic_era=deDE` | `installed enUS → deDE after 14 s; .build.info eu/deDE; receipt files=1541 bytes=5584700583; play=shown` |
| `20261031T211038` | `locale:bnet-wow_classic_era=enUS` | `installed deDE → enUS after 2 s; .build.info eu/enUS; receipt files=1541 bytes=5584700583; play=shown` |

- A region change rewrote `.build.info` and downloaded nothing, both ways.
- The language change to deDE downloaded only that locale's data: the receipt grew from the
  install's 5,291,720,744 to 5,584,700,583 bytes (+292,979,839, about 0.29 GB, against the
  install's 5.00 GB) in 14 s, and Play stayed available. Back to enUS took 2 s with no download:
  the enUS data was still in the store (the receipt is the same size).
- Screenshots: after the change to us the page's table says Region "Americas (us)", On this phone
  5.29 GB, Language "English (United States…"; after deDE it says Region "Europe (eu)", On this
  phone 5.58 GB, Language "German (Germany) · d…". Both pages show the Play button and the
  ban-risk notice's text (PLA-514). The action buttons in that row are cut to their first letter
  ("P", "R…", "L…", "C…") at this page width: the labels do not fit, though they work.

## Art (PLA-607)

Run `20261031T215422`, `--action open:battlenet --action open:bnet-wow --action
open:bnet-wow_classic_era --shot-each-action`, IPA `9ee99874` (commit `c52acf00`):

- **The Battle.net chip:** each of the four tiles has its picture from Blizzard's public image
  host behind the name: Classic Era (Ready), World of Warcraft (a download of the retail product
  had been started on the phone and showed "Downloading · 27%"), Classic and Classic Anniversary
  (Not installed).
- **World of Warcraft's page:** the hero behind the title is Blizzard's World of Warcraft key art
  with its logo, dimmed under the page; the page shows "Downloading 27% 37.0 GB of 133 GB · 57.3
  MB/s", Cancel, and Download 132 GB, Space needed 139 GB, Region Europe (eu), Language enUS,
  Version 12.1.5.70688.
- **Classic Era's page:** its own picture behind the page, with the installed copy's Play row
  and the ban-risk notice's text.

No art is in the repository; the app fetches and caches it (`BattleNetArtCache`).
