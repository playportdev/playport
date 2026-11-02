# Evidence: Super Meat Boy (Epic) on the phone

**Date:** 2026-10-08. **Phone:** iPhone18,4, iOS 27.0, Wi-Fi, dev build, driven with `pp ui`;
the sessions were unattended. Title: Super Meat Boy from the owner's Epic library
(`epic-Buffalo`, Epic app name `Buffalo`), build `1.2.5.3`. **Linear:**
[PLA-108](https://linear.app/playportdev/issue/PLA-108). Run directories are under
`$PLAYPORT_BUILD/ui-runs/` (the first test's under `$PLAYPORT_BUILD/agent-notes/super-meat-boy/`),
desktop runs under `$PLAYPORT_BUILD/agent-notes/smb-black/`; the screenshots stay there.

## Status

**Plays** on dev IPA `Playport-26.5-ee7f22e1.ipa`, sha256
`ee7f22e170c33f37048955b6d560e9594dfce27311a923fe7d1d03d1d4d6e106` (commit `36c536b`; release
build of the same commit `433b514647fa796855cca36142ca3c6ce07086b87e8b506286a76a9a746e4626`,
verified by `pp verify`, not played: decision 0068). Its game page is untouched: the game's
compatibility default (decision [0074](../decisions/0074-per-title-compatibility-defaults.md))
gives it the 16:9 aspect ratio ([0073](../decisions/0073-screen-aspect-ratio.md)), so it runs
at 1280x720 (Playport's 720p) with bars at the sides, and renders: the intro, the menus and
level 1-1 with a scripted pad. Graphics through DXVK 3.1.1's `d3d9` (i386) on KosmicKrisp under
WoW64.

The black screen of the earlier runs was the game's, not Playport's: **Super Meat Boy draws
nothing on a screen wider than 16:9**, and the phone's guest screen was 1564x720 (2.17:1).

Earlier blockers, each fixed on the way: exit `0xc0000142` at load (i386 `opengl32`, below;
[2026-10-08-wow64-opengl32.md](2026-10-08-wow64-opengl32.md)), the unaudited window thunks
([2026-10-08-wow64-menu-thunks.md](2026-10-08-wow64-menu-thunks.md)) and the PNG textures
(WIC's registration, [2026-10-08-wow64-registry.md](2026-10-08-wow64-registry.md)).

## The black screen

State before: alive, presenting at 60 Hz (a 640x480 swap chain for the game's render test,
then 1564x720 FIFO on a new borderless window), textures loading, no failing call and no DXVK
error, an entirely black screenshot; its `OutputDebugStringA` trace stopped after 78 lines in
every run.

- **The trace stops in our log, not in the game.** `ios_log_guest_exception`
  (`signal_arm64_ios.c`, Madeira's ntdll) logs only the first 80 guest exceptions, and each
  `OutputDebugStringA` is one (`[exc-disp] dispatch` plus its text: 80 + 78 lines). The game's
  own log, `UserData/TommunismEngine.log`, pulled from the phone, goes on: 12,067 lines, through
  the characters, the intro player and its cut scenes, the same lines in the same order as on
  the desktop.
- **Desktop A/B** (Proton 10 on the sway display, the phone's game files pulled read-only with
  `pp phone pull`, Playport's Epic arguments with zeroed identity; the game needs no EOS). In
  its own window at the desktop's mode it shows the Team Meat logo, a "Newgrounds" splash and
  the intro at +5/+15/+30 s, with no input. The same with the IPA's own i386 `d3d9` (DXVK
  3.1.1), `d3dx9_43`, `d3dcompiler_43`, `d3dxof` and `wined3d` as native DLLs. The guest screen
  is the difference: in a Wine virtual desktop of each size (the IPA's DLLs unless noted),

  | Virtual desktop | Aspect | Screen at +20 s |
  | --- | ---: | --- |
  | 1152x720 | 1.60 | renders |
  | 1280x720 | 1.78 | renders |
  | 1600x900 | 1.78 | renders |
  | 1312x720 | 1.82 | black |
  | 1366x720 | 1.90 | black |
  | 1440x720 | 2.00 | black |
  | 1564x720 (the phone's) | 2.17 | black; also with Proton's own DXVK |
  | 1568x720, 1600x720 | 2.18, 2.22 | black |

  The game picks the screen's mode for its 1564x720 window and draws nothing in it.
- **Phone A/B** (dev IPA `c71c13d6`, one setting each, through `pp ui --settings`):

  | Run | Setting | JIT | First frame | Screen at `first-frame+25` |
  | --- | --- | --- | --- | --- |
  | `20261008T211823` | `dxvk.hud=fps,devinfo,frametimes` | 2.41 s | +3.90 s | black, DXVK's HUD drawn over it at 59.8 FPS: the present path works |
  | `20261008T212050` | `x87Reduced=false`, HUD | 2.38 s | +3.68 s | black, HUD at 59.8 FPS: not FEX's x87 precision |
  | `20261008T212856` | `screen=1280x720` | 2.38 s | +3.72 s | the intro's backdrop, pillarboxed: renders |

## The fix

- Decision [0073](../decisions/0073-screen-aspect-ratio.md): an aspect ratio (Phone, 16:9,
  16:10, 4:3) beside the resolution, in Settings and on a game's page.
- Decision [0074](../decisions/0074-per-title-compatibility-defaults.md): per-title
  compatibility defaults; Super Meat Boy's is aspect 16:9, with the reason "This game draws
  nothing on a screen wider than 16:9." shown on its page.

Phone, one locked session on the final dev IPA (`ee7f22e1`, installed in place, container and
titles kept, game page untouched):

| Run | What | JIT | First frame | Outcome |
| --- | --- | --- | --- | --- |
| `20261008T221152` | Settings › Graphics | | | Aspect ratio "Default · Phone", Resolution "Default · 720p" |
| `20261008T221226` | the game's page, both pickers | | | "ⓘ Set for this game's compatibility" with the reason; Aspect ratio "ⓘ For this game · 16:9"; Resolution "Default · 720p"; the aspect picker's Default reads "16:9, for this game's compatibility"; the resolution picker lists Native, 1080p, 900p, 720p, 540p |
| `20261008T221404` | play to `first-frame+30`, then a scripted pad (START and A) for about 50 s | 2.28 s | +3.59 s | `display: screen 1280x720 (the title's screen 16:9@720)`; the intro ("Nobody loves Dr. Fetus", pillarboxed); with the pad the world map and level 1-1 (Meat Boy, Bandage Girl, the timer, the tutorial sign) |
| `20261008T221559` | Hollow Knight's page | | | no marker; "Default · Phone", "Default · 720p" |
| `20261008T221634` | Hollow Knight to `first-frame+10` | 2.36 s | +8.65 s | 1564x720, main menu |
| `20261008T221723` | Portal 2 to `first-frame+10` | 2.38 s | +5.70 s | 1564x720, the "powered by Source" splash |

An earlier session on dev IPA `b721f4fe` (the compatibility default as a fixed 1280x720 before
the resolution became a level in each shape) showed the same: the intro, then the world map and
level 1-1 with the pad (runs `20261008T215123` to `20261008T215655`). The pad runs left Super
Meat Boy's own save with level 1-1 started.

## First test: exit 0xc0000142

**IPA:** `Playport-26.5-44b6e3dc.ipa` (dev), sha256
`44b6e3dcc2df40238b3af47eaa189a6c30eacddc0b8400003d0caf92a02110e7`.

## Profile (from the PE headers)

`SuperMeatBoy.exe` (3.6 MB, read from the Epic depot with the DLL survey's fetch):

- **i386** (`PE32`, Machine `0x14c`), Windows GUI subsystem 6.0.
- **Direct3D 9**: imports `d3d9.dll` (`Direct3DCreate9`) and **`d3dx9_43.dll`**; input
  through `DINPUT8.dll` and `XINPUT9_1_0.dll`; audio through `WINMM.dll` (its strings name
  `fmod`). The other imports: WS2_32, CRYPT32, ADVAPI32, WLDAP32, Normaliz, USER32, ole32,
  OLEAUT32, KERNEL32, SHELL32.
- **Engine:** Team Meat's own, with libcurl 7.54.1 linked in statically (the WLDAP32,
  Normaliz and CRYPT32 imports).
- **DRM / store SDK:** no Epic Online Services, Steam or Galaxy library in its imports or
  among the depot's executables (the depot's other PE files are DirectX and VC++ redist
  installers under `Prerequisites/`).

This is decision [0047](../decisions/0047-i386-titles-on-vulkan.md)'s class: an i386
Direct3D 9 title on the Vulkan route (DXVK's `d3d9` over KosmicKrisp, under WoW64 with FEX).
The app found the same: `Direct3D evidence for epic-Buffalo: Direct3D 9`.

### Install (`--action install:epic-Buffalo`)

Through Library › Epic Games with the existing signed-in session (not refreshed or
exported): build `1.2.5.3`, 519,255,478 bytes in **9 s**, catalogued as `epic-Buffalo`,
executable `SuperMeatBoy.exe` from the manifest, arguments `-epicapp=Buffalo -epicenv=Prod
-EpicPortal -epiclocale=en`. Verify before the first play: **42/42 files OK** against
Epic's manifest in 1.2 s, nothing unlisted. Free space before: 4.9 GB.

### Plays (Vulkan, the defaults)

`pp ui --play` refuses `epic-Buffalo` (its title-ID check takes lower case only; Epic app
names can have capitals), so the runs used `--action play:epic-Buffalo`, which reaches the
same Play button.

| Run | JIT | Runtime | Game started | End |
| --- | --- | --- | --- | --- |
| `play1` (verify, then play, `--until first-frame+20 --shot`) | 2.41 s | +2.84 s | +3.07 s | `0xc0000142` after 188 ms, no frame |
| `play2` (play, same `--until`) | 2.52 s | +2.95 s | +3.17 s | `0xc0000142` after 187 ms, no frame |

Both screenshots show Playport's Home screen with "Super Meat Boy stopped unexpectedly. It
exited with code 0xC0000142." over it. Pool 26 MiB head, band 214 MB used: memory and JIT
are not involved.

### Why it failed

The game never runs a line of its own code. Its i386 process (WoW64) loads its imports from
`system32`: DXVK's `d3d9.dll` (the `vulkan/i386-windows` overlay; it imports `SETUPAPI`, not
wined3d), then Wine's `d3dx9_43.dll`, which imports Wine's `d3dcompiler_43.dll`, which
imports **`wined3d.dll`**, which imports **`opengl32.dll`**:

```
002c:err:wow:wow64_NtMapViewOfSection Playport: i386 image C:\windows\system32\d3d9.dll at 79fd0000
002c:err:wow:wow64_NtMapViewOfSection Playport: i386 image C:\windows\system32\SETUPAPI.dll at 79f50000
002c:err:wow:wow64_NtMapViewOfSection Playport: i386 image C:\windows\system32\d3dx9_43.dll at 79eb0000
002c:err:wow:wow64_NtMapViewOfSection Playport: i386 image C:\windows\system32\d3dcompiler_43.dll at 79e70000
002c:err:wow:wow64_NtMapViewOfSection Playport: i386 image C:\windows\system32\wined3d.dll at 79b80000
002c:err:wow:wow64_NtMapViewOfSection Playport: i386 image C:\windows\system32\opengl32.dll at 79a40000
[unixlib] module 0x70b2390000 (opengl32.dll) WoW64 -> 0x163dba638 (stub table)
002c:err:opengl:DllMain Failed to load unixlib, status 0xc00000bb
002c:err:module:loader_init "opengl32.dll" failed to initialize, aborting
002c:err:module:loader_init Initializing dlls for L"C:\\Games\\SuperMeatBoy\\SuperMeatBoy.exe" failed, status c0000142
```

The import chain is read from the staged DLLs in the IPA (`llvm-objdump -p`): i386
`d3dx9_43` imports `d3dcompiler_43`, `d3dxof`, ole32, gdi32, user32; `d3dcompiler_43` imports
`wined3d`; `wined3d` imports `opengl32`. Both `d3dx9_43` and `d3dcompiler_43` were in
`app/artifacts.tsv` before 0070, so this is not a regression of the Proton module set.

This is the failure the compatibility plan records as class 0
([PLA-12](https://linear.app/playportdev/issue/PLA-12), found in the PLA-29 log): an
i386 process cannot initialise `opengl32.dll` because `patches/madeira-unix` 0068 gives a
WoW64 caller the all-fail stub table, whose attach fails. The plan names wined3d's own users;
Super Meat Boy shows a new path into it: **any i386 title that imports `d3dx9_*`** reaches
opengl32 through `d3dcompiler_43` and `wined3d`, even with DXVK's `d3d9`. The plan's proposed
fix (keep the GL-absent table, whose attach succeeds, for WoW64 callers) would let this load
finish; what the game does after that is not known. Not fixed here.

Ruled out: the install (42/42 verified), Epic sign-in (the process ends in the loader,
before the game reads its arguments; no EOS library), memory and JIT (both normal),
a hidden window (no `[win-pos]` line: no window is created), DXMT (no i386 build; the title is i386).
Not done: a desktop Wine/Proton run (only the depot's PE files are on the workstation and
the phone's log answers what it stops on).

Outcome then: exit `0xc0000142` at load, before any frame.
