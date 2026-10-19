# 2026-10-16: DirectWrite had no font on the phone; with Tahoma registered, Social Club loads its UI (PLA-374)

**Linear:** [PLA-374](https://linear.app/playportdev/issue/PLA-374), for
[PLA-370](https://linear.app/playportdev/issue/PLA-370) stage D. Plan:
[CEF low-VA build](../plans/finished.md#own-low-address-space-cef).
**Change:** `app/tools/prefix-registry.py` (`FONTS`), the regenerated `app/registry/system.reg`,
and the test `Fonts` in `tools/tests/test_prefix_registry.py`.
**Question:** In the phone Open of [the alias table fix](2026-10-16-alias-table-cap-phone.md),
the CEF browser's main thread overflowed its stack in Chromium's default-font recursion. Why
could Skia create no typeface, and does the launcher's d2d `DrawTextLayout` failure have the
same cause?

- **IPA:** dev, sha256 `6ff8e72669423a6dca99625a15cb1d44b1f50861275ba1d817104099b24852eb`,
  built from `afeb8e2` (branch `dev/pla-291-rockstar-launcher`).
- **Phone:** iPhone18,4, iOS 27.0.1, at 80 % with 3.8 GB free. The owner was attended.
- [M] measured, [I] inferred.

## Result

- **The font recursion is fixed [M].** The browser's main thread did not overflow. The browser
  started its network and storage services and two renderers. The launcher's d2d
  `DrawTextLayout` failures (`hr 0x80004005`) went from 830 lines in the previous Open to none.
- **Social Club loaded its UI [M].** Its log reached `PAGE_READY`, `START_SIGN_IN` and
  `FINISHED` ("Finished loading Social Club UI") at 8.2 s. One second later it lost the browser.
  No screenshot shows the sign-in page.
- **The next blocker is the JIT pool [M].** The second renderer could not load `msvcrt.dll`
  because the 896 MiB pool was full. The browser and the launcher then faulted, and the app
  ended the session with its "ran out of JIT memory" alert.
- **Hollow Knight still works [M].** Its first frame came at +10.18 s, and the screenshot shows
  the title menu.

## The cause

1. **The face Chromium asks for is Tahoma [M].** `SystemFonts::Initialize` reads
   `SPI_GETNONCLIENTMETRICS`. Wine's `win32u` fills the message font from `DEFAULT_GUI_FONT`
   ("MS Shell Dlg"), and `get_real_fontname` resolves that through GDI to the full name
   "Tahoma" (`dlls/win32u/sysparams.c` `init_font_entry`). The phone prefix's `user.reg` has no
   `WindowMetrics` override.
2. **Skia asks DirectWrite's system collection [M].** In Chromium's Windows build,
   `SkFontMgr_New_DirectWrite` takes `GetSystemFontCollection` and the system font fallback.
   `onLegacyMakeTypeface` tries `FindFamilyName`, then `MapCharacters` against the same
   collection (`third_party/skia/src/ports/SkFontMgr_win_dw.cpp`). With an empty collection,
   both "Tahoma" and "sans" give no typeface, and `PlatformFontSkia::InitFromDetails` re-enters
   `EnsuresDefaultFontIsInitialized`.
3. **Wine's DirectWrite collection was empty on the phone [M].** Wine's `dwrite` builds its
   system font set only from the files named in
   `HKLM\Software\Microsoft\Windows NT\CurrentVersion\Fonts` (`dlls/dwrite/main.c`
   `create_system_path_list`; a bare file name is in `%windir%\fonts`). The phone prefix's key,
   pulled with `pp phone pull`, named only four `.fon` files that the app does not ship.
   `.fon` is not a DirectWrite format either.
4. **Why GDI had Tahoma but DirectWrite did not [M].**
   - `wine_host.c` `link_fonts` links `Runtime/fonts` (Wine's own `tahoma.ttf` and
     `tahomabd.ttf`) into `C:\windows\fonts`, where `win32u`'s directory scan finds them for GDI.
   - `win32u` writes that registry key only for fonts in Wine's data directory
     (`dlls/win32u/font.c` `update_external_font_keys`), and the app has none there.
   - The app runs no `wineboot`, and the seed carried the key with no values.
   - So GDI text (dialogs, other titles) worked, while DirectWrite, and Direct2D text drawn
     through it, had no font.
5. **The d2d failure had the same cause [M].** `DrawTextLayout` lays text out with DirectWrite's
   system collection. Once the key named the faces, the failures stopped.

**Host A/B [M]** (desktop Wine 11.19, a scratch prefix in the build area, a small
llvm-mingw program that lists the DirectWrite system collection):
- stock prefix: 335 families, Tahoma found;
- the phone's key (one `.fon` value), with Tahoma only linked into `windows\Fonts`: 0 families,
  and neither Tahoma nor `sans` found;
- the same, plus the two seed values: 1 family, Tahoma.

## The change

- `prefix-registry.py` seeds `"Tahoma (TrueType)"="tahoma.ttf"` and
  `"Tahoma Bold (TrueType)"="tahomabd.ttf"` in that key. These are Wine's own faces, not
  Microsoft fonts.
- The key is already marked for top-up, so an existing prefix gets the values at its next
  launch. On the phone, `wine_host` logged `2 values added to 1 present keys`.
- The value names are the faces' full names plus " (TrueType)", as `win32u` names its own
  registrations, so `load_registry_fonts` skips the faces it has already loaded.
- The generator fails if `FONTS` names a file that `Runtime/fonts` does not have. The test
  checks that the seed registers exactly the faces that `stage-artifacts.py` ships.

## The phone runs (IPA `6ff8e726…`)

| Run | What | Result |
| --- | --- | --- |
| `20261016T195914` | `pp install --no-build`, then `--play app-367520 --until first-frame+10 --shot` (one lock session) | JIT 2.39 s, runtime +3.35 s, first frame +10.18 s; title menu |
| `20261016T200019` | `--settings 'launcher-rockstar:{"runtime":"env.FEX_SMCCHECKS=none"}'` | Saved |
| `20261016T200043` | `--action open-launcher:rockstar --until "mark:first window+240" --wait 600`, screenshots at 60, 150 and 230 s and at stop | First window +30.39 s; until mark reached; the session ended on `pool=exhausted:head` |
| `20261016T200457` | `--settings "launcher-rockstar:{}"` | Key cleared |

Runs 2–4 were one `pp phone lock` session.

**Social Club [M]** (ms from its SDK start):
- 216: `WAIT_BROWSER_WINDOW`;
- 808: browser subprocess connected;
- 3,358: `LOADING`;
- 3,372: `WAITING_FOR_PAGE_LOAD`;
- 5,389: the second IPC channel connected (the renderer);
- 7,716: `WAITING_FOR_PAGE_READY`;
- 8,163: `PAGE_READY`, then `START_SIGN_IN`;
- 8,166: `FINISHED`;
- 9,105: "Main browser connection lost";
- 9,221: `FAILED`.

**Screenshots [M]:**
- 60 s: the crash handler's dialog, "The Rockstar Games Launcher exited unexpectedly", code
  `C0000005`. This is a GDI dialog, and its text was drawn.
- 150 s, 230 s and stop: Playport's alert "Rockstar Games Launcher ran out of JIT memory".
- No launcher window drawn with d2d was on screen, so its text is known only from the log
  (no `DrawTextLayout` failures).

**The tree [M]:**
- `services.exe`;
- `Launcher.exe` with its crash handler, `LauncherPatcher.exe`, a second `Launcher.exe` with its
  crash handler, and `RockstarService.exe` (twice);
- the browser `SocialClubHelper.exe`, with its network service, storage service and two renderers;
- later, `rpcss.exe`.

**Memory [M]:**
- footprint peak 5,849 MB;
- pool 896 MiB, just before the end:
  - head 534 MB (502 live), tail 363 MB (337 live), room 0;
  - 392 images, 13 children;
  - `head_exhausted=99`, `tail_refused=7`, `alias_full=0`;
- band 16,384 MB: peak 15,862 MB, largest free 227 MB, 197 threads, `refused=0`.

**The first renderer's large reservations [M]:** one 256 MB placeholder reservation
(`type=0x42000`), then eight 512 MB `MEM_RESERVE` reservations, 4,352 MB in total. The second
renderer died before it made any.
(Corrected in [fewer CEF processes](2026-10-16-cef-fewer-processes-phone.md#v8-code-range-correction-m):
these are requests, and V8 retries each code range four times, so most were refused.)

## The next blocker: the JIT pool fills [M]

- **Where it fails.** The second renderer's `msvcrt.dll` `.text` asked for 1.1 MB, and the pool
  had none left: `[jit-pool] EXHAUSTED … FAILING the load`. Its `advapi32.dll` then failed to
  load.
- **What fills the head.** Pool copies of the ARM64EC builtins, one per process. Examples:
  `shell32` 87 MB over 9 copies, `libarm64ecfex` 64 MB over 14, `kernelbase` 43 MB over 14.
- **What fills the tail.** FEX code buffers per process: the first renderer 160 MiB, the
  browser 144 MiB, the network service 96 MiB, and the others 16 MiB each. FEX logged
  `exec alloc degraded … (pool pressure)` 22 times.
- **What failed next.**
  - Two browser threads raised `c000001d` at a tail address (`0x139d24608`).
  - The launcher's threads `0378` and `00a4` read `0x90` at a pool address (`0x13b625c94`),
    and that is the crash handler's `C0000005`.
  - That these follow from code-buffer allocations failing in a full pool is inferred [I].
- **Also seen again.** The storage service's main thread jumped to guest RIP `0x30000010a`, then
  read `0x48` in FEX code (52 times), then overflowed its stack. This came after the browser
  had died, as in the previous Open. Not diagnosed.

## Not checked

- The sign-in page on screen: the browser died 1 s after `FINISHED`, before the 60 s screenshot.
- A launcher window drawn with d2d.
