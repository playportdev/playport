# A child's standard output through a pipe carries the runtime's start-up lines (PLA-403)

**Linear:** [PLA-403](https://linear.app/playportdev/issue/PLA-403), found by the console probe of
[PLA-390](https://linear.app/playportdev/issue/PLA-390). Branch `dev/pla-403-child-stdout-pipe`.

**Question:** On the phone, the console probe (`tools/compat/probes/console.c`) starts
`cmd.exe /c echo console-probe-cmd-echo` with `STARTF_USESTDHANDLES` and one pipe for its standard
output and error. cmd exits 0, but the pipe holds `[rpm-sink] alive rev=ml492`,
`[FEX-iOS] fast-write ENABLED …` and `[FEX-iOS] ThreadInit() entered`, and not cmd's echo. Desktop
Wine 11.19 passes the same check. What writes there, and where did cmd's output go?

## Before: IPA `322331eb…`, run `m3-console`

The run is `$PLAYPORT_BUILD/ui-runs/m3-console`, on merged main's dev IPA
`322331eb09b6e351b21e52cf0df3527ccfcab12025e4ff51b2046d0660e3da42`. Its log
`pull/s1-host.log` shows the following.

- **The handles are inherited.** The cmd child is pid `0040`. Its `[std-handles] at-create`
  lines name stdout and stderr `0x68`, the probe's pipe, with console `0x18`. Every pseudo-process
  shares the app's unix fds, but a guest's handles are its own: `spawn_process` in
  `process_ios.c` starts a thread and does not touch fds 0–2.
- **cmd ran.** It loaded its imports, and `NtTerminateProcess(0, 0)` ended it. The c check
  (`cmd /c exit 7`) returned 7 from the same binary.
- **The three lines are the child's own.** They are FEX's (`libarm64ecfex.dll`, loaded in every
  ARM64EC process, cmd included) and rpmalloc's start-up diagnostics. On the iOS port these go to
  the guest's standard error handle:
  - `ProcessParameters->hStdError` through `WriteFile`: `fast-write ENABLED` in ProcessInit;
    `ThreadInit() entered`, the `TI:` step markers, the `DispatcherPatch` lines and
    `ThreadInit() done` in every ThreadInit; and two FATAL lines. These come from
    `patches/fex-port` 0013 (Madeira's ThreadInit logging, 2026-04-29), 0028 (fast-write,
    2026-07-06) and later port commits, plus `Logging.cpp`'s fallback when
    `__wine_dbg_output` does not resolve.
  - `GetStdHandle(STD_ERROR_HANDLE)`: rpmalloc's `[rpm-sink]` banner in `rpmalloc_initialize`,
    `[rpm-band]`, `[rpm-avail]`, `[rpfree-skip]`, the `[rpm-poison]` copy and the VA selector's
    beacons (`patches/rpmalloc-port` 0007 and earlier).
- **They reach the log only by chance.** For the game the launcher starts, that handle is the
  app's log file (the probe's own stdout is type 1). So these lines usually read as log lines.
  In a child with a redirected standard error, they go into the guest's pipe or file.
- **A NUL cut the output off.** `ThreadInit() entered` is written as 32 bytes: 31 characters and
  the string's terminating NUL. The log shows the NUL: line 1251 starts with `\0` before
  `[FEX-iOS] TI:lock`. The probe printed its buffer as a C string, which ended at that NUL. After
  it came the `TI:` markers, four `DispatcherPatch` lines and `ThreadInit() done`: about 610
  bytes in the probe's own process (log lines 2697–3656). That is more than the probe's 511-byte
  buffer, so cmd's echo would have fallen past it even without the NUL.
- **Where cmd's echo went is inferred.** None of the child's `TI:` or `DispatcherPatch` lines
  are in the host log, while those of the two processes whose standard error is the log file
  (the first process and the probe) are. So they went into the pipe.
  cmd's own output was not seen directly.

**Root cause.** It is not a pipe or handle fault in the iOS process spawn. The runtime's
diagnostics are written to the guest process's own standard error handle. A pipe's reader gets
them, with a NUL, ahead of the child's output.

**Since when.** It predates Wine 11.20. The writes date from Madeira's FEX and rpmalloc ports
(fex-port 0013, April 2026; rpmalloc-port 0007, August 2026), which were brought over unchanged.
Nothing in the Wine 11.20 move touched them. No probe had captured a child's output through a
pipe before PLA-390. This is concluded from the code history; no older IPA was run.

## The fix

- **`patches/fex` 0052, "ARM64EC: send iOS diagnostics to the log, never to the guest's standard
  error".**
  - Every iOS diagnostic in `Source/Windows/ARM64EC/Module.cpp` now goes through
    `FEX::Windows::Logging::IosDiagWrite`. That is ntdll's `__wine_dbg_output`, the path LogMan's
    lines already take to the app's log, called in NUL-terminated pieces.
  - The `hStdError` fallback in `Logging.cpp` is gone. Without `__wine_dbg_output`, a line is
    dropped.
  - `Logging::Init` gives rpmalloc its sink.
  - ProcessInit's flush of the deferred buffer now names it "deferred rpmalloc log".
- **`patches/rpmalloc` 0005, "Send iOS diagnostics to FEX's log, never to the guest's standard
  error".**
  - rpmalloc's writes go through `ios_rpm_diag`: to that sink once `Logging::Init` has run, and
    until then into `ios_va_log`, which ARM64EC's ProcessInit already flushes.
  - `[rpm-poison]` notes also still go to `C:\rpm-poison.log`.
  - Builds without `FEX_IOS_HOST` are unchanged.
- **The probe.** Check b now counts the bytes it reads, shows a NUL as `\0`, and has a third
  check: `b-echo nothing else in the pipe`, which passes only if the pipe holds exactly
  `console-probe-cmd-echo\r\n`.

## Checks

| What | Result |
| --- | --- |
| `./pp build` (dev; only fex, stage, notices, app and verify ran) | IPA `.work/out/20261019-080753-a4e14664/`, sha256 `a4e14664753c7b390cdff3b2ad9086a7e69db6182416b0ec1426d95c80231a4e`; verify-ipa 89 passed, 0 failed |
| Build records | `app/artifacts.tsv`: `xtajit64.dll` (`libarm64ecfex.dll`) and `xtajit.dll` (`libwow64fex.dll`) changed, as expected |
| `./pp test` (full) | all passed; Swift PlayportKit 337 tests |
| The new probe on desktop Wine 11.19 (sway's X display, own prefix under `.work`) | every check ok, including `b-echo nothing else in the pipe` (24 bytes); `console: done ok` |
| Phone (2026-10-19, after the phone was woken) | IPA `a4e14664…` installed (`installed` event sha256 `a4e14664753c7b390cdff3b2ad9086a7e69db6182416b0ec1426d95c80231a4e`); Hollow Knight first frame +9.47 s, main menu (`.work/ui-runs/f2-hk`); console probe `console: done ok`: a-conout/a-mode/a-write, b-echo exit 0, marker present, nothing else in the pipe, c-new-console exit 7, all ok (`.work/ui-runs/f2-console`); probe uninstalled through the UI. |

**Checked on the phone** (session `.work/agent-notes/followups/f2/session.sh`, log `session.log`): the probe passes every check; Hollow Knight reaches first frame+10.
