# BattleNetClient: the Battle.net store's TACT client

`BattleNetClientKit` is the Battle.net store (decisions 0174 and 0177, spec
[PLA-516](https://linear.app/playportdev/issue/PLA-516), [PLA-510](https://linear.app/playportdev/issue/PLA-510),
[PLA-517](https://linear.app/playportdev/issue/PLA-517)): which World of Warcraft products are
offered, what an install of one is, and the install itself in the layout the game reads. No
Battle.net session; everything it reads is public. Foundation and
[ContentKit](../ContentKit/README.md) (MD5, zlib, the install engine) only; `pp test` runs its
offline tests on the Linux host. The app's Battle.net store (`UI/BattleNetStore.swift`, PlayportKit
`BattleNet`, PLA-519) lists the offers and runs installs through it.

- **Products and regions** (`BattleNetProduct`, `StoreRegion`): the fixed list `wow`,
  `wow_classic`, `wow_classic_era`, `wow_anniversary`; the store regions us, eu, kr, tw (each
  region's manifest tag is its code in capitals).
- **Transport** (`BattleNetTransport`, `URLSessionTransport`): one GET seam, a URL and headers in,
  the status, headers and body out; it throws only when no answer came. It follows no redirect: a
  3xx is the answer, which the client refuses, so no host the endpoints did not name is asked.
  Tests inject recorded answers through it.
- **Manners** (`BattleNetManners`, decision 0174): every request carries `User-Agent: Playport`;
  at most `maxConcurrent` (8) are in flight; an HTTP 429 pauses that host for its `Retry-After`
  (at most 120 s; one that is not a finite, non-negative number of seconds counts as none: 2 s,
  doubling, up to 120 s) and asks again, five times, before the host counts as refusing. Only the
  hosts the version and CDN endpoints name are asked, plus, for the art alone, the World of
  Warcraft site's public image host (see **Art**); no mirrors. `adding(keys:)` (a build's key
  ring, for its download) keeps the same limit and paused hosts.
- **Errors** (`BattleNetError`): `unreachable` (no answer) and `refused` (an HTTP status other than
  the one asked for) are the network's (`isNetwork`); `damaged` (truncated, wrong magic, a hash
  that does not match, a missing field, a number out of range), `missingKey` and `unsupported`
  are the content's; `outdated` is a region or language change of an install on another build
  than the region's (it changes after an update). Every parser bounds-checks before each read
  (`ByteReader`).
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
  `TagQuery.client` is the Windows x64 client (decision 0177) in one locale and region, without
  `Alternate`; nothing of the ARM64 client is asked for.
- **Offer** (`BattleNetClient.offer`, `BattleNetOffer`): a build is offered only when its install
  manifest lists the product config's x64 executable tagged for Windows and x64 (`client`). Five
  small requests per product and region.
- **Sizes** (`BattleNetClient.sizes`, `BattleNetSizes`): the download is the size manifest's
  selection for the x64 client (the stored objects, encoded); the install adds the product
  folder's files from the install manifest.
- **Art** (`BattleNetArt`, `BattleNetClient.art`, PLA-607): each product's picture for its tile
  (800 wide) and page backdrop (1600 wide), 16:9 JPEGs from the World of Warcraft site's public
  image host (`blz-contentstack-images.akamaized.net`, no session, no cookies), fixed per product
  and sized and cropped by the host's `width`, `crop` and `format` parameters; asked with the
  client's manners. Retail's picture carries the game's logo, the Classic panels no words. The app
  keeps it under Caches (PlayportKit `BattleNetArtCache`); none of it is in the repository.
- **CDN indexes and the download manifest** (`ArchiveIndex`, `DownloadManifest`, `PackedKey`):
  archive indexes, the file index and the archive group, each checked by its name (the MD5 of
  its footer), its table of contents and every block's hash; the writer builds the archive group
  in the same format. The download manifest lists every stored object's EKey and encoded size
  with its tags. Keys are packed into two integers, as retail plans about 1.6 million objects.
- **The local store** (`CASC`, `BuildInfo`): data files of 30-byte local headers (the EKey
  reversed, the size, two checksums over the header and its place, lookup3 among them) each
  followed by the object as the CDN serves it; each data file starts with sixteen header-only
  entries, one per journal; sixteen `.idx` journals (version 7, entries keyed by the EKey's
  first 9 bytes, both hashes chained per entry) map objects to their place. `.build.info` is
  written in the column order Blizzard's installer uses.
- **Install plan** (`BattleNetInstallOptions`, `BattleNetSelection`, `ArchiveLocations`,
  `BattleNetInstallPlan`): for a product, region and locale, the store gets the download
  manifest's selection (platform, x64, the locale, both categories, without `Alternate`;
  region-tagged data for all four regions, so a later region change downloads nothing) plus the
  build's own manifests (root, encoding, install, download, size, patch index, every `vfs-*`);
  the product folder gets the install manifest's selection as plain files, each directory
  spelled as it first appears, and the x64 client (`client`) under the manifest's spelling
  (`_retail_/Wow.exe` for the config's `WoW.exe`). The x64 and ARM64 clients share nine
  (Classic) or ten (retail) names under `Utils` (the browser and voice helpers) with different
  builds; a name selected twice keeps the x64 file. Each object's place in the data files is
  fixed by the plan, so the journals are a function of it; neighbouring objects in an archive are
  one ranged read (up to 8 MiB, across
  gaps up to 16 KiB). `present` and `firstDataFile` let an update plan only the objects a store
  lacks (PLA-521). A ContentKit `ContentPlan`: data files (`check: .none`, the source checks every
  object) and product folder files (`md5` = CKey).
- **Installer** (`BattleNetInstaller`): `prepare` reads the build's configs, manifests and every
  CDN index into a work area beside the install (kept for a resume) and plans, refusing a build
  whose selection lacks the product config's x64 client; `Prepared.clientPath` names it for the
  store's receipt. `install` stages the plan through ContentKit's engine (the chunk source checks
  each object's EKey and block
  hashes before writing it with its header, and re-checks journalled runs on resume), then writes
  `Data/config`, `Data/indices` (with the archive group, when the one built here hashes to the
  CDN config's name), the journals, `<product>/.flavor.info` and `.build.info` last, and renames
  the stage to the install root. `verify` reads every journal entry's header and object back,
  checks every planned object is journalled and every product folder file against its CKey.
  The patch manifest is left out (its name is not the MD5 of its bytes, so nothing checks it;
  the game fetches it).
- **Region and language of an install** (`BattleNetInstallChange.swift`, PLA-520):
  `changeRegion` asks only the region's version and CDN endpoints and rewrites `.build.info`
  (branch, CDN hosts and servers, the region tag) and an existing `WTF/Config.wtf`'s `portal`; a
  region on another build is `outdated`. `prepareLocaleChange` plans the new locale's selection
  of the installed build minus the objects the store's journals name and the product folder files
  already there, numbering data files after the store's and reading the CDN indexes from
  `Data/indices`; `changeLocale` stages it through the engine, renames the new files in (each
  replacing its old one at once), writes the next journal generation (old entries plus new)
  before removing the old one, then the locale into `.build.info` and an existing
  `WTF/Config.wtf` (`textLocale`, `audioLocale`, replaced or added). The old locale's data stays.
- **Updates** (`BattleNetUpdate.swift`, PLA-521): `checkUpdate` asks the install region's version
  endpoint for its current build (`BattleNetUpdateCheck`), and says whether the install lacks the
  x64 client (`lacksClient`: its `.build.info` tags name no `x86_64`, every WoW product config's
  `tags_64bit`, `BattleNetProduct.x64ClientTag`; an install from before decision 0177 has only
  the ARM64 client); `needsUpdate` is either. `prepareUpdate` refuses a build without the x64
  client, as `prepare` does, then plans its x64 selection in the install's locale minus the
  objects the store holds and the product folder files already on disk as the new build has
  them, fetching only the manifests and CDN indexes the install lacks: at the installed build that
  is the x64 client's files and data alone. `update` adds it as a language change does, then the
  new build's configs, the missing indexes and the archive group, and `.build.info` last (its
  region and locale kept, its machine `x86_64`). Never a reinstall; run again after an
  interruption, it resumes. A product folder file still to write is decoded from its archive even
  when the store holds its object (both here and in a language change).
- **The game's settings** (`WoWConfig`): `prepareForPlay`, before each Play, writes into
  `<product folder>/WTF/Config.wtf` (made when missing) the install's `textLocale`,
  `audioLocale` and `portal` where it names none (without them WoW opens a Win32 language and
  region box first), `GamePadEnable "1"` where it names none (off, WoW looks for no controller),
  `HardwareCursor "0"` where it names none (WoW then draws its cursor into its frames; the phone
  draws no Windows cursor, and the controller moves that cursor at the login), for retail
  `playIntroMovie "14"` where it names none (the client marks its intro cinematic seen only in the
  settings it saves on a clean exit, so on the phone the cinematic, about 265 s, played before the
  login on every Play) and pins `GxApi` to `D3D12` (after one failed Direct3D 12 start WoW saves
  Direct3D 11); every other line stays.
- **Live runs**: `BATTLENET_LIVE_REPORT=$PLAYPORT_BUILD/bnet-live.md ./pp test --swift
  BattleNetClient --filter testLiveOffersAndSizes` asks Blizzard for every product and region and
  writes the table in [the offer evidence](../../docs/evidence/2026-10-30-battlenet-offer.md).
  `BATTLENET_LIVE_INSTALL=<product>:<install root> BATTLENET_LIVE_REPORT=<file> ./pp test
  --swift BattleNetClient --filter testLiveInstall` installs a
  product (us, enUS), resuming on network failures, verifies it and reports
  ([install evidence](../../docs/evidence/2026-10-30-battlenet-install.md)).

Fixtures (`Tests/BattleNetClientKitTests/Fixtures`) are Blizzard's public answers recorded on
2026-10-30, byte for byte (their names are their hashes): version and CDN tables, build, CDN,
product and key ring configs, the four install manifests, an archive index and a 64-byte object
from that archive, and three encrypted objects; `known-keys.txt` is one public WoW key. Encoding,
download and size manifests are tens of megabytes, so the tests build small ones from the
format, and the install tests build a small product on an in-memory CDN.
