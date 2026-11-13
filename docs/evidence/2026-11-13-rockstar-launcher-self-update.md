# The Rockstar Games Launcher's self-update stalls on the phone (PLA-851)

**Phone runs:** dev IPA `3d3ee5c9eacdc316f363f78902b68f2d3e95b1da9f3d864f8a8b292c36ed45e1` (M2 `d0df15cd`),
Red Dead Redemption 2's Play, runs `pla841-rdr2-census` and `pla841-rdr2-census2` (2026-11-13), and
Rockstar Service's own log pulled from the prefix afterwards
(`ProgramData/Rockstar Games/Launcher/service_log.txt`). **Desktop runs:** Proton 10 under Xvfb in
scratch prefixes under `$PLAYPORT_BUILD/agent-notes/pla851/`. The launcher's own log holds
BRANCHACCESS tokens and stays in the build area.

## What a self-update is (desktop)

The launcher in Steam's depot 1899671 (`Rockstar-Games-Launcher.exe`, sha256 `7bcbe2fa…`, the
installer `gamedownloads.rockstargames.com` serves today) is 1.0.110.3150. Live build 1311 is
newer, so a launcher installed from it updates itself at once (it reports 283.39 MB; six files,
193 MB, come down).

1. **Download.** Rockstar Service (SYSTEM) writes six files into `Launcher\swap\<hash>.swap`
   through a 400 MB shared-memory view, about 6 s on the desktop.
2. **Apply** ("Applying downloaded self-update..."). The launcher has the service move each swap
   file into place, one request at a time: `Social-Club-Setup.exe`, the Epic SDK, the crash
   handler, both D3D12 DLLs, then `RockstarXboxHelper.dll` to `.old` and the new one in. The
   service then writes `index.bin`. About 100 ms per file on the desktop, 1.4 s in all.
3. **Restart.** "Self-update applied, need to restart". The launcher stops the service and starts
   `Launcher.exe -skipPatcherCheck -upgrade`. No LauncherPatcher runs.

A launcher killed after the download or between two moves finishes the update at its next start.

## On the phone

Every exchange between the launcher and its service waits for the launcher's 10 s ping:

| Run | Launcher | Rockstar Service |
| --- | --- | --- |
| 1, 00:05 | connected at 09.986; "Handshake with service timed out" after 500 ms (desktop: answered in 90 ms); its shared-memory and download steps 10 s and 30 s apart; the download completes at 00:05:55, then nothing | `Started fix folders` 10 s after the connect, writes in bursts at :20, :28, :50, 06:20 |
| 2, 00:16 | handshake timed out at 03.168; "Applying downloaded self-update..." 03.175; then nothing for 7 min, black screen | moves at 03.213 and 03.283, then **12.694, 22.706, 32.704, 42.703**, `index.bin` 52.766; every swap file was moved (`swap\` is empty, `RockstarXboxHelper.dll.old` is there) |

`FEX_SMCCHECKS=none` reached both processes, so this is not PLA-367's churn. The update itself is
applied on the phone; the launcher never logs that it is.

## Cause

A system APC that never reaches a thread asleep in `select()`. A named-pipe read completes
through an `APC_ASYNC_IO` system APC on the thread that started it. On the desktop, SIGUSR1 ends
that thread's `Sleep()` (a non-alertable `NtDelayExecution`, which sleeps in `select()`) and runs
the APC. On iOS no signal reaches a thread (wine-unix 0002), and ppsync's kick (wine-unix 0045)
reaches only a thread in a ppsync wait. The launcher's thread that talks to the service sleeps
between its checks, so it got each reply only at its next server wait, its 10 s ping.

Desktop A/B, the same prefix (launcher 1.0.110.3150, the download complete), fsync and esync off so
that every wait is a server wait (what a kicked ppsync wait stands for), and an `LD_PRELOAD` shim in
wineserver that drops SIGUSR1 and logs the target thread's system call:

| Run | SIGUSR1 | Result |
| --- | --- | --- |
| `selfupd1` | Proton's default | handshake 90 ms, apply 1.4 s, restart |
| `nousr1-a`, `nousr1-b` | dropped for every thread | the phone's run 1: handshake timeout, steps 10 s and 30 s apart, download completes, no apply in 90 or 150 s. 41 of 42 dropped signals went to one `Launcher.exe` thread in `pselect6` (`NtDelayExecution`) |
| `nousr1-c` | delivered only to a thread in `select()`, dropped for the rest | handshake 89 ms, download, apply 1.4 s, restart; 94 signals delivered to `Launcher.exe` threads in `select()` |

## Fix

wine-unix 0205: with ppsync, a non-alertable timed `NtDelayExecution` is a ppsync wait on no
object until the same deadline, and a sleep forever is that wait in a loop. A kick ends it,
`linux_wait_objs()` runs the APC through a zero-timeout server wait, and the sleep goes on.
ppsync's host test `test_sleep` covers the wait on no object: it ends at its deadline, a kick ends
it early, and a kick before it is kept. Not yet checked on the phone.

## The reinstall's prerequisite run

The reinstalled game's `installscript_sdk.vdf` names the launcher `101103150` (October's:
`101093031`), so its HasRunKey value was new and the Play ran `Rockstar-Games-Launcher.exe /s /t`
again, as desktop Steam would (decision 0081). That installer (1.0.110.3150) is newer than the
prefix's launcher (1.0.109.3031 at build 1239 since October), and it upgrades in 4 s. The
self-update to build 1311 follows from any install today, so the rerun is not the cause, and
Playport keeps Steam's rule.
