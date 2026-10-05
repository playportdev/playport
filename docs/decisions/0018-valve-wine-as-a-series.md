# 0018: Valve's Wine commits as a series on WineHQ, not Valve's branch as the base

**Status:** accepted, 2026-09-28. Keeps [0013](0013-wine-on-upstream.md)'s
base, WineHQ's latest development release, and adds a series on it. It
settles the choice the [Wine-on-Proton plan](../plans/2026-09-27-wine-on-proton.md)
left open at its step-0 checkpoint. The measurements are in the
[evidence record](../evidence/2026-09-28-wine-proton-rebase.md). Its pin
source (picks from `proton_11.0`) is superseded by
[0049](0049-latest-pins.md): `wine-valve` is picked from Valve's
bleeding-edge branch.

## Decision

- `pins.lock`'s `wine` row stays a WineHQ release commit (wine-11.18).
  Valve's `proton_11.0` branch (ValveSoftware/wine, the Wine that Proton 11
  ships) is not the base.
- The Valve commits Playport wants are carried as `patches/wine-valve`,
  cherry-picked from `proton_11.0` onto the `wine` pin with `patches/wine-port`
  applied. Each patch names its original in `Valve-commit:` and says
  `Picked: clean` or `Picked: resolved`; the class is `valve`, and only this
  series may use it. The series is applied after `patches/wine-port` and
  before `patches/wine-unix` and `patches/wine-pe`, in both Wine trees.
- The new `wine-valve` row records the `proton_11.0` commit the series was
  picked from. It is provenance: the build takes the patches, not Valve's
  tree, and `pp sync` never moves it.
- Wanted are Valve's PE-side game fixes and its ARM64EC and FEX work, the
  plan's two wanted classes. Left out are the commits that WineHQ already has
  in the pin, fsync and ntsync, the Linux desktop and input drivers, Proton's
  Steam, VR and launcher integration, the Media Foundation and GStreamer
  stack (Playport keeps its own video work), changes to files the `*_ios.c`
  replacements override, and changes that do nothing on this runtime (for
  example `wine.inf`, which the app never runs). The record lists every one of
  the 1,453 commits with its verdict.

## Why

The plan's rule was: take Valve's branch as the base when the class of
changes lost to the replacements is small and the ARM64EC and FEX work
depends on the rest of Valve's tree; otherwise carry a series. Neither holds.

- **The replacement class is not small.** 152 of Valve's own commits (not
  backports) change a file that a `*_ios.c` replacement overrides, 3,306 lines
  in those files, each to be carried into the replacement by hand. Before
  that, the replacements would have to be ported back from 11.18 to 11.0
  across 6,615 changed lines in the 22 overridden files, the work 0013 did
  in the other direction.
- **The ARM64EC and FEX work does not depend on Valve's tree.** 395 of the
  1,453 commits are backports that wine-11.18 already has, among them the
  ARM64EC changes the plan named: cooperative suspend, the synthesized
  caller context in `RtlRaiseException`, EC-aware `capture_context`,
  `BTCpuNotifyProcessExecuteFlagsChange`, and cooperative suspend for syscall
  callbacks. Of Valve's own ARM64EC and FEX commits, five were reverted in
  Valve's own tree (Asahi TSO, unaligned atomics, the FEX stats shm, a
  work-in-progress ARM64EC suspend and a `RtlVirtualUnwind2` fault handler,
  the last two replaced by the upstream commits above). Of the rest, the AVX
  context does nothing on iOS, where
  Madeira's FEX reports no AVX (`patches/fex-port` 0009). The SVE state does
  nothing on Apple CPUs, which have no SVE. The WoW64 suspend work serves
  32-bit guests, which are not built. The DLL-name commit makes Wine load
  FEX as `libarm64ecfex.dll`, while Playport ships it as `xtajit64.dll`, the
  name Windows and upstream Wine use and Madeira's loader patches expect.
  The Wine Mono commit changes only the aarch64 build: arm64ec builds define
  `__x86_64__`, so the `mscoree` that x86-64 games load already picks the
  x86 Wine Mono.
- **A series keeps what 0013 bought.** The base stays the latest WineHQ
  release, so upstream fixes arrive every two weeks, and the Media
  Foundation video work on 11.18 stays as it is. Valve's 115 winegstreamer
  commits would have meant redoing that work.

## What it costs

- A Valve change to a file a replacement overrides is not in the build.
  That is the price of B, as the plan said, and the evidence record lists
  those commits.
- The series has to be re-picked when the base moves. On each WineHQ
  release that 0013's re-port brings in, `patches/wine-valve` is replayed
  after `patches/wine-port`: a patch that no longer applies is resolved or
  dropped. A patch that upstream now has is dropped. Each outcome is
  recorded.
- **How the pin moves.** When Valve moves `proton_11.0` (each Proton 11
  point release), the new commits are sorted by the same rules, the wanted
  ones are picked onto the series, and the `wine-valve` row moves to that
  commit. The step-0 scripts are kept with the evidence record for this. When
  Valve opens its Proton 12 branch on Wine 12.0, measure again. If that base
  is then no older than Playport's WineHQ pin, the cost that decided this
  record (porting the replacements backwards) is gone, and Valve's branch as
  the base is worth deciding again in a new record.
- Every change to the series is a hand-driven pick followed by the device
  gate (a Hollow Knight play), as for `patches/wine-port`.
