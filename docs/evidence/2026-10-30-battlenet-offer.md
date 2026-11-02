# Battle.net store: which World of Warcraft products are offered (2026-10-30)

**Linear:** [PLA-510](https://linear.app/playportdev/issue/PLA-510) (spec
[PLA-516](https://linear.app/playportdev/issue/PLA-516); decisions 0170, 0174 proposed).

`BattleNetClientKit` (`app/BattleNetClient`, commit `15813b9`) asked Blizzard's live endpoints for
every product on the fixed list in every store region, on the workstation, 2026-10-30 at about
11:55 UTC, with User-Agent `Playport`:

```sh
BATTLENET_LIVE_REPORT=$PLAYPORT_BUILD/bnet-live.md ./pp test --swift BattleNetClient --filter testLiveOffersAndSizes
```

Per product and region: the version endpoint's row (Ribbit v2 over HTTPS), the CDN row, the product
config, the build config and the install manifest, then the size manifest (once per build). Every
config matched its name (MD5), every BLTE object its EKey and block MD5s, every decoded manifest
its CKey. The run finished without an error in about 28 s. CDN requests went to the HTTPS servers
the `cdns` rows name, primaries before fallbacks (no CDN row has an HTTPS primary today, so the
HTTPS fallbacks come first); a server that fails is passed over, so this run does not record which
host answered.

## Result

Every product is **offered** in every region: each build's install manifest lists the product
config's ARM64 executable tagged `Windows` and `arm64`.

Sizes are for the Windows ARM64 client, locale `enUS`, the row's region tag, `speech` and `text`,
without `Alternate`. *Download* is the size manifest's selection: the stored objects, encoded, as
the store keeps them. *Install* adds the product folder's files (the install manifest's selection,
decoded). Neither counts the store's own indexes (about 125 MB of archive indexes) or the local
headers, which PLA-517 adds when it plans an install.

| product | region | version | build | offered | ARM64 client | download | install | of which product folder | objects |
|---|---|---|---|---|---|---|---|---|---|
| wow | us | 12.1.5.70575 | 70575 | yes | `Wow-ARM64.exe` 75970768 B | 131.87 GB (131866560943 B) | 132.14 GB (132144486903 B) | 0.28 GB (277925960 B) | 1567982 |
| wow | eu | 12.1.5.70575 | 70575 | yes | `Wow-ARM64.exe` 75970768 B | 131.87 GB (131866624707 B) | 132.14 GB (132144550667 B) | 0.28 GB (277925960 B) | 1567990 |
| wow | kr | 12.1.5.70575 | 70575 | yes | `Wow-ARM64.exe` 75970768 B | 131.87 GB (131866560943 B) | 132.14 GB (132144486903 B) | 0.28 GB (277925960 B) | 1567982 |
| wow | tw | 12.1.5.70575 | 70575 | yes | `Wow-ARM64.exe` 75970768 B | 131.87 GB (131866560943 B) | 132.14 GB (132144486903 B) | 0.28 GB (277925960 B) | 1567982 |
| wow_classic | us | 5.5.4.70631 | 70631 | yes | `WowClassic-arm64.exe` 62027472 B | 79.96 GB (79959129993 B) | 80.19 GB (80189127681 B) | 0.23 GB (229997688 B) | 503354 |
| wow_classic | eu | 5.5.4.70631 | 70631 | yes | `WowClassic-arm64.exe` 62027472 B | 79.96 GB (79959197305 B) | 80.19 GB (80189194993 B) | 0.23 GB (229997688 B) | 503361 |
| wow_classic | kr | 5.5.4.70631 | 70631 | yes | `WowClassic-arm64.exe` 62027472 B | 79.96 GB (79959129993 B) | 80.19 GB (80189127681 B) | 0.23 GB (229997688 B) | 503354 |
| wow_classic | tw | 5.5.4.70631 | 70631 | yes | `WowClassic-arm64.exe` 62027472 B | 79.96 GB (79959129993 B) | 80.19 GB (80189127681 B) | 0.23 GB (229997688 B) | 503354 |
| wow_classic_era | us | 1.15.9.70576 | 70576 | yes | `WowClassic-arm64.exe` 59313872 B | 4.73 GB (4732119402 B) | 4.96 GB (4959406050 B) | 0.23 GB (227286648 B) | 145431 |
| wow_classic_era | eu | 1.15.9.70576 | 70576 | yes | `WowClassic-arm64.exe` 59313872 B | 4.73 GB (4732186714 B) | 4.96 GB (4959473362 B) | 0.23 GB (227286648 B) | 145438 |
| wow_classic_era | kr | 1.15.9.70576 | 70576 | yes | `WowClassic-arm64.exe` 59313872 B | 4.73 GB (4732119402 B) | 4.96 GB (4959406050 B) | 0.23 GB (227286648 B) | 145431 |
| wow_classic_era | tw | 1.15.9.70576 | 70576 | yes | `WowClassic-arm64.exe` 59313872 B | 4.73 GB (4732119402 B) | 4.96 GB (4959406050 B) | 0.23 GB (227286648 B) | 145431 |
| wow_anniversary | us | 2.5.6.70577 | 70577 | yes | `WowClassic-arm64.exe` 59524816 B | 6.32 GB (6322412372 B) | 6.55 GB (6549909964 B) | 0.23 GB (227497592 B) | 173617 |
| wow_anniversary | eu | 2.5.6.70577 | 70577 | yes | `WowClassic-arm64.exe` 59524816 B | 6.32 GB (6322479688 B) | 6.55 GB (6549977280 B) | 0.23 GB (227497592 B) | 173624 |
| wow_anniversary | kr | 2.5.6.70577 | 70577 | yes | `WowClassic-arm64.exe` 59524816 B | 6.32 GB (6322412372 B) | 6.55 GB (6549909964 B) | 0.23 GB (227497592 B) | 173617 |
| wow_anniversary | tw | 2.5.6.70577 | 70577 | yes | `WowClassic-arm64.exe` 59524816 B | 6.32 GB (6322412372 B) | 6.55 GB (6549909964 B) | 0.23 GB (227497592 B) | 173617 |

## Notes

- All four regions have the same build of each product today; the client still reads each
  region's row, since Blizzard stages rollouts per region.
- The eu selection has 7–8 more objects (about 64–67 KB) than us, kr and tw: data tagged `EU` only.
  The install manifests have no region-only files.
- The smallest offered product is `wow_classic_era` (4.73 GB download, 4.96 GB install), the one
  for PLA-519's phone gate.
- Retail's ARM64 selection includes `D3D12_ARM64\D3D12Core.dll` (the Agility SDK), relevant to
  PLA-513. The x64 `Wow.exe` is not in the ARM64 selection; it has one entry for China and one for
  the other regions.
