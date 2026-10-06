# PC game import and GOG on the phone (plan Phases 0–2)

**Date:** 2026-10-06. **Plan:** [PC import, GOG and Epic](../plans/2026-10-06-pc-import-gog-epic.md).
**Decisions:** [0057](../decisions/0057-store-identity.md), [0058](../decisions/0058-store-sessions.md).
**Phone:** iPhone18,4, iOS 27.0, dev builds. Driven with `pp ui`; the GOG sign-in was
done by hand by the owner.

## Phase 0: the shared core and store identity

IPA `a053349b…` (`a053349b30bd04f7a52408b0c9fcacfca60c8d4df21633ded43f0ed8c8179d71`):
Hollow Knight (Steam) played to `first-frame+10`, first frame at +10.17 s, JIT in 2.63 s.
IPA `57ef926c…` (`57ef926c2a8b86f068638c9ec5582d8b7ea1d700eaf741687c61b604874d45a1`):
`pause-resume:945360` (Among Us) paused at 309 MB of 1.15 GB with the stage kept,
resumed from it, landed in the library as `app-945360` after 21 s, then 105/105 files
verified against its Steam manifests in 1.4 s. The first run of it (IPA `c60f2343…`)
found a resume during a pause's wind-down ignored; fixed before this run.

## Phase 1: import from Files

IPA `c60f2343…` (`c60f23433c4ee5341c4ebef3f340d78a06eef19a26dd31809ed14c923f92fa49`).
At the owner's direction the workstation put a DRM-free PC folder (Hollow Knight's
Windows install, 1785 files, 5.23 GB) into the container's `Documents/Import` (AFC,
106 s), and `pp ui --action "import:Import/Hollow Knight"` handed it to Add a game as
the picked item (the picker is iOS's and cannot be driven).

- The import job copied it into `C:\Games\Hollow Knight 2` in 1.1 s (the clone path on
  one volume) and the library adopted `dir-hollow knight 2`, source `imported`, store
  `local`, executable `hollow_knight.exe`.
- It played to `first-frame+10`: first frame at +8.95 s, JIT in 2.42 s.
- `uninstall:dir-hollow knight 2` removed the folder and its `local-…` receipt; the
  Steam receipts stayed.

The zip import (1.4), the Executable and Name rows (1.3) and the icon art (1.6) are
host-tested only. The picker itself, by hand, is not checked yet.

## Phase 2: GOG

From the workstation first (see `app/GOGClient/README.md`): the API shapes in the plan
held, with one correction: GOG's desktop-client secret is 64 hex digits (the 32-digit
form is refused, `invalid_client`). Test title by 0005's scorecard: **Shogun Showdown**
(1104084973), Unity x86-64, 433 MB, five generation-2 builds. Hollow Knight is not in
the owner's GOG library.

On the phone (IPA `49d0dcf5…`, `49d0dcf51138382660420081be3677fca0efc2acab71f80dbab74bf163adad4f`):

- **Sign-in**: the owner signed in through Settings › Accounts › GOG. In landscape,
  1Password's AutoFill sheet drew only grey; the sheet now allows portrait while it is up
  (`49d0dcf5…` onward), and the sign-in then worked. The library listed 46 Windows games.
- **Install** of build 0.9.1.3: 204 files, 397 MB in 5 s, into `C:\Games\Shogun Showdown`,
  catalogued as `gog-1104084973`, executable from `goggame-1104084973.info`.
- **Update** to 1.0.2.1a: 172 changed files fetched, 5 s; **verify**: 208/208 OK.
- **Play** to `first-frame+10`: first frame at +19.17 s, JIT in 2.35 s; the title screen
  shows build 1.0.2.1. Hollow Knight on the same IPA: first frame at +9.72 s.
- On IPA `29105231…` (`29105231a0a597fbfd4f19f58b5a404bc02e6016cf3c093cabeca5b567b3a2c1`)
  the page of the older build shows **Update** (the first IPA recorded the installed build
  as the newest, which hid it), and the update ran again to build 1.0.2.1a.

Not checked on the phone: a repair from GOG (checked from the workstation: a corrupted
executable found and replaced), uninstall of a GOG game, GOG art on tiles.
