# Several games in one app run: a Wine session root with each title as a child

**Date:** 2026-09-28. **Phone:** iPhone18,4, iOS 27.0, the shared reference phone.
**Follows:** the second-launch scout (the pp-second-launch scout report, `data/pp-second-launch/report.md` in the task tracker),
which showed that a second `wine_host_init` or `__wine_main` aborts the app and
proposed a long-lived session root that starts each title as a child
pseudo-process. **Outcome:** not shippable today. Titles still run one per app
process; the branch keeps the product launch path unchanged and adds only
`pp ui` counting title ends, so an action list with several plays (`play:`,
`back:library`, another `play:`) ends at the last title's end, not the first.

## What was built (scratch, not shipped)

- A session root, `playport-session.exe`: a small Windows program started once
  as the session's `__wine_main`; on a request from the app's UI it
  `CreateProcessW`s the title with that title's own arguments, working
  directory and environment, waits for it and reports its exit.
- The host side (`wine_host_session_start`, `_launch`, `_wait`): one JIT pool,
  one wineserver and one `__wine_main` for the app process, a fail-closed state
  machine, and a refusal when another guest process outlives a title.
- Madeira patches: `jumbo-mb` reserved on demand before each child (it is read
  once at the session's start, so Witcher 3's 32 GB hole could not follow a
  Hollow Knight root), `WINEDLLPATH` captured per child PEB (the backend
  overlay is read once too), and the fixed per-PEB identity table's free slots.

## Device runs (dev IPAs from branch `fm/pp-multigame-session`)

| Run | IPA | What happened |
| --- | --- | --- |
| 1 | `90ae9420…` | ARM64EC session root: the app aborted as the root started, `update_arm64ec_ranges` ← `virtual_map_image` ← `virtual_map_main_module` ← `load_main_exe` ← `__wine_main`. A native ARM64EC main image is not a path the runtime supports. |
| 2 | `632c7c24…` | x86-64 root (the path every title takes): the root started (`runtime started` +4.17 s, JIT 3.34 s) and spawned Hollow Knight as a child, which faulted at once in `init_syscall_frame` (a memmove to `0 - 0x3a0`): `signal_start_thread` ran on a TEB/PEB pair that was not the child's. |
| 3 | `83aa04ab…` | With a fix for run 2 (below), the child got past its start and loaded its images, then stopped about 2 s in; the log was not pulled (the session was cut short by the driving tool's timeout). |
| 4 | `cbdf26e7…` | With the child's environment filtered as well (below): Hollow Knight loaded every DLL as a child, then faulted in `NtUserCreateWindowEx` (win32u's unix side, `addr=0x99`, `pc` in the S1Probe image) and ended with `NtTerminateProcess(0xc0000005)`; a second thread faulted too. The root never reported the child's exit: the host waited in `wine_host_session_wait` until the run was ended. |

## Findings

1. **Child pseudo-processes are broken since the wine-11.18 port.**
   wine-11.18 allocates the first TEB in `init_startup_info`
   (`virtual_alloc_first_teb`), and `wine_ios_child_main` calls
   `unix_init_startup_info` for a child after it already gave the child a TEB,
   a stack and a PEB. The child's thread data then pointed at a fresh stackless
   TEB and the session's `peb` global moved to a new block (run 2). Skipping the
   first-TEB allocation while a child boots got the child past that (runs 3, 4).
   No committed title starts a child (Hollow Knight's crash handler is refused
   by the spawn gate; decision 0019), which is why this was not seen.
2. **A child that creates a window faults in win32u** (run 4). The window
   station, desktop and per-process user state are the session's; a
   pseudo-process that is not the session's main process has not created a
   window on this runtime since the port.
3. **The root does not observe a child's death reliably** (run 4): after the
   child's `process_exit_wrapper`, the root's `WaitForSingleObject` on it did not
   return within the run.
4. **Session-wide state a later title cannot change**, found at the desk:
   `jumbo-mb` (`ios_jumbo_holdback_init`, once), `WINEDLLPATH` (`set_dll_path`,
   once), `MADEIRA_DOCS_DIR` readers that cache at start-up, and Wine's
   translation of Unix `PATH`/`TEMP`/`TMP`/`HOME` into the Windows environment,
   which happens for the first process only: a child given the app's raw Unix
   environment gets Unix paths for `TEMP` and `PATH`.
5. **The report's JIT facts hold:** one blessed pool served the root and the
   child; no second attach was needed.

## What it would take

Several games per app run needs child pseudo-processes to work first: the
first-TEB fix (finding 1), win32u's per-process user state for a child
(finding 2) and a reliable child exit (finding 3), proven by a title that
starts a child, before the launch path depends on them. That is a runtime task
of its own; until it lands, the `spent` guard and the one-game-per-process
result screen stay as they are.
