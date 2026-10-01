# Steam game management from the product UI: install, pause and resume, verify, uninstall

**Date:** 2026-09-25. **IPA:** dev, sha256
`2a67cb3952b66fa5cc238f21dc95130b26a7c10b8aee27a3e0b4e5b46ec42cb8`, installed in
place with `build/build-and-install --from app`. **Tree:** the commit that adds
`app/Sources/S1Probe/UI/SteamInstalls.swift`, before its last UI changes (see the re-run).
**Result:** on the phone, with the app's paired Steam session, the UI's
download queue installed Relic Hunters Zero: Remix (app 382490, 116 MB). It
paused at a quarter with the stage kept, resumed from that stage, landed in
the library as *Ready*, verified offline against its retained manifests, and
uninstalled with nothing left behind.

## Run

```sh
flock $PLAYPORT_BUILD/device.lock python3 harness/device/ui-device-run.py --wait 1500 \
    --action pause-resume:382490 --action verify:app-382490 --action uninstall:app-382490 --screenshot-after 12
```

`S1_MODE=ui` runs each action through the model calls the buttons make
(`app/Sources/S1Probe/Dev/UIDriver.swift`). From `s1-host.log`:

```
ui: install 382490 Relic Hunters Zero: Remix: started
ui: install 382490: paused at 43.3 MB of 116 MB · 35.5 MB/s; phase=paused(nil) stage kept=true
ui: install 382490: resumed at 68.6 MB of 116 MB · 31.0 MB/s (downloading)
ui: install 382490: in the library as app-382490 [Ready] build=6232733 size=116044468 exe=RelicHuntersZero.exe after 6 s
ui: verify app-382490: 11/11 OK, 0 unlisted
ui: uninstall app-382490: folder present=false record present=false stage present=false catalogued=false
ui: done nonce=2994b766 ok actions=3
```

From `steam-drive.log` (`[ui] install` lines), the resume used the kept stage.
The paused run had 47 of the 119 chunks in its journal; the resumed run
re-hashed the journalled chunks of unfinished files and fetched only the other 72:

```
resuming stage: 47 chunk and 2 file records in the journal
resume: 14 journalled chunks re-hashed OK, 0 failed and will be fetched again; 2 files already verified
stage: 11 files, 116044468 bytes; 72 unique chunks to fetch (67550562 bytes to write) with 8 in flight
install: committed to Games/Relic Hunters Zero with one rename; record written
```

The pulled `steam-drive.log` passed the leak check
(`steam-device-run.py --scan`). The screenshot at 12 s shows the Installed
tab empty again after the uninstall, with the new empty-library text.

## Re-run on the committed tree

The commit then centred the Install and Play labels and merged the Installed
and Steam game pages into one (`GameDetailView`). Its dev IPA, sha256
`167edd0ffad89cbe1b61390f41ca24bdba3c2cba169c8610bdc9317fc87c9fcd`, passed
`--action install:382490 --action uninstall:app-382490`: in the library as
`app-382490 [Ready]` after 5 s, then removed with no folder, record, stage or
catalogue entry left (`ui: done nonce=efe10c73 ok actions=2`).

## Not covered

- The driver calls the model directly. No run has tapped the buttons, and
  no screenshot shows a download in progress: the whole install took 6 s.
- A title launch pausing a running download, and the Update and Repair
  buttons (which need a newer build, or a damaged file), were not run.
