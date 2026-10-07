# Plan: testing reported games without owning them

**Date:** 2026-10-07. **Kind:** plan; research done, nothing built, no phone used.
**Linear:** PLA-12 (the umbrella), the Compatibility project (PLA-22 to PLA-38), PLA-9,
PLA-11, PLA-19, PLA-33.

## Goal and limits

Players report titles that the test account does not own, and the owner will not buy
each one to test it. This plan gets every report to one of three states: reproduced
on our phone, explained by its class, or waiting on the player's log. It uses only
legal routes:

- **Exact copies that cost nothing:** free demos, free-to-play titles, Steam free
  weekends, and the free-to-keep giveaways on Epic and GOG, which the app already
  installs from.
- **Proxies:** a free title with the same profile as the reported one. The profile is
  the PE machine, the graphics API, the engine, and the launcher or DRM.
- **Probes we build ourselves:** small programs cross-compiled with llvm-mingw,
  imported as Local games.
- **The players' own data:** logs and A/B runs.

Out of scope: copies from any other source (torrents, "repacks", unpacked files sent
by players), and the two routes the owner declined: asking publishers for keys and
Steam Families sharing. Nothing here changes decision 0005: the cohort stays owned
titles; the test set below is for finding faults, not for gating releases.

## What the reports are (2026-10-07)

The profiles come from PCGamingWiki's page wikitext (`api.php?action=parse&prop=wikitext`;
its Cargo query API is closed to anonymous users) and Steam's public `appdetails` call.
`.work/agent-notes/compat/` holds the fetch script and the raw answers.

| Issue | Title (app) | Machine | API | Engine | Free route |
| --- | --- | --- | --- | --- | --- |
| PLA-34 | Castle Crashers (204360) | i386 | D3D9 (GL 2.0 also) | Behemoth's own | **Castle Crashers Demo, 207100** |
| PLA-35 | South Park: The Stick of Truth (213670) | i386 | D3D9 | Onyx | proxy (class B) |
| PLA-36 | Mortal Kombat Komplete Edition (237110) | i386 | D3D9 | Unreal Engine 3 | proxy (class B) |
| PLA-37 | Catherine Classic (893180) | i386 | D3D9 | Gamebryo | proxy (class B) |
| PLA-38 | Bloodstained: Curse of the Moon (838310) | i386 | D3D9 | (not listed) | proxy (class B) |
| PLA-24 | DiRT 3 Complete Edition (321040) | i386 | D3D9 and D3D11 | EGO 2.0 | probe (class C); delisted |
| PLA-29 | Need for Speed: The Run | i386 | D3D11 | Frostbite 2 | none: needs Origin/EA app (class E) |
| PLA-31 | The Binding of Isaac: Rebirth (250900) | i386 | **OpenGL 2.0** | own | proxy/probe (class A) |
| PLA-30 | Final Fantasy III (3D Remake) (239120) | i386 | **OpenGL** | own | proxy/probe (class A) |
| PLA-32 | Geometry Dash (322170) | x86-64 | **OpenGL 2.0** | cocos2d-x | proxy/probe (class A) |
| PLA-22, PLA-25 | Counter-Strike (10), Half-Life (70) | i386 | OpenGL, D3D, software | GoldSrc | detection fault first (class F) |
| PLA-27 | Cat Mail Co. (4380490) | x86-64? | ? | ? | **Cat Mail Co. Demo, 4622530** |
| PLA-28 | Oxygen Not Included (457140) | x86-64 | D3D11 | Unity 2020.3 | the player's log (class D) |
| PLA-26 | Portal 2 (620) | i386 | D3D9 | Source | owned; works |
| PLA-23 | FF VII Remake Intergrade (1462040) | x86-64 | D3D12 | Unreal Engine 4 | works; audio is PLA-10 |

The reports fall into these classes:

- **0. Found in the PLA-29 log (2026-10-07): an i386 child cannot load `opengl32.dll`.**
  The player's `playport.log` (LiveContainer, 6 GB limit; kept in
  `.work/agent-notes/compat/logs/PLA-29/`) shows every i386 launch that loads opengl32
  ending at once with `0xc0000142` (STATUS_DLL_INIT_FAILED), right after
  `[unixlib] module (opengl32.dll) WoW64 -> (stub table)`. That covers NFS The Run on
  Vulkan and DXMT, and Spacewar (Steam app 480, free) on both. The cause is in
  `patches/madeira-unix` 0068: its WoW64 branch swaps opengl32's GL-absent table, whose
  attach codes succeed, for the all-fail stub table, so opengl32's DllMain fails. Hit:
  every i386 title that imports opengl32, and every i386 title whose Direct3D goes
  through wined3d, which imports it: Direct3D 10/11 (class C), Direct3D 9 set to DXMT,
  and older ddraw titles. Proposed fix (not applied): keep the GL-absent table for
  WoW64 callers; it takes no parameter block. A draft is in
  `.work/agent-notes/compat/`. Free repro: Spacewar (480). After the fix, GL calls
  still fail (class A), but D3D titles that only import opengl32 should start.

- **A. OpenGL: no driver at all.** The iOS display driver has no OpenGL:
  `nulldrv_OpenGLInit` returns `STATUS_NOT_IMPLEMENTED` (in
  `patches/madeira-unix` 0029's context), and the Mesa stage builds with
  `-Dopengl=false`. Isaac, Final Fantasy III and Geometry Dash cannot work today, on any
  phone, and neither can GoldSrc in its OpenGL mode. This is a missing feature, not a
  regression. For now, adoption could tell the player so instead of "stopped
  unexpectedly" (Track 6).
- **B. i386 Direct3D 9** (WoW64, DXVK `d3d9` over KosmicKrisp, decision 0047). Portal 2
  plays on our phone. All five failures came from one player on iOS 27 with
  LiveContainer, StikDebug and iRAM Plus, who says Castle Crashers and South Park run
  "flawlessly" on Madeira in the same setup. The free demo answers the first question:
  does it fail on our phone, as its own app?
- **C. i386 Direct3D 10/11: no backend.** The `vulkan-pe` stage builds the i386 DXVK
  with `-Denable_d3d10=false -Denable_d3d11=false` (only `d3d9.dll`), and DXMT has no
  i386 build. DiRT 3 picks Direct3D 11 when it can.
- **D. x86-64 Unity on Direct3D 11.** This is the cohort's own profile (Hollow Knight).
  Cat Mail Co. crashing at launch is unexpected, and the demo reproduces it exactly.
  Oxygen Not Included reaches its menus and crashes in world generation; that needs the
  player's log and the game's `Player.log` (PLA-33).
- **E. A third-party launcher.** NFS The Run is an Origin/EA app game (delisted). It is
  not fixable here; refuse it before launch, as Epic's online-only titles are refused.
- **F. Detection.** Half-Life and Counter-Strike fail with "No Windows executable in this
  folder" (PLA-9), before any runtime question.

## Track 1: classify every report the same way

1.1 `pp compat profile APP|NAME` (`tools/compat.py`). It reads PCGamingWiki's wikitext
  (engine, 32/64-bit executable, Direct3D, OpenGL and Vulkan versions, DRM, anti-cheat)
  and Steam's `appdetails` (free or not, `demos`, DRM and third-party-account notices).
  It prints a one-line profile and the class (A–F), and checks Epic's
  `freeGamesPromotions` for the title. It needs no key and stores nothing in the
  repository (raw answers go to `.work/agent-notes/compat/`). It is host-tested with
  saved fixtures.
1.2 The triage skill (`.pi/skills/playport-triage`) puts a `**Profile:**` line and the
  class into each Compatibility issue, and a `**Free route:**` line (demo, proxy, probe,
  or none).

Done when the tool reproduces the table above.

## Track 2: a free test set by profile

2.1 **Licences without buying.** A demo or free-to-play title needs a free licence on the
  account. For now, the owner adds it once in Steam (any client, including Linux) with
  the store's Download/Play button. For the product, the Steam client gains a free-licence
  request (`EMsg.ClientRequestFreeLicense` 5572 / response 5573) behind an **Add to
  library** button on a demo's or a free game's page (decision 0012: the capability goes
  into the UI first; PLA-19 is the demos-missing half). The driver then uses
  `pp ui --action install:APP`.
2.2 **Exact repros first:** Castle Crashers Demo (207100) for PLA-34 and class B, and Cat
  Mail Co. Demo (4622530) for PLA-27 and class D.
2.3 **Proxies.** Adoption records each candidate's machine and Direct3D evidence on
  install (decision 0046), so the profile is checked, not assumed. Candidates (free
  status checked on Steam on 2026-10-07; machine and API to be confirmed on install):

  | Profile | Candidates | For |
  | --- | --- | --- |
  | x86-64 OpenGL 2 | DDNet (412220; OpenGL 2, Vulkan option), Teeworlds (380840) | A: Geometry Dash |
  | OpenGL through a script engine | Doki Doki Literature Club! (698780, Ren'Py) | A |
  | x86-64 Direct3D 9 | Team Fortress 2 (440; 64-bit since 2024) | an untested route: DXMT has no D3D9, so what does the default pick? |
  | i386 Unity (Direct3D 9 or 11) | older free Unity titles, e.g. Emily is Away (417860) | B, C |
  | UE3 i386, Gamebryo i386 | none free found yet; watch Epic/GOG giveaways and Steam free weekends | B: MK, Catherine |

  Already owned: Hollow Knight, The Witcher 3, Among Us (Steam), Death's Door (Epic),
  Shogun Showdown (GOG), Portal 2.
2.4 **Giveaways and free weekends.** `pp compat watch` lists the current Epic giveaways
  (`store-site-backend-static.ak.epicgames.com/freeGamesPromotions`) against the open
  Compatibility issues and the profile gaps. The owner claims what fills a gap: claimed
  titles are owned for good, and the app installs Epic and GOG games already. A Steam
  free weekend gives a temporary licence and is used the same way, while it lasts.
2.5 The set is written down in `docs/compat/test-set.md`: profile, title, store, the
  recorded machine and API, the last result with its IPA sha256. Free titles are
  installed while they are being tested and uninstalled after (the phone's space).

## Track 3: probes we build

Small Windows programs, source in `tools/compat/probes/`, built with llvm-mingw into
`$PLAYPORT_BUILD/compat/probes/`, imported with `pp ui --action import:PATH` and
uninstalled after. They are not in the IPA, so decision 0035 holds. Each probe clears,
draws a triangle, presents for N seconds, writes a mark through `OutputDebugString`, and
exits with a code.

| Probe | Machines | Tests |
| --- | --- | --- |
| `d3d9` | i386, x86-64 | class B; x86-64 D3D9 routing |
| `d3d11` | i386, x86-64 | class C (expected to fail on i386 until 6.2); class D |
| `gl21` (WGL, fixed function and GLSL 1.20) | i386, x86-64 | class A: today it should fail cleanly; it is the gate for 6.1 |
| `laa` (large-address-aware, 3 GiB of allocations, threads) | i386 | the 4 GiB WoW64 window that 32-bit engines stress |
| `audio` (XAudio2 and DirectSound tone) | i386, x86-64 | PLA-10-style reports |

A probe separates the runtime from the game: if `d3d9`/i386 plays and Castle Crashers
Demo does not, the fault is in what the game does, not in the route.

## Track 4: data from the players

4.1 **Collect the logs we were offered**, before the links expire. The gofile log on
  PLA-29 needs a browser: gofile's API now refuses guest downloads (`error-notPremium`).
  Also Mobile_Light5556's three logs, Corner-Mundane's, and tPimple's direct messages
  (PLA-11). They go to `.work/agent-notes/compat/logs/<issue>/`, never into the
  repository (`pp secrets`).
4.2 **Ask once, in one template**: device, iOS, install route (own app, SideStore,
  LiveContainer), JIT route, backend, memory limit shown, and Report a problem's zip.
  The triage skill carries the template.
4.3 **PLA-33:** Report a problem also gathers the game's own logs (Unity `Player.log`,
  Unreal `Saved/Logs`, logs beside the executable), size-capped.
4.4 **Owner question (decision needed):** a release-build switch on a game's page,
  "Detailed log for the next play", which lifts `quietRuntime()` for that one launch.
  Release builds now log almost nothing (`WINEDEBUG=-all`, `MADEIRA_QUIET`), which makes
  player logs thin. This would amend decision 0009 with a new record.
4.5 **Player A/B runs**, where a player offers: the same title as its own app versus in
  LiveContainer, Vulkan versus DXMT, and the probes from Track 3 as a .zip they import.

## Track 5: the players' setup on our phone

5.1 Castle Crashers Demo on our phone, as our own app. If it plays, class B's reports
  point at the LiveContainer and StikDebug route (PLA-11), not at the runtime.
5.2 If the slots allow (three free-team slots; the dev app takes one), install
  LiveContainer and play the demo inside it with its JIT route, then compare with 5.1.
5.3 Madeira at the frozen pin (8c050d0), the same demo, the same phone. saviu_u's "works
  on Madeira" then becomes our own A/B, and a difference is bisected over
  `patches/madeira-unix` and Playport's app layer.

## Track 6: fixes per class (each its own plan or patch once reproduced)

6.1 **A, OpenGL.** First, adoption detects `opengl32.dll` imports (an extension of 0046's
  evidence), and the page and the launch screen say "OpenGL games are not supported
  yet" instead of a crash. Then a spike on two routes:
  - **Host-side:** Mesa's Zink built for iOS over KosmicKrisp, with EGL surfaceless,
    behind the iOS display driver's `OpenGLInit` through win32u's EGL path. This is
    native ARM64 code, and one build serves i386 and x86-64 titles through Wine's
    `opengl32` thunks. Zink over KosmicKrisp is known to run on macOS.
  - **Guest-side:** Mesa's Zink and WGL built as PE DLLs (`opengl32.dll` for ARM64EC and
    i386) over `vulkan-1`. This route touches less of the driver, but the i386 build runs
    emulated.

  Recommended: host-side. The spike writes a decision record, and the `gl21` probes and
  DDNet are the gate.
6.2 **C, i386 Direct3D 11.** Build the i386 DXVK with `d3d11`/`dxgi` too, and route i386
  D3D10/11 titles to Vulkan. This extends 0047 with a new record. Gate: the `d3d11`/i386
  probe plus Portal 2 and Hollow Knight.
6.3 **B.** Whatever 5.1–5.3 find, with the Castle Crashers Demo as the gate.
6.4 **D.** Cat Mail Co. Demo's own fault. Oxygen Not Included waits on its log.
6.5 **E.** Refuse up front a title whose files or store notices name the EA app, Origin
  or Ubisoft Connect, with the reason on the page.
6.6 **F, PLA-9.** The launch entries for apps 70 and 10 (and the GoldSrc family) come
  from anonymous PICS app info, which the Steam client can already read without owning
  the app. Their depot file layout comes from public listings. Fix adoption against a
  synthetic folder of that shape, in host tests; no purchase is needed. After that,
  GoldSrc is class A unless `-gl` is switched off. GoldSrc's software and D3D modes are
  worth a look.

## Order

0. Class 0: Spacewar (480) on our phone to confirm, then the 0068 fix as a new
   `madeira-unix` patch, gated on Spacewar, Portal 2 and Hollow Knight. Then the class B
   and C titles again, since some of their failures may be this.
1. 4.1 (done for PLA-29: the player sent the files; the others never posted logs), 2.1
   (done: the owner added both demos), 2.2 and 5.1 on the phone: a day. These answer
   whether class B and class D reproduce here at all.
2. Track 1 and 6.6 (host-only).
3. Track 3 probes, then 6.1's detection message and 6.2.
4. 2.1's in-app free licence (with PLA-19), 2.3 to 2.5, 4.3, 4.4 if accepted.
5. 6.1's OpenGL spike and its own plan.

Each chunk ends with `./pp test`, and a phone gate where it changes the runtime (Hollow
Knight to `first-frame+10`, plus the class's free title). The Linear issues get a
`**Plan:**` line pointing here and their class.
