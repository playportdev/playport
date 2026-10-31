# Portal 2 loads a map again: i386 steamclient serves GetFriendPersonaName and InitiateGameConnection

**Linear:** PLA-596 (found in PLA-538)

Dev IPA `9114e1eb786754e2a392d4ba8d05f620f3e62584390e63e8ffeec2a15c77f16a` (branch
`dev/pla-596-portal-2-crashes-0xc0000417-loading-a-map-playports-i386`, main `3fb12ccb` plus the fix).
Runs under `$PLAYPORT_BUILD/agent-notes/pla-596/`.

## Before

Portal 2 (app-620, i386) with `+map sp_a1_intro3` crashed `0xc0000417` ~20 s after launch, right after
`ISteamFriends017 GetFriendPersonaName() -> 0 (not served)`: the game hands the NULL name to a CRT
string function (dev IPA `6f177007…`, PLA-538 runs).

## Steps

1. `GetFriendPersonaName` served (own SteamID: the persona; any other: `""`). Run `p2-map2`, IPA
   `78915511…`: no crash, `GetFriendPersonaName() -> len=4`; the map then stops at "Disconnected —
   STEAM certificate length error! 0/2048", after `ISteamUser021 InitiateGameConnection() -> 0 (not served)`.
   The Source client refuses its own listen server without that blob.
2. `InitiateGameConnection` served with an auth session ticket (the decision 0062 broker), only in the
   7-word signature (ISteamUser010 on; 004–009 take other arguments); `TerminateGameConnection` cancels it.
   Run `p2-map3`, IPA `9114e1eb…`: `auth session ticket …: 234 bytes`,
   `InitiateGameConnection() -> 234`; at 90 s the screenshot shows the player in the level (no menu,
   no dialog), no crash.
3. Hollow Knight (`hk`, same IPA): first frame at +10.14 s, first-frame+10 reached.

Not checked: gameplay in the level beyond the 90 s screenshot, other i386 Source titles.
