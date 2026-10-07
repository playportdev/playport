# PLA-57: the GOG install driver's library check

**Date:** 2026-10-07. **Result:** fixed and checked on the phone.
**IPA:** dev, SHA256
`a8ec0956b75d80eac5ddb285bbd6ce6c46b935a185d64d9cb0a02245fc07f257`.
Installed in place on iPhone18,4 / iOS 27.0; container and store sessions kept.

## Cause and change

`UIDriver.installGOG` waited while the catalogue's version was absent or unchanged,
**and** the requested build differed from the previous build. A fresh latest-build
install has neither a requested nor a previous build: `nil != nil` is false, so
it skipped the wait. Downloads had removed its finished job but the asynchronous
library adoption had not returned. The saved Moonscars, Duck Paradox and Monster
Train install logs in `$PLAYPORT_BUILD/agent-notes/store-auth/gog-b9/` show the
failure immediately followed by `library: adopted` with the new title.

The driver now waits for adoption to finish and for the title to have a store
version. An explicit requested build must match that version. Latest-build and
same-build installs do not require a version change. The existing 60-second
adoption bound stays; an unfinished scan or mismatched explicit build now fails
rather than reporting success with the old catalogue. The tested predicate lives
in `Dev/DriverInstallCheck.swift`, excluded from release builds with the driver.

## Phone checks

Runs under `$PLAYPORT_BUILD/pla-57/`, all with `result.ok=true`:

- **`fresh-install/`:** `install:gog-1950069341`, then its page and Verify.
  Coromon was absent before this run. The install took 83 s; adoption preceded
  the driver's success line: `gog-1950069341 [Ready]`, build
  `58986473441409558`, 1,194,957,130 bytes, `coromon.exe`.
  Verification: **12539/12539 OK, 0 unlisted** against GOG's manifest.
- **`repeat-install/`:** `install:gog-2106173825`, then
  `install:gog-2106173825@56642357309108551`, then its page.
  Both Moonscars installs retained build `56642357309108551`, returned success
  after about 2 s each, and reported `[Ready]` without waiting for a version
  change. The page screenshot shows Play, GOG and 697 MB on the phone.
- **`installed-page/`:** reopened Coromon in a new process. The page screenshot
  shows Play, GOG, 1.19 GB and Last played: Never. The earlier fresh-install
  screenshots showed the app's Downloads finished sleep screen, so this separate
  run confirms the installed page visually.

No game was launched, no achievement/stat was written, and no account was signed
out. These are install-driver checks, not new game-compatibility verdicts.
Screenshots and logs remain in the run directories, not in this record.

## Host checks

- `./pp test`: all passed on rerun, including 508 tools tests, host C tests and
  all six Swift packages. The first run hit an unrelated transient notices-test
  error reading a vanished `.git/objects/maintenance.lock`; no notices code was
  changed, and the rerun passed.
- `test_driver_install.py` compiles the actual dev-only Swift predicate and checks
  missing/adopting titles, latest installs, unchanged builds, explicit builds,
  wrong builds and downgrades. Skipped only when no Swift compiler is installed
  (source-only CI).
- `./pp build`: dev IPA verified, **80 checks passed**. No committed build-record
  changes. `git diff --check` clean.
