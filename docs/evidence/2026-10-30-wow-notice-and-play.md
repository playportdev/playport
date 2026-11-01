# World of Warcraft: the ban-risk notice and Play to character select (PLA-514)

**Status:** host checks done; on the phone the notice's decline, refusal and accept pass, and
Play starts the ARM64 client as a native ARM64 child
([below](#phone-runs-2026-10-31-ipa-9ee99874)). WoW does not reach its login screen yet: its
start-up is in [2026-10-31-wow-arm64-start.md](2026-10-31-wow-arm64-start.md). The sign-in to
character select (step 5) and the log secret scan of the sign-in run (step 6) are still to make.

## What changed

- PlayportKit `BattleNetPlay.decide` is Play's decision for a Battle.net copy: the ban-risk notice
  until the player accepts it (`InstalledTitle.riskNoticeAccepted`, kept across saves and library
  scans, per product, gone with the copy), then the receipt's ARM64 client, refused when the
  copy's executable is not ARM64 (PE machine 0xAA64), started on the Vulkan backend with `-d3d12`
  whatever the graphics settings say. The session starts an ARM64 executable as a native ARM64
  child (PLA-512, decision 0170); Vulkan links the aarch64 vkd3d-proton set over `sysarm64`
  (PLA-518 evidence `2026-10-30-arm64-d3d12.md`). No sign-in argument: WoW shows its own login,
  and the player types email, password and authenticator code with the text bar.
- The notice (`BattleNetPlay.notice`): "Blizzard does not support Playport. Blizzard may take
  action against your Battle.net account for playing World of Warcraft here, up to a suspension
  or a ban. Playport changes nothing in the game. You sign in inside World of Warcraft itself:
  Playport stores no Battle.net email, password or session." It is a picker over the page with
  Don't play (the cursor starts there) and I understand, play; Don't play, B or a tap outside
  start nothing. An installed copy's page shows the text, with "Play asks you to accept it
  first." or "You accepted this on DATE."
- Decision 0175 (proposed) describes this behaviour as built; no update to it was needed.
  *2026-11-01:* the sentence "Playport changes nothing in the game." was wrong once decision 0176
  rewrote the image in memory; it is now "Playport changes none of the game's files; to run on
  iPhone it rewrites some of the game's instructions in memory, which Blizzard may detect." (0175
  amended by 0176). The runs below showed the old text.
- Redactor and `pp secrets` learn what WoW and Battle.net carry for a session. The ARM64 client's
  strings (retail `Wow-ARM64.exe`, installed on the workstation in PLA-517) show its command line
  carries no session value: its switches are `-d3d11`, `-d3d12`, `-metal`, `-compat`,
  `-windowed`, `-launcherlogin` (login from the Battle.net app's agent, which Playport neither
  runs nor passes), `-config FILE`, `-datadir`, `-cascdir` and others with no secret. The session
  values live in its login: `WEB_TOKEN` and `GAME_ACCOUNT` (launcher login), `login_ticket`,
  `session_key`, `auth_token`, a reconnect token, `Param_BnetSessionKey`,
  `Param_RealmJoinTicket`, `Param_RealmListTicket`, `login/sso?token=…`, and the account name in
  `login/…?accountName=…` and Config.wtf (its `accountName` and `accountList` SET lines).
  Battle.net's web login returns a ticket `ST=<region>-<32 hex>-<digits>`. Each is scrubbed by
  `ContentKit.Redactor` (rules before the JWT and generic token rules) and three patterns are
  appended to `tools/checks.py` `SECRETS`: Battle.net login ticket, WoW session value, WoW
  account name. No `WOW_LAUNCHER_*` environment variable exists in the client.

## Host checks (this branch)

- `./pp test --swift PlayportKit` (379 tests, `BattleNetPlayTests` among them), `ContentKit`
  (`RedactorTests.testBattleNetAndWorldOfWarcraftSessionValuesAreScrubbed`), `EpicClient`,
  `GOGClient`, `SteamClient`, `BattleNetClient`: pass.
- `python3 -m unittest discover -s tools/tests -p 'test_checks.py'` and `-p 'test_ui.py'`: pass.
- `./pp secrets`, `./pp names`: clean.
- The app target (`LibraryModel.play`, `GameDetailView`, `Dev/UIDriver.swift`) is not compiled
  on the host; `pp check`/`pp build` in the main checkout compiles it.

## Phone runs to make (main checkout)

The commands. The runs made so far used Classic Era (`bnet-wow_classic_era`), installed by
PLA-519's run ([2026-10-31-battlenet-store-phone.md](2026-10-31-battlenet-store-phone.md)).

WoW retail must be installed on the phone first (PLA-519's path, about 132 GB with both clients;
Classic Era is far smaller and the same commands work with `bnet-wow_classic_era`):

```sh
./pp ui --action install:bnet-wow
```

1. Decline keeps Play from starting; the page shows the notice:

   ```sh
   ./pp ui --action notice:bnet-wow=decline --shot-each-action
   ```

   Expect `ui: notice bnet-wow: declined; Play did not start …`, `library: play World of Warcraft
   (bnet-wow): ban-risk notice declined`, the first screenshot the notice over the page, the last
   the page with the notice's text and "Play asks you to accept it first."

2. Play is refused while the notice asks:

   ```sh
   ./pp ui --action play:bnet-wow --shot
   ```

   Expect `refused: the ban-risk notice asks first`, the notice on the screenshot.

3. Accept reaches WoW's login screen:

   ```sh
   ./pp ui --action notice:bnet-wow=accept --until first-frame+60 --shot
   ```

   Expect `library: play bnet-wow: ban-risk notice accepted`, `library: play World of Warcraft:
   Battle.net's ARM64 client as a native ARM64 child on vulkan, -d3d12`, the `[arm64-child]` and
   `sysarm64: … links from overlays` lines (PLA-512/518), and WoW's login screen on the shot.

4. The acceptance is remembered, and the page shows it:

   ```sh
   ./pp ui --action open:bnet-wow --shot-each-action
   ./pp ui --action notice:bnet-wow=accept   # expect: fails, "its Play does not ask again"
   ```

5. **Owner gate** (the owner at the phone, a controller connected): Play, then sign in on WoW's
   login screen with the text bar (email, password, authenticator code) and reach character
   select:

   ```sh
   ./pp ui --play bnet-wow --until first-frame+900 --shot
   ```

6. Secrets on the run's logs (`pp secrets` scans the index; this applies its patterns to the run
   directories the runs above printed):

   ```sh
   python3 -c 'import sys,pathlib; sys.path.insert(0,"tools"); import checks; \
     [print(f, w) for d in sys.argv[1:] for f in pathlib.Path(d).rglob("*.log") \
      for w,_ in checks.secret_hits(f.read_text(errors="replace"))]' RUN_DIR...
   ```

   Expect no output, then `./pp secrets` clean once this file has the results.

Then: PLA-515 and the compatibility list (`site/compatibility/games.json`) get the result, the
IPA and the run directory, and this file the IPA's sha256.

## Phone runs, 2026-10-31 (IPA 9ee99874)

IPA sha256 `9ee9987479c1eedfce817665aaf62f87335ee045b04afcb348e3b75991a1e32e` (branch at
`326f2d43`), Classic Era installed (eu, enUS, 1.15.9.70576). Run directories are under
`.work/ui-runs/`.

| Run | Step | Result |
| --- | --- | --- |
| `20261031T215605` | 1, `notice:bnet-wow_classic_era=decline --shot-each-action` | ok: `notice bnet-wow_classic_era: shown, "Before you play World of Warcraft Classic Era", cursor on decline: …`, then `declined; Play did not start and the copy keeps no acceptance; the page shows the notice's text`; the library logged `ban-risk notice declined; Play not started` |
| `20261031T215655` | 2, `play:bnet-wow_classic_era --shot` | refused, as it should be: `refused: the ban-risk notice asks first` |
| `20261031T215724` | 3, `notice:bnet-wow_classic_era=accept --until first-frame+60 --shot` | accepted (`accepted at 2026-10-31 20:57:36 +0000; the Play goes on`); the game started; the run ended at the UI's done, 6.5 s in, before any frame |
| `20261031T215841` | the text bar over the running game (`menu:open`, `menu:text`, then `textbar:secret`) | the text bar opened; `textbar:secret` failed: `no value arrived in 60 s` |

- **Decline** (screenshot `action-01-notice_bnet-wow_classic_era=decline.png`): Classic Era's
  page after the decline, with the notice's full text in orange under the action row ("Blizzard
  does not support Playport. Blizzard may take action against your Battle.net account for playing
  World of Warcraft Classic Era here, up to a suspension or a ban. Playport changes nothing in the
  game. You sign in inside World of Warcraft Classic Era itself: Playport stores no Battle.net
  email, password or session.") and "Play asks you to accept it first.". The notice's picker
  itself has no screenshot: the driver answered it within the action.
- **Accept**: the library logged `ban-risk notice accepted; kept with the copy, the Play goes
  on`, then `Battle.net's ARM64 client as a native ARM64 child on vulkan, -d3d12, Config.wtf's
  GxApi D3D12; WoW asks for its own sign-in`, and the session started
  `C:\Games\World of Warcraft Classic Era\_classic_era_\WowClassic-arm64.exe -d3d12` with
  `[arm64-child] native ARM64 child: private aarch64 ntdll, no window, no FEX`. Its screenshot is
  the launch screen ("WORLD OF WARCRAFT CLASSIC ERA", "Waiting for JIT…") over Classic Era's
  art, taken when the run ended: `pp ui` stopped at the action's done, not at `--until`. Commit
  `99b6df9d` makes `notice:…=accept` follow its Play, so `--until` can match; not yet run on the
  phone.
- **Text bar** (PLA-267, PLA-606; screenshot `action-04-menu_text.png`): the in-game menu's Type
  text row opened the bar over the game: a close button, the password-mode lock, the field "Type
  into the game", Tab and Enter, with the iOS keyboard and its Passwords suggestion under it.
  `textbar:secret` then waited for a value `pp ui` never pushed: the app names only the action's
  number in its request, and `pp ui`'s tests had faked an action field the app does not send.
  Fixed in `0ea5f9f2`, not yet run on the phone.
- **WoW itself** went no further than its start-up on this IPA (stuck in its vectored handler; run
  `20261031T215841` is the first entry of
  [2026-10-31-wow-arm64-start.md](2026-10-31-wow-arm64-start.md), where the later IPAs and their
  blockers are).

**Secrets** (step 6's scan, on the four runs above): no Battle.net or WoW pattern hit. The only
hits are the `container UUID` pattern in the raw `pull/s1-host.log` of `20261031T215724` and
`20261031T215841` (the app's bundle path), which stay under `.work` and are not committed.

Not yet: the acceptance remembered across a later Play (step 4), the login screen, the owner's
sign-in (step 5), PLA-515 and the compatibility list.

## Text bar into Wine's ARM64 notepad (2026-11-01)

PLA-267's and PLA-606's phone criteria, with Wine's ARM64 notepad as the guest text field (it runs
since wine-pe 0058, [2026-10-30-native-arm64-child.md](2026-10-30-native-arm64-child.md#wines-arm64-notepad-the-aarch64-assemblies-2026-11-01)).
IPA sha256 `89baa2762d5d5caae1d320a0315082d6ba0b48b9c0c6fbf066f3c9966beacbd3` (branch
`dev/pla-516-battlenet`), run `20261101T053916`:

```sh
./pp ui --action play:dir-notepad --action wait:20 --action menu:open --action menu:text \
    --action "textbar:type:Zażółć gęślą jaźń ok" --action textbar:enter --action textbar:secret \
    --action wait:5 --secret-file .work/secrets/sentinel --shot-each-action --wait 150
```

The sentinel is a 26-character test value in a gitignored file (mode 600), never on argv. Every
action returned ok (`ok actions=8`); the events show `secret-pushed` with the action's number
only. An earlier run on IPA `5f72d802…` (`20261101T053243`) stopped at `menu:open`, which waited
for a first frame a GDI-only program never draws; `menu:open` now takes a guest window up 10 s
with no frame.

- **Screenshots:** `action-03-menu_open.png` the in-game menu over the dimmed notepad ("PLAYING ·
  JUST STARTED", notepad; Resume, Controls, Touch keyboard, Type text, Screenshot, Performance
  overlay, Controller, Quit game); `action-04-menu_text.png` the bar (close, the open lock, "Type
  into the game", Tab, Enter) above the iOS keyboard with its Passwords bar, notepad's caret at the
  top of its empty edit area; `action-05-…` and `action-06-textbar_enter.png` notepad's first line
  "Zażółć gęślą jaźń ok", every Polish letter drawn; `action-07-textbar_secret.png` and
  `action-08-wait_5.png` the lock lit orange (password mode) and a 26-character line, the sentinel
  file's length and form, on notepad's second line (so Enter made the new line), the caret after it.
  The bar's field stays empty after each send.
- **Scan:** `grep -rFf .work/secrets/sentinel` over the run directory (events, `argv.txt`,
  `timeline.txt`, `cmd/`, `pull/s1-host.log`, `pull/run-events.jsonl`) and over the two earlier
  notepad runs found nothing (exit 1). The screenshots hold it as pixels only, as notepad shows it,
  and stay under `.work`. The log has only `textbar: open, plain (not logged)`, `textbar: enter`,
  `textbar: secret on (not logged)` and the driver's `ui: textbar …` lines, and no `post_key vk=` or
  `drv_post_key … vk=` line.
- **Not covered:** AutoFill and the password mode by hand (PLA-267's person check), and the
  release build's absence of the action (`pp verify --variant release`, side copy, PLA-606).

**Tab** (PLA-267): IPA sha256 `b0fdcf2a63fec7e65a273289cc76264902144f6ef8b91ea4f1b80aa7d7caf46d`
(the same branch plus Marlett in the prefix's fonts), run `20261101T060119`:

```sh
./pp ui --action play:dir-notepad --action wait:20 --action menu:open --action menu:text \
    --action textbar:type:a --action textbar:tab --action textbar:type:b --shot-each-action --wait 120
```

Every action returned ok (`ok actions=7`). `action-05-textbar_type_a.png` and
`action-06-textbar_tab.png` show `a` on notepad's first line (the tab is blank space and the
caret is not in that shot); `action-07-textbar_type_b.png` shows `a`, a tab stop's gap, then `b`
on the same line, the bar's field empty. The log has `textbar: open, plain (not logged)` and
`textbar: tab`.

## Controller and sign-in on the phone (2026-11-01, IPA a0acb433)

Branch `dev/pla-516-battlenet` with `dev/pla-522-wow-pad` merged (HEAD `d8bc9b88`, the merge of
`8f9e4edc`); IPA sha256 `a0acb433b27b53d8c6ccc48018e1c7d2e30a981de8b5a50a66756d3f9e723529`,
no build records changed.

**Gates:** Hollow Knight first frame at +9.04 s (`20261101T123140`); arm64 probe exit `0x2a`
(`20261101T123241`); d3d12 probe on Vulkan exit 0 (`20261101T123345`), its log `textures: 24
made, 0 skipped` and `done ok`; `./pp test --quick` passes.

**Controller** (`./pp ui --pad --play bnet-wow --until first-frame+40 --leave-running`, run
`20261101T123607`, then `pp pad send`): s1-host.log has `hostio:
WINEDLLOVERRIDES=windows.gaming.input=d SDL_JOYSTICK_RAWINPUT=0`, xinput1_4.dll loaded, SDL's
`SDL_joystick` thread, and `controls: the game read XInput state (3 reads by now)`; the pulled
`Config.wtf` has `SET GamePadEnable "1"`. WoW showed no reaction on the login screen to D-pad
left/right, the left and right sticks, A or START (screenshots identical apart from the
animated backdrop; no focus ring on the Screen Narrator dialog's buttons, no pointer). Whether WoW
reacts to the pad in the world or at character select is not checked.

**Narrator dialog:** a tap on its Disable button (`tap:0.576:0.596`, routed "on the game" with
the scripted pad connected) closes it and shows the Email or Phone / Password fields. Its answer
is not in `Config.wtf` while the game runs (WoW writes it at exit), so the next Play shows it
again unless WoW exits cleanly.

**Sign-in** (runs `20261101T124046`, `20261101T124851`; `--secret-file` email then password):
- The Email field has no caret until tapped (`tap:0.5:0.43`); after the tap, `menu:open`,
  `menu:text`, `textbar:secret` types the email into it (shown in the field).
- `textbar:tab` moves the caret to the Password field (`20261101T124851`,
  `action-11-wait_2.png`, after `textbar:close`).
- `textbar:secret+enter` with the password then leaves the Password field empty and starts no
  login: 20 s and 60 s later the login screen is unchanged, `Aurora.log` has no line after the
  start-up's. The second value was pushed (`secret-pushed` index 10) and the action returned ok.
- **Cause (2026-11-01, PLA-606): the game froze, the field did not refuse the text.** The phone
  runs `Wow-ARM64.exe`. In both runs the screenshots are identical, pixel for pixel, from the first
  one taken a few seconds after `textbar:tab` (`20261101T124046` action-10 on, `20261101T124851`
  action-11 on): the animated backdrop stops. In `20261101T124046`'s `s1-host.log`, Tab goes at
  12:43:49.9 and the last `[frames]` line is at 12:43:54.6. The main thread (0068) then allocates
  0x542 bytes RWX (`NtAllocateVirtualMemory … prot=0x40`, the JIT-pool path) and jumps to pc 0
  (`[thunk-slot] WEDGE`, `dispatch_call_no_redirect=0`, an unhandled SEGV). No other WoW run that day
  logs that allocation. The password's 32 key events reached the server (`send_hardware_message=32`,
  status 0), but nothing accepted them (no `accept_hardware_message` or `get_message` after),
  whereas the email's 36 were accepted. The blocker is that ARM64 crash, not the text bar.
- **Desktop check** (Wine 11.20, x64 `Wow.exe` at the login screen in a headless sway, input from a
  Win32 program in the prefix using `SendInput`, dummy values only): `KEYEVENTF_UNICODE`
  characters sent in one burst (the `VK_PACKET` path the phone's `winios_drv_post_char` takes)
  type into the Email field and into the Password field (14 asterisks for a 14-character dummy).
  Shifted characters sent as keys (VK and scan code, with Shift) add to the Password field the same
  way. A `VK_PACKET` burst followed at once by Enter logs in: the Connecting dialog appears, then a
  dummy account's `BLZ51914400`, and `Aurora.log` shows the attempt. WoW drops the IME
  context on the Password field (`ImmAssociateContext(hwnd, NULL)`) and restores it on the Email
  field; the characters arrive either way. The x64 client allocates no RWX memory from the login
  screen through typing.
- The second run was cancelled during its `wait:20` when the owner took the phone.

**Secret scan:** `grep -rlFf .work/secrets/wow-password` over the three WoW run directories, the
pulled logs and the session notes prints nothing (exit 1). The email address matches only each
run's `cmd/apps.out` (the device's app list: the signing identity, also in runs before these);
`./pp secrets` is clean.
