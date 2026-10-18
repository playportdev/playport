# 0109: Chromium's switches for a CEF browser, and where a launcher's Open lives

**Status:** accepted, 2026-10-16, by the supervisor of the publisher-launchers run (chunk 4, steps
4 and 5 of the [launchers plan](../plans/2026-10-12-launchers.md)), within the owner's decisions D1
and D2 there. [PLA-277](https://linear.app/playportdev/issue/PLA-277),
[PLA-271](https://linear.app/playportdev/issue/PLA-271),
[PLA-254](https://linear.app/playportdev/issue/PLA-254).
Amended by [0111](0111-fewer-cef-processes-with-chromium-features.md) (2026-10-16): the switch set
also turns on `NetworkServiceInProcess2` and `RunVideoCaptureServiceInBrowserProcess`.

## Context

The Rockstar Games Launcher draws its UI with CEF (Chromium 143) in `SocialClubHelper.exe`, which
`socialclub.dll` starts inside `Launcher.exe` and inside the game. Each Chromium process is a
pseudo-process here and costs FEX threads, band and footprint. Plan R1 asked for
`--single-process`; Stage R showed Social Club's UI fails under it, and fails with one renderer
(its IPC wants one renderer per page). What worked under desktop Wine was `--in-process-gpu
--disable-gpu --disable-gpu-compositing --js-flags=--jitless`: 8 processes, not 9
([recon](../evidence/2026-10-15-rockstar-launcher-recon.md)). The only official switch,
`-scDisableGpu`, covers two of the four.

## Decision

- **The policy (madeira-unix 0152).** At process creation, a process whose image has `libcef.dll`
  beside it and no `--type=` switch is a CEF browser. Its command line gets those four switches;
  Chromium hands them on to its children. This is R1's fallback, made the default for every CEF
  browser, in one place (D1), with `--jitless` first (D2). No `--single-process`, and no child is
  refused.
- A switch the app already passes is kept as it wrote it. Children are left as started. Every case
  logs a `[chromium]` line.
- Rockstar's files are never changed. The same rule covers the launcher's `SocialClubHelper.exe` and
  the one a game's `socialclub.dll` starts.
- **Settings › Launchers.** A launcher's play settings live in PlayportKit's `PublisherLauncher`
  table: Windows services, its JIT pool and its backend. The compatibility table is keyed by a
  game's title id. The Rockstar entry has services on, 896 MiB (0108) and Vulkan (0100). The
  executable is found from the `InstallFolder` its installer wrote, and Open starts it standalone.
  The section is **dev builds only until a launcher passes Stage 1**. The dev driver's
  `open-launcher:ID` calls the same Open (0012).

## Consequences

- Another CEF app (a later launcher) gets the same four switches without new code. A launcher
  that needs another set gets a new record.
- JavaScript runs interpreted. That is slower, but it adds no V8 machine code for FEX to
  translate again or for the alias table to hold. Whether V8's JIT is worth it is measured once the
  UI works (D2).
- Qt WebEngine (the EA app) is not detected by this rule; Stage 3 adds it.
