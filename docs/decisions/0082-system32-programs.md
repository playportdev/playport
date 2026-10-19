# 0082: system32 has Wine's programs, built for arm64ec

**Status:** accepted, 2026-10-11, by the supervisor of the compatibility speedrun with the owner
away (the conservative option at each choice, recorded for review);
[PLA-165](https://linear.app/playportdev/issue/PLA-165). Amends the arm64ec program set of
[0070](0070-wine-modules-proton-parity.md) and [0071](0071-wine-modules-full-proton-set.md); the
rest of both stands. [Evidence](../evidence/2026-10-11-system32-programs.md). Its "a `.cmd`
prerequisite now really runs `cmd`, `conhost`, `start`" is amended by
[0096](0096-steam-outcome-parity.md): a standard Steam VC++ `.cmd` runs its installer directly.
Since wine-11.20 the mechanism below is out of date, not the decision: a program's `Makefile.in`
chooses its architectures (`ENABLE_ARCHS`), so `--enable-<program>` no longer adds one. The
arm64ec tree builds every program that does not restrict them, `patches/wine-pe` 0047 adds
arm64ec to the ten that name only the host or the 16-bit architecture (`conhost`, the services,
`winemenubuilder`, `winevdm`), and `wine-pe.sh` passes `--disable-` for `winetest`, `winedbg`,
`wineboot` and `explorer`; the arm64ec set is what it was on wine-11.19
([evidence](../evidence/2026-10-18-wine-11.20.md)).

## Context

A wineboot'ed prefix, and Proton's for x86-64, has about 100 programs in `system32`
(`start`, `reg`, `conhost`, `taskkill`, `xcopy`, `where`, `setx`, …). Playport's had eight.
The cause is the build, not the staging. Wine's configure leaves every program out of an
arm64ec build unless its `enable_` default names arm64ec (`aclocal.m4`
`wine_fn_config_makefile`). Upstream's ARM64 layout is ARM64X, and there `system32`'s
programs are native aarch64 builds. Playport builds arm64ec alone, `system32` is that set,
and the aarch64 programs live in `sysarm64`, which only a WoW64 process's native loader
reads (wine-pe 0015). An x86-64 process cannot start a pure ARM64 one here. 0070/0071's rule
stages what the manifest has, so `system32` held only the eight programs configure enables
for arm64ec.

On the phone, Counter-Strike's Steam VC++ 2019 `.cmd` failed at once:
`wine: failed to start L"\??\C:\windows\system32\start.exe": c0000135`. kernelbase's start of
`conhost.exe` failed the same way.

## Decision

- **The arm64ec tree builds every program configure lists.** `build/stages/wine-pe.sh` passes
  `--enable-<program>` for each `programs/` entry of the tree's own `configure`. The list is
  derived, not pasted, so a new Wine program comes with a pin move. 0070/0071's rule stages
  them into `Runtime/arm64ec-windows` and so into `system32`, as Proton's x86_64 set has them.
- **Left out, so what happens on the phone today does not change:**
  - 16-bit programs (`enable_win16`).
  - `winetest`, as before.
  - `winedbg`. kernelbase starts `winedbg --auto` for any unhandled exception (the seed has
    wine.inf's `AeDebug` `Auto`). This is unproven for x86-64 pseudo-processes under FEX, and
    it could hold a crashing title instead of ending it. Today the start fails and the title
    ends. A follow-up issue tracks it.
  - `wineboot`. `ExitWindowsEx` starts it to end the session (an installer asking for a
    restart).
  - `explorer`. A folder's `ShellExecute` opens it as a file browser window. win32u's desktop
    start of it stays skipped on iOS.

  Their aarch64 and i386 builds are staged as before.
- **Kept as-is:** `control` and `winemenubuilder` were already turned off by the seed's load
  orders (0071), and that covers the arm64ec builds too. Nothing starts the services
  (`services`, `rpcss`, `plugplay`, …), since the app runs no service manager, so they are
  files only.

## Why

The redistributable installers Steam runs (VC++ 2015–2022 `.cmd` files with `start /w`),
installers and launchers call these programs by their `system32` path, as on Windows and under
Proton. Building them is the existing rule applied to the guest's architecture. No staging
special case, no copy and no new launch path is needed.

## What it costs

- **Size.** +101 files and +68.6 MB (65.4 MiB) in the bundle. The IPA, now deflated, grows by
  about 3.4 MB. The build record is `build/generated/wine-pe-arm64ec-windows.tsv`.
- **Console windows.** A console program started without a console gets Wine's `conhost`,
  which shows a console window. Examples are a Steam `.cmd` prerequisite, or a console title
  itself. Before the first frame it shows as any guest window (0075), as it would on Windows.
  Before this decision the console failed and the program ran without one.
- **JIT pool.** Each child process costs head space, which is not reused (see
  ARCHITECTURE.md). A `.cmd` prerequisite now really runs `cmd`, `conhost`, `start` and the
  installer's processes before the game, in the game's session. Counter-Strike's two VC++
  2019 entries left 225 of 512 MiB of head used before the game, against 27 without them.
  Only the Play that runs them pays this.
