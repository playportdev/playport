# 0177: World of Warcraft plays its x64 client through FEX; the runtime never changes the game's memory

**Status:** accepted, 2026-11-01, by the supervisor on the owner's instruction for the World of
Warcraft work ([PLA-516](https://linear.app/playportdev/issue/PLA-516),
[PLA-514](https://linear.app/playportdev/issue/PLA-514)). Amends
[0170](0170-native-arm64-guests.md), [0174](0174-battle-net-store-client.md),
[0175](0175-anti-cheat-refusal-scope.md) and [0176](0176-native-arm64-images-live-in-the-jit-pool.md).

## Decision

- **The runtime never changes a game's code or data in memory.** No x18 rewrite, no relocated or
  remapped image copy, no patch at `FlushInstructionCache`: what the game's code reads of itself is
  what Windows' own loader would have put there. This holds for every allowed anti-cheat title
  (0175), and World of Warcraft is the first.
- **World of Warcraft plays its x86-64 Windows client** (`_retail_\Wow.exe`, the Classic products'
  `WowClassic.exe`, the product config's `relative_path`) through FEX on the ordinary x86-64 path,
  the one The Witcher 3 and Red Dead Redemption 2 run on: Direct3D 12 through the arm64ec
  vkd3d-proton on the Vulkan backend (KosmicKrisp), `-d3d12`, and `Config.wtf`'s `GxApi D3D12`
  (with `GamePadEnable`) written before every Play as before. FEX translates the client's code
  into its own code cache in the JIT pool, out of band, as Rosetta and Windows on ARM's Prism do;
  the client's pages keep their bytes.
- **The store installs and updates the x64 client only** (amends 0174): the install manifest's
  `Windows` + `tags_64bit` (`x86_64`) selection, no `arm64` files. A product is offered while its
  build carries the x64 client. An install made before this record (its `.build.info` names no
  `x86_64`) needs an update, which Check for update offers and every Play asks for (PLA-521): the
  update plans the x64 selection of the region's current build and fetches only what the install
  lacks, so a retail install's 133 GB of data stay. The store receipt then names the x64 client.
- **Play starts only the x64 client** (PE machine 0x8664). A copy whose receipt still names an ARM64
  client is updated first, or refused when the update cannot be had.
- **The ban-risk notice no longer says the runtime rewrites the game's instructions** (amends
  0175's 2026-11-01 amendment): it says Playport changes none of the game's files and none of its
  code in memory, and runs Blizzard's x64 Windows client through a translator.
- **The native ARM64 child stays** (0170, 0176): the session still starts a plain ARM64 program as
  a native ARM64 child with its JIT-pool image copy and x18 patching, for Playport's own probes and
  any other native ARM64 program. World of Warcraft no longer uses it; 0170's "where a game ships an
  ARM64 client, Playport runs that client only" no longer applies to it.

## Why

- **The owner banned the ARM64 path's memory changes** after the WoW ARM64 runs (2026-11-01): a
  client that runs only once the runtime has rewritten 196,547 of its instructions, moved its image
  and patched code it decrypts (0176) is exactly what Blizzard's 2025 crackdown names
  ("software that modifies the client"), whatever the reason for it.
- **The ARM64 client cannot run unrewritten on the phone.** iOS clears x18, which Windows ARM64
  code reads as its TEB. The kernel's custom x18 ABI keeps x18 only until a context switch, and
  installd refuses an app carrying the `com.apple.security.custom-x18-abi-toggle` entitlement under
  free-team signing (0xe8008015, no valid provisioning profile)
  ([evidence](../evidence/2026-11-01-ios-custom-x18-abi.md)). So every x18 reader in the client
  must be patched, which the owner does not accept.
- **x86-64 code never reads host x18.** FEX's arm64ec host serves the guest's TEB reads itself
  (`patches/fex-port` 0002), and code the game generates (Warden) is translated like the rest, not
  run through the fault-emulated path.
- **The x64 path is proven on the phone** for large Direct3D 12 games (W3 on vkd3d-proton,
  RDR2), and a desktop Wine run of `Wow.exe` reached character select with Direct3D 12
  (`.work/research-x64`, feasibility study of 2026-11-01).

## Costs

- **CPU.** Retail's minimum is 6 cores at 4 GHz; FEX leaves the phone a fraction of that (0170's
  original reason for the ARM64 client). Cities and raids may be slow; Classic Era is the lighter
  product.
- **AVX.** FEX reports AVX/AVX2, and Wine's ARM64EC exception contexts drop the ymm high halves
  (ARCHITECTURE.md, the Valve Wine AVX/YMM row); WoW's start-up raises many exceptions. Carried as
  a separate fix in FEX/Wine, not by changing the game.
- **Space.** The x64 product folder is about 64 MB (retail) or 61 MB (Classic Era) larger than the
  ARM64 one; an older install that is updated keeps its ARM64 files beside the x64 ones until it is
  reinstalled.
- The ARM64-child machinery and the aarch64 vkd3d-proton set stay built and shipped with no game
  using them.
