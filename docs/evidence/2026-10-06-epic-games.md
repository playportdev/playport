# Epic Games on the phone (plan Phase 3 gate)

**Date:** 2026-10-06. **Plan:** [PC import, GOG and Epic](../plans/2026-10-06-pc-import-gog-epic.md), Phase 3.
**Decisions:** [0057](../decisions/0057-store-identity.md), [0058](../decisions/0058-store-sessions.md).
**Phone:** iPhone18,4, iOS 27.0, dev build. Driven with `pp ui`; the Epic sign-in was done by
hand by the owner.

## From the workstation (plan 3.1)

Read-only on the owner's account; the shapes are in `app/EpicClient/README.md`. What the plan
expected held, with these findings:

- **Sign-in.** The first sign-in did not give a code: the redirect page answered
  `errors.com.epicgames.oauth.corrective_action_required` with `PRIVACY_POLICY_ACCEPTANCE`.
  After the owner accepted Epic's updated privacy policy, the redirect gave the code. The app's
  sheet reads the redirect page's JSON, says what a corrective action asks and offers Try again.
  Tokens: `eg1~`, access 36 h, refresh one year.
- **Manifests.** Every manifest seen (Snakebird Complete, Death's Door, Limbo) was the binary form,
  feature level 17, zlib body, version-0 sections (no md5 or SHA-256 per file: SHA-1 only). A
  manifest URL needs its CDN's token; the chunks under it need none, on all three CDNs. Chunks are
  1 MiB, header version 3, zlib, SHA-1 as the manifest lists it. Files slice chunks (2155 sliced
  parts in Death's Door).
- **Library.** 38 records, 34 Windows games after DLC, engine assets and private sandboxes.
  Needing Epic online sign-in at launch (plan 3.6) by the catalogue's attributes: an ownership
  token (Borderlands 3, Guardians of the Galaxy, Football Manager 2022 and its tools, Jurassic
  World Evolution), no offline play (Jurassic World Evolution, Star Trek Online), Epic's access
  control (Fortnite). Two install through another company's launcher (Roller Champions,
  Trackmania). None of these is a game the owner asked for, so decision 0059 is not written
  (plan 3.6): they are refused.
- **Test title** (0005's scorecard): **Death's Door** (`65d73e3be8824829b5b788bd849b6559`), Unity
  x86-64, D3D11, offline, no Epic SDK in its files, 1334 files, 3.93 GB installed, 1.40 GB download.
- `EpicInstaller` from Linux: Limbo (103 MB) installed in 1.7 s, 44/44 verified, a corrupted
  executable found and repaired, and a second install over it changed nothing.

## On the phone

IPA `d17028de…` (`d17028deda46778b4834acc5db3a48b985d443b18048b2a4650319efb9a38942`).

- **Sign-in**: the owner signed in through Settings › Accounts › Epic Games. The Library showed
  the Epic Games filter with 34 games.
- **Install** (`install:epic-65d73e3be8824829b5b788bd849b6559`): 3.93 GB written in 32 s (68 to
  154 MB/s), catalogued as `epic-65d73e3be8824829b5b788bd849b6559`, executable `DeathsDoor.exe`
  from the manifest, arguments `-epicapp=… -epicenv=Prod -EpicPortal -epiclocale=en`.
- **Verify**: 1334/1334 files OK against the kept manifest.
- **Refusal**: Borderlands 3's page shows "This game needs Epic online sign-in, which Playport
  does not support yet." under a disabled Install.
- **Art**: Death's Door's tile shows Epic's 16:9 art (800 wide) once fetched, and the page and
  launch screen its 1920-wide form.
- **Play** to `first-frame+10`: first frame at +4.47 s, JIT in 2.47 s; the title screen
  (Start, Options, Exit) was drawn at the stop.
- Hollow Knight on the same IPA: first frame at +8.60 s, JIT in 2.52 s.

Not checked on the phone: an update (Epic published no newer build in the session), a repair
from Epic (checked from the workstation), the uninstall of an Epic game, the sign-out's session
kill. Death's Door stays installed.
