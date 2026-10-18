# Every Steam call of the Rockstar launcher before its HLT (PLA-401)

**Linear:** https://linear.app/playportdev/issue/PLA-401.
**Change:** commit `232b14f`.
- **Dev builds only:** Playport's `steamclient64.dll` traces every call when HELLO's `trace` is 1. Only a dev app's `SteamClientHost` sets it (`#if !PLAYPORT_RELEASE`).
- **What it logs:** `app/SteamClientShim/steamclient_trace.h`.
  - Each method's first 30 calls, then changed results only.
  - A summary of call counts every 250 ms.
  - No SteamIDs, names, ticket bytes or tokens.
- **Test:** `app/tests/steamclient_trace_test.c`.
- **Release:** the unsigned release build passed its 87 checks, with the same steamclient record.

**Desktop check of the wrappers:** a `.work` copy with tracing forced on, under desktop Wine 11.19, with the launcher's own `steam_api64.dll` and the earlier probe. `SteamAPI_Init` succeeded and every call was traced.

## Phone round (IPA `d49d72d99dad809a3341a5801f0798d4d2b4a09c832a79cc9b940d42dfb23d5c`)

One hold of the lock. Battery went from 63% to 68% while charging; free space went from 6.1 to 5.4 GB.

| Run | Result |
| --- | --- |
| `20261018T220352` Hollow Knight | first frame +9.45 s, first-frame+10 reached. It runs in emulated mode, so no trace |
| `20261018T220445` | RDR2 settings cleared for this session only |
| `20261018T220514` RDR2 | 282 trace lines; the fault recurs |

## What the launcher asks Steam

Times are from the shim's first use, which is `SteamAPI_Init`, about 10 ms after the launcher logs "Creating Steam min mode launch". Every call is on the launcher's main thread, `0x54`, which is also the thread that faults.

1. **+2 to +11 ms: `SteamAPI_Init` and its first questions.**
   - `CreateSteamPipe`, `ConnectToGlobalUser`.
   - Interfaces: SteamUtils010, SteamUser022 (twice), SteamFriends017, `STEAMAPPS_INTERFACE_VERSION008`, UserStats012 (a stub) and SteamController008 (a stub).
   - `GetAppID` 1174180, `GetSteamID` set, `BLoggedOn` 1.
   - `BIsSubscribedFromFamilySharing` 0, `IsSteamRunningOnSteamDeck` 0, `GetAppOwner` set, `GetPersonaName` (a non-empty name).
   - One `GetAuthSessionTicket`.
   - `GetCurrentGameLanguage` "english", `GetAvailableGameLanguages` "english", `GetSteamUILanguage` "english".
2. **+11 ms to +20.79 s: no Steam call at all.**
3. **+20.79 s: the first `SteamAPI_RunCallbacks`.**
   - It hands out the one callback ever made, 163 (`GetAuthSessionTicketResponse_t`).
   - From then on, about 60 times a second, it calls `ISteamUtils010::RunFrame`, SteamInput006 slot 3 and SteamController008 slot 2 (both `RunFrame` stubs), and `Steam_BGetCallback`, which answers 0.
4. **No other method is called** in the rest of the run:
   - no further ticket;
   - no `RequestEncryptedAppTicket`;
   - no call result, `IsAPICallCompleted` or `GetAPICallResult`;
   - no `BIsSubscribedApp`, `BIsDlcInstalled` or `GetAppInstallDir`;
   - no UserStats method.

   A method's first 30 calls are always lines of their own, so any first call would show.
5. **The last trace line is a 250 ms summary at +54.58 s:** 15 of each of the four `RunCallbacks` calls.
   - The launcher's Auth → MainWindow comes at about +54.90 s, `Active` at +55.04 s and the HLT at +55.31 s.
   - A summary is due at the first call 250 ms after the previous one, and none came. So the main thread made **no Steam call at all** from somewhere between +54.58 and +54.83 s until the fault. That is the half-second in which it builds its main window.
- **The fault itself:** launcher `Exception: 0xc0000096`, hash `0xCC1B2291`. The host log has the same `[generated-fault] producer=INTOp` at Launcher.exe RVA `0x258cf6`.
- **Pool:** head 515 MiB, tail 353 MiB, room 29 MiB, `head_exhausted` 0. Band peak 13,828 MiB, 0 refused.

## Answers that differ from a real Steam client (public SDK)

- **`GetAvailableGameLanguages` answers only the current language.** A real client gives the comma-separated list of the app's languages. Called once, at +11 ms.
- **`GetIPCountry` would answer `""`.** It was not called.
- **No callbacks beyond the ticket's (163).** A real client also posts others, such as persona and server-connection changes. The launcher registers for whichever it needs; nothing shows it waiting on one.
- **Slot-table observation.** The launcher asked for `SteamController008` through `ISteamClient017` slot 26, which the pinned headers call `GetISteamUGC`; 25 is `GetISteamController`. So its 017 vtable puts that method one slot later. It made no difference here: the shim routes every `GetISteam*` slot by the version string it is given. But a non-`GetISteam` method of 017 after slot 15 could be mis-slotted. The launcher calls none.

## Reading

Steam's answers are not what precedes the HLT. The last Steam activity is the ordinary callback pump, which stops when the main thread starts building its main window, about half a second before the fault. In that window the launcher asks Steam nothing, and no call or callback is outstanding.
