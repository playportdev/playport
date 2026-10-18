# RDR2 Story with the Rockstar Games Launcher, measured during play (desktop Proton)

**Linear:** [PLA-291](https://linear.app/playportdev/issue/PLA-291) (Stage R, in-game phase), plan
[launchers](../plans/2026-10-12-launchers.md) (Progress (Rockstar track)). Date 2026-10-15.

**Setup**

- **Game:** RDR2 (Steam 1174180, build 13773296), Story mode, prologue.
- **Who:** started and played by the owner from the owner's own Steam client, under Proton
  Experimental on the workstation's desktop. The owner signed in to Rockstar in person.
- **Observation:** a read-only observer took `/proc` and `ss` snapshots every 10 s (203 snapshots,
  23:00–23:34) and read the launcher and Social Club logs. It took no screenshots, sent no input
  and wrote nothing into the prefix.
- **Ending processes:** done by PID with the owner's approval, after a save.
- **Not covered:** the launcher start, the loading and the main menu. They are reconstructed from
  the logs only, because the observer's poll did not fire.
- **Raw data:** `$PLAYPORT_BUILD/agent-notes/pla254-rockstar/ingame/` (`report.md`, `snaps.jsonl`,
  `deptest.log`).

Marks: [M] measured, [O] seen by the owner, [I] inferred.

## Start-up [M, logs]

1. `PlayRDR2.exe` starts `Launcher.exe -skipPatcherCheck -steamAppId=1174180` (no
   LauncherPatcher in Steam mode).
2. `RockstarService` and the CEF browser start.
3. The owner signs in. "Begin game launch: rdr2" follows, with a cloud-save sync.
4. RDR2.exe starts about 10 s later with `-fromRGL -useSteam`.
5. The game's `socialclub.dll` gets its ticket from the launcher over `rgsc_gameinst_0` and signs
   in online.

## Cost during play, 610 s of Story [M]

| | Processes | Threads | PSS | CPU (one core = 100%) |
| --- | ---: | ---: | ---: | ---: |
| Launcher side (Launcher.exe, service, error handler, CEF browser, gpu, 4 utilities, 2 renderers) | 11 | 319 | 3.5 GiB | 20% |
| RDR2.exe | 1 | 120 | 3.2 GiB | 250% |
| Wine, Proton and the Steam stub | 17 | 114 | 0.4 GiB | 5% |

**Flat cost, no hibernation.** The launcher side does not shrink during play. Its UI renderer and
GPU process keep rendering, about 16% of a core, while the game runs, and no renderer exits.

**The overlay runs in the launcher's CEF.** The game loads `socialclub.dll` and
`SocialClubVulkanLayer.dll`, but not libcef. Its Social Club overlay is a renderer of the
launcher's CEF.

**libcef is copied into every CEF process.** Each holds about 239 MiB of private memory for
`libcef.dll`: Wine's private copy of a 0x200-aligned image. That is about 1.9 GiB of the
launcher side.

**Traffic between the game and the launcher during play** [M, logs]:

- the ticket hand-off and refresh (`ExchangeTitleAccessToken` at each game sign-in);
- presence relayed for the game (`SetRichPresence`, once a minute);
- stats (`SubmitUpdate`, every 5 min);
- telemetry.

It is low-rate, and the launcher's CPU does not follow the game's load.

## Ending launcher processes one at a time, 60 s each [M, O]

| # | Ended | Result |
| --- | --- | --- |
| 1 | the game's overlay renderer | respawned at once. The game's Social Club signed in again. [O] About 40 s later the game showed its own "exit to desktop?" prompt with no key pressed (the owner chose No; the cause is not logged). |
| 2 | the launcher UI renderer | respawned, along with the GPU process. [O] The launcher window came to the front, full screen: "A game is currently running… EXIT". |
| 3 | audio, video-capture, storage and network utilities | each respawned |
| 4 | the GPU process | respawned |
| 5 | the CEF browser | `Launcher.exe` restarted the whole tree in 0.5 s, and the full-screen window came back [O] |
| 6 | RockstarErrorHandler | not restarted |
| 7 | RockstarService | restarted through the SCM in 1 s |
| 8 | Launcher.exe | not restarted, and the service exited by itself about 22 s later |

RDR2 kept running through every step.

**After step 8, the game runs without the launcher.**

- Its `socialclub.dll` logged "IPC system failed to connect to launcher, loading UI".
- It started **its own** CEF tree (browser, gpu, network, storage and one renderer), then signed
  in online again with the ticket it already held.
- RDR2 ran on for at least 6.5 minutes with no launcher process.
- The game-owned CEF uses 5 processes, 150 threads and 2.1 GiB PSS (1.2 GiB of it libcef copies),
  at 0.5% CPU.

**Saving without the launcher works.** At 23:44, about 17 minutes after step 8, the owner saved
once the prologue was over [O]. With no launcher process alive, the game wrote its save slots
(`SRDR30000`, `SRDR30015`, their `.bak` copies, `Player` and `cloudsavedata.dat`) [M, file
times]. The game's `socialclub.log` logged "Cloud file registered" for the save files after the
launcher was gone, with no sign-out or offline line [M].

**An hour without the launcher** [M, 00:29]: RDR2 was still running 62 minutes after
`Launcher.exe` was ended, with only the game's own Social Club CEF browser left. The game kept
autosaving about every 5 minutes. The last save was at 00:24:52: `SRDR30015`, its `.bak` and
`cloudsavedata.dat`. The game's `socialclub.log` logged "Cloud file registered" for each save. It
logged no sign-out, offline, ticket or error line after the 23:27 sign-in. No ticket refresh was
logged in that hour either, so whether a refresh would succeed without the launcher is not shown.

**Not determined:**

- the ticket refresh without the launcher (none was attempted in 62 minutes);
- whether cloud saves reach Rockstar's servers (only their local registration is logged);
- achievements and presence without the launcher.

## What it means for Playport

- **The launcher is needed to start the game, not to keep it running.** The full launcher, about
  3.5 GiB and 319 threads, does not fit beside RDR2 on the phone [I]. Ending it after the game's
  Social Club has signed in leaves one game-owned CEF, about 2.1 GiB on desktop.
- **Suspension is dropped.** The owner's rule allowed suspending the launcher only if no traffic
  runs between the game and the launcher during play, and some does (ticket, presence).
- **The phone's floor depends on the libcef copies.** Mapping one shared copy of libcef instead of
  a private one per process would cut about 1.2 GiB from the game-owned tree (PLA-274) [I].
- **The launcher window is a hazard on the phone.** It returns full screen whenever its UI
  rebuilds, so it would cover the game. "First present = first frame" (R3a) does not hold while the
  launcher lives [I].
- **FEX band.** The thread count is about 550 guest threads with the launcher in play, and about
  380 without it [M]. Both may exceed the 16 GB band at the chunk-1 rate per thread [I]; to be
  measured on the phone.
