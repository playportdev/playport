# EpicClient: Epic Games sign-in, library and content

`EpicClientKit` is Epic's side of the PC-store plan (docs/plans/2026-10-06-pc-import-gog-epic.md,
Phase 3), on [ContentKit](../ContentKit/README.md)'s install core. Foundation only; `pp test`
runs its offline tests on the Linux host.

- **Session** (`EpicSession`): the launcher's desktop-client identity (decision 0058). The app's
  sign-in sheet opens `EpicAPI.loginURL`, which ends on Epic's redirect page: JSON with the
  `authorizationCode`, which the session trades for `eg1` tokens (36 h access, a year's refresh)
  and keeps only in the credential store (the Keychain, service `dev.playport.app.epic`). A
  corrective-action reply (seen: accept the updated privacy policy) is told to the player.
  Sign-out ends the session at Epic (`sessions/kill`), then deletes the item.
- **Library** (`EpicLibrary`): the library service's records (cursor-paged), then the
  catalogue per namespace for titles, art (DieselGameBox, resized by Epic's image CDN) and the
  custom attributes used here. DLC, Unreal Engine assets and non-Windows items are left out.
- **Refusals** (`EpicGame.refusal`, `EpicManifest.refusal`): anti-cheat (files in the manifest,
  Epic's access control, Marvel Rivals) and another company's launcher (Ubisoft Connect by the
  catalogue; Elite Dangerous and Star Trek Online by name), each with its own message. An
  ownership token or no offline play is not a refusal (decision 0059).
- **A game's sign-in** (`EpicSession.exchangeCode`, `ownershipToken`, `account`;
  `EpicInstaller.authArguments`, `EpicOwnershipFile`): the launcher's arguments for a signed-in
  launch (decision 0059), fetched at Play; the ownership token's file in the game's folder.
- **Content** (`EpicContent`, `EpicManifest`): the live build's asset (the manifest on three CDNs,
  each URL with its own token), the binary manifest (bounds-checked, counts and sizes capped,
  the body's SHA-1 checked) or Epic's older JSON form (`EpicManifestJSON.swift`: numbers as
  decimal byte triplets, 1 MiB chunks, `ChunksV3`; the same caps; the file's SHA-1 is the
  asset's hash), and the plan: chunks by GUID, SHA-1-checked, each file a list of
  slices of chunks, each file SHA-1-checked.
- **Chunks** (`EpicChunkSource`): from the manifest URLs' folders with no token, the CDNs in
  Epic's order, one that keeps failing passed over; each chunk file's GUID, size and SHA-1 checked.
- **Installer** (`EpicInstaller`): as GOG's: a first install stages and commits with one rename;
  an update or repair stages only the files whose SHA-1 differs; verify checks every file against
  the kept manifest (`manifests/epic-APP.manifest`, with `epic-APP.json`). Launch arguments: the
  manifest's command, the catalogue's extra command line, `-epicapp -epicenv=Prod -EpicPortal
  -epiclocale`; a Play adds the sign-in arguments.

Measured from the workstation (2026-10-06): the library listed 34 games; Limbo (Hazelnut, 44
files, 103 MB) installed in 1.7 s, verified 44/44, a corrupted executable found and repaired,
and a second install over it changed nothing.
