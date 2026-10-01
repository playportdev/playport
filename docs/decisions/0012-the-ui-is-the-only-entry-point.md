# 0012: The UI is the only entry point

**Status:** accepted, 2026-09-25. Supersedes, in
[0009](0009-dev-and-release-builds.md), the dev build's harness modes, test
programs and guests, and in [0011](0011-no-workstation-jit.md) the driven
launch modes it names. The workstation title staging of
[0005](0005-title-cohort.md) is retired with them.

## Decision

The app is self-contained. A person does everything through its UI: pairs
with Steam, installs, verifies and uninstalls games, sets a game's launch
settings (screen, frame rate limit, environment variables), imports the JIT
pairing file, and plays. No other entry point reaches that functionality: no
launch mode that bypasses the UI, no terminal client, no tool that pushes files
into the container to change what the app does.

Testing and tooling follow the same rule. The workstation tests the app by
driving its UI, in a dev build, through the same model calls the buttons make
(`S1_MODE=ui`, `pp ui`). The dev build keeps only that driver, the scripted
pad that stands in for a controller (`HIO_VPAD`), and its unbounded log.

A build is good on the phone when Hollow Knight, played through the UI,
reaches its first frame and keeps running (`pp ui --play app-367520 --until
first-frame+10`), and a UI change is good when a run shows it.

Retired with this record:

- the probe ladder (G0 payloads, rungs 1 to 6, LadderKit), the G2 host-I/O
  probes with their test prompts, and `pp gate`;
- the dev launch modes `S1_MODE=title`, `steam` and `probe` and Settings'
  Diagnostics screen, with their drivers (`pp play`, `pp steam`);
- the `steamclient` terminal client with its terminal QR code and its Linux
  transport and keyring store;
- the workstation title staging (`stage-title.py`, `steam-manifest-check.py`,
  the Witcher 3 settings file), `pp cfg`, `pp phone push`, the pairing-file
  push, and Madeira's `proc-test` programs in the dev bundle;
- launch environment knobs the UI does not offer (`HOST_SCREEN`,
  `HOST_PRESENT`, `S1_JIT_POOL_MB`, `TITLE_WAIT_S`, `TITLE_CFG`);
- the host checks that ran pieces under the workstation's Wine
  (`hostio-selfcheck.sh`, `prefix-registry-check.sh`, `title-launch-check.sh`),
  and build lanes for parallel checkouts.

## Why

The probes proved, before any game ran, that JIT, Win32, threads, processes,
persistence, Direct3D 11, audio and input worked in one process. A game now
runs, and one Play of Hollow Knight exercises all of it, through the path a
player takes. Every committed ladder and G2 record passed. They cost about
9,000 lines, a build stage, a dev-only Swift package and a document, and
their records named the backend by a hand-edited string, so they could not
tell builds apart.

Side entrances test a route no player takes. `S1_MODE=title` started a game
by its DOS path, the Steam mode ran CLI commands, and staging pushed files the
UI never saw, so a passing run said little about the app a player has. Each
side entrance was also one more thing to document, keep working and explain.

## What it costs

- Witcher 3 needs its own `xinput1_3.dll` hidden and a low-preset
  `user.settings` written, which only the staging tool did. Until the app does
  both itself (from its cohort entry, at install), Witcher 3 is set up by hand
  or not at all.
- Nothing checks, as a separate step, that files survive a forced kill,
  that audio comes back after the device is invalidated, or that input
  survives the Home Screen, lock and rotation. Those are checked by hand on
  the phone after a change to that code.
- A runtime switch for one run is a game's launch settings (its
  `environment`), which stay saved as a player's would until cleared.
  `perf-run.py` turns the Metal HUD on through Settings in a launch of its own.
  The shared `madeira.cfg` has no writer; a title's keys come from its
  cohort entry.
- The workstation cannot talk to Steam; the offline SteamClientKit tests
  still run on Linux.
- One build at a time, in one checkout.
