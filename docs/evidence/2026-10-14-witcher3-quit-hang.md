# The Witcher 3: a hang when quitting from the game's own menu (PLA-344)

**Linear:** [PLA-344](https://linear.app/playportdev/issue/PLA-344) (from PLA-43).
**Phone:** iPhone18,4, iOS 27.0.1. **Game:** The Witcher 3 1.32 (`bin\x64\witcher3.exe`,
Direct3D 11 on DXMT), app `app-292030`. Logs: `$PLAYPORT_BUILD/scratch/w3quit/`.

## Result

The cause was a lost wakeup in Playport's win32u (iOS). Quitting from the game's pause menu
could leave the main thread in a SendMessage to Wine's dinput worker thread. That thread was
asleep in `MsgWaitForMultipleObjectsEx` and was never woken.

madeira-unix 0145 fixes it. madeira-unix 0144 adds the diagnostic that named the call. With
the fix (IPA `c606b68f`), the owner's quit with on-screen controls and gyro aim ended with exit 0.

## The hangs

1. **IPA `792375cd…` (log `s1-host.log`).**
   - The owner played, chose Exit in the pause menu and confirmed. The game hid its window,
     drew nothing more for about 94 s, and was ended by Playport's menu › Quit game (exit `0x42b`).
   - The main thread `009c` was blocked in `send_inter_thread_message` in every `[thread-sample]`.
   - `wine_dinput_worker` sat in `NtUserMsgWaitForMultipleObjectsEx → wait_message →
     server_wait`. `RenderThread` was busy-looping in its command queue at
     `witcher3.exe+0xc65dc0`. That was a side effect, not the cause; an earlier reading of
     this record blamed it.
2. **IPA `3cc547ac…` (with 0144; log `owner2/s1-host.log`).**
   - The owner's second play hung the same way.
   - The new line named the call:
     `[sendmsg-stuck] tid=002c waits 5000 ms for a reply: hwnd=0x10040 msg=410 (WM_USER+16) wp=1 lp=0 type=1 … to tid=00b4`,
     where `00b4` is `wine_dinput_worker`.
   - `WM_USER+0x10` with wParam 1 is dinput's `INPUT_THREAD_NOTIFY` / `NOTIFY_REFRESH_DEVICES`.
     `dinput_hooks_unacquire_device` sends it to the worker's message window when the game
     unacquires its devices at quit.
   - The worker was again in `MsgWaitForMultipleObjectsEx`, which wakes on `QS_ALLINPUT`
     and should have taken the sent message at once.

## Cause

On iOS, `process_driver_events` (`build/win32u-unix/message_ios.c`) calls winios.drv's
`pProcessEvents` on every call and on every thread. When that call drained input, it sends
`set_queue_mask` with `poll_events = drained`.

The server's handler stores the thread's wake and changed masks. When `poll_events` is set and
the queue has no driver fd, it returns before storing them. No iOS queue has a driver fd:
nothing sends `set_queue_fd`, which only winemac.drv does.

So a thread whose wait-time call drained input kept the masks some earlier call had left.
That could be none: for example a call through `check_for_events` sets `0/0`. The thread then
slept on its queue with nothing to wake it, and a SendMessage to it waited for ever.

The dinput worker drains input often while gyro aim or touch input is flowing. The owner's
logs show the phone gyro moving the mouse at 66–97 moves/s at both quits. The driven runs had
the phone still on the desk and never hung.

## Fix (madeira-unix 0145)

On iOS, `set_queue_mask` is sent with `poll_events = 0`, so the masks are always stored.
`poll_events` only clears `QS_DRIVER` and re-arms a driver fd, and neither exists on iOS.

## The diagnostic (madeira-unix 0144)

`wait_message_reply` waits in 5 s slices until the first 5 s have passed. It then logs once
`[sendmsg-stuck] tid=… waits … ms for a reply: hwnd=… msg=… (name) … to tid=…`, and on the
reply `… replied … after N ms`. Waits under 5 s are unchanged and log nothing.

## Runs

| IPA | Run | Result |
| --- | --- | --- |
| `3cc547ac5808c399378c9a4acee84a073652bc8d70a152f6451489c94c841909` | driven, scripted pad, phone still: title menu › Exit (`run1`); pause menu › Exit (`run2`); same after two Playport menu pause/resume cycles (`run3`) | exit 0 each time; no `[sendmsg-stuck]` |
| same | owner, on-screen controls, gyro aim | hung; `[sendmsg-stuck]` as above (`owner2/`) |
| `c606b68ff9ed38c0ae8e0aac212fd11b89690ad7658d319f1db75e37c7addf81` | owner, on-screen controls, gyro aim (11–27 moves/s at the end), pause menu › Exit | first frame +19.33 s, exit 0 after 84 s; no `[sendmsg-stuck]` (`owner3/`) |
| same | Hollow Knight smoke gate (`hk2`) | first frame +8.57 s, ran to first-frame+10 |

One clean quit after the fix does not prove that the race is gone. The mechanism, though, is
named in the code, and every sleeping message thread on iOS was exposed to it, not only
dinput's.
