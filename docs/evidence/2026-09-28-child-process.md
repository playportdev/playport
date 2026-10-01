# Child pseudo-processes: start, windows, exit, the parent's wait

**Date:** 2026-09-28 (device runs 2026-09-29 morning). **Phone:** iPhone18,4, iOS 27.0.
**Follows:** [2026-09-28-multigame-session-root.md](2026-09-28-multigame-session-root.md),
which found that since the wine-11.18 port a child pseudo-process faults at start, faults
creating a window, leaves its parent's wait hanging, and that an ARM64EC main image
aborts. The fixes are `patches/madeira-unix` 0039 to 0043.

| Patch | Fault | Cause |
| --- | --- | --- |
| 0039 | the child faults in `init_syscall_frame` | `init_startup_info` (wine-11.18) allocated a second first TEB and PEB for the child; now only a thread with no TEB gets one |
| 0040 | the child faults in `NtUserCreateWindowEx` (`addr=0x99`) | `PsGetCurrentProcessId`/`RtlGetCurrentPeb` (new in 11.18), a new thread's TEB and client id took the session's `pid`/`peb` globals; win32u took the child's own window for another process's (`OBJ_OTHER_PROCESS`, 1). They now answer from the calling thread's TEB |
| 0041 | the parent's `WaitForSingleObject` on a dead child never returns | a child thread that wineserver killed (iOS delivers no `SIGQUIT`) died inside an uninterrupted section and kept `fd_cache_mutex`; the parent's thread waited on it for ever. A dying thread now leaves its sections, with a `[section]` line |
| 0042 | an ARM64EC main image aborts in `update_arm64ec_ranges` | a log line read `peb->EcCodeBitMap` before 11.18 has made the PEB (NULL + 0x368) |
| 0043 | a child whose parent had drawn no window creates none (`ERROR_ACCESS_DENIED`) | only the first process could make the desktop window, and it did so at its first `CreateWindowEx`; the session now makes it at `init_user`, and every process registers the desktop classes |

0043 was found by these runs: with 0039 to 0042 the child no longer faulted, but its
`CreateWindowExW` returned NULL, error 5, while `GetDesktopWindow` in the child failed;
when the parent called `GetDesktopWindow` first, the children's windows worked.

## The test

No shipped title starts a child, so a scratch harness drove it
([childtest.c](2026-09-28-child-process/childtest.c)), wired into a scratch build only
([wire.py](2026-09-28-child-process/wire.py): with the game's launch setting
`PLAYPORT_CHILDTEST` set, `wine_host_run_exe` starts `C:\childtest.exe`, or
`C:\childtest-arm64ec.exe` for `ec`, with Hollow Knight's path and arguments). The root
starts itself twice as a child that registers a class, creates and shows a window, runs
its message loop until a 2 s timer destroys it, and exits with 41 or 42; the root waits
for each and checks the code; then it starts Hollow Knight as its child and waits. None
of this is in the branch. The session ran as
[session.sh](2026-09-28-child-process/session.sh), under one device lock.

| IPA | sha256 | What |
| --- | --- | --- |
| `Playport-26.5-5118e677.ipa` | `5118e67707328ab642598f79ca90d43eb5d232fad0dd51194a78be644f1e8141` | the branch plus the scratch harness |
| `Playport-26.5-47231174.ipa` | `47231174a88af24c60b904b369be858a903a491bea1239796eaf6aca63033fdf` | **the branch's** (dev) |

## Results

- **x86-64 root** ([log lines](2026-09-28-child-process/childtest-a.txt)): both window
  children started, got `WM_CREATE`, `WM_TIMER`, `WM_DESTROY`, and exited with 41 and 42;
  the root's waits returned (`wait=0`) after 2093 and 2099 ms with those codes.
  `window children PASS`.
- **ARM64EC root** ([log lines](2026-09-28-child-process/childtest-b.txt)): the main
  image mapped (`[ec-map] ... (no PEB yet: the first TEB gets it)`), the root ran, and the
  same two children passed.
- **Hollow Knight as the child**, under both roots, loaded and then faulted after about
  1 s (`UNHANDLED pc=<JIT pool> addr=0x20`, the same fault as run 4 of the session-root
  record), and ended with `0xc0000005`; the root's wait on it returned at once
  (`wait=0`, exit code `0xc0000005`). In an earlier run of the series the same death
  logged `[section] thread abort: tid=0054 leaves the section of mutex ... (fd_cache_mutex)`
  ([line](2026-09-28-child-process/section-dev3-b.txt)): the mutex that hung the
  parent in the session-root runs, given back. Why Hollow Knight faults as a child is not
  one of these faults and is left open.
- **The shipped path**, the branch's IPA, Hollow Knight as the one process
  (`pp ui --play app-367520 --until first-frame+10`): runtime at +3.85 s, first frame at
  +9.55 s, ran 10 s on, ok ([timeline](2026-09-28-child-process/shipped-path-timeline.txt)).
