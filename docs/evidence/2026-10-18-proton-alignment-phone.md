# Proton alignment on the phone: FEX 5285020d, Wine 11.20 and the CPSR masks, built in the main checkout (PLA-76)

**Date:** 2026-10-18 (the phone session ran from 00:09 to 00:40 on 2026-10-19).
**Kind:** the M2b phone gates of the [Proton ARM64 alignment plan](../plans/2026-10-05-proton-arm64-alignment.md).
**Linear:** [PLA-76](https://linear.app/playportdev/issue/PLA-76), with
[PLA-389](https://linear.app/playportdev/issue/PLA-389) (`fex` 5285020d, `rpmalloc` ed22744),
[PLA-390](https://linear.app/playportdev/issue/PLA-390) (`wine` wine-11.20, `wine-valve` c53678ab,
madeira-unix 0161) and [PLA-393](https://linear.app/playportdev/issue/PLA-393) (`pp rebase`).
**Branch:** `dev/pla-76-proton-alignment-ws` at `042c89c`, rebased on `main` `dfc527f`. It was moved
from the side copy into the main checkout, as the owner asked ("Move both to main checkout, rebase
onto main and start phone tests"). It is not merged and not pushed. The owner was away, so the
conservative option was taken at each choice.

These runs replace the phone gates that [fex-5285020d](2026-10-18-fex-5285020d.md),
[wine-11.20](2026-10-18-wine-11.20.md) and [cpsr-reserved-bits](2026-10-18-cpsr-reserved-bits.md)
left owed on their side-copy IPAs.

## Build (main checkout)

- **Plan:** `./pp build --plan` listed unix, pe, fex, dxmt, vulkan, steamapi, idevice, stage,
  notices, app and verify.
  - The pins and series of this branch are the reason for most of these.
  - The main checkout's build area had last built the M1 branch (`dev/pla-386-rdr2-vulkan-kk`),
    so vulkan rebuilt from this branch's Mesa series.
- **Time:** `./pp build` (dev) ran from 23:40 to 23:55. The compiler cache was warm.
- **Warnings:** the `libwineserver.a` link test reported its 4 known duplicate symbols, as in W7,
  W8 and M2a.
- **IPA:** `$PLAYPORT_BUILD/out/20261018-235533-6e68a205/Playport-26.5-6e68a205.ipa`, dev.
  - sha256 `6e68a205931092652b519890eeeaa9b464cfcf7e1816734f29d257b2bff9c2de`.
  - verify-ipa: 89 checks passed, 0 failed.
- **Build records:** unchanged.
  - The build rewrote `app/artifacts.tsv` and `build/generated/wine-pe-*.tsv` byte for byte as
    M2a committed them.
  - M2a had kept main's values for the two rows that depend on the build path,
    `lib/libdxmt_combined.a` and `lib/libidevice_ffi.a`. The main checkout's path is main's own,
    so those values are right here as well.
  - Nothing needed committing.
- **Checks:**
  - `./pp test` (full) passed: names, secrets, patches, `tools/tests` (664), the C tests and the
    Swift packages (PlayportKit 337).
  - `./pp slots`: "150 slots, 149 calls: every call matches its slot".

## Phone

- **Phone:** iPhone18,4, iOS 27.0.1, the dev app. Built-in JIT was acquired in 2.37–2.49 s on
  every launch.
- **Battery and space:** the battery went from 78 % to 73 %, on battery throughout. Free space went
  from 6.5 to 6.8 GB.
- **Sessions:** the install, both Hollow Knight plays, the probe import and both probes ran in one
  `pp phone lock` session. Each `pp perf` run took the lock itself.
- **Run directories:** under `$PLAYPORT_BUILD/ui-runs/` and `$PLAYPORT_BUILD/perf-runs/`.
- **Install:** `pp install --no-build` upgraded in place. The `installed` event names the IPA
  above, at head `042c89c`.

| Run | What | JIT | First frame | FEX disk cache | Screen |
| --- | --- | --- | --- | --- | --- |
| `m2b-hk-1` | Hollow Knight, first launch | 2.40 s | **+9.87 s** | cold (misses 36,675) | main menu, with Start Game highlighted and the touch controls drawn |
| `m2b-hk-2` | Hollow Knight again | 2.37 s | **+8.66 s** | warm (hits 106,440, misses 28) | main menu, the same |
| `m2b-probe64` | `threadctx`, x86-64 | 2.40 s | n/a | n/a | the probe ends after 4 s (below) |
| `m2b-probe32` | `threadctx-i386`, WoW64 | 2.37 s | n/a | n/a | the probe ends after 4 s (below) |
| `perf-runs/m2b-hk-1`, `m2b-hk-2` | Hollow Knight, `pp perf` | 2.43 / 2.49 s | +8.78 / +8.79 s | warm | in play at first frame+70: the Knight in a cave, Metal HUD 59.5 fps |

**Baseline on main.** The comparison runs are main-lineage Hollow Knight launches from the same
evening:

| IPA | Head | Run | Cache | First frame |
| --- | --- | --- | --- | --- |
| `3671f980` | `0300139`, fex 0051 final | `20261018T224030` | cold (misses 36,716) | +9.99 s |
| `4479e2ae` | `1524cf4` | `20261018T222843` | cold | +9.18 s |
| `3f4f8876` | the M1 IPA, main plus Mesa | `20261018T231825`, `20261018T231915` | warm | +9.18 / +9.21 s |

The new IPA is within that spread when the cache is cold and 0.5 s faster when it is warm.

## The threadctx probe (PLA-302/303/304, and the CPSR masks of madeira-unix 0161)

The probes were imported through the UI from `tools/compat/probes/build.sh`'s output:
- `pp phone put` copied `threadctx.exe` and `threadctx-i386.exe`, both v4 as committed. The rebuild
  was byte-identical to the build area's earlier one.
- `pp ui --action import:Import/threadctx --action import:Import/threadctx-i386` added them
  (`m2b-import`).
- `pp ui --play dir-threadctx --wait 40` and `--play dir-threadctx-i386` ran them.
- Both were uninstalled through the UI afterwards (`m2b-uninstall-probes`). That run reported the
  second uninstall as "something was left behind" (`catalogued=true` right after the folder went).
  The next launch's library (`m2b-library-check`) lists only Hollow Knight and Red Dead
  Redemption 2, as before the session.

| Check | 2026-10-13 final, 64 / i386 (`f39cd151`) | this IPA, 64 / i386 |
| --- | --- | --- |
| a: never-run thread | ok / ok | ok / ok |
| d: `SetThreadContext` on a never-run thread | ok / ok | ok / ok |
| b: spinning thread, 16 of 16 for `rip` in the loop, `rsp` on its stack and `rax` the marker | ok / ok | ok / ok |
| c: thread in `WaitForSingleObject` or `Sleep`, `rip`/`eip` in ntdll, 4 of 4 | ok / ok | ok / ok |
| e: a second suspension sees the counter move on, 3 of 3 | ok / ok | ok / ok |
| d: `rax` set on the spinning thread reaches it | BAD / BAD (PLA-303) | BAD / BAD (unchanged) |

- Every `CHECK` line matches the 2026-10-13 final run text for text, with addresses masked.
- The never-run thread's flags read back the same, `0010000b` for 64-bit and `00010007` for i386.
- The probe exits 1 (`done FAIL`) because of the known PLA-303 check, as before. No crash report
  was written.

## Console program (conhost.exe through ENABLE_ARCHS, wine-pe 0047)

**Not checked on the phone in M2b.** M3 checked it with a new probe
([below](#merged-main-and-the-console-probe-m3)).
- Every committed probe is linked with `-mwindows`, so none has a console.
- The x86-64 console caller of [2026-10-11](2026-10-11-system32-programs.md) was a scratch import
  and was not kept.
- The phone has no title with a pending Steam `.cmd` prerequisite. Red Dead Redemption 2's
  conhost runs date from 2026-10-15, and none of its runs since have started conhost.

A check without new tooling was therefore not possible. Hollow Knight starts no conhost, services
or rpcss on either IPA.

Statically, the build's `build/generated/wine-pe-arm64ec-windows.tsv` holds arm64ec
`conhost.exe`, `cmd.exe`, `start.exe`, `services.exe`, `rpcss.exe` and `plugplay.exe`. That is the
set W8 found missing before 0047.

## `pp perf`, Hollow Knight

**No main baseline.**
- No main-IPA `pp perf` of the step-1 route has been recorded since 2026-10-06 (`a1-hk-500`,
  `rb-final-hk`).
- The owner's 2026-10-14 pool A/B used a different route (a human play).
- Main's IPA was not reinstalled for a baseline, so the two runs here are of the new IPA only.

**Command:** `pp perf --secs 100 --pad first-frame+25:hk-new-game --pad first-frame+45:hk-walk`,
with `--cool 10`. Both runs started at thermal nominal, on battery.

| | `m2b-hk-1` | `m2b-hk-2` | `a1-hk-500` (2026-10-06, for reference only) |
| --- | ---: | ---: | ---: |
| Mean FPS (p10, median) | 53.3 (30.0, 60.0) | 52.9 (30.0, 59.8) | 58.3 (53.9, 60.0) |
| Frame / GPU time (ms) | 18.54 / 6.44 | 18.44 / 6.45 | 16.93 / 7.19 |
| Hitches ≥25 / 50 / 100 ms | 762 / 15 / 6 | 673 / 17 / 3 | 361 / 10 / 5 |
| Wineserver requests per frame | 25.9 | 21.0 | |
| In play, 70–105 s: FPS, Mi/f, P/E %, system mW | 59.7, 83.7, 85/29, 3,837 | 60.0, 84.5, 91/33, 2,542 | |

**The difference is one window.**
- From about 45 s to 65 s after the first frame, both runs show a black screen at 25–30 fps. This
  is the load after the profile is picked; the `first-frame+55` shot of `m2b-hk-2` is black, with
  the Metal HUD at 25.4 fps and a 39 ms frame interval.
- In that window the game's main thread (`002c`) does 44.8 Mi/f, against 27.5 Mi/f in `a1-hk-500`'s
  60 s window. The window is CPU-bound on the P cluster: P 55–73 %, GPU 5–6 ms.
- Outside it, the two runs match each other and the 2026-10-06 runs: 57 fps over 0–30 s and 60 fps
  in play.
- The save in profile 1 has changed since 2026-10-06, because agents play it (`tools/pad/hk-new-game.txt`).
  Whether the long load is the new pins or that save needs a main-IPA run on today's save.
- **This is not a recorded regression, and not a clearance either.**

**Portal 2 was not measured** (next section).

## Portal 2: not played

- Portal 2 (620) is not installed on the phone. The library has held only Hollow Knight and Red
  Dead Redemption 2 since 2026-10-14.
- Its install is 12.76 GB ([2026-10-05](2026-10-05-deps-latest.md)), and the phone has 6.8 GB free.
- Installing it would mean removing Red Dead Redemption 2, which main's RDR2 work uses, so it was
  not done.
- The Portal 2 first frame+10 gate and its `pp perf` route are therefore owed. The i386 (WoW64)
  path was covered only by `threadctx-i386`.

## M2a's risk list, in these logs

| Risk | Observed |
| --- | --- |
| FEX SMC and fault paths (fex 0045–0051) | The same lines as main's `20261018T224030`: `[smc-atomic]` 3, `[smc-byte]` 1, `[smc-off]` "Mono backpatcher detected", `[smc-trap]` 4, `[smc-write]` 3. No `[generated-fault]`, `[ec-ring]` or `[smc-for]` lines, as on main for this title. |
| JIT SIGBUS | 2 per Hollow Knight run (both plays and the perf run), the baseline's 2. None in the probes. `Unhandled non-JIT atomic` 1 per run, as on main. |
| Crashes | None: the crash directories are empty and the app ran every launch to its stop. |
| GetLocalTime (madeira-unix 0159) | `[wine_host] time zone bias -120 min (local = UTC+120 min)`, as on main. The guest-side check (Red Dead Redemption 2, [rockstar-local-time](2026-10-18-rockstar-local-time.md)) was not run. |
| SetThreadAffinityMask (0160's system_affinity) | Nothing in the default logs on either IPA. Hollow Knight (Unity) runs normally. |
| Image aliases and the pool | Pool and alias counts are in line with main (`alias_full=0`, `exhausted=none`). |
| CEF swap, services, the Steam bridge | Not exercised: no Red Dead Redemption 2 run (below). |

## Not checked

- **Portal 2:** first frame+10 and `pp perf` (not installed; above).
- **A console program or conhost** on the phone (above; checked in M3, below).
- **Red Dead Redemption 2's Rockstar launcher through Steam** (M2a gate 6), with the guest
  local-time check. Not in this session's steps; it can ask for a sign-in.
- **A main-IPA `pp perf` on today's Hollow Knight save,** to decide the 45–65 s load window.

## Merged main and the console probe (M3)

**Date:** 2026-10-19 (the phone session ran from 01:35 to 01:38).
**Merges:** the owner's decision ("Accept [HK perf load window], merge both go main"; Portal 2
skipped) merged both branches into `main` with `--no-ff`, without conflicts:
`c8095ce` (`dev/pla-76-proton-alignment-ws`, `d19fe2f`) and then `db3d0a6`
(`dev/pla-386-rdr2-vulkan-kk`, `aaf598a`). `main` is not pushed.

**Build:** `./pp build` (dev) on `db3d0a6`. unix, pe, fex and dxmt were unchanged from M2b's
build; vulkan restaged with the merged Mesa series (0037–0043).
- **IPA:** `$PLAYPORT_BUILD/out/20261019-013009-322331eb/Playport-26.5-322331eb.ipa`.
  - sha256 `322331eb09b6e351b21e52cf0df3527ccfcab12025e4ff51b2046d0660e3da42`.
  - verify-ipa: 89 checks passed, 0 failed.
- **Build records:** unchanged, so nothing needed committing.
- **Checks:** `./pp test` (full), `pp slots` (150 slots, 149 calls), `pp names` and
  `pp secrets` passed.

**The console probe** (`tools/compat/probes/console.c`, `7148fc5`, PLA-390) is the one probe
built without `-mwindows`.
- Started from the app, which has no console, it must get a conhost from kernelbase.
- It checks:
  - (a) that `CONOUT$` opens, and that `GetConsoleMode` and `WriteConsoleA` succeed on it;
  - (b) `cmd.exe /c echo <marker>`, with the output in a pipe: exit code 0 and the marker in
    the output;
  - (c) `cmd.exe /c exit 7` with `CREATE_NEW_CONSOLE`, which starts a second conhost: exit code 7.
- **Desktop Wine 11.19:** with the probe started in a new console (`wine start /wait`, on an
  `xvfb-run` display), every check passes (`done ok`).

**One `pp phone lock` session,** on the IPA above (the `installed` event's
`ipa_sha256` `322331eb…`):

| Run | Result |
| --- | --- |
| `m3-hk` (`--play app-367520 --until first-frame+10 --shot`) | First frame at +8.58 s, ok. JIT 2.76 s. The screenshot shows the Hollow Knight main menu. 2 JIT SIGBUS (the baseline's 2), no crash report. |
| `m3-import` (`import:Import/console`) | ok |
| `m3-console` (`--play dir-console --wait 60`) | Exit 1 (`done FAIL`) after 0 s, details below. No crash report. |
| `m3-uninstall-console` (`uninstall:dir-console`) | ok: folder, record and stage gone, not catalogued. The library then held Hollow Knight, Red Dead Redemption 2 and the probe; M2b's leftover `dir-threadctx-i386` was no longer listed. |

**conhost and cmd start (`m3-console` host log):**
- The probe's start runs `C:\windows\system32\conhost.exe --server 0x34`. The arm64ec
  `conhost.exe` loads (`re-patching L"conhost.exe" metadata`, `Load module conhost.exe`), and
  the log has no `c0000135`.
- (a) passes: `CONOUT$` opens, `GetConsoleMode` returns mode 3, and `WriteConsoleA` writes 39 of
  39 bytes. `GetConsoleWindow` is `0x10030`. Standard output is the app's log file (type 1),
  which the launcher hands to the probe.
- (b) cmd starts, loads its arm64ec `cmd.exe` and exits 0 (**ok**). **The marker check is BAD**:
  - the pipe held the runtime's own start-up lines for the child (`[rpm-sink] alive`,
    `[FEX-iOS] fast-write ENABLED`, `[FEX-iOS] ThreadInit() entered`) and not cmd's echo;
  - the marker appears nowhere in the log except in cmd's command line.
- (c) passes: cmd in a new console starts a second conhost (`--server 0x28`), which loads and
  opens a console window (`[win-text] … "C:\windows\system32\cmd.exe"`), and its exit code
  is 7 (**ok**).
- **Before:** a 2026-10-08 log (`20261008T175727`, Portal 2) has the same `NtCreateUserProcess`
  line for `conhost.exe --server 0x60 --headless`, then
  `wine: failed to start L"\??\C:\windows\system32\conhost.exe": c0000135`. That failure
  is gone. The `NtCreateUserProcess` line itself is the runtime's trace of every process start
  (it also logs `hollow_knight.exe`), not an error.

**Verdict:**
- conhost and cmd start through wine-pe 0047's arm64ec builds on the merged main IPA.
- A child's standard output through a pipe is wrong on the phone: the runtime's start-up
  lines reach the pipe and cmd's output does not. Desktop Wine passes the same check, so the
  probe exits 1 until this is fixed or explained. This is a separate finding, not part of
  0047.

