# 0166: The Xbox store

**Status:** proposed, 2026-10-30, with the [Xbox plan](../plans/2026-10-30-xbox-game-pass.md)
([PLA-483](https://linear.app/playportdev/issue/PLA-483)). The owner settled each point below
in the plan's grilling session; the record is accepted when the plan is. Amends
[0057](0057-store-identity.md)'s list of stores; [0045](0045-library-store-copies.md) and
[0058](0058-store-sessions.md) unchanged.

## Decision

- **A fifth source, the Xbox store.**
  - `Store.xbox`, labelled "Xbox".
  - Its game ID is the **Product ID**, the Store's twelve-character product identifier.
  - A copy is `(xbox, Product ID)`, its title ID `xbox-<ProductId>`, its receipt the neutral
    `installs/xbox-<ProductId>.json`.
  - A Game Pass title is a copy whose licence can lapse, not a different kind of thing.
  - Copies of one game from Steam and Xbox stay two copies (0045).
- **What it covers.**
  - GDK titles in MSIXVC and MSIXVC2: the account's purchases and the PC Game Pass
    catalogue.
  - Not UWP/EAppx titles, and not Game Pass titles Microsoft delivers through Battle.net or
    EA (the launchers plan, PLA-254).
- **The synthetic device.**
  - Microsoft's sign-in and licensing need a registered Windows device. Playport registers
    one per app installation with random hardware details and **none of the phone's**
    identifiers.
  - It keeps the device's private key and proof secrets in the Keychain
    (`ThisDeviceOnly`).
  - The device survives sign-out and a later sign-in, so it does not use up the account's
    10 Microsoft Store devices.
  - It is replaced only by the dev app's "Reset Xbox device" or when Microsoft rejects it.
- **Sign-in.**
  - Microsoft's own inline login page in 0058's sheet, with no persistent website data.
  - When Microsoft offers a passkey, the sheet steers to its other ways (Authenticator,
    emailed or texted code, password); passkeys are not made to work in the app.
  - Session secrets live in the Keychain under one service for Xbox; sign-out deletes
    them, never the device.
- **Dev only.**
  - Every Xbox surface is compiled into the dev app only (0009), and
    `pp verify --variant release` fails a release executable that carries one.
  - Release needs a new record, after three titles are proven on the phone (one cloud save
    round trip with Windows or Xbox, one licence lapse, one save conflict) and a security
    review of the whole path.

## Why

- **The Product ID** is what the catalogue, the Game Pass lists and licensing key on, and
  it stays the same across a game's updates and packages. A package family name or content
  ID names one package, not the copy.
- **The synthetic device.** No real device can be used: the phone is not a Windows PC, and
  its identifiers are secrets (AGENTS.md). One random device per installation, kept across
  sign-outs, spends one of the account's Store devices, not one per sign-in.
- **Dev only.** Presenting a synthetic device and decrypting store DRM carries a risk to
  the account and the project that Steam, GOG and Epic do not. Testers get it only after
  the owner has seen it work and reviewed it.

## Costs

- **The account's limits.** The account's Microsoft Store device list shows a Windows PC
  for each Playport installation and for each reset. A player at the limit must unlink one
  at Microsoft.
- **Microsoft's changes.** Microsoft can change the login page, the device registration or
  licensing without notice; Xbox then stops until Playport follows.
- **Passkey-only accounts.** A player with only passkeys must add another sign-in way to
  the account first.
