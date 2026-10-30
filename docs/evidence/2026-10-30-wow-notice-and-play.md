# World of Warcraft: the ban-risk notice and Play to character select (PLA-514) — draft, phone runs to make

**Status:** host checks done; **no phone run yet**. The `pp ui` runs and the owner's sign-in below
are still to make from the main checkout, with this branch merged into `dev/pla-516-battlenet` and
built there. IPA sha256 and run directories go here once they exist.

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
- Decision 0169 (proposed) describes this behaviour as built; no update to it was needed.
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
