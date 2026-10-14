# Evidence: Assassin's Creed (15100), SteamStub 2.0 x86 and the WoW64 disk-cache bucket

**Date:** 2026-10-14. **Kind:** host unit tests, a real-sample test, phone runs (dev app).
**Linear:** [PLA-347](https://linear.app/playportdev/issue/PLA-347) (the title),
[PLA-348](https://linear.app/playportdev/issue/PLA-348) (the disk-cache bug).
**Branch:** `dev/pla-347-assassins-creed`.
**IPA (dev):** `d8603db1d55ca3fd4dd574f9e9a09f803a085e1e09d142f1d6a010b7bf10dbf5`.
iPhone18,4, iOS 27.0.1. Run directories are under `$PLAYPORT_BUILD/ui-runs/`.

## Profile

Steam starts `AssassinsCreed_Game.exe`, a 32-bit "DirectX Version Selector". It starts
`AssassinsCreed_Dx10.exe` itself; no dialog was shown. `AssassinsCreed_Dx9.exe` and
`AssassinsCreed_Dx10.exe` are 32-bit, not wrapped, and import no `steam_api`.
`testapp.exe` is the same file as the launcher.

## 1. SteamStub 2.0 x86 on the launcher

IPA `2e47d6e3…` (before the change), run `20261014T093831`: a Steam Error dialog,
"Application load error 2:0000065558", and nothing else.

The launcher's entry point is in `.bind`, preceded by the dword `0xC0DEC0DE`. The stub
starts `53 51 52 56 57 55 8B EC 81 EC 00 10 00 00`, then `mov esi, 0x46E4D8` and
`mov ecx, 0xEE`. That is a 952-byte header at that address, XOR-chained the way 3.x
headers are. Decoded, it gives:

- flags `0x5` (validation, encoded code);
- original entry `0x425C98`;
- code `0x401000` + `0x3C000`, the dwords XOR-chained from key `0x50917C1F`;
- app ID 15100.

The decoded code at the entry is MSVC's CRT start (`call`, then `jmp`).

**Change:** `SteamStub.swift` now reads variant 2.0, x86 only:

- header sizes 856, 884 and 952 (in the 856 layout the fields start 4 bytes earlier);
- the code is decoded when flag `0x04` is set;
- the entry point is set back, and `.bind` stays (as for 3.1 x86).

**Tests:** `./pp test --swift SteamClient --filter SteamStub` passes 17 tests with
1 skipped. That includes made-up 2.0 images (all three sizes, with and without encoded
code, refusals). With `STEAMSTUB_SAMPLE` set to the real launcher, the real-sample test
passed: `SteamStub 2.0 x86 with encrypted code, app 15100, OEP 25c98, flags 5`.

## 2. The game's process faulted: one WoW64 disk-cache bucket for every process

IPA `cb99adcb…` (stub removed), run `20261014T094849`:

- The launcher (window `0x7038950000`) started `AssassinsCreed_Dx10.exe` and exited.
- The child (window `0x7138950000`) faulted at its first i386 instruction,
  `LdrInitializeThunk` (`c0000005`, eip `7bf8f112`, then a loop at `7bf8e628`).
- The faulting block loads `x20 = 0x7038950000`, the launcher's window (`movz`/`movk`).
  The fault address was `0x703bc9fd0c`, which is that base plus the child's esp.

With the FEX disk cache off for the title (`--settings 'app-15100:{"diskCache":false}'`,
run `20261014T095308`), the game reached first frame at +5.08 s and showed its disclaimer
screen.

**Cause:** fex 0043 keys the process bucket on `IosGuestWindowBase`. But the WOW64 module
set that in `IosHostInit`, after `CreateNewContext`, and the `ContextImpl` constructor
runs `DiskCache::Init`. Every 32-bit process hashed a base of 0. The phone's cache held
only two process buckets, one ARM64EC and one WoW64. A second 32-bit process with another
window therefore loaded blocks compiled for the first one's window.

**Fix:** `patches/fex/0044` calls `IosHostInit` before the context is created.

## Phone runs (IPA `d8603db1…`, disk cache on, the default)

Each run logged `steamapi: emulated, stub: removed`.

| Run | Title | Result |
| --- | --- | --- |
| `20261014T100045` | AC, cache cold | first frame +5.25 s; child window `0x7138950000`, its own bucket |
| `20261014T100138` | AC, again | first frame +5.18 s; child window `0x7139b70000` (moved), cold again; intro video shown |
| `20261014T100231` | Hollow Knight, `--until first-frame+10 --shot` | first frame +9.29 s; title menu |

The cache now holds four process buckets: ARM64EC, the launcher, and two game windows.

With `pp ui --pad --leave-running`:

- The intro trailer (Bink) plays smoothly.
- The title screen ("Press Any Key To Continue") is reached.
- One mixed A/Start/B sequence got past the title into a loading screen and further
  scenes, then back to the title.
- A single A or Start sent during the title's fade-in did not register.

The owner took over testing at this point. Menus, new game and control in play were
**not** checked by this session.

## The owner's play

On the same IPA, the owner played the game on the phone and reported it **playable**:
status Works.

## Open

- A warm start gains nothing when the game's window base moves between launches (seen once
  here). This costs speed only, not correctness.
