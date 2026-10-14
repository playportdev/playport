# The Witcher 3: a hang when quitting from the game's own menu (PLA-344)

**Linear:** [PLA-344](https://linear.app/playportdev/issue/PLA-344) (from PLA-43).
**Phone:** iPhone18,4, iOS 27.0.1. **Game:** The Witcher 3 1.32 (`bin\x64\witcher3.exe`,
Direct3D 11 on DXMT), app `app-292030`.

## The owner's hang (IPA `792375cd…`)

The owner played, then chose Exit in the game's pause menu and confirmed. The game hid its
window, then drew nothing more for about 94 s. Playport's menu › Quit game ended it: WM_CLOSE,
then forced after 10 s, exit `0x42b`. The log was pulled to `$PLAYPORT_BUILD/scratch/w3quit/s1-host.log`.

- **Main thread `009c`:** blocked in every `[thread-sample]` in
  `send_inter_thread_message → wait_message_reply → … → server_select`. It had sent a message
  across threads and was waiting for a reply.
- **`RenderThread` `010c`:** at 97–100 % CPU, making no server calls. It was in
  `witcher3.exe+0xc65dc0`, a loop that runs the render thread's queued commands to a time
  budget (`QueryPerformanceCounter`, IAT `0x141cc87c0`). Its samples are FEX JIT code,
  `libarm64ecfex!ExitFunctionEC` and ntdll `RtlQueryPerformanceCounter`: the game's own loop,
  with no message pump in it.
- **The game window `0x500ea` and its Default IME window** were created right after
  `RenderThread` started, interleaved with its thread-init lines, so `RenderThread` owns them.
- **Window steps at the quit:** the hang logged only the hide (`[win-pos] … flags=800018bf`).
  A clean quit (below) logs three steps:
  1. the hide;
  2. `SetWindowPos(HWND_NOTOPMOST, …, 0x73b)` (`after=0xfffffffffffffffe flags=80001f3b`;
     `witcher3.exe+0xc64484`);
  3. `ShowWindow(SW_MINIMIZE)` (`-32000,-32000`; `+0xc64493`).

  So the main thread most likely blocked in that `SetWindowPos`. Wine sends it to the window's
  owner as an internal message. The owner, `RenderThread`, had by then entered the loop above,
  which never reads messages.

This reading is an inference from the window steps, not yet a logged message. If the
hypothesis is right, the hang is a race: the quit hangs when `RenderThread` is already in that
loop as the main thread repositions the window. Why Windows does not show this was not
established.

## The diagnostic (madeira-unix 0144)

`wait_message_reply` (`build/win32u-unix/message_ios.c`) now waits in 5 s slices until the
first 5 s have passed. It then logs once
`[sendmsg-stuck] tid=… waits … ms for a reply: hwnd=… msg=… (name) … to tid=…`, and on the
reply `… replied … after N ms`. Waits under 5 s are unchanged and log nothing.

## Driven attempts on IPA `3cc547ac5808c399378c9a4acee84a073652bc8d70a152f6451489c94c841909`

All three used the scripted pad (`pp ui --play app-292030 --pad --leave-running`, then
`pp pad send`). They are in `$PLAYPORT_BUILD/scratch/w3quit/` (`run1`, `run2`, `run3`; pulled
logs `mainmenu-exit/`, `ingame/`, `p3/`).

| Attempt | Path | Result |
| --- | --- | --- |
| 1 | title menu › Exit | exit 0 at once |
| 2 | Continue, Kaer Morhen, pause menu (BACK) › Exit › OK | exit 0 in about 2 s; the three window steps |
| 3 | as 2, after two Playport menu pause/resume cycles and some walking (the owner paused twice too) | exit 0 in about 2 s |

No `[sendmsg-stuck]` line appeared in any of the three logs, during play or at the quit.
The hang did not reproduce in these three runs. The owner's session differed in other ways:
on-screen controls with no controller, phone gyro aim as a mouse, and about 3.5 min of play.

Hollow Knight smoke gate on this IPA: first frame +9.61 s, ran to first-frame+10, no `[sendmsg-stuck]` (`$PLAYPORT_BUILD/scratch/w3quit/hk`).

## Next

Keep 0144 in the dev builds. The next hang will then name the stuck message and its receiver
in `s1-host.log` (`grep sendmsg-stuck`), which confirms or refutes the SetWindowPos reading.
Possible fixes then: compare with Windows/Proton behaviour for a cross-thread
`SetWindowPos` (z-order only, the window already hidden), or send it without waiting
(`SWP_ASYNCWINDOWPOS`) where Windows would not block either.
