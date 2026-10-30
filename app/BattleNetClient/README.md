# BattleNetClient: the Battle.net store's TACT client

`BattleNetClientKit` is the Battle.net store (decision 0168, plan
`docs/plans/2026-10-30-world-of-warcraft.md`, [PLA-510](https://linear.app/playportdev/issue/PLA-510)):
which World of Warcraft products are offered, and what an install of one is. No Battle.net
session; everything it reads is public. Foundation and [ContentKit](../ContentKit/README.md)
(MD5, zlib) only; `pp test` runs its offline tests on the Linux host. The app does not use it yet
(PLA-519).

- **Products and regions** (`BattleNetProduct`, `StoreRegion`): the fixed list `wow`,
  `wow_classic`, `wow_classic_era`, `wow_anniversary`; the store regions us, eu, kr, tw (each
  region's manifest tag is its code in capitals).
- **Transport** (`BattleNetTransport`, `URLSessionTransport`): one GET seam, a URL in, the status
  and body out; it throws only when no answer came. The URLSession one sends `User-Agent:
  Playport`. Tests inject recorded answers through it.
- **Errors** (`BattleNetError`): `unreachable` (no answer) and `refused` (an HTTP status other than
  200) are the network's (`isNetwork`); `damaged` (truncated, wrong magic, a hash that does not
  match, a missing field), `missingKey` and `unsupported` are the content's. Every parser
  bounds-checks before each read.
- **Discovery** (`BattleNetClient.version`, `cdn`, `build`): Ribbit v2 over HTTPS
  (`https://{region}.version.battle.net/v2/products/{code}/versions|cdns`), pipe-separated tables
  read by column name (`PSVTable`, `VersionRow`, `CDNEndpoint`). CDN bases are only the hosts the
  `cdns` row names, HTTPS servers first (the phone's transport security refuses plain HTTP),
  `fallback=1` servers after the primaries. A base that fails is passed over; when all do, a
  damaged answer is reported over the network's failures.
- **Configs** (`TACTConfig`, `BuildConfig`, `CDNConfig`, `ProductConfig`, `TACTKeyring`): each
  config is checked against its name (its MD5). The product config gives the product folder, the
  x64 and ARM64 executables, the manifest tags per machine, the launch arguments and the locales.
- **BLTE** (`BLTE`): the EKey (MD5 of the header, or of the whole object without a block table)
  and every block's MD5 are checked before decoding; `N` and `Z` blocks, and `E` blocks
  (Salsa20, the key looked up by its 64-bit name in a `TACTKeyring`; an unknown key is
  `missingKey` with its name). LZ4 and nested blocks and ARC4 are `unsupported`. The decoded
  bytes are checked against the CKey.
- **Manifests** (`InstallManifest`, `SizeManifest`, `EncodingTable`, `TagQuery`): the install
  manifest's files with their tags; the size manifest's encoded sizes; the encoding table's
  CKey → EKeys and EKey → spec and encoded size, kept as page bytes and binary-searched. Tag
  queries OR tags within a type, AND across types, then take away the excluded ones;
  `TagQuery.arm64` is the Windows ARM64 client in one locale and region, without `Alternate`.
- **Offer** (`BattleNetClient.offer`, `BattleNetOffer`): a build is offered only when its install
  manifest lists the product config's ARM64 executable tagged for Windows and ARM64. Five small
  requests per product and region.
- **Sizes** (`BattleNetClient.sizes`, `BattleNetSizes`): the download is the size manifest's
  selection (the stored objects, encoded); the install adds the product folder's files from the
  install manifest.
- **Live run**: `BATTLENET_LIVE_REPORT=$PLAYPORT_BUILD/bnet-live.md ./pp test --swift
  BattleNetClient --filter testLiveOffersAndSizes` asks Blizzard for every product and region and
  writes the table in [the evidence](../../docs/evidence/2026-10-30-battlenet-offer.md).

Fixtures (`Tests/BattleNetClientKitTests/Fixtures`) are Blizzard's public answers recorded on
2026-10-30, byte for byte (their names are their hashes): version and CDN tables, build, CDN,
product and key ring configs, the four install manifests, a 64-byte archive object and three
encrypted objects; `known-keys.txt` is one public WoW key. Encoding and size manifests are tens
of megabytes, so the tests build small ones from the format.
