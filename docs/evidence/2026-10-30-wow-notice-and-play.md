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
