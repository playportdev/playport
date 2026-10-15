# Rockstar Games Launcher: Stage 0 on the phone

**Date:** 2026-10-15. **Branch:** `dev/pla-291-rockstar-launcher`.
**Linear:** [PLA-365](https://linear.app/playportdev/issue/PLA-365) (step 1),
[PLA-254](https://linear.app/playportdev/issue/PLA-254),
[PLA-364](https://linear.app/playportdev/issue/PLA-364).
**Plan:** [publisher launchers](../plans/2026-10-12-launchers.md), Progress (Rockstar track), chunk 2.

Phone: iPhone18,4, iOS 27.0.1. Runs are under `$PLAYPORT_BUILD/ui-runs/`.

## Step 1: Rockstar's installers from Steam's depot (PLA-365)

### Desktop Steam's rule

Red Dead Redemption 2 (1174180) lists its depots in PICS (anonymous read, 2026-10-15):

| Depot | Fields | Desktop Steam |
| --- | --- | --- |
| 228987, 228990 | `depotfromapp` 228980, `sharedinstall` 1 | Steamworks Shared |
| 1174181–1174186 | own manifests | the game's folder |
| 1899671 | `depotfromapp` 1899670, no `sharedinstall`, its public manifest in the game's record | the game's folder |

App 1899670 is "RGL/SC", type Config, installdir `RGLSC`. A depot borrowed from another app
without `sharedinstall` 1 is therefore installed into the game's own folder, as desktop Steam
installed it for the owner (chunk 1).

### What changed

- **Depot selection.** `DepotInfo.isContentFromAnotherApp` covers both cases: another app's
  depot without `sharedinstall` 1, and Half-Life's depots that share Counter-Strike's folder,
  as before. Either one is content. Its key and manifest request code are asked for its source
  app.
- **Depots left out.** A `sharedinstall` depot of an app other than 228980 is still left out,
  with the new reason `shared install in app N's own folder (not installed)`.
- **Records from before.** A record written earlier gave every borrowed depot the old reason.
  Such an entry from an app other than 228980 is a depot to check again
  (`InstallReceipt.depotsToRecheck`):
  - the offline check (Game options › Check game files) reports "Content to check with
    Steam";
  - Repair from Steam then reads Steam's depot list at the record's build;
  - a depot the selection now installs joins the record, and only its files are downloaded.
- **Driver action.** `pp ui --action repair:ID` presses the page's Repair from Steam, after a
  `verify:` that did not pass.
- **Install scripts.** The new depot's `installscript_sdk.vdf` is flagged as an install script
  (flags 256) in its manifest, so the existing install-script path runs it with nothing new.

### On the phone (IPA `2a24887030e5ae1fbd580dcfb79b568fca3f6461474dc4f15aa3984d2e04df41`)

**Repair**, run `20261015T225700` (`verify:app-1174180`, then `repair:app-1174180`):

```
verify: 120 files, 128041489146 bytes, 0 bad, 0 unlisted, 157.7 s; depots to check with Steam: 1899671
  depot 1899671 joins the install: gid 3914969219305676290 size=239826989 (from app 1899670)
repair: depot(s) [1899671] added to the record, 3 files to download
stage: 3 files (3 SHA-1-verified now, ...), 239826989 bytes; 232 chunks downloaded (235632685 bytes) ... 9.5 s, 24.7 MB/s
repair: 3 of 3 files replaced and re-verified; 0 still bad
ui: repair app-1174180: 123 files OK after 171 s
```

The repair downloaded 235.6 MB; nothing else of the 128 GB install moved.

The depot holds:

- `Redistributables/Rockstar-Games-Launcher.exe` (111,419,512 B);
- `Redistributables/Social-Club-Setup.exe` (128,406,648 B);
- `installscript_sdk.vdf` (829 B), with two entries:
  - `240240`: `Social-Club-Setup.exe /silent`, HasRunKey `HKLM\Software\Rockstar Games\Steam\SDK`;
  - `101093031`: `Rockstar-Games-Launcher.exe /s /t`, HasRunKey
    `...\Steam\Launcher`, `Requirement_OS` `Is64BitWindows` 1.

**Play**, run `20261015T230510` (`play:app-1174180`):

- The library lists 4 prerequisites: the two VC++ 2017 entries (rerun once with this build after
  their earlier 0x666 failure), then `240240` and `101093031`.
- `Social-Club-Setup.exe /silent` exits 0 after 3 s, and its HasRunKey value is written.
- The launcher installer starts.

**The installer by hand**, run `20261015T230843` (Play, then the owner at the phone):

- The installer's pages appear through decision 0075's guest windows (`[guest-window] ... shown:
  1028x600`). The owner pressed through Language select, Welcome, Terms of Service, Choose
  install location and Installing by touch.
- The installer ran both VC++ 14.44 redistributables (WiX Burn) and put its files in
  `C:\Program Files\Rockstar Games\Launcher`.
- It then started `RockstarService.exe` (pseudo-process `00cc`). That process looped on write
  faults into its own code. FEX logged `Handled self-modifying code ... AV WRITE of 127644F47`,
  sampled 1 in 1,000, about 2,000 exceptions in all. The process then ended with
  `NtTerminateProcess(-1, 0xc0000005)`.
- The installer then showed `[msgbox] "Rockstar Games Launcher"`: "An error has occurred. Please
  make sure all instances of the Rockstar Games Launcher have been closed and try again. If you
  continue to see this error, please visit: https://support.rockstargames.com".
- The prefix has no `Rockstar Games\Launcher` key, so `PlayRDR2.exe` would still look for the
  installer.

In the first Play (`20261015T230510`) the same box came up before the language page. A console
window left by the VC++ 2017 `.cmd` stayed in the guest window layer over it.

### RockstarService.exe and the storm breaker (step 2, part 1)

The faulting store wrote 4 bytes at RVA 0x24F47 of `RockstarService.exe`. The service has a second
`.text` section, and its own code shares that 16 KiB host page. Each pass of its loop took a
self-modifying-code fault that FEX handled, then went on. The breaker (ml461, and madeira-unix
0119 for a child) counts identical `(thread, pc, address)` deliveries, so it ended the process at
2,000 passes. madeira-unix 0151 adds the thread's general registers to that key. FEX holds the x86
registers in host registers, so a pass that made progress no longer counts as a repeat.

With IPA `fb14fc653935ebfec9b6730bb409ef97c83a3ce9caad96953a01ef9bc7dea244`, run
`20261015T234109`, the owner pressed through the pages again. This time `PlayRDR2.exe` started
the installer, because the prerequisite was recorded as failed with this build. Results:

- The service's loop got through: `[smc] ml1055 147000 self-modifying writes handled so far` in
  about 28 s, and no `[host-fault]`.
- The installer's log (`ProgramData\Rockstar Games\Launcher\installer_log.txt`) shows where it
  stopped. Its files were written and both VC++ 14.44 setups exited 0, then:
  `Found service` / `Running install service action...` / `App launched: ...RockstarService.exe
  with args: install` / `Exit code: 1`.
- The cause is `[file-wfail] ... status=0xc0000034 ... name=\??\pipe\svcctl`: no SCM runs in the
  session. That is step 2's subject (PLA-275). The same `[msgbox]` followed; the screenshot shows
  it over the installer's Installing page.

Hollow Knight on `fb14fc65`, run `20261015T235413`: first frame at +11.22 s, ok.

### Not done in step 1

- The SCM (step 2).
- The Hollow Knight smoke play: Hollow Knight is not installed on the phone (the library holds
  only RDR2). Step 1 is not a runtime change; its gate is the RDR2 runs above and the host tests.
  Hollow Knight is installed before step 2.
