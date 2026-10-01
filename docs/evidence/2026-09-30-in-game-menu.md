# The in-game menu on the phone

**Status:** the menu opens over Hollow Knight, pauses it and resumes it,
saves a screenshot and quits the game back to Home. Tested on the phone with
the driver's Home press (`menu:open`), not with a real controller's Home
button.

## Build

- Dev IPA `478ec0cb` (sha256
  `478ec0cb6054371620327380661db24ee328c63e60c28043197d04d365c8c7be`).
  It is built from the commit that adds the menu, with patches/madeira-unix
  0048.
- The phone is an iPhone18,4 on iOS 27.0.
- The runs used Hollow Knight (`app-367520`) at the default 720p and 60 fps.
  No controller was connected in the last runs. A DualShock 4 was connected
  in one earlier run, and the menu showed it as "DualShock 4 · 15%".

## Runs

Every run was started with `pp ui --shot-each-action`. The run directories
are under `$PLAYPORT_BUILD/ui-runs/`.

### `20260930T214206` (IPA 478ec0cb)

The actions were `play:app-367520, wait:10, menu:open, menu:resume, wait:6,
menu:open, menu:quit, open:home`.

- JIT arrived in 3.10 s and the first frame at +9.75 s.
- The first `menu:open` logged `safe area top=0 left=68 bottom=20 right=68`. The session root held 50 threads of 1 process in 23 ms: 63 ms from the menu's request to its answer.
- `menu:resume` resumed the 50 threads, and the game went on to its title screen.
- The second pause held 53 threads.
- `menu:quit` logged `WM_CLOSE to 1 windows of 1 processes`. The game then ended with `exit=0x00000000`.
- Playport restarted, and the new process came up 473 ms after the request. The continued run opened Home. The result was ok.

### `20260930T212415` (IPA 73a77b94, before the safe-area fix)

This run also toggled the performance overlay from the menu.

- The Metal HUD showed on the game after Resume (`action-06-wait_6.png`).
- Two screenshots were taken 2.6 s apart during one pause (`action-03`, `action-04`). The game region of both is identical: the mean greyscale difference is 0.0. Two screenshots of the running game taken 6 s apart differ by 0.94.
- Hollow Knight's title screen animates all the time, so the game was stopped while the menu was up.

### `20260930T214031` (IPA 478ec0cb)

The actions were `menu:open, menu:screenshot, menu:resume`.

- The screenshot row said "Saved to Photos", and the log said `screenshot: saved to Photos`. The phone already allowed Playport to add to Photos.
- The dev copy `Documents/Screenshots/20260930T214109.png` (1564x720) shows the game's frame the right way up with its own colours.
- The build before it (run `20260930T213821`) saved a frame that looked washed grey. The game leaves alpha below 1 in its drawable. The capture now sets alpha to one.
- Both screenshots were also saved to the phone's Photos.

## The retries of deferred holds (madeira-unix 0048)

The wineserver's real suspend (madeira-unix 0010) holds a thread only at a
safe point. A deferred hold is retried every 1 ms. The two-pause flow above
was run twice, once before and once after 0048, and the `[real-susp]` tick
lines count the retries:

| build | retries after the first pause | after the second |
| --- | --- | --- |
| 89310fb4, without 0048 | 286836 | 627791 |
| 478ec0cb, with 0048 | 16791 | 36209 |

- Without 0048 that is about 28,000 retries a second while a game is paused: 627,791 over about 21 s of menu.
- With 0048 the retries fall by a factor of about 17.
- Nearly all of Hollow Knight's threads wait in server calls during a pause: `holds=0 ... deferred=57` in the last run. They are not woken while they are suspended.
- Hollow Knight's plays in these runs reached their first frame at +9.0 to +9.8 s, the same as before the change.

## Not checked

- A real controller's Home button (held, and pressed again to close) was not tested. The driver and the scripted pad feed the same `HostIO.menuInput`.
- The Photos permission prompt was not tested. This phone had already allowed Photos access.
- A game that ignores WM_CLOSE, which the session root ends after 10 s, was not tested. The 25 s restart fallback was not tested either.
- The release variant compiles but was not installed.
