# Steam Cloud for Portal 2

## Result

- **Portal 2's saves sync again.** After a play that saved (`tools/pad/p2-save-load`),
  the next start of the app uploaded the new save and Steam's file list grew by one:
  `app 620: 17 on Steam, 18 on the phone; 0 down, 1 up, 0 conflict(s)`, then on the
  next sync `app 620: 18 on Steam, 18 on the phone; 0 down, 0 up, 0 conflict(s)`. The
  game page's facts card shows Cloud saves "Up to date".
- **Before the fix no Portal 2 sync had finished since its first one** (the download of
  its 12 files on 1 October). Every later sync stopped with
  `Cloud.ClientCommitFileUpload#1: EResult FileNotFound`, or with
  `Cloud.BeginAppUploadBatch#1: EResult 108` when it followed one that stopped, so
  nothing went up and the page showed "Not synced".
- **Hollow Knight is unchanged:** `app 367520: 5 on Steam, 5 on the phone; 0 down, 0 up,
  0 conflict(s)` before its play, which reached `first-frame+10` (first frame at 9.17 s).

IPA: `.work/out/20261004-234838-7d5d8b3d/Playport-26.5-7d5d8b3d.ipa` (dev). SHA256:
`7d5d8b3d3a683440471c45d3290dcd26529ce9dd620a497bfc40f685223bc438`.

## Cause

Portal 2 keeps its saves through Auto-Cloud: its PICS `ufs/savefiles` rule has the root
`gameinstall` and the path `portal2/SAVE/<account>/`, as the names the sync built from it
show. The game writes them in `C:\Games\Portal 2\portal2\SAVE\<account>\`, and the
emulator's account ID is the player's, so they land in the folder the rule names. `cfg/config.cfg` goes through
ISteamRemoteStorage, into the emulator's `GSE Saves/620/remote/`. Both were mapped
correctly.

The names were not. Steam lists the files a Windows client uploaded as
`%GameInstall%portal2/SAVE/<account>/….sav`, but `Cloud.localFiles` built the phone's
name from the rule's spelling, `%gameinstall%…`. The names were compared with case, so
every save had two names: Steam's, found through the remote list, and the rule's. With a
baseline in place, each rule-spelled name was "new on the phone" and went up. Steam takes
cloud names without case: it refused every one that matched a stored file
(`Cloud.ClientBeginFileUpload#1: EResult DuplicateRequest`, seen once the upload logged
each file). The commit after that failed with `FileNotFound` and threw, which ended the
sync before it completed the upload batch or saved a baseline. Hollow Knight's rule
spells its root `WinAppDataLocalLow`, as Steam does, so it never had two names.

One diagnostic run (IPA `ca0425f7`) went past the refusals and uploaded Portal 2's
five newer saves under the rule's spelling, `%gameinstall%…`. Steam keeps them as
named; a Windows client places them in the same folder, and the fixed sync matches them
(below).

## Fix

- `Cloud.canonicalRoot`: a rule's root takes Steam's spelling (`GameInstall`,
  `WinMyDocuments`, `WinAppDataLocal`, `WinAppDataLocalLow`, `WinAppDataRoaming`,
  `WinSavedGames`), so a new save goes up as a Windows client would name it.
- `Cloud.named`: before the plan, each local name that matches a name on Steam (or in
  the last sync's baseline) without case takes that spelling, so one file has one name.
- `SteamSession.cloudUpload`: a file Steam refuses is logged by its file name (its
  folders carry the account ID) and left out, and the batch is always completed. A
  refused file used to abort the sync.

The conflict rules (Cloud.plan, the first-sync question, the backups) are unchanged.

## Tests

`CloudTests.testARulesRootTakesSteamsSpellingAndLocalNamesTakeSteamsCase` (the rule's
root, `Cloud.named`) and `CloudServiceTests.testPortal2sSavesSyncUnderTheNamesSteamHas`.
That test has a Portal 2-like rule, an autosave on Steam as `%GameInstall%`, an earlier
save as `%gameinstall%` and `cfg/config.cfg`. The first sync downloads all three and
the second moves nothing. After a play, the new save and the changed autosave go up
under Steam's spelling, and a later PC change comes down. The fake backend now refuses
a name that differs from a stored one only in case, as Steam does.

## Not checked on the phone

The download before a play ran (`17 on Steam, 17 on the phone; 0 down`, just before
Play) but had nothing to bring down: that needs a save made on another computer.
