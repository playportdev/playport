# Launch settings: resolution, frame rate limit and environment variables per game

**Date:** 2026-09-25. **IPA:** dev, sha256
`3ea151dbef04578d8bda05910d09e7cdc3266362e84d713e869e9befa6e85f59`, installed in
place with `build/build-and-install --from app`. **Tree:** the commit that adds
`app/PlayportKit/Sources/PlayportKit/LaunchSettings.swift`.
**Result:** a library Play of Hollow Knight (app-367520) with the game's own
settings at 540p, a 30 FPS limit and two environment variables ran at
1172x540 at a steady 30 FPS, and the runtime honoured the variables. With
those settings cleared, the same Play ran at the panel's native 2736x1260 with
no limit (85 FPS on the main menu, GPU-bound).

## Runs

```sh
flock $PLAYPORT_BUILD/device.lock python3 harness/device/ui-device-run.py --out $PLAYPORT_BUILD/ui-runs/settings-limit30 \
    --settings 'app-367520:{"frameLimit":30,"screen":"540","environment":[{"name":"WINEDEBUG","value":"+loaddll"},{"name":"PLAYPORT_TEST_VAR","value":"hello"}]}' \
    --play app-367520 --title-wait 100 --screenshot-after 60 --screenshot-after 95
flock $PLAYPORT_BUILD/device.lock python3 harness/device/ui-device-run.py --out $PLAYPORT_BUILD/ui-runs/settings-cleared \
    --settings 'app-367520:{}' --play app-367520 --title-wait 100 --screenshot-after 95
```

`--settings` saves the JSON through `LaunchSettingsStore`, as the game's page
does (`UIDriver.swift`'s `settings:` action), and `--play` goes through
`LibraryModel.play`, which resolves the settings for the launch.

### With the settings

```
ui: settings app-367520: screen=540 limit=30 environment=["PLAYPORT_TEST_VAR", "WINEDEBUG"]
title: Unity title; added -screen-fullscreen 1 -screen-width 1172 -screen-height 540
title: environment: the player's PLAYPORT_TEST_VAR, WINEDEBUG
title: display: screen 1172x540 (the title's screen 540) (panel 1260x2736 px), landscape, swap chain aspect-fitted, presents free-running, display link asks for up to 120 Hz, frames limited to 30 FPS, guest monitor 120 Hz
```

- The Metal HUD at 95 s (main menu): `1172x540`, FPS 29.99, frame interval
  33.35 ms with a flat graph, GPU 4.23 ms.
- `WINEDEBUG=+loaddll` reached the runtime: 51 `trace:loaddll` lines after
  this launch's start, and none in the log before it.

### Cleared

```
ui: settings app-367520: screen=native limit=0 environment=[]
title: Unity title; added -screen-fullscreen 1 -screen-width 2736 -screen-height 1260
title: display: screen 2736x1260 (panel 1260x2736 px), landscape, swap chain aspect-fitted, presents free-running, display link asks for up to 120 Hz, no frame rate limit, guest monitor 120 Hz
```

- The Metal HUD at 95 s: `2736x1260`, FPS 84.68, frame interval 11.81 ms,
  GPU 12.33 ms. No `loaddll` lines.

The per-game settings were left cleared after the runs. The global settings
in the Settings tab were never set (Automatic, Off).
