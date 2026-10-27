# Playport's Steam client reports an unowned app as not owned (PLA-25)

**Linear:** [PLA-25](https://linear.app/playportdev/issue/PLA-25) (Half-Life (70)).
**Result:** Steam refuses Half-Life's ownership ticket with `AccessDenied`. Playport's Steam client
(decision [0115](../decisions/0115-a-steam-client-for-the-launched-app.md)) now passes that refusal
on: `BIsSubscribedApp(70)` answers 0 where it used to answer 1, and the runtime log says why. Given
that answer, Half-Life's own steam_api ends the game at once (exit 0). An owned title is unchanged:
Hollow Knight is logged on, owned and has tickets armed.

IPA: `.work/out/20261027-082216-0107f809/Playport-26.5-0107f809.ipa` (dev), sha256
`0107f8096ec1f1234e1cfa8812850c1faa198b34ffad2828b30b4f070ac3a38a`, built from `ce36a49` plus this
change (branch `dev/pla-25-app70-logon`).

## Why "not logged on" for app 70

The i386 client run of PLA-442 (`.work/ui-runs/20261027T080141`) said `not logged on` for Half-Life,
where the other i386 titles were logged on. The cause is ownership, not the i386 client:

- The paired account holds no licence for app 70. App 70 is in none of its packages' `appids`
  ([2026-10-12](2026-10-12-shared-installdir-compat-merge.md)). Half-Life's depots 71 and 96 are
  listed by a package the account owns, so their keys are given and the install works. That is why
  the title could be installed through the driver (`install:70`) even though it is not in the
  library.
- Steam answers `ClientGetAppOwnershipTicket 70` and `ClientRequestEncryptedAppTicket 70` with
  `AccessDenied`. Without an ownership ticket, no ticket session is armed. Without a ticket
  session, the CM session closes at launch (decision 0062), so the client says it is not logged on.
- Before this change, the client still answered `owns_app = 1` ("a Play from the Steam library is
  of an app the account owns"), so `BIsSubscribedApp(70)` returned 1. Steam's own client would not
  give that answer for an app the account does not own.

## Change

- `SteamService.prepareTicketSession` returns a `TicketSession`: `.armed(broker)`, `.off`, or
  `.notOwned`. `.notOwned` is returned only when the ownership ticket comes back `AccessDenied`;
  any other refusal stays `.off`.
- `LibraryModel.play` passes `owned: false` through `LaunchCoordinator.SteamAPI` to
  `SteamClientHost.Play` for `.notOwned`. When ownership is unknown (no session), the title still
  counts as owned, as before.
- `SteamClientHost` HELLO sets `owns_app` from it. The shim's `BIsSubscribed`, `BIsSubscribedApp`,
  `BIsAppInstalled` and `UserHasLicenseForApp` follow from that.
- The log line `steamclient: client connected … not logged on, not owned (Steam refused its
  ownership ticket: AccessDenied)` gives the reason.

## Runs (iPhone18,4)

| Title | Run | Result |
| --- | --- | --- |
| Half-Life (70), `-gl` | `.work/ui-runs/20261027T082245` | game started +7.43 s, then `exit=0x00000000 after_s=0`, no first frame. Its log has `not logged on, not owned (…AccessDenied)` and `ISteamApps008 BIsSubscribedApp(app=70) -> 0`; the game ends right after. |
| Hollow Knight (367520) | `.work/ui-runs/20261027T082338` | first frame +12.36 s, to first-frame+10; `logged on, tickets armed, owned`. The screenshot at stop shows the on-screen controls over a black frame. |

## Host checks

- `pp test --swift SteamClient --filter TicketServiceTests`: 2 tests passed. An `AccessDenied`
  ownership refusal gives `.notOwned`; `Fail` gives `.off`.
- `pp build` verify: 90 checks passed.

## Consequence

Half-Life can no longer be tested on this account with Playport's Steam client. It needs a licence
for app 70 (or the emulated Steam API mode, which makes up its own ownership). For a person, the
game closes with no message: [PLA-443](https://linear.app/playportdev/issue/PLA-443).
