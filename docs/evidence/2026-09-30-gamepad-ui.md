# The gamepad-first UI on the phone

**Status:** the landscape UI of [decision 0034](../decisions/0034-a-gamepad-first-ui.md)
works on the phone with `pad:` presses: every page was walked with the focus
ring, and Hollow Knight reached its first frame and ran on through the new
Play buttons (Home's card and the game page), then paused, resumed and quit
through the in-game menu back to Home. This is step 5 of the
[plan](../plans/finished.md#the-gamepad-first-ui). The runs used the driver's
presses. No real controller was used, and no person was at the phone.

## Build

- Dev IPA `91169753` (sha256
  `91169753b69178b5834b464cd4a936a4bed2243087eebebc822792174c859112`). It was built
  from the Swift of commit 37a7a7b (the review's fixes) and is installed on the
  phone.
- Release IPA `35f02d5e` (sha256
  `35f02d5ec630416d8c28837f2faa14c47e6624d0b6c578b696922e6d3e0be33b`) was built from the same tree.
  `pp build --variant release` and `pp verify --variant release` passed all 72 checks,
  including the one that keeps driver names out of the release executable. It was
  not installed: the dev app stays on the phone for the driver.
- The phone is an iPhone18,4 on iOS 27.0, with LocalDevVPN up and the on-phone pairing.
  Steam was signed in. No controller was connected ("No controller" in the top bar).
- Hollow Knight (`app-367520`) played at the defaults, 720p (1564×720) and 60 fps.

## Runs

The run directories are under `$PLAYPORT_BUILD/ui-runs/`. Every run used
`--shot-each-action`. The `pad:` lines in each run's `pull/s1-host.log` name the ringed
item after each press.

| Run | IPA | What it showed |
| --- | --- | --- |
| `20260930T225519` | 91169753 | **Play from Home's card** (`open:home`, `pad:a`, `--until first-frame+10`). `setup: before play: … ready`. JIT arrived in 2.93 s and the first frame at +9.57 s, and the game ran 10 s more. Result ok. `screen-stop.png` is Hollow Knight's main menu. |
| `20260930T223506` | aae6f9e6 | **Play from the game page's button** (`open:library`, `pad:a` on the tile, `pad:a` on Play). JIT 3.05 s, first frame at +8.86 s, `frames limited to 60 FPS`. Result ok. |
| `20260930T224013` | 91169753 | `play:`, `wait:6`, `menu:open`, `menu:resume`, `wait:3`, `menu:open`, `menu:quit`, `open:home`. First frame at +9.96 s. The menu (`action-03`) keeps its rows and footer clear of the Dynamic Island (`safe area … left=68 … right=68`). Quit restarted Playport, and the new process opened Home. Result ok. |
| `20260930T223624` | aae6f9e6 | The same flow, before the inset fix. `screen-0006s.png` is the launch screen (art, bar, dots, the no-controller note, the ⌂ tip). `action-04` shows the menu's footer inset twice, which the next build fixed. `action-08` is Home after the quit: "Played 1 min. ago · 32 min total". |
| `20260930T222202` | b6c9a5b2 | The Library, the sort picker, the game page, and Game options. In Game options a frame rate limit of 30 fps was set and then put back with Y. `action-09`: the "Changed for this game" note now sits low at the left, clear of the page's subtitle. `action-04`: the shell's A hint still showed through the picker's scrim. |
| `20260930T222859` | 3e47881f | `action-04`: the sort picker with only its own footer. Report a problem's share sheet opened, and `pad:b` closed it with the panel left open (`action-09`; the log shows the ring still on `opt:report`). `action-02`: Home. |
| `20260930T222436` | b6c9a5b2 | Settings walked down its list and into Graphics, Setup check and Developer (`action-03`, `-08`, `-11`), About (`action-09`), an empty Downloads (`action-13`), the checklist (`action-14`), and the sign-in preview (`action-16`), each left with B. |
| `20260930T223332` | aae6f9e6 | Home's "All games" is on the ring (`action-03`), and A on it opens the Library. |
| `20260930T224316`, `…224613`, `…224835`, `…225136` | 91169753 | Among Us, RC Cars and #DRIVE Rally were queued (`queue:`) and installed, then uninstalled. The downloads ran at up to 80 MB/s, so a waiting row never lasted until a screenshot. Done today reads "Among Us · 1.15 GB" and "RC Cars · 986 MB", and the running card reads "72.3 MB of 986 MB" (`224835/action-04`). |

`action-08` of `222859` is the system share sheet. It shows the phone's contacts, so
it is not reproduced anywhere.

## What the review asked about

- **Downloads sizes (T04 suspect).** This was a real defect. RC Cars' size counted its
  Russian and Polish depots (985786348 + 157255481 + 7369974 bytes = 1.15 GB), which
  happens to equal Among Us's one depot (1150526746 bytes). The install size now counts
  only the depots an install takes, as `DepotSelection` does: the default language, and
  no low-violence variant. A SteamClient test has RC Cars' depots. Each row always showed
  its own game's record, so the rows never shared a value.
- **The sort picker's hint (T01) and the Game options note (T02).** Fixed, see
  `222859/action-04` and `222202/action-09`.
- **The share sheet (T02).** It still takes no pad focus: iOS gives the app's pad no way
  into it. The pad's presses no longer reach the page under it, and B closes it.
  Choosing a share target needs touch.
- **An update queued by itself blocks Play (T04 risk).** This is unchanged: an update
  applies its files at the end, so Play waits for it. The game page now says so: "Play
  is available once it finishes, or after Cancel". For an update Playport queued by
  itself, it also says that after a Cancel it waits for Steam's next version. Not seen
  on the phone: no installed game had an update.
- **Two cancels in a row (T05).** When a job is removed the ring moves, so a second
  `pad:x+down+a` presses on whatever is ringed next. DEVICE.md says to send `pad:x` and
  `pad:down+a` as separate actions for each job and to read the `pad:` log line.
- **Screenshots of a later action (T09).** One cause is fixed. A run ended by the driver
  could leave its last `ui-step-N` marker in Documents, and the next run's action N then
  went on before its screenshot. The app now removes old markers when a driven run
  starts. In the runs after the fix, the first shots that were checked each showed
  their own action. A marker pushed as a play's process restarts can still race the
  new process, so read the `pad:` log beside the shots.
- **Safe area.** The in-game menu drew its note and footer inset twice. They are now
  inset once, clear of the island on either side. The app's own screens sit inside the
  shell, which keeps the safe area. The launch screen's title and tip are centred.
- **The JIT helper stall (T08).** It was not seen again. Every play here (four) had JIT
  in 2.9 to 3.1 s.
- **madeira-unix 0048** (the retry backoff for deferred holds) changes the cadence for
  every game. Only Hollow Knight was played. The Witcher 3 and others were not.

## Not seen on the phone

These need a person at the phone, or a state this phone does not have:

- A real controller: its Home button held for the menu (whether iOS 27 delivers
  `buttonHome` with the system gesture off), its battery in the top bar and the menu, and
  touch on every screen.
- The launch failure screen and the slow-JIT steps (LocalDevVPN off at the phone), and
  the first-run checklist opening by itself (no pairing).
- A live Steam sign-in by account name (needs the paired session signed out). The RSA
  step is tested only against OpenSSL.
- An automatic update, the cellular wait, the Photos permission prompt, and a game that
  ignores WM_CLOSE.
- Earlier runs saved three screenshots from the in-game menu to the phone's Photos, one
  of them grey. The person may delete them.

The phone is left as found: Hollow Knight and PoolStress installed, the download queue
empty, and the Steam session and the pairing untouched.
