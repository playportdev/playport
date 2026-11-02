# Xbox pilot: a black screen until the runtime finds its own module

**Linear:** [PLA-499](https://linear.app/playportdev/issue/PLA-499) (Hollow Knight: Voidheart Edition,
Xbox `9MW9469V91LM`), spec [PLA-485](https://linear.app/playportdev/issue/PLA-485).

## The fault

The Xbox copy installed and started (dev IPA `74eb84d505822752f37e10d68d256178cdbc36e8116d57d5526bc389e70bde16`),
presented at 60 FPS and drew only black. Unity's `Player.log` named the wait:

```
Selected online subsystem GameCoreOnlineSubsystem
Loaded Blob : "sharedData" : "sharedData.dat" failed. No user detected.
```

The bridge listened for the play and no connection came. A play with
`XGAMERUNTIME_LOG_LEVEL=trace` and `XGAMERUNTIME_LOG_FILE` (the game page's environment row)
showed the runtime's first task queue failing:

```
WaitTimer.cpp::Initialize Returning HR 0x8007007e
XTaskQueue.cpp::XTaskQueueCreate Returning HR 0x8007007e
```

`WaitTimer::Initialize` names its callback's module with `GetModuleHandleExW(FROM_ADDRESS)` for
`SetThreadpoolCallbackLibrary`. On iOS a builtin's code runs from its JIT-pool copy, so the
callback's address lies in the copy, and `LdrFindEntryForAddress` found no module there:
`ERROR_MOD_NOT_FOUND`. With no task queue, `XUserAddAsync` never ran its sign-in, and the game
waited for a user.

## The fix

`patches/wine-pe/0064`: `LdrFindEntryForAddress` retries a miss with `xlate_ios_jit_rev`, which
turns an address in a pool copy into its PE address and leaves any other address alone.

## Result

Dev IPA `a17d1ad72981b8ed5b4c9b1d9975cc00c5fd6399aa7e42040e35c8039c3d0082`, branch
`dev/pla-485-xbox-store`:

- **Xbox copy:** first frame at +8.91 s, then the title menu at 60 FPS through first frame +40,
  with the account's Xbox profile shown in the corner. The runtime's trace has no failed
  `Returning HR`; the bridge served one `MSA_TOKEN_REQUEST`, as the ground truth's runtime made
  ([2026-10-30-xbox-ground-truth-nexus.md](2026-10-30-xbox-ground-truth-nexus.md)). Run:
  `.work/ui-runs/20261102T231621`.
- **Steam copy (367520), the runtime gate:** first frame, title menu at 60 FPS through first
  frame +10. Run: `.work/ui-runs/20261102T231810`.

Not checked: gameplay past the menu, cloud saves (PLA-500).
