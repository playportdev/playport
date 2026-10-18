# Rockstar launcher on desktop Proton versus the phone's generated fault (PLA-401)

**Linear:** https://linear.app/playportdev/issue/PLA-401. Follows
[the generated fault](2026-10-18-rockstar-generated-fault.md). Workstation only: no build, no
install, no play on the phone. The phone was used only for directory listings and two file pulls,
under its lock.

**Question:** On x86-64 desktop Wine, does the RDR2 Steam chain
(`PlayRDR2.exe` → `Launcher.exe -steamAppId=1174180`) get past the main window, or does it hit the
same privileged instruction (`c0000096`) about 0.2 s after `Active`? Where the two differ, which
input differs?

**Answer:**
- **The owner's own desktop play (2026-10-15) went past that point.** It used real Steam and
  Proton Experimental, with the same launcher, Social Club and Rockstar profile as the phone.
- **The Playport-like desktop run could not reach that point.** It used our Steam client with no
  host, and the phone's remembered Rockstar session did not carry over.
- So the fault was **not** reproduced or excluded on desktop.

## Owner's desktop play against the phone (launcher.log line kinds)

The owner's log was copied read-only and deleted after this comparison. It came from the owner's
own RDR2 prefix: launcher 1.0.109.3031, Social Club 2.4.0.240, the same profile id as the phone.
The phone run is `20261018T120626`. Times are from `UiWindowController::SetContext: Auth -> MainWindow` (t0).

| Step | Owner's desktop | Phone |
| --- | --- | --- |
| `Setting up steam title: rdr2` | `Successfully setup title` | `Successfully setup title` |
| Time to start up | 4,365 ms | 37,383 ms |
| Auth status 200, privacy 200, "external launch post-sign in", Auth → MainWindow | yes (the owner signed in by hand) | yes (remembered session) |
| Main window placement | `Centering on monitor` | `Using saved geometry` 1280×600 |
| Signed In / Went Online / title list | +14 / +21 / +21 ms | +57 / +110 / +111 ms |
| `SetState … -> Active` | +21 ms | +127 ms |
| Next logged step | +451 ms `Could not enumerate … <profile folder>`; +458 ms `Attempting external title launch`, `Begin game launch: rdr2` | +316 ms `Exception: 0xc0000096`, backtrace hash `0xCC332291` |

**Reading.**
- Both logs follow the same sequence up to `Active`.
- The phone faults inside the ~430 ms in which the desktop logs nothing before its external-launch step.
- Other differences in the logs:
  - **Phone only:** the service handshake times out (protocol 0), and `Shell_NotifyIconW` fails.
  - **Desktop only:** the launcher is a second, `-upgrade` generation, and logs "Could not do OpenProcess on parent process".
  - Locale.

## Desktop reproduction (Proton 10, scratch prefix)

**Setup:**
- **Wine and prefix:** Proton 10's own `wine`, run directly so that Proton's Steam setup never ran. The prefix was a copy of the Stage R scratch prefix, with launcher 1.0.109.3031 and Social Club 2.4.0.240.
- **Display:** the sway session (`DISPLAY=:0`, `WAYLAND_DISPLAY=wayland-1`, checked to belong to `sway-nocap`). URL opens were blocked.
- **Steam client:** Playport's `steamclient64.dll` (sha256 `8a570de9…`, as `app/artifacts.tsv`) in `C:\Program Files (x86)\Steam`, with no host. That means `BLoggedOn` 0, no SteamID and no tickets.
- **Registry:** `Valve\Steam` keys in both views. `ActiveProcess\pid` was a stand-in session process.
- **Environment:** `SteamAppId`, `SteamGameId` and `STEAM_COMPAT_APP_ID`.
- **Game folder:** the phone's `PlayRDR2.exe` (sha256 `028db16c…`), started with no arguments in `C:\Games\Red Dead Redemption 2`. There was no `RDR2.exe`.
- **Rockstar session:** the phone's remembered Social Club `profile.dat` and launcher `settings_user.dat`. The owner approved copying them; they were deleted after the run.

**Result (one run, 240 s):**
- **Command line and working directory:** identical to the phone's launcher.
- **Steam:** `SteamAPI_Init` succeeded. The interfaces served and the stubs called were the same as on the phone.
- **Service and tray:** the service handshake succeeded, and there was no tray failure.
- **Where it stopped:** `Setting up steam title: rdr2` → "Aborting launch due to being unable to auto sign in to offline profile!" → error 133 ("services are unavailable and offline play could not be verified"). The main window then opened in Offline Mode with that error.
- **Remembered session:** Social Club logged `Failed to import profile … profile.dat (2508 bytes read)`, then `START_SIGN_IN`. The session does not carry over to another machine, and it was not worked around.
- **No fault:** no `c0000096` and no unhandled exception. Launcher.exe stayed alive for 240 s with the saved 1280×600 geometry in use. That was an offline main window, not the signed-in one, so it says little about the geometry lead.

**Differing inputs this run could not close:**
- Steam logged on, with a SteamID and an auth ticket (the phone has them, this run had none).
- The Rockstar session.
- `RDR2.exe` present.

On the owner's desktop, title setup succeeded *before* any sign-in, with real Steam. This run failed
the same setup step with no Steam logon and no importable profile. Which of the two caused it is not
separated: inference only.

## Not done

- Rockstar sign-in on the desktop.
- A real Steam session for the shim. Playport's session exists only in the phone's Keychain, and
  the Linux host has no CM transport. The owner chose not to make a new Steam sign-in.
- Gameplay.

All private inputs are deleted:
- the owner log copies;
- the pulled `profile.dat` and `settings_user.dat`;
- the scratch prefix copy.

Social Club originals were verified, 81 of 81 files, in the copy and in its source.

## Candidate next checks (phone, not run)

- With the launcher's saved window geometry removed (`settings_user.dat` placement), does the main
  window still fault? Desktop centred; the phone used saved geometry.
- The `Shell_NotifyIconW` failure: whether the tray icon call's failure precedes the fault on
  every run.
- On the desktop, a Steam answer with a logged-on user (a stand-in snapshot), to reach title setup
  without Rockstar's offline path. A sign-in there would still need the owner in person.
