# The Witcher 2 (20920): the launcher starts the game and `witcher2.exe` faults at its entry

**Linear:** [PLA-478](https://linear.app/playportdev/issue/PLA-478) (the title; the game does not
start), [PLA-479](https://linear.app/playportdev/issue/PLA-479) (guest windows take clicks for a
window the layer draws behind another one).

The owner reported that the installed game's launcher "doesn't allow me to click to start the
game". It does take the click — the launcher's Play item is reachable, spawns `bin\witcher2.exe`,
and the game faults 0.3 s later before any frame. The taps on most of the launcher's menu go to a
different window (PLA-479), which is why nothing seemed to happen.

Dev IPA `defe3d01ee144147ffcb11e8d11ea5c640a15493ddb0fa361bb8acae374ec33e` (HEAD `46c72d5`,
dirty), iPhone18,4, iOS 27.2, title defaults (Vulkan, the title's screen 720), app 20920 installed
from Steam. Runs under `$PLAYPORT_BUILD/w2-diag/run1..run7`; logs are `pull/s1-host.log` and the
full pull in `$PLAYPORT_BUILD/w2-diag/s1-host.log`.

## The launcher

`Play` starts `C:\Games\the witcher 2\Launcher.exe` (32-bit MFC, Direct3D 9 for its background and
GDI+ for its labels). It becomes a guest GDI window (decision 0075):

```
title: in-app start Games\the witcher 2\Launcher.exe
[guest-window] hwnd=0x100ae shown: 363x363 at (597,166)
title: +7.89 s first window
[guest-window] hwnd=0x1005e shown: 576x725 at (494,0)
[guest-window] showing desktop (494,0 576x720) in (288,-0 336x420) pt
```

The picture is readable and its menu drawn at desktop y 469 (`Launch game`), 486 (`Launch
REDkit`), 507 (`Options`), 527 (`Mods`), 546 (`Register game`), 565 (`View Readme file`) — measured
in the run's screenshot through the log's fit (`screenshot y = desktop y * 1.0236`).

Read in the exe: the menu's handler is a command dispatch (`0x40a712`, ids 1–7); `Play` is case 4
and calls `0x40c9b3`, which builds `moduleDir + "\bin\witcher2.EXE"` and calls `CreateProcessW`
with `CREATE_NEW_PROCESS_GROUP|CREATE_UNICODE_ENVIRONMENT`, a `NULL` working directory, and then a
500 ms `SetTimer` that polls `GetExitCodeProcess`. **It never tests `CreateProcessW`'s return
value**, so a failed start is silent. `Options` calls the same code with `"\bin\Configurator.EXE"`
(`0x40c91e`), command 1 `"\bin\editor.exe"` and command 2 `"\bin\UserContentManager.exe"`; the
installed `bin\` has no `editor.exe`.

## The taps (PLA-479)

A sweep of single taps at desktop x=816, one every 5 s, over the launcher:

| desktop y | what is drawn there | result |
| --- | --- | --- |
| 370, 384, 400, 415, 429, 445, 460, 474 | above and on `Launch game` (469) | nothing: no `phase spawn`, no window change |
| 490, 505, 519 | `Launch REDkit` (486) … `Options` (507) | nothing |
| **535** | `Mods` (527) | **`[18:06:45.880] phase spawn: …\bin\UserContentManager.exe`** |
| 550, 564 | `Register game` (546), `View Readme file` (565) | nothing visible (a URL or `ShellExecute`, suppressed) |

The same in the owner's own attempts of 17:43–17:46: taps at (763,530) and (768,535) spawned
`bin\UserContentManager.exe`, a tap at (784,407) spawned `bin\Configurator.EXE`, and no tap ever
spawned `witcher2.exe`.

The boundary is the bottom edge (529) of the unnamed 363x363 window at (597,166) that the launcher
shows first and never hides: `Winios.m` orders the layers by *show* order, so the launcher is drawn
over it and the screenshots show only the launcher, while Wine routes a click to that window. A tap
at the drawn close cross (desktop 925,177) is inside it and also does nothing. With the launcher
alone, the pad's A — Enter on a guest window (`HostIOKit/WindowKeys`) — reaches the default item at
once.

## The launch and the fault

From the same lock session, 20 s after the launcher is up: `pp pad send "600 A" "300 -"`.

```
[18:12:59.248] [wine_host] phase spawn:L"C:\Games\the witcher 2\bin\witcher2.exe"
[wow64-placement] preferred=0x400000 guest=0x400000 delta=0 host=0x71c03f0000 fixups=guest
[wow64-image] … guest=0x400000 size=0x25b0000 … native_exec=0
0074:err:wow:call_user_exception_dispatcher Playport: i386 exception c0000005 at eip 02926f76
    (00000000 81625776): eax 00000000 ebx 7ff00000 ecx 81625776 edx 7bfb1d40 esi 041f8e47 …
wine: Unhandled page fault on read access to 81625776 at address 02926F76 (thread 0074), starting debugger...
0074:err:process:NtCreateUserProcess … image=L"C:\windows\system32\winedbg.exe" cmdline=L"winedbg --auto 112 260"
0080:err:dialog:MessageBoxIndirectW [msgbox] style 0 caption L"Program Error"
    text L"A program on your system has crashed, but WineDbg was unable to attach to the process to obtain a backtrace."
```

`run5-a.png` is that box over the launcher. A second run (18:14) faulted identically: same eip
`0x02926f76`, same `ecx` `0x81625776`, same `ebx` `0x7ff00000` (the 32-bit PEB, `peb32_guest=
0x7ff00000` in the same log).

The exe: 32-bit (`0x14c`), image base `0x400000`, `SizeOfImage` `0x25b0000`, entry
`AddressOfEntryPoint` `0x25262ee` — inside `.bind` (RVA `0x2526000`, `0x8a000`), an unpacker stub
that copies each table entry `([eax+0x10]` bytes from `moduleBase + [eax+0x14]`) into a fresh
`VirtualAlloc`. The faulting instruction at RVA `0x2526f76` is the copy's own `mov cl,BYTE PTR
[ecx]`, with `[ebp-0x56c]` (source = base + table offset) wild, so the stub's table yields a
nonsense source. FEX's own log of the access:

```
[unalign-byte] ml624 #4 SKIP backpatch: byte access cannot be unaligned; insn=19400014 pc=0x13cb8bfbc
    addr=0x7241615776 -> alias emulator (pc-4 preserved)
[store-noalias] #2 addr=0x7241615776 … NO pool/anon alias | region 0x723fff0000+0x8000000 prot=0 max=7
[bus-rgn]   VERDICT <== ANONYMOUS, NEVER RESIDENT — never materialised
```

The target is inside the reserved, never-committed upper half of the WoW64 window, so a wild
32-bit pointer faults there instead of being absorbed.

## The files are Steam's

`pp ui --action verify:app-20920` (run6):

```
library: verify The Witcher 2: Assassins of Kings Enhanced Edition against its Steam manifests
library: verify The Witcher 2: Assassins of Kings Enhanced Edition: 1694/1694 OK, 0 bad, 0 unlisted, 35.7 s
```

## Desktop A/B

The same `bin\` (exe + `fmodex`/`fmod_event*`/`w1import`/`steam_api`/`NewNetworkClient`, pulled
from the phone, no game data) under the workstation's Wine 11.20 in a scratch prefix
(`$PLAYPORT_BUILD/w2-diag/hostrun`, `xvfb-run -a`): **no fault.** It loads `shell32`, `uxtheme`,
`psapi`, `version`, reads all 15,685,632 bytes of itself and exits 1 — it gets past the stub and
stops for the data it does not have.

So the fault is specific to the phone's 32-bit runtime (WoW64 + FEX) — not the game's files, not
the launcher, and not reached by desktop Wine.

## Not checked

The game's first frame (it never got there); a play under desktop Proton with the game's data;
whether the stub's table comes out right if its PEB module walk is fed the same list twice.
