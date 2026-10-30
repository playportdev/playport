# Plan: World of Warcraft through a Battle.net store client and a native ARM64 child

**Linear:** [PLA-508](https://linear.app/playportdev/issue/PLA-508) (under
[PLA-254](https://linear.app/playportdev/issue/PLA-254); related to
[PLA-298](https://linear.app/playportdev/issue/PLA-298)). Spec:
[PLA-516](https://linear.app/playportdev/issue/PLA-516). Compatibility:
[PLA-515](https://linear.app/playportdev/issue/PLA-515).

**Date:** 2026-10-30. **Kind:** design and execution plan, decided by the owner the same day.
**Status:** written; nothing built or run. Branch `dev/pla-508-world-of-warcraft`.

A user asked to play World of Warcraft on the phone. The owner chose a route that never runs the
Battle.net app: Playport installs WoW itself and runs its native ARM64 Windows client without FEX.
Proposed records: [0168](../decisions/0168-battle-net-store-client.md) (the store client),
[0169](../decisions/0169-anti-cheat-refusal-scope.md) (Warden and the ban-risk notice),
[0170](../decisions/0170-native-arm64-guests.md) (native ARM64 children).

## Done when

The owner, on the phone, installs a WoW product from Playport's Battle.net store, acknowledges the
ban-risk notice, signs in inside the game with a controller and the text bar, and reaches
character select; the compatibility issue records the run.

## Facts it rests on (2026-10-30)

| Fact | Source |
|---|---|
| `Wow.exe` started directly shows its own login (email, password, authenticator code); Battle.net only installs and updates | Blizzard forums 2024–2026 |
| TACT version, CDN and content endpoints need no sign-in; no maintained open tool lays down a playable install | wowdev.wiki TACT; BuildBackup, TACTSharp |
| Retail ships `Wow-ARM64.exe`, installed by Battle.net on Windows on ARM; Classic products had ARM64 clients in 2022, today unverified | rkblog Dec 2025; Blizzard forums |
| Warden is user-mode, sent by the server; Blizzard does not ban Wine play for itself | Blizzard forums, 2025 third-party software post |
| Retail is about 131 GB; minimum 8 GB RAM, DX12-capable GPU, 6 cores at 4 GHz | AMD Midnight page |
| Playport ships Wine's aarch64 set (`sysarm64`) and runs aarch64 images from the JIT pool; an x86-64 session starts no pure ARM64 process | 0071, 0082, `ARCHITECTURE.md` |
| vkd3d-proton, DXVK and `vulkan-1` are built arm64ec and i386 only | `build/stages/vulkan-pe.sh` |
| An Android launcher (ARM64EC Proton + FEX) runs WoW, installed by Battle.net | that launcher's guide, 2026 |

## Decisions (owner, 2026-10-30)

| | Decision |
|---|---|
| Goal | WoW on the phone; Battle.net only as where its files come from |
| Install | Native Swift store client `app/BattleNetClient` (0168); full install before Play; update check at every Play |
| Products | Fixed list: WoW retail and the Classic products; a product is offered only while its build has an ARM64 client |
| Region, language | Store region picker defaulting from the phone; the phone's language, `enUS` fallback |
| CDN | Hosts from the `cdns` endpoint only; a User-Agent naming Playport; bounded concurrency; back-off on 429 |
| Sign-in | In the game, through the text bar; no Battle.net session in Playport |
| Client | `Wow*-ARM64.exe` only, as a native ARM64 child on the aarch64 Wine set; two Wine trees stay; no x64 fallback (0170) |
| Graphics | vkd3d-proton and `vulkan-1` built for aarch64 |
| Anti-cheat | Warden allowed; ban-risk notice once per title; the client never patched (0169) |
| Input | Controller (WoW's gamepad mode) and the text bar; no touch controls |
| A broken Blizzard ARM64 build | Fails like any other play; the compatibility issue records it |

## Steps

1. **Host spike** ([PLA-509](https://linear.app/playportdev/issue/PLA-509)), side worktree. Install
   retail with `BattleNetClient` run on the workstation; record per product whether its build has an
   ARM64 client and the install size. Run x64 `Wow.exe` from that install under desktop Wine with
   vkd3d-proton ([HOST-DEBUGGING.md](../HOST-DEBUGGING.md)) to login and character select: a
   baseline, never shipped. Record WoW's D3D12 needs against [0032](../decisions/0032-vkd3d-proton-as-a-series.md),
   whether `-d3d11` is still accepted, Warden's behaviour, and the gamepad mode.
2. **Store client** ([PLA-510](https://linear.app/playportdev/issue/PLA-510)): `app/BattleNetClient`
   as decided above, host-tested.
3. **Native ARM64 child** ([PLA-512](https://linear.app/playportdev/issue/PLA-512)): a native branch
   in `wine_ios_child_main` reusing madeira-unix 0061's aarch64-ntdll path without the WoW64 window;
   `sysarm64` resolution without `WowTebOffset` (wine-pe 0015); every `is_arm64ec()` use checked.
   Phone gate: a small aarch64 test exe runs from the session root and exits with its code; Hollow
   Knight still reaches first frame+10.
4. **aarch64 Vulkan** ([PLA-513](https://linear.app/playportdev/issue/PLA-513)): vkd3d-proton and
   `vulkan-1` for aarch64 in `vulkan-pe.sh`, staged into `sysarm64`, checked by `pp verify`.
5. **App** ([PLA-514](https://linear.app/playportdev/issue/PLA-514)): the Battle.net store page, the
   ban-risk notice, Play of the ARM64 client, `pp ui` paths. Phone gate: the Done-when run.

Steps 1, 2 and 4 can run in parallel; 3 needs the phone; 5 needs 2, 3 and 4.

## Risks

| Risk | Effect | Answer |
|---|---|---|
| Blizzard ships an ARM64 client that fails (as in March 2026) | WoW unplayable until a later build | none by decision; recorded in PLA-515 |
| Blizzard's CDN throttles or blocks an unofficial client | no install or update | none beyond polite pacing; record and stop |
| WoW's D3D12 renderer needs more than 0032 gives (64-bit atomics, FL12_1+) | no first frame | spike finds it first; a KosmicKrisp issue |
| Warden's run-time code is slow through the fault-emulated executable path | stalls at login | measured in step 3/5 |
| Warden flags the session under the JIT pool's image copies | account action | the ban-risk notice; nothing patched |
| 131 GB on a phone already full of games | no retail install | the up-front space check; Classic is smaller |
| A Classic product has no ARM64 client | not offered | by decision |
| CPU and memory under 8 GiB guest RAM | low frame rate | measured with `pp perf` after step 5 |
