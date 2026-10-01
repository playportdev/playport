# Ownership and provenance of Playport's own files and patch series

Date: 2026-09-30. Scope: Gate A item 2 for everything this repository itself
holds: its tracked files outside `upstream/`, and the authorship of every
patch series. It is not a review of the upstream trees the patches apply to
([LICENSING.md](../LICENSING.md) covers those), and not legal approval.

## Playport's own files

Every tracked source file outside `upstream/`, `patches/` and `docs/` (Python,
shell, C, Objective-C, Swift, JavaScript, LLVM IR, GLSL and the build scripts)
was checked for an `SPDX-License-Identifier` line. All carry
`GPL-3.0-or-later` except the ones below, fixed or classified here:

| Files | Origin | Outcome |
| --- | --- | --- |
| `build/air-helpers/air_{msad,samplepos,tessellation}.ll` | hand-written LLVM IR ports of DXMT's `air_*.metal` at v0.74, before DXMT's LGPL relicensing (after v0.80), so MIT-era code | header added: `GPL-3.0-or-later`, naming the MIT origin; DXMT's MIT text is collected as `DXMT-LICENSE.OLD.txt`. Comments do not reach `llvm-as`'s `.air` output, so the shipped bytes do not change |
| `build/mesa-host-test/shaders/*` (18 GLSL files) | Playport's host tests of KosmicKrisp (added with `patches/mesa` 0006) | header added; `#version` may follow a comment |
| `tools/sampleprof.py` | Playport's profile reader | header added |
| `tools/pad/*.txt` (8 scripted-pad scripts) | Playport's test data, read by `tools/pad.py` | no header (data, no comment syntax); covered by `LICENSE` |
| `app/SteamClient/LICENSE-JavaSteam.txt` | JavaSteam's MIT licence, for the protocol schema tables transcribed in `Wire/Schemas.swift` (which says so) | kept; collected as `JavaSteam-LICENSE.txt` |
| `app/PlayportKit/Titles/*.sha256`, `app/registry/*.reg`, SteamClient test fixtures | generated data (checksum lists, the prefix registry seed, `make-fixtures.py` output) | no header needed |
| `docs/design/2026-09-28-gamepad-ui/*.dc.html`, `canvas.json` | the owner's UI design export (pull request 38); they load a `support.js` that is not committed and fonts from Google Fonts at view time | nothing third-party is committed; not part of any build |

No other third-party copyright line appears in Playport's own files. The one
copyright notice in the app, `Copyright (C) 2026 The Playport authors`
(`LicencesView.swift`), names the copyright holder.

## Patch series authorship

`From:` of every patch, by series (2026-09-30):

| Series | Authors | Reading |
| --- | --- | --- |
| `dxmt`, `fex`, `gbe`, `idevice`, `madeira-winios`, `mesa`, `rpmalloc`, `vkd3d-proton`, `wine-pe`, `wine-unix` | the owner only | Playport's changes, GPL-3.0-or-later with the exception where the owner holds the copyright; the patched file's own licence still governs the combined code |
| `madeira-unix` | the owner (47, including the two `madeira-port` ports below) | Playport's changes to Madeira's host layer |
| `dxmt-port`, `fex-port`, `rpmalloc-port` | Madeira's author (40, 62, 16), one other contributor in `dxmt-port` (4), the owner (1 in `dxmt-port` and `fex-port`) | Madeira's ports, rebased by Playport; Madeira's licence terms apply |
| `wine-port` | Madeira's author (55), one other contributor (1), the owner (1) | Madeira's Wine fork, carried as a series; its ownership confirmation is the pending item in Madeira's provenance document |
| `wine-valve` | 18 upstream Wine/Proton authors | Valve's Proton commits picked onto WineHQ with their original authors; Wine's LGPL-2.1-or-later |

**Fixed:** `madeira-unix` 0020 and 0021 (the Wine 11.18 ports of Madeira's
`*_ios.c` replacements, committed by the owner in `9c28d4d`) had a placeholder
author, `port@localhost`; they now name the owner, like the other `madeira-port`
patches. `idevice` 0001 (merged from main on 2026-09-30) had the placeholder
`build@localhost` and now names the owner too. Earlier, `dxmt-port` 0044 and
`fex-port` 0063 were changed from the owner's personal address to the project
address. Only headers changed; the trees are checked by content, and the next
build reapplies the changed series.

## Still open

- Madeira's own open items stand: the ownership confirmation of its downstream
  Wine commits, and its `build/*-unix` files whose licence its documents state
  differently ([LICENSING.md, "Open items"](../LICENSING.md#open-items)). They
  need Madeira's author, not this repository.
- The exception in `LICENSE-EXCEPTION.md` covers only code whose copyright the
  owner holds. The files above are the owner's, or say where they come from.

## Madeira's two questions (host-only, 2026-09-30)

Read at the `pins.lock` `madeira` commit `8c050d03`, cloned read-only under
`.work/licence-research`:

- **Wine commits.** `docs/wine-lgpl-provenance.md` lists 51 commits by Madeira's
  author and says "OWNERSHIP CONFIRMATION: pending an explicit statement by the
  author that no patch below was adapted from third-party code except as noted
  (requested 2026-09-16)". The noted exceptions are the `wineios.drv` CoreAudio and
  CoreMIDI files, which keep upstream Wine's notices.
- **`build/*-unix`.** Madeira's `docs/LICENSING.md` gives the Wine unix side "and
  `build/*-unix`" as LGPL-2.1-or-later. Its `THIRD-PARTY-NOTICES.md` says original
  Madeira files without another notice are GPL-3.0-or-later, and its README still
  describes the retired GPL-converted Wine branch. In `build/crypto-unix`,
  `build/ntdll-unix`, `build/win32u-unix` and `build/wineserver`, 36 of 57 C,
  Objective-C and assembly files have no copyright or licence line in their first
  40 lines. Most are short iOS shims and stubs; the larger ones are
  `ntdll-unix/audio_null_ios.c` (1,312 lines), `ntdll-unix/nsi_unixlib_ios.c`,
  `ntdll-unix/dwrite_freetype_ios.c`, `win32u-unix/freetype_ios.c` and the generated
  `crypto-unix/gnutls_symtab_ios.c`.

Either licence lets Playport convey the app under GPL-3.0-or-later, so neither
blocks the source publication; they decide which notice and which relinking duty
a recipient gets for those files. The owner decided to send no request and to
rely on the stricter reading (decisions 0039 and 0041); the request drafted for
willfaust/Madeira is kept as a record only:

> Two licence questions from a downstream project that ships Madeira's host layer
> and Wine port:
>
> 1. `docs/wine-lgpl-provenance.md` records the ownership confirmation for the 51
>    `madeira-lgpl` Wine commits as pending since 2026-09-16. Could you add the
>    statement it asks for (that no patch was adapted from third-party code except
>    as noted), or note which ones were?
> 2. `docs/LICENSING.md` lists `build/*-unix` as LGPL-2.1-or-later, while
>    `THIRD-PARTY-NOTICES.md` makes original files without a notice GPL-3.0-or-later.
>    36 source files in `build/crypto-unix`, `build/ntdll-unix`, `build/win32u-unix`
>    and `build/wineserver` have no header (for example `audio_null_ios.c`,
>    `nsi_unixlib_ios.c`, `freetype_ios.c`). Which licence do they have? A header
>    or an SPDX line in each, and the README's line on the retired GPL-converted
>    Wine branch brought up to date, would settle it.

Until an answer, Playport's documents keep both readings open
([LICENSING.md, "Open items"](../LICENSING.md#open-items)).
