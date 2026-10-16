**Linear:** [PLA-254](https://linear.app/playportdev/issue/PLA-254) (part 1 of 2: publisher
launchers in general; part 2, Red Dead Redemption 2, is [the RDR2 plan](2026-10-12-rdr2.md)).

# Plan: publisher launchers (Rockstar Games Launcher, Ubisoft Connect, EA app, Battle.net)

**Date:** 2026-10-12. **Kind:** design and execution plan, decided, not started. **Review
2026-10-13:** the owner took D1–D10 as recommended (74c7c52); the answers are under
[Owner decisions](#owner-decisions). Next: Stage 0, with its workstation reconnaissance (Stage R,
PLA-291) first. Until a launcher works, the Steam client bridge's D10 refuses its Steam and Epic
copies with a message ([PLA-266](https://linear.app/playportdev/issue/PLA-266)); see
[Where a launcher lives in the UI](#where-a-launcher-lives-in-the-ui). **Repository path:** `docs/plans/2026-10-12-launchers.md`. Scratch for this
plan: `$PLAYPORT_BUILD/agent-notes/pla254/`.

## Progress (Rockstar track)

**Owner, 2026-10-15:** work the Rockstar Games Launcher alone first (Stages R, 0, 1, 2 for
Rockstar only; Ubisoft, EA and Battle.net wait). Run with the plan-runner skill: hard tasks
`anthropic/claude-opus-5-5` (medium), easy tasks `anthropic/claude-sonnet-5-5` (medium).
Branch `dev/pla-291-rockstar-launcher` from `main` `f7ac25f`, not merged. Reports and scratch:
`$PLAYPORT_BUILD/agent-notes/pla254-rockstar/` (`reports/`, `inputs/`).

- **Why now:** RDR2's Steam copy (installed on the phone, about 120 GB) stops at its
  bootstrapper `PlayRDR2.exe` with "File not found." because no Rockstar Games Launcher is
  installed ([PLA-364](https://linear.app/playportdev/issue/PLA-364), run
  `$PLAYPORT_BUILD/ui-runs/20261015T210227`).
- **Done:** chunk 1 (subagent run `4209acb9`), Stage R for Rockstar only, launcher alone
  ([PLA-291](https://linear.app/playportdev/issue/PLA-291)), host only, no phone;
  [evidence](../evidence/2026-10-15-rockstar-launcher-recon.md). The in-game phase is not run: it
  needs the owner's sign-in, and a Steam client for the launcher (below). In parallel, read-only
  research run `82cea138`: routes that avoid running the whole launcher during play (a host-side
  bridge to Rockstar's services, a minimal genuine launcher, the launcher's heap on the donor
  pool), report `reports/research-alternatives.md`. **Done 2026-10-15:** no legitimate route avoids
  the genuine launcher. A Rockstar bridge (the Steam-bridge model) is rejected: no public SDK seam,
  ROS is encrypted with keys in Rockstar's binaries, sign-in is behind a captcha, the EULA ends the
  licence for interfering with access controls, and even Rockstar's own Cfx.re requires the running
  RGL (decision 0004). The target becomes a *minimal-footprint genuine launcher*: hidden,
  "Hibernate while game is running" on, offline after one sign-in (RGL adds `-scOfflineOnly`),
  `PlayRDR2.exe -skipInstallers` after the first install, R1's Chromium switches on
  `SocialClubHelper.exe` (the CEF host, Chromium 143 per Rockstar's notes; to confirm), and its
  heaps on the donor pool (PLA-216). Stages 0–2 stay; their subject is one or two idle CEF
  instances at play time, not a launcher in use. Suspending the launcher during play is measured
  only after a policy ruling. Questions 1–10 of the report went to the Stage R writer.
- **Owner, 2026-10-15:** (1) RDR2 is downloaded in the owner's desktop Steam on the workstation, so
  Stage R gets an in-game phase under desktop Proton (which launcher processes stay alive during
  Story play, their cost, ending each to see dependency); the one online Rockstar sign-in is the
  owner's, in person. (2) Suspending the launcher during play is measured only if that phase shows
  no traffic between the game and the launcher during play; otherwise it is dropped.
- **Found 2026-10-15:** the phone's "File not found." is Playport's Steam installer skipping
  RDR2's depot 1899671 (shared install from app 1899670, 240 MB), which desktop Steam installs into
  the game's folder: `Redistributables/Rockstar-Games-Launcher.exe`, `Social-Club-Setup.exe` and
  `installscript_sdk.vdf` (`Social-Club-Setup.exe /silent`, which is silent, and
  `Rockstar-Games-Launcher.exe /s /t`, which is not: it shows language, Terms of Service and
  location pages to click through; Stage R). So a Steam copy gets the genuine installers
  from Steam itself, with no publisher-URL download.
  [PLA-365](https://linear.app/playportdev/issue/PLA-365) (blocks PLA-364) goes in the queue
  before Stage 1's Install step.
- **Stage R's results (chunk 1), and what they change:**
  - **No cheaper route.** The service is required before the sign-in page, so R4/D5 applies to
    Rockstar from Stage 0.
  - **`--single-process` breaks the UI.** So does a single renderer, because Rockstar's IPC wants
    one renderer per page.
  - **The working minimum** is `--in-process-gpu --disable-gpu --disable-gpu-compositing
    --js-flags=--jitless`: 8 CEF processes (browser, network, storage, audio, video capture, three
    renderers), about 4.0 GiB PSS and about 285 threads under desktop Wine. That is far above
    R2's estimate. About 285 threads × about 50 MB is beyond the 16 GB FEX band (an inference,
    to measure in Stage 0).
  - **The UI is drawn through D3D11.** CEF renders off-screen and `Launcher.exe` presents with
    D3D11, so R3's "GDI first" does not apply to Rockstar.
  - **Steam mode needs a Steam client.** `PlayRDR2.exe` starts the launcher with
    `-steamAppId`, and the launcher then calls `SteamAPI_Init` before its sign-in page. So Stage 0
    and Stage 1 start `Launcher.exe` standalone, and Stage 2 needs the Steam client bridge
    ([PLA-253](https://linear.app/playportdev/issue/PLA-253)) or the emulator in the launcher's
    `ThirdParty\Steam` folder (Rockstar's entitlement check against it is untested).
  - There is no "Hibernate while game is running" setting string in this build; there is an
    internal UI hibernation in Social Club.
  - The installer and `Social-Club-Setup.exe` are the same bytes from Steam and from Rockstar.
- **In-game phase done (observer run `319b1952`, 2026-10-15):**
  [evidence](../evidence/2026-10-15-rdr2-launcher-in-game.md).
  - **Cost during play:** the full launcher costs 11 processes, 319 threads and 3.5 GiB PSS during
    Story. It does not hibernate, and the game's overlay is a renderer of its CEF.
  - **The game runs on without it:** once `Launcher.exe` is ended, RDR2 keeps running (at least
    6.5 min). It hosts its own Social Club CEF (5 processes, 150 threads, 2.1 GiB, of which
    1.2 GiB is libcef private copies) and signs in with the ticket it already holds.
  - **Suspension is dropped:** traffic runs between the game and the launcher during play
    (ticket, presence).
  - **Saving works without the launcher** (23:44, 17 min after it was ended; save files and Social
    Club cloud registration). RDR2 ran **62 minutes** without the launcher, autosaving every 5 min, with no sign-out; no
    ticket refresh was attempted in that time.
  - **Owner, 2026-10-16: (b) close the launcher after hand-off.** Every play starts through the
    genuine launcher and its genuine sign-in. Once the game's Social Club logs "Signed in online",
    Playport closes the launcher, and the game keeps its own Social Club CEF. This needs a
    decision record (Stage 2, with PLA-295). It takes the place of "hidden and hibernating"
    during play, and of suspension (dropped).
- **Chunk 2 ended 2026-10-16 after steps 1–2** (writer run `7179aee9`, stopped for context;
  commits `f71f15a`, `9a381ca`, `df5d1d5`; report `reports/chunk2-stage0.md`).
- **Chunk 3 ended 2026-10-16 after steps 2–3** (writer run `8c1186ac`, stopped at half its context;
  report `reports/chunk3-stage0.md`). **Next: a fresh writer for steps 5, 4, 6, 7, in that order**
  (the supervisor's order: Open first, so CEF can start without Steam mode).
- **Chunk 4 stopped 2026-10-16** (writer run `25d06b24`, owner away; report
  `reports/chunk4-stage0.md`). Step 5 is done and step 4 is in place, not yet exercised. Run
  `20261016T014751` stopped the chunk. The standalone launcher's first self-update (141.68 MB left)
  runs through Rockstar Service, and the service is far too slow under FEX: 1.79 million guest
  `c0000005` exceptions and 3.45 million `NtProtectVirtualMemory` calls in about 950 s, from a
  write-then-reprotect loop on its own code. The update fails (code 242). The 896 MiB pool runs out
  (`exhausted=head`) with 10 children and no CEF process. So steps 6 and 7 did not start.
  **Next:** the follow-up on the service's per-fault cost (madeira's NtProtect-sync scan, the ERR
  lines per call, the guest exception path) and on FEX re-translating its code, which looks like the
  tail's 128 MiB steps. Then Open again, so the update finishes and CEF starts (steps 4's
  measurements, 6, 7).
- **Chunk 5 stopped 2026-10-16** (writer run `9f45b045`, [PLA-366](https://linear.app/playportdev/issue/PLA-366),
  owner away; report `reports/chunk5-pla366.md`; commit `1fdc552`, IPA `60611f78`). The loop is
  FEX's self-modifying-code tracking, not the guest's VirtualProtect: each write to the
  protected code faults, FEX invalidates the 16 KiB host page (resetting the thread's call-return
  stack), untraps it, recompiles a block from that page and traps it again. The writes cycle over
  the same 0x144390000–0x1443C8000 range for ever (a decrypt-and-re-encrypt protector), and
  Launcher.exe and the service's helper process do the same at a smaller rate. The per-call log
  lines are now sampled (log 1.5 GB → 26 MB for a 5-minute Open), but the rate stayed about
  2,000 writes a second, the self-update still stalls after "Updating launcher...", and the
  pool ends with 15 MiB of room. Per process, the service and the second Launcher.exe each hold
  272 MiB of tail (bounded: later carves are reused). Steps 4's measurements, 6 and 7 did not
  start. **Next:** a FEX change so these writes stop faulting: a host page that takes many
  self-modifying writes is compiled with code checks (FullSMC) and left writable, after fixing
  PLA-206's x86-64 FullSMC deadlock; or, as an owner decision, `SMCChecks` off for
  `RockstarService.exe` and `Launcher.exe` through FEX's per-executable AppConfig (cheap, but
  stale code if the protector ever writes different code). Then Open again.
- **Owner decisions, 2026-10-16:** [PLA-369](https://linear.app/playportdev/issue/PLA-369): research route 1 (a larger or separate address window for CEF processes) and route 3 (sign-in shown another way); no in-memory patching of Chromium. [PLA-367](https://linear.app/playportdev/issue/PLA-367): the proper FEX fix first (PLA-206's deadlock, then FullSMC for hot pages); no per-executable `SMCChecks=none`. [PLA-368](https://linear.app/playportdev/issue/PLA-368): the next chunk. **Chunk 10 done:** madeira-unix 0154 releases an exited child's private and image views (about 300 MB per Rockstar CEF helper); the footprint now climbs about 36 MB per helper, not about 260 MB ([evidence](../evidence/2026-10-15-rockstar-stage0-phone.md#chunk-10-an-exited-childs-views-are-released-pla-368)). Next: what the 142 MB of kept views per helper are, and a regression play of a title whose children worked. **Running now:** the PLA-369 research (read-only).
- **Stopped: chunk 9 (run `4e17ac0e`), waiting on the owner's architecture call ([PLA-369](https://linear.app/playportdev/issue/PLA-369), [PLA-368](https://linear.app/playportdev/issue/PLA-368)).** Host analysis only, no phone run ([evidence](../evidence/2026-10-15-rockstar-stage0-phone.md#chunk-9-why-cefs-browser-dies-and-why-crashed-helpers-cost-memory-pla-369-pla-368-stopped-for-the-owner)).
  - **PLA-369.** CEF's browser dies in chrome_elf's DLL init. The trap at + `0x13A535` is PartitionAlloc's `HandlePoolAllocFailureOutOfVASpace`: its 32 GiB, 32 GiB-aligned pool reservation fails (`ERROR_NOT_ENOUGH_MEMORY`). All pseudo-processes share one 64 GB window, which holds FEX's band and the JIT pool, so no such slot exists. Every Chromium process needs one. No setting or switch changes this.
  - **PLA-368.** The helpers did end, 17 times with `0x80000003`. Their memory stays: an exited x86-64 child's views (a 251 MB libcef image each) are never deleted, because views record no owner. The evidence has the fix as an issue-ready design: per-view owner, released at the last thread's reclamation.
  - **Owner to decide:**
    - PLA-369's route: (1) keep a 32 GiB slot free, which fits one Chromium process at most and does not make CEF work; (2) patch PartitionAlloc's pool size in memory, which touches thousands of sites and Rockstar's code at run time and needs a policy; (3) host CEF another way, or avoid the UI.
    - Whether to schedule PLA-368's owner teardown.
    - PLA-367's permanent route, still open.
  - **Next step:** the owner's PLA-369 choice. Until then, an Open repeats chunk 8.
- **Chunk 8 (run `ef661d2e`): services get the launch's FEX variables, and the launcher reaches CEF ([PLA-367](https://linear.app/playportdev/issue/PLA-367)).**
  wine-pe 0045 now copies `FEX_*` too (`7213e77`), so a service runs with the launch's FEX profile
  and runtime keys. Open with `env.FEX_SMCCHECKS=none` (run `20261016T040029`, IPA `243d9b4b…`):
  - Rockstar Service ran unchecked: no write faults, and every one of 28 processes had a 16 MiB tail.
  - The self-update no longer blocked ("No self-update, continuing").
  - SocialClubHelper started 18 times. Each time CEF's browser process raised `c000001d` at
    chrome_elf.dll + 0x13A535.
  - The launcher logged `SC_INIT_ERR_WEBSITE_FAILED_LOAD`.
  - The crashed helpers stayed. Their footprint reached about 8 GB, and the app ended at about +143 s,
    likely a memory kill.
  - The 896 MiB pool kept 422 MiB of room.
  An earlier Open in the same session (run `20261016T033304`) stalled before its first window, with no
  launcher log; the cause is unknown
  ([evidence](../evidence/2026-10-15-rockstar-stage0-phone.md#chunk-8-services-get-the-launchs-fex-variables-the-launcher-reaches-cef-pla-367)).
  **Next:** find what chrome_elf.dll + 0x13A535 is: disassemble the shipped chrome_elf.dll on the
  workstation, likely Chromium's deliberate crash after a failed check. Then reproduce
  SocialClubHelper's start under desktop Wine to see which check fails. Separately, a crashed
  helper should not stay alive (file it). The owner still chooses PLA-367's permanent route; the
  `none` key works for the diagnostic only.
- **Chunk 7 (run `eaecb8d6`): the SMC diagnostic, [PLA-367](https://linear.app/playportdev/issue/PLA-367).**
  A dev build's Open now takes `launcher-rockstar`'s saved runtime keys and FEX inputs (PLA-271
  gap, `fe39ed5`, `07acf11`). With `env.FEX_SMCCHECKS=none`, Launcher.exe and the service's helper
  stopped faulting and their JIT tails fell from 144–272 MiB to 16 MiB each; the pool kept 319 MiB
  of room (chunk 5: 15 MiB). Rockstar Service did not get the variable: services.exe builds a
  service's environment afresh, and wine-pe 0045 copies only `WINE_IOS_*` and `MADEIRA_*` into it.
  So the service still looped (1.5 million write faults, 256 MiB tail), and the self-update stopped
  at "Applying downloaded self-update..." with the splash up for 600 s
  ([evidence](../evidence/2026-10-15-rockstar-stage0-phone.md#chunk-7-open-with-fexs-self-modifying-code-checks-off-pla-271-pla-367)).
  `full` was not run: it would not reach the service either. **Next:** the owner chooses PLA-367's
  route. Option 2 (`SMCChecks` off per executable, FEX AppConfig for `RockstarService.exe` and
  `Launcher.exe`) reaches the service without the environment; option 1 (FullSMC for hot pages)
  needs PLA-206 first. The diagnostic itself can finish with one small dev change, `FEX_` added to
  wine-pe 0045's copied prefixes, so a service gets the launch's FEX variables (the profile's too),
  then one more Open. The pool question waits on that run: with every process unchecked the tails
  suggest 896 MiB is enough; if the service keeps 256 MiB, it stays tight once CEF starts.
- **Chunk 2: Stage 0 on the phone.** Subject: the Rockstar installer, then the
  standalone launcher to its sign-in page. No game and no sign-in. The work below is in order;
  each step passes Hollow Knight's smoke play.
  1. [PLA-365](https://linear.app/playportdev/issue/PLA-365): install depot 1899671 and run
     `installscript_sdk.vdf` as prerequisites with the launch screen. The installer's pages are
     GDI windows, which 0075's layer shows and touch can press. **Done 2026-10-15** (depot rule,
     Repair adds the depot: 235.6 MB downloaded; both scripts run; the owner pressed through the
     pages; [evidence](../evidence/2026-10-15-rockstar-stage0-phone.md)). The launcher is now
     installed in the phone's prefix, with its `InstallFolder` key and the `Rockstar Service`
     entry.
  2. [PLA-275](https://linear.app/playportdev/issue/PLA-275): `services.exe` and `rpcss` for a
     play flagged as needing them (D5). This is required for Rockstar, not optional. The flag
     covers `RockstarService.exe` and COM over rpcss. **In place 2026-10-16**
     ([decision 0107](../decisions/0107-windows-services-for-a-flagged-play.md); madeira-unix 0151
     stops the storm breaker ending the service's self-modifying loop; wine-unix 0038 fixes a job
     termination that crashed the app; the profile's Desktop and Start Menu folders). **Done
     2026-10-16** (chunk 3): `[service] Rockstar Service: running`. The `0xC0000001` was
     services.exe's environment block dropping `WINE_IOS_JIT_RX/RW` (wine-pe 0045); then the
     service needed a 2-minute SCM start timeout and the play an 896 MiB JIT pool
     ([decision 0108](../decisions/0108-a-launchers-jit-pool-and-service-start-timeout.md)).
  3. [PLA-292](https://linear.app/playportdev/issue/PLA-292) and
     [PLA-314](https://linear.app/playportdev/issue/PLA-314): fault containment for child
     pseudo-processes (renderers, crashpad). **Checked 2026-10-16:** wine-unix 0038 holds on a
     forced close of a two-process job, and the services stop with the title. Containment today
     covers a guest's unhandled exception, an exited child's thread (0118) and a child's fault
     storm (0119, 0151); the other fatal host-fault paths still end the app. **Open:** the
     general case, and a renderer killed on purpose once CEF runs (step 5 or 4).
  4. [PLA-277](https://linear.app/playportdev/issue/PLA-277): the Chromium policy, with
     Rockstar's set (`--in-process-gpu`, `--disable-gpu`, `--disable-gpu-compositing`,
     `--js-flags=--jitless`), applied to `SocialClubHelper.exe` (detected by `libcef.dll` next to
     it). It leaves out `--single-process`, lets the three renderers start, and logs
     `[chromium]`. The decision record states that the fallback is the default for this launcher. **In place 2026-10-16** (madeira-unix 0152, [decision 0109](../decisions/0109-chromium-switches-for-a-cef-browser.md)),
     not yet exercised: the standalone launcher first self-updates through a very slow Rockstar
     Service, and no CEF process started in 5 minutes (run `20261016T013646`).
  5. [PLA-271](https://linear.app/playportdev/issue/PLA-271), minimal: Settings › Launchers with
     an Open row that starts `Launcher.exe` standalone, and the driver action for it. Install
     comes from step 1. **Done 2026-10-16** (chunk 4, run `20261016T012523`): Settings ›
     Launchers lists the launcher from PlayportKit's `PublisherLauncher` table, **dev builds only
     until a launcher passes Stage 1** (supervisor, 2026-10-16), "Not installed" without
     `InstallFolder` or its `Launcher.exe`; Open (driver `open-launcher:rockstar`) starts it
     standalone with services, 896 MiB and Vulkan, and reaches its splash. The Open play sets `windowsServices` (0107) and a JIT pool of
     896 MiB (0108); the launcher is in the prefix at `InstallFolder`. In Steam mode the launcher
     reaches a 940×318 dark dialog with no text (run `20261016T010049`); standalone it should go on
     to `SocialClubHelper.exe`.
  6. The launcher's D3D11 present on the Vulkan backend (decision 0100), with sane DXGI adapter
     data. On a display without a GPU, the launcher divided by zero while reading D3D11 device
     information. In a launcher-only session, the launcher's present stands for the first frame;
     [PLA-273](https://linear.app/playportdev/issue/PLA-273) waits for Stage 2.
  7. [PLA-274](https://linear.app/playportdev/issue/PLA-274): pool, band, VA and footprint for
     about 13 processes and about 300 threads, then Stage 0's acceptance. If the band or the
     footprint is short, it stops there for a decision.

  Not in chunk 2: [PLA-267](https://linear.app/playportdev/issue/PLA-267),
  [PLA-293](https://linear.app/playportdev/issue/PLA-293),
  [PLA-278](https://linear.app/playportdev/issue/PLA-278) (Stage 1, sign-in),
  [PLA-294](https://linear.app/playportdev/issue/PLA-294) and
  [PLA-295](https://linear.app/playportdev/issue/PLA-295) (Stage 2; PLA-295 also depends on
  PLA-253), PLA-273 (until a game runs beside the launcher), and PLA-213 (done).
- **Queue:** steps 4–7 above (fresh writer) → Stage 1 (PLA-271, 267, 293, 273, 278) → Stage 2 (PLA-294, 295,
  PLA-253; RDR2 per [the RDR2 plan](2026-10-12-rdr2.md)).
- **Phone:** dev IPA `1102672b` installed. RDR2 (with depot 1899671), Hollow Knight and Steamworks
  Shared are installed, and the Rockstar launcher is installed in the prefix, part-updated (its
  self-update failed). There is 1.2 GB free, because the last two runs' host logs hold 4.6 GB.
  The next `pp ui` run rotates them and drops the older one.

## Goal

The owner's goal (2026-10-12): Playport runs publisher launchers, and through them the games that
need them. Red Dead Redemption 2 (Rockstar Games Launcher with Social Club) is the first goal. The
same machinery should serve Ubisoft Connect, the EA app and Battle.net, and the Steam and Epic
copies of games that start one of them.

**Done, for the whole plan,** when:

- a person installs a launcher, signs in to it and signs out of it, all in Playport's UI, by touch
  or controller (decision 0012);
- the launcher shows and is usable on the phone, and a crash in one of its helper processes does
  not end the app;
- a Steam or Epic copy of a game that needs that launcher reaches `first-frame+10` from Play, with
  the launcher signed in by itself (no host secret crosses; decision 0004);
- this holds for each of the four launchers, or the launcher's compatibility issue says why not.

This plan does not cover games bought in a launcher's own store (out of scope, owner decision
D7) or games
with kernel or launcher anti-cheat (refused as today, 0059).

## Where things stand (the tree at 2026-10-12)

- **One Mach process.** Every Windows process is a pseudo-process: a thread running
  `__wine_main` with its own PEB and private ntdll copy, in one address space
  (ARCHITECTURE.md, "One process on iOS").
- **Fault containment is partial.**
  - Two host-fault cases end the child, not the app (`patches/madeira-unix` 0118, 0119): a thread
    of a child that has already exited, and a live child's thread that faults 2,000 times.
  - Any other unhandled host fault still ends the app.
  - A thread killed while in an in-process wait, and the threads of a terminating process, are not
    reliably ended yet ([PLA-229](https://linear.app/playportdev/issue/PLA-229),
    [PLA-230](https://linear.app/playportdev/issue/PLA-230);
    [evidence](../evidence/2026-10-12-killed-threads.md)).
  - A Chromium app has many processes and kills them freely, so all of this matters.
  - **Review 2026-10-13:** PLA-230 is done (`patches/madeira-unix` 0139–0140: a terminating
    process's threads busy in FEX are ended). PLA-229 is done for i386 only (0142); a killed
    x86-64 waiter still stays parked, now [PLA-314](https://linear.app/playportdev/issue/PLA-314)
    ([evidence](../evidence/2026-10-13-killed-wait-shared-queue.md)). Children share the session's
    64-bit heap and locks ([PLA-312](https://linear.app/playportdev/issue/PLA-312)).
- **The session root** (`app/SessionRoot/playport-session.c`) starts one title per app process in a
  job (decisions 0027, 0030). It waits for the job to empty and reports the exit code of the
  executable it started. So a launcher that stays running keeps the session alive after the game
  ends. A launcher that exits 0 also hides a failing game
  ([launcher feasibility](../evidence/2026-10-02-launcher-feasibility.md)).
- **The JIT pool** is 512 MiB (0036). Each child process takes about 20 MiB of the pool head (its
  ntdll copy and its ARM64EC image copies) and at least FEX's first 16 MiB code buffer from the
  tail. A pure x86-64 image gets no pool copy (`patches/madeira-unix` 0090), which helps
  `libcef.dll`. A dead process's image ranges never go back to the head
  ([PLA-213](https://linear.app/playportdev/issue/PLA-213)). A Play whose pre-game processes leave
  the game less than 320 MiB restarts Playport before the game (0084, 0094).
  **Review 2026-10-13:** PLA-213 is done (`patches/madeira-unix` 0138): a dead process's image
  ranges are taken by later image copies (twelve children took the head to 98 MiB, not 284). The
  head cursor does not move down, and a reused range never holds FEX's code buffer
  ([evidence](../evidence/2026-10-13-pool-head-reuse.md)). A dead process's images also leave
  every emulator's 256-entry alias table now (PLA-310, `patches/fex` 0039, madeira-unix 0141;
  [evidence](../evidence/2026-10-13-alias-table-retire.md)), so many short-lived children no
  longer fill it.
- **Memory.** The limit is 8 GB with Game Mode (the increased-memory-limit entitlement), not the
  4 GB in Madeira's handoff. The FEX host band is 16 GB of address space at
  `[0x7c00000000, 0x8000000000)`, about 50 MB per emulator thread.
- **Address space.** The guest window is `[0x7000000000, 0x73ffff0000)` (16 GB, "the furniture
  ceiling"). A request the ceiling clamps is placed above it, in `[0x7400000000, 0x7c00000000)`
  (32 GB) (`patches/madeira-unix` 0082,
  [guest VA exhaustion](../evidence/2026-10-06-guest-va-exhaustion.md)). iOS's GPU carveout
  `[64 GB, 448 GB)` cannot be used.
- **Madeira's CEF work.** Madeira ran Steam's CEF client in one Mach task
  (`upstream/madeira/STEAM_CEF_HANDOFF.md`). What it found:
  - The VA map fits **one** CEF instance's PartitionAlloc pools and one V8 sandbox. So it forced
    `steamwebhelper.exe` into `--single-process`, refused its `--type=` children, and defaulted V8
    to `--jitless`.
  - The login window rendered and took input. But it had tile-granular render corruption, suspected
    to be FEX misexecuting Skia. Black, alpha-0 pixels needed a per-window alpha gate.
  - It crashed every run in `libcef.dll` on a `KERN_MEMORY_ERROR` that its "bus-reheal" misdiagnosed.
  - Steam's CM websocket failed above TLS.
  - Optional helpers that faulted ended the app, so a `[proc-gate]` refused them by name.

  Playport removed the CEF-only pieces (`patches/madeira-unix` 0083: the 8 GB V8/cppgc holdback,
  the 4 GB soft cppgc grant, the V8 CodeRange service and the steamwebhelper gate). The name gate
  for optional helpers (steamerrorreporter, gldriverquery, vulkandriverquery, steamsysinfo,
  UnityCrashHandler64) stays.
- **No services run.** The app runs no service manager:
  - `services.exe`, `rpcss.exe`, `plugplay.exe` and `winedevice.exe` are staged as files only
    (0080, 0082).
  - So `CreateService`/`StartService`, out-of-process COM and the RPC endpoint mapper are absent.
  - Madeira's desktop mode did run `services.exe`, which started `rpcss` for Steam's COM
    (Madeira `app/Madeira/ContentView.swift`; `patches/wine-port` 0017 keeps combase's
    `start_rpcss` retry).
- **GDI windows** (PLA-152, decisions 0075 and 0076):
  - Until the game's swap chain presents, every visible top-level window whose client area has
    more than one colour is shown. They are placed as on the desktop, with their bounding rect
    fitted to the screen.
  - Afterwards, only windows made since then ("dialogs") are shown.
  - Input: a finger is the left button; the pad sends keys (`WindowKeys`).
  - Limits: no text entry, no hover, wheel or right button, and layered windows are black where
    they are transparent.
  - **The first frame comes from any swap chain**: Playport cannot yet tell a launcher's Direct3D
    or Vulkan present from the game's.
- **Network and TLS.**
  - A guest's TLS checks against Mozilla's roots, shipped and synced into the ROOT store, and
    Schannel is built in (ARCHITECTURE.md, "Trusted roots").
  - Microsoft code-signing roots are present (0078).
  - The NSI tables come from the host (no `nsiproxy.sys`).
  - Loopback sockets work (GOG's Galaxy service on `127.0.0.1:9977`, 0063).
- **What the prefix and runtime have.**
  - `msiexec` runs (0103). Wine Mono ships (0077).
  - Every Wine module Proton ships is staged (0070, 0071): `dcomp`, `uiautomationcore`,
    `taskschd`, `wbemprox` and others.
  - `cmd`, `start` and `conhost` are built for arm64ec (0082).
  - i386 titles run through WoW64 within limits (0047); the 2026-10-02 feasibility note predates this.
- **What the library does today.**
  - The Epic catalogue refuses `ThirdPartyManagedProvider` games ("installed and started through
    Ubisoft Connect, which Playport does not run"; EpicClientKit `EpicLibrary.refusal`).
  - Steam receipts skip `REDprelauncher.exe` (PlayportKit `Catalog.isPrelauncher`).
  - A game's executable can already be chosen (`chosenExecutable`).
- **Proton's launcher hacks** (Valve's Wine commits, triaged in
  [the rebase evidence](../evidence/2026-09-28-wine-proton-rebase.md),
  `valve-commits.tsv`):
  - **Taken** (`patches/wine-valve` 0037 onwards): kernelbase's `hack_append_command_line`, which
    adds Chromium switches by executable name: `--in-process-gpu`, `--use-gl=swiftshader`,
    `--use-angle=gl|d3d9`. That is the mechanism this plan would reuse or replace.
  - **Not taken, because they touch files an `*_ios.c` replacement overrides:**
    `WINE_SIMULATE_WRITECOPY` for `UplayWebCore` and for `Battle.net.exe`, and the `gta5.exe`
    first-page hack.
  - **Unused:** "make sure popups are not managed for Rockstar Launcher" (winex11).
  - **Inert:** "use native vulkan-1 for RDR2" (wine.inf, which the app never runs).
  - **In Valve's bleeding edge** (2026-10-05 survey): "force `--no-sandbox` for
    `msedgewebview2.exe` on ARM" and "clear `WS_EX_TOOLWINDOW` for the EA launcher splash".

## Requirements common to all launchers

### R1. Chromium's process model

Each of the four launchers draws its UI with an embedded Chromium: CEF (Rockstar's launcher and
Social Club, Ubisoft's `UplayWebCore`, Battle.net) or Qt WebEngine (the EA app). (Public knowledge;
Stage R checks each one.) A default Chromium browser starts:

- a GPU process (`--type=gpu-process`);
- one or more renderers (`--type=renderer`);
- a network service (`--type=utility --utility-sub-type=network.mojom.NetworkService`);
- other utility processes (audio, storage);
- a crash handler (`--type=crashpad-handler`).

Each is a pseudo-process here. Each one maps its own `libcef.dll`, initialises its own
PartitionAlloc pools and V8 cage, and costs pool head, a FEX code buffer and emulator threads.
Madeira's measurement is that the VA fits one instance's pools. So:

- **The browser runs as one pseudo-process.** For the browser process, the runtime adds:
  - `--single-process` (renderer and GPU as threads);
  - `--no-sandbox` (Chromium's sandbox needs restricted tokens, job objects and process
    mitigations that Wine does not give, and Proton forces it off on ARM);
  - `--in-process-gpu`;
  - `--enable-features=NetworkServiceInProcess`;
  - `--disable-gpu-compositing` until R3's GPU path exists;
  - `--disable-breakpad` / no crashpad.

  It refuses the optional `--type=` children that are still asked for, as Madeira did, and logs
  each one (`[chromium]`). It does this in one place for any Chromium browser (owner decision D1),
  not per launcher. It is detected by the image (`libcef.dll` or Qt WebEngine's core library
  loaded next to the executable) or by a child's `--type=` switch.
- **`--single-process` is unsupported upstream** and some CEF apps refuse it or set it from code
  (`CefSettings`, `OnBeforeCommandLineProcessing`). The fallback is a reduced multi-process model:
  - in-process GPU and network;
  - `--renderer-process-limit=1`;
  - `--disable-site-isolation-trials`;
  - PartitionAlloc's pools placed above the ceiling once per process, so two to three processes
    fit (measured in Stage 0).
- **V8: JIT or `--jitless`.** V8's JIT writes x86 code that FEX must translate again. It uses the
  anonymous-alias table (4096 entries) and the pool head for guest JIT blocks. Madeira defaulted
  to `--jitless`. Decided (owner decision D2): start `--jitless` (`--js-flags=--jitless`), then
  measure the JIT once the UI works.
- **Proton's per-executable switch list** (`hack_append_command_line`) stays as Valve wrote it.
  Playport's Chromium policy goes beside it, in `process_ios.c` where 0083 removed Madeira's, and
  not as more names in that list.

### R2. Memory and address-space budget

Estimates to be replaced by Stage 0's measurements (the `title: pool|band|limits` lines and
`[jit-pool]`, `[band]` and `[va-ceiling]` logs):

| Resource | Limit | A single-process launcher (estimate) | What it competes with |
| --- | --- | --- | --- |
| JIT pool head and tail | 512 MiB (0036) | 80–200 MiB: ntdll and ARM64EC DLL copies for each process, FEX code for a `libcef.dll` of 100–200 MiB of x86 code, V8 blocks if not jitless | the game's 320 MiB room (0094) |
| Dead processes' pool head | reused only by later image copies; the cursor does not move down (PLA-213, done; Review 2026-10-13) | every helper that starts and exits, and every self-update relaunch | the same |
| Footprint | 8 GB with Game Mode | 0.3–1 GB resident | a large game (RDR2: several GB) |
| FEX band | 16 GB | 40–80 emulator threads × about 50 MB, so 2–4 GB | the game's threads (Hollow Knight 3.3 GB) |
| Guest VA | 16 GB below the ceiling and 32 GB above it | PartitionAlloc pools of up to 16 GB each, a V8 sandbox (Chromium falls back to a smaller one when 1 TB cannot be reserved), the `libcef.dll` mapping | the game's own reservations (Death's Door put 7 GB above the ceiling) |

Consequences:

- **A launcher that must stay running while its game plays** (Rockstar's, Ubisoft's, and the EA
  app for its DRM) shares the pool, the band and the VA with the game for the whole play. Stage 0
  measures the launcher alone, and Stage 2 measures it with the game.
- **A launcher that can exit or idle once the game has started** is cheaper, but its dead head
  stays used until PLA-213 is fixed. PLA-213 goes from Low to a Stage 0 dependency.
  (Review 2026-10-13: PLA-213 is done; the game's own image copies can reuse that head, but
  nothing else can. Stage 0 measures what is left.)
- **If the room is short, options in order:**
  1. jitless V8 and fewer processes;
  2. PLA-213;
  3. a larger pool for launcher plays only (a new decision amending 0036; owner decision D3,
     decided: no change until measured, then up to 768 MiB for launcher plays only, within the
     896 MiB the reservation holds);
  4. 0084's restart between launcher and game, which works only for launchers the game does not
     need while it runs.

### R3. Rendering

- **First: software compositing through GDI.**
  - With GPU compositing off, Chromium's software output device draws each frame into the HWND
    with GDI (`BitBlt`, or `UpdateLayeredWindow` for a layered window).
  - That reaches 0075's window surfaces with no new graphics path.
  - Known costs: upscaled bitmaps; transparency shown black (Madeira saw alpha-0 pixels; it needs
    the per-window alpha gate); Skia's raster work runs as x86 code under FEX, where Madeira saw
    tile corruption.
  - Stage 0's first question is whether that corruption is still there under Playport's FEX
    (many FEX fixes since: `patches/fex` 0025–0034).
- **Later: GPU compositing on Vulkan only** (decision 0100).
  - Chromium's ANGLE on its D3D11 backend over DXVK and KosmicKrisp, as under Proton, or ANGLE's
    Vulkan backend over winevulkan.
  - Never through DXMT: a launcher play forces the Vulkan backend for its processes.
  - This needs R3a first.
- **R3a: a present that is not the game's.**
  - Today the first swap chain to present is "the first frame". It ends 0075's window layer, and
    every window made afterwards becomes a 0076 dialog over the game.
  - A launcher drawing through D3D11/Vulkan, or a launcher window that stays up while the game
    runs, would break both rules.
  - Needed: the host tells the **game's** process tree from the launcher's. The launch knows the
    game's executable (the Steam/Epic receipt), so presents and windows can be attributed by
    process.
  - The launcher's windows are a launcher layer, not the game, and are never a dialog over it.
  - New decision amending 0075/0076 (owner decision D4, decided as recommended: attribution by
    process; the record is written with the work).

### R4. Services, SCM and rpcss

Launchers install Windows services and expect the SCM:

- Rockstar Games Library Service (`RockstarService.exe`);
- the EA app's background service (`EABackgroundService.exe`);
- Ubisoft's and Blizzard's helper or update services, to verify in Stage R.

Out-of-process COM and the RPC endpoint mapper need `rpcss`, which the SCM starts.

- **Run `services.exe` in a launcher session**, as Madeira's desktop mode did: started by the
  session root before the launcher, so combase's `start_rpcss` and a launcher's `StartService`
  find it.
  - The services it runs are pseudo-processes too: pool head, threads and the fault-containment
    rules.
  - Only demand-start and auto-start services in the prefix's `Services` key run. The prefix seed
    holds no `AddService` entries (0080) until a launcher installs some.
- **Not every Play.** Only a play whose title or launcher is marked as needing services (owner
  decision D5, decided). It costs pool head and start time that a plain game does not need.
- **wineboot's `AddService` work** (0080 "the app runs none") is checked against what `services.exe`
  expects when it starts with a seeded prefix. Desktop: a scratch prefix seeded the same way.

### R5. IPC: named pipes, shared memory, loopback

Launchers talk to their services, to the game and to their own helpers through:

- named pipes (`\\.\pipe\…`);
- named sections and events;
- loopback TCP (the EA app's local host service; Social Club and the game);
- for some, custom URL protocols (`link2ea://`, `uplay://`) through `ShellExecute`.

Pipes, sections and events go through the in-process wineserver and need no new mechanism, but
every one crosses pseudo-processes in one address space: the `[iOS-xrem] via=section` paths are
exercised. Protocol handlers registered in `HKCR` must open the guest handler, not Playport's URL
opener. `playport-url-opener` is registered only for `http`/`https` (decision 0064). Check: a
launcher's own protocol reaches its executable in the guest.

### R6. TLS, certificates and the network

- Chromium carries its own TLS (BoringSSL) and checks certificates through the Windows store
  (`CertGetCertificateChain` and the ROOT store). The shipped Mozilla roots cover public sites.
  Revocation checks (CRL/OCSP) through Wine's `cryptnet` must time out quietly, not fail closed.
- Native parts (services, `UbisoftConnect.exe`, the game's SDKs) use WinHTTP or WinINet, Schannel
  and GnuTLS.
- Madeira's Steam CM websocket failure (TLS was up, the websocket failed) is the warning:
  - Stage 0 checks a websocket against a public echo endpoint inside the launcher's browser;
  - Stage 1 checks the launcher's own push channel.
- `GetAdaptersAddresses` now answers from host tables (PLA-71); connectivity checks (Network List
  Manager, `InternetGetConnectedState`) must say online.

### R7. Updates and self-patching

Every launcher updates itself before its UI comes up and refuses to run old:

- it downloads a new build;
- it replaces its own executables (often through a separate updater process or a rename and
  relaunch);
- sometimes it goes through the service with elevation.

Each relaunch is a new pseudo-process whose old head stays used (PLA-213), and a long update can
start several. (Review 2026-10-13: since PLA-213, later image copies reuse that head.) Requirements:

- updates run, and are not blocked, since a blocked update usually means no UI;
- the bytes are written into the container's prefix (`Program Files`), where they persist;
- the pool budget includes one update cycle;
- an update that needs a reboot (`ExitWindowsEx`, wineboot, 0082) ends the session and Playport
  restarts cleanly (0029);
- an update is never driven by Playport: Playport never replaces a launcher's files.

### R8. Elevation and UAC

Wine runs every process with an administrator token. `requireAdministrator` manifests and
`ShellExecute` with `runas` succeed with no prompt, as under Proton. Checks:

- an installer that re-launches itself elevated (a second pseudo-process with the same command
  line) completes;
- a launcher's "is admin" and "is service running" checks (`OpenSCManager`, `QueryServiceStatus`)
  answer as Windows does once R4 is in.

No UAC prompt is ever shown, and nothing asks the person.

### R9. How the launcher starts the game

The common shapes:

| Shape | Example | What Playport needs |
| --- | --- | --- |
| The store starts the game; the game finds no launcher and starts it, which restarts the game | RDR2's `RDR2.exe` → `Launcher.exe` → `RDR2.exe` (Madeira's RDR2 handoff) | a process chain under one job; know which process is the game |
| The store starts a small bootstrapper that starts the launcher with a game id | Steam copies of EA games (EA's launch helper, `link2ea://`), Steam/Epic Ubisoft copies (`upc.exe` with the game id) | the launcher installed and signed in first; protocol handlers |
| The launcher passes a one-time token on the game's command line, or through its own local service | Battle.net, Ubisoft (`uplay_r1`/`upc_r2` loader DLLs talking to the running launcher), Rockstar (Social Club in the game) | the launcher stays running; IPC (R5) |

What applies to all of them:

- **The game is a descendant of the launch's job.** The root waits for the game's process, which
  the launch names from the receipt's executable. It reports the game's exit code, and it ends the
  job (the launcher too) when the game ends. That changes 0030's "wait for the job to empty" for a
  launcher play (a decision record; part of D4, decided).
- **Backend and per-title settings** are chosen for the game, from its own executable, as today.
  The launcher's processes get the Vulkan backend (R3).
- **A launcher shown with no game** (Stage 1, "Open launcher") ends when its window is closed or
  the person ends it from the in-game menu, followed by the restart (0029).

### R10. Fault containment

A Chromium app crashes processes on purpose: a renderer killed on navigation, crashpad's dumps, a
GPU process restarted. Requirements before any launcher runs on the phone (Stage 0):

- **An unhandled host fault in any pseudo-process other than the session root ends that process
  with `c0000005`, not the app.** This generalises 0118 and 0119 (today only a child that has
  exited, or a 2,000-fault storm). A fault inside FEX's or the wineserver's shared state still ends
  the app: those locks are shared, and the fault rules must say so.
- **PLA-229 and PLA-230 fixed:** a killed thread in an in-process wait, and the threads of a
  terminating process. Chromium's `TerminateProcess` of a renderer must leave no thread running.
  (Review 2026-10-13: PLA-230 done; PLA-229 done for i386; the x86-64 part, which a CEF launcher
  needs, is PLA-314.)
- **Optional helpers are refused by name and logged**, as today's `[proc-gate]` does: crash
  reporters, crashpad handlers, telemetry and hardware-survey tools. The refusal is something the
  launcher survives, as Chromium survives a failed crashpad start. The list is generic (helper
  kinds), not per launcher where avoidable.
- **Madeira's open `libcef.dll` `KERN_MEMORY_ERROR`** is checked first: does Playport's runtime
  still hit it with today's section and alias handling?

## Product integration under decision 0012

### Where a launcher lives in the UI

- **Settings › Launchers**: one row per supported launcher, with its state (not installed,
  installed, signed in as the launcher says, or unknown) and the actions:
  - **Install**: download the publisher's official installer from its public URL on the phone,
    check its Authenticode signature (0078), and run it in the guest as a prerequisite-like step
    with the launch screen;
  - **Open**: a launch whose title is the launcher itself;
  - **Reset**: remove the launcher's stored session and caches in the prefix, after a
    confirmation;
  - **Uninstall**: run its uninstaller.

  This is the one entry point. The dev driver reaches it with the same model calls (`pp ui
  --action open:launchers`, new actions in Stage 1).
- **A game's page** says when its copy needs a launcher ("Starts through Ubisoft Connect"). If the
  launcher is missing or signed out, Play offers to install or open the launcher first. The Epic
  refusal for `ThirdPartyManagedProvider` turns into this row once that launcher passes Stage 3.
- **Until then (Review 2026-10-13):** the Steam client bridge's D10, decided 2026-10-13, refuses
  launcher-gated Steam and Epic copies with a message naming the launcher
  ([PLA-266](https://linear.app/playportdev/issue/PLA-266)), and records them as Broken (launcher)
  in Compatibility. That refusal is lifted per publisher when its launcher passes Stage 2 here
  (Rockstar) or Stage 3 (the others); the titles then run through it.

### Signing in on the phone

- **The person signs in inside the launcher's own window**, shown through 0075's window layer:
  their email, password, two-factor code and any captcha, in the publisher's own page. Playport
  never sees, stores or fills the credentials, and holds no host session for these publishers (D6).
- **Text entry** is new and is needed: 0075 has none.
  - Decided with D10: a text bar over the guest window that opens the iOS keyboard. It sends each
    character to the focused guest window as `WM_CHAR` (Unicode, so symbols in passwords type).
  - It also sends Backspace, Tab and Enter as keys, and opens when the person taps a text field or
    presses a controller button.
  - It shares the touch keyboard work of [PLA-13](https://linear.app/playportdev/issue/PLA-13)
    (its "touch keyboard"). Nothing typed is logged; the HostIO key path already logs no
    characters, and a test keeps it so.
  - iOS password AutoFill and paste: the bar is a secure `UITextField`. A pasted or auto-filled
    value goes the same way, character by character. It is the person's launcher password, not a
    host secret (0004 is about the host's store sessions), but it still never reaches a log.
- **QR or companion-app sign-in**, where a launcher offers it (Battle.net's authenticator app, to
  verify), needs nothing more than the window.
- **A sign-in page the launcher opens in the system browser** reaches Playport's web panel (0064).
  That panel's session is non-persistent and separate from the guest. A login that must return to
  the launcher through a custom protocol or a loopback redirect (`http://127.0.0.1:<port>/…`) does
  not return from the panel. Such a launcher needs its page opened in the guest instead: a per-URL
  rule in `UrlOpenRequest` (Stage 1 finds out whether any of the four does this).

### Where its window shows

- Before a game's first frame: 0075's layer, as Tomb Raider's launcher shows today.
- With R3a: the launcher's windows are a **launcher layer**, attributed by process. They show
  while no game of the session is presenting, and never as a 0076 dialog over the game. While the
  game runs they stay hidden, except a launcher window that asks for attention, such as an error
  box (D4, decided as recommended: hidden, with a launcher's error box shown as a dialog only when
  the game has exited).
- Scaling: the launcher's window is fitted to the screen as 0075 does. Chromium is told a DPI that
  makes its text readable on a 6-inch screen once fitted. A virtual monitor at a lower resolution
  for launcher plays (0097's display modes) is the first thing to try, not a Chromium zoom switch.

### Touch and controller

- **Touch:** a finger is the left button (0075). Add:
  - a drag that scrolls (wheel events, `WM_MOUSEWHEEL`), which Chromium pages need;
  - long press for the right button;
  - hover not needed.
- **Controller:** 0075's `WindowKeys` (arrows, Enter, Escape, Tab) work in Chromium pages that are
  keyboard-navigable. Add:
  - a pointer mode (the left stick moves a cursor drawn by the host, A clicks, the right stick
    scrolls), for launchers whose pages are not keyboard-navigable;
  - the text bar opened from a button.
- The in-game menu (controller Home, or the touch control PLA-13 adds) ends a launcher session as it
  ends a game.

### The stored session (decision 0004)

- **The guest launcher signs itself in and keeps its own session**: its own "remember me" token in
  the prefix (often DPAPI-protected, which Wine does not really protect) or in its own files. This
  is a guest client performing its own login, which is what 0004 asks.
- **No host secret crosses.** Playport's Steam, Epic and GOG sessions give the launcher nothing.
  This plan needs no exception to 0004. The exceptions that exist stay per-game:
  - an Epic copy of a Rockstar or Ubisoft game still gets 0059's exchange code on its command
    line, as Epic's launcher would give it;
  - the launcher then redeems it or links the account itself.
  - Whether a launcher's account-linking flow asks for anything more from Epic is checked in
    Stage 3. Anything more needs its own record.
- **Where the guest session lives** is recorded per launcher in its evidence: files and registry
  keys found by searching the prefix after sign-in, as 0059's measurement did. Reset deletes them,
  and the evidence lists them.
- **Residual:** the container holds the launcher's session in a form any guest code, and a
  container copy, can read. That is the same as the Wine prefix under Proton. It is stated on the
  Launchers page ("Signing in keeps the launcher's session in Playport's Windows files").
- **Logs:** a launcher's own logs and Chromium's `--enable-logging` are off by default. Playport's
  `Redactor` gets patterns for launcher tokens seen in command lines: Battle.net's and Ubisoft's
  game-launch tokens, Rockstar's and EA's (Stage R collects the forms). `pp secrets` learns them.

## Per-launcher notes

Public knowledge as of 2026-10-12. Every item marked *(verify)* is checked in Stage R on the
workstation under desktop Proton/Wine (HOST-DEBUGGING.md) before the phone.

### Rockstar Games Launcher and Social Club

Measured on the workstation, 2026-10-15 (Stage R; launcher 1.0.109.3031, Social Club 2.4.0.240;
[evidence](../evidence/2026-10-15-rockstar-launcher-recon.md)):

- **Parts:**
  - `Launcher.exe`: the UI host. It loads `socialclub.dll` and draws Social Club's off-screen CEF
    pages into its own window with D3D11. It has no CEF of its own.
  - `LauncherPatcher.exe`: a version gate on a standalone start; it stays alive.
  - `RockstarService.exe`: the "Rockstar Game Library Service". Demand start, LocalSystem,
    started through the SCM by a `RockstarService.exe start` helper. It writes the self-update
    files and fixes folder permissions. **Without it the launcher stops before its sign-in page**
    ("Failed to connect to the Rockstar Games Library Service").
  - `RockstarErrorHandler.exe`: crashpad.
  - Social Club (`Program Files\Rockstar Games\Social Club`). The launcher installs it on first
    run (`Social-Club-Setup.exe /silent /forceinstall`). `socialclub.dll` starts
    `SocialClubHelper.exe`, which is the CEF host (CEF 143.0.14, Chromium 143.0.7499.193,
    `libcef.dll` 249 MB): a browser, GPU, network, storage, audio and video-capture processes, and
    three renderers (one per page). There is no separate `subprocess.exe`.
  - At the sign-in page: 13 Rockstar processes, about 330 threads and 4.4 GiB PSS under desktop
    Wine.
- **Game hand-off:** a Steam copy starts `PlayRDR2.exe`. It reads
  `HKLM\SOFTWARE\WOW6432Node\Rockstar Games\Launcher\InstallFolder`, runs
  `Redistributables\Rockstar-Games-Launcher.exe /s /t` if that value is missing, then opens
  `Launcher.exe -skipPatcherCheck -steamAppId=1174180 -steamLocation "<game folder>" @args.txt`.
  In that Steam mode the launcher calls `SteamAPI_Init` through its own `steam_api64.dll` before
  its sign-in page, and stops if no Steam client answers. From there, Madeira's handoff gives
  `Launcher.exe` → `RDR2.exe`. The game's `socialclub.dll` very likely starts its own
  `SocialClubHelper.exe` CEF processes, as the launcher's does (not yet measured). The IPC is
  named pipes: `chrome.rgsc_gameinst_0`, `rgsc_launcher_0`, `rgsc_ipc_*`, `MTL*_Pipe`.
- **Offline:** without a prior online sign-in there is no sign-in page and no offline mode. The
  launcher has `-scOfflineOnly` and an offline auto sign-in (`autosignin.dat`). How long offline
  lasts, and what the game is given, needs the owner's sign-in. Single-player RDR2 still cannot
  start without the launcher.
- **Steam and Epic copies:** both start the launcher. Steam ships the genuine installers in the
  game folder (depot 1899671). Epic copies use `-epicAppId` and `Rockstar-Games-Epic.exe`;
  account linking is still to be seen in Stage 3.
- **Proton today:** Steam's own RDR2 and GTA V run under Proton. Valve's tree carries an RDR2
  `vulkan-1` load-order line, a GTA V first-page write-copy hack, and a winex11 popup fix for this
  launcher (`SocialClubHelper.exe`). Proton 10 also turns off OPWR for Rockstar app ids (login
  text-input delay) and has an RDR2 SIGSYS handler. It has no Chromium switches for this launcher.
  None of them reaches Playport as-is (see [Where things stand](#where-things-stand-the-tree-at-2026-10-12)).
- **Known Playport walls** ([sibling plan](2026-10-12-rdr2.md)): RDR2's anti-tamper puts x64 inline hooks on ARM64EC
  exports (Madeira's `research/HANDOFF-rdr2-arm64ec-hooks.md`). [The RDR2 plan](2026-10-12-rdr2.md) owns that work; this
  plan owns the launcher and Social Club.

### Ubisoft Connect

- **Parts:**
  - `UbisoftConnect.exe` / `upc.exe`, the native shell;
  - `UplayWebCore.exe`, CEF;
  - `UbisoftGameLauncher(64).exe`, started by a game to reach the launcher;
  - the game-side `uplay_r1_loader64.dll` / `upc_r2_loader64.dll`, which talk to the running
    launcher;
  - possibly a background service *(verify)*;
  - some binaries may be 32-bit, which puts them under WoW64 and 0047's limits *(verify)*.
- **Game hand-off:** the game, or its Steam/Epic bootstrap, starts the launcher with the game id.
  The launcher stays running and the game asks it for its ticket.
- **Offline:** "Go offline" after an online sign-in *(verify)*.
- **Steam and Epic copies:** Steam copies start Ubisoft Connect, and some install it through their
  install script *(verify)*. Epic copies are `ThirdPartyManagedProvider=UbisoftConnect`, refused
  today; Epic's launcher hands the launcher an Epic sign-in for linking *(verify against 0059's
  exchange code)*.
- **Proton today:** `WINE_SIMULATE_WRITECOPY` is forced for `UplayWebCore`. Proton then reports
  image pages as write-copy as Windows does, and the launcher's checks need that. Playport's
  `virtual_ios.c` replacement must give the same answer: a host check first, which may need a
  `madeira-unix` patch (Stage 3).

### EA app

- **Parts:**
  - `EADesktop.exe`, Qt with Qt WebEngine, which is Chromium (`QtWebEngineProcess.exe` children);
  - `EABackgroundService.exe`, a Windows service the app requires;
  - a local host service the game and EA's launch helper talk to *(verify)*.
- **Game hand-off:** Steam copies of EA games start EA's link helper, which opens the EA app
  (`link2ea://`) to sign in and start the game. The game asks the running app for its licence.
- **Offline:** an offline mode after an online sign-in *(verify)*.
- **R1 for Qt WebEngine:**
  - Qt WebEngine reads Chromium switches from `QTWEBENGINE_CHROMIUM_FLAGS` as well as its command
    line;
  - Qt also reads `QTWEBENGINE_DISABLE_SANDBOX`;
  - whether `--single-process` holds there is a Stage R question.
- **Proton today:** Steam's EA titles run the EA app under Proton. Valve's bleeding edge fixes its
  splash window's style. Some EA titles use EA's kernel anti-cheat, which stays refused.

### Battle.net

- **Parts:**
  - `Battle.net Launcher.exe`, a bootstrap;
  - `Battle.net.exe`, CEF;
  - `Agent.exe`, the update agent that installs and patches games, run as a process
    *(verify whether a service)*.
- **Game hand-off:** Battle.net starts the game with a launch token. Most games ask the running
  client.
- **Sign-in:** email, password and the Battle.net Authenticator. A QR sign-in through Blizzard's
  phone app may exist *(verify)*.
- **Offline:** few games allow it.
- **Steam and Epic copies:** recent Blizzard and Activision titles on Steam link a Battle.net
  account. Many do not run the Battle.net app at all *(verify per title)*. Most Battle.net games
  are online-only with anti-cheat. **Lowest value of the four**; done last.
- **Proton today:** `WINE_SIMULATE_WRITECOPY` is forced for `Battle.net.exe`, the same host check
  as Ubisoft.

## Stages

Each stage gets its own Linear issue (below) and its own evidence record. The phone gates follow
AGENTS.md:

- every runtime change still passes Hollow Knight `--play app-367520 --until first-frame+10`;
- a launcher step is shown by a `pp ui` run with screenshots in its run directory;
- device commands run under the lock;
- the owner signs in where credentials are needed: agents never hold or type a launcher password.

### Stage R. Reconnaissance on the workstation (no phone)

- **Goal:** know each launcher's process tree, command lines, services, pipes, ports, Chromium
  version and switches, update behaviour and resident memory before building anything.
- **How:** desktop Proton/Wine on the sway display, a scratch prefix per launcher under
  `$PLAYPORT_BUILD`, per HOST-DEBUGGING.md. Install, update, open the sign-in page and quit, with
  Wine's `+process` (and `+service`) channels. Then try the R1 switches (`--single-process`,
  `--no-sandbox`, `--disable-gpu-compositing`, `--js-flags=--jitless`) by hand and note what each
  launcher accepts. Sign-in only with the owner's own account, in the owner's presence, or not at
  all (D6).
- **Done when:** a private reconnaissance note per launcher in `$PLAYPORT_BUILD/agent-notes/pla254/`, and a
  scrubbed summary table (no account data) in the Stage 0 evidence. The *(verify)* items above are
  answered, and the first launcher for Stage 1 is confirmed.
- **Effort:** 2–4 agent-days.

### Stage 0. A fault-contained pseudo-process host for a Chromium app

- **Goal:** a CEF app's browser runs as one pseudo-process (or R1's fallback), draws its first page
  through GDI into 0075's layer, takes touch, and survives its own helpers' crashes, without ending
  the app.
- **Work:**
  - R10: fault containment for children, and PLA-229/230 fixed (PLA-230 may already be a dependency
    of other work).
  - PLA-213: dead image ranges back to the pool head, raised from Low.
  - (Review 2026-10-13: PLA-213 and PLA-230 are done, PLA-229 for i386; what remains of these two
    lines is PLA-314, the x86-64 killed waiter.)
  - R1: the Chromium policy in `process_ios.c` (`[chromium]` lines), with a decision record.
  - R4: `services.exe` and `rpcss` started by the session root on request, with a decision record.
    It can land in Stage 1 if the first launcher's sign-in page needs no service.
  - A measurement build: pool, band, VA and footprint per Chromium process, and websocket and TLS
    checks.
- **Test subject:** the Stage 1 launcher's own installer and its sign-in page, which needs no
  account. Not a shipped test title (decision 0035). It is installed through the Stage 1 UI,
  brought forward in a minimal form: the Launchers row with Install and Open, no sign-in.
- **Acceptance:**
  - the launcher's sign-in page shows on the phone (a `pp ui` run with `--until "mark:first
    window+60"` and screenshots), legible, with no tile displacement on a ratio-tested comparison
    against the desktop Proton screenshot of the same page (Madeira's rule);
  - a renderer or helper killed or crashed on purpose leaves the app running and is logged
    (`[chromium]`, `c0000005` for that process only);
  - 10 minutes idle on the page with no growth in `pool` and `band` after its first minute;
  - a websocket and a TLS 1.3 fetch succeed from the page (from the launcher's own traffic, or a
    test page its browser opens);
  - Hollow Knight's smoke play still passes on the same IPA.
- **Phone gates:** the runs above, under one `pp phone lock` session. Evidence:
  `docs/evidence/<date>-chromium-host.md`.
- **Effort:** 3–6 weeks. **Highest uncertainty**: Madeira's render corruption and its
  `KERN_MEMORY_ERROR` were open when it stopped. If either reproduces, Stage 0 becomes their
  diagnosis, which may need a cheaper offline oracle first: Madeira's parked FEX conformance
  harness, or Chromium's compositor in a test PE on the workstation.

### Stage 1. One launcher's UI and sign-in

- **Goal:** a person installs the first launcher (Rockstar Games Launcher, for the RDR2 goal;
  D8, decided), signs in with touch and controller, and finds it signed in after an app
  restart.
- **Work:**
  - the Launchers page;
  - Install (official URL, Authenticode, the launch screen's step), Open, Reset and Uninstall;
  - the text bar (with PLA-13);
  - scroll, long press and controller pointer mode;
  - R3a, at least the attribution of windows to the launcher's processes;
  - R7: one self-update cycle survives;
  - `Redactor` and `pp secrets` patterns;
  - the guest session's files listed for Reset.
- **Acceptance:**
  - Install, then Open, shows the launcher's sign-in;
  - the owner signs in on the phone (2FA included);
  - Open after a restart shows the launcher signed in, with no host secret in the container that
    was not there before (a search like 0059's);
  - Reset signs it out;
  - an update from the publisher, when one arrives in the window, completes;
  - the dev driver can open the page, press Open and take screenshots without credentials.
- **Phone gates:** a `pp ui` run for each action with screenshots, plus the owner's sign-in session
  (owner present). Evidence: `docs/evidence/<date>-<launcher>-sign-in.md`.
- **Effort:** 3–5 weeks after Stage 0.

### Stage 2. Handing off to the game

- **Goal:** Play on a Steam or Epic copy of a game that needs the Stage 1 launcher reaches the
  game's first frame through the launcher, signed in.
- **Work:**
  - R9: the game named from the receipt, the root waiting for it and reporting its exit, and the
    job ended when it ends;
  - R3a: the launcher layer and the game layer, and no launcher window as a dialog over the game;
  - R5: protocol handlers and IPC;
  - the budget with the launcher alive (R2), and D3 if it is short;
  - the game page's launcher row and its "open the launcher first" path.
- **Test subject:** the RDR2 plan's title once its own walls are passed. Until then, a smaller
  title with the same launcher (D8), so this stage is not blocked on RDR2's anti-tamper.
- **Acceptance:**
  - Play reaches `first-frame+10` with the launcher signed in;
  - the game's exit code is the one reported;
  - the session ends when the game ends, with the restart as 0029;
  - `pool`, `band` and footprint stay under their limits for a 10-minute play;
  - a launcher error (offline, signed out) shows its own window and Playport's notice, not a hang
    under the launch screen;
  - the title's compatibility issue and `site/compatibility/games.json` are updated;
  - PLA-266's refusal is lifted for this launcher's Steam and Epic copies (Steam bridge D10).
- **Phone gates:** `pp ui --play <id> --until first-frame+10 --shot` under one lock with the
  install. Hollow Knight still passes.
- **Effort:** 2–4 weeks, plus the title's own walls ([sibling plan](2026-10-12-rdr2.md)).

### Stage 3. The other launchers

- **Order (recommended):** Ubisoft Connect, then the EA app, then Battle.net.
  - Ubisoft unlocks the Epic catalogue's refused Ubisoft titles and many Steam copies.
  - The EA app is the only Qt WebEngine one: R1 needs a second detection.
  - Battle.net offers the least playable content.
- **Per launcher:**
  - Stage R's answers;
  - the write-copy check (Ubisoft, Battle.net);
  - its services (R4);
  - its install, Open, sign-in and Reset rows;
  - its Redactor patterns;
  - its hand-off shape (R9);
  - for Epic copies, whether account linking stays within 0059.
- **Acceptance per launcher:** Stage 1's and Stage 2's acceptance with one title. The Epic
  refusal, and PLA-266's refusal of its Steam and Epic copies, are lifted for that provider only
  after it passes.
- **Effort:** 2–4 weeks each, less once Stages 0–2 hold. Battle.net may stop at sign-in if no
  title runs without anti-cheat.

## Risks and unknowns

| Risk | Likelihood | Effect | Mitigation, and the default |
| --- | --- | --- | --- |
| Madeira's tile corruption in Skia under FEX is still there | medium | unreadable launcher UI | Stage 0's first measurement. If present: GPU compositing on Vulkan (R3) to skip Skia's software raster, and an offline oracle for the FEX bug |
| Madeira's `libcef.dll` `KERN_MEMORY_ERROR` | unknown | the app dies at the sign-in | reproduce early. Madeira's lead: section-backed memory lifetime, not protection |
| `--single-process` refused or unstable in a launcher's CEF | medium | no UI | R1's reduced multi-process fallback; PartitionAlloc pools above the ceiling, measured per process |
| A launcher and a large game do not fit the pool, VA or footprint together | high for RDR2 | the game cannot start beside the launcher | jitless V8, PLA-213, then D3 (a larger pool for launcher plays) |
| No SCM: services and out-of-process COM fail in ways that only show as hangs | high | the launcher waits forever | R4 before Stage 1. `[service]` log lines for every SCM call |
| The launcher's present or late windows are taken for the game | certain without R3a | broken first frame; launcher dialogs over the game | R3a, by process attribution |
| Self-updates leak pool head and restart the launcher many times | medium | the room runs out before the game | PLA-213; the budget includes one update cycle |
| A publisher blocks or flags the environment (VM/Wine detection, hardware ID checks) | unknown | sign-in refused | none in Playport. Record it in the launcher's issue; no spoofing beyond Proton's |
| Kernel or launcher anti-cheat (EA's, Battle.net titles) | high for some titles | refused | stays refused (0059) |
| Login pages with captchas need hover or drag | medium | sign-in blocked | pointer mode; the person solves it by touch |
| i386 parts (some Ubisoft binaries) | medium | WoW64 limits (0047) | Stage R finds them; R1 on i386 is a separate measurement |
| Launcher ToS and redistribution | low | none if downloaded by the person's phone from the publisher | never bundle installers in the IPA (D9) |

## Owner decisions

**Decided by the owner, 2026-10-13:** D1–D10 as recommended below. (Review 2026-10-13: the
third column gives each decided answer.)

| # | Decision | Decided answer (the recommended default) | Needed by |
| --- | --- | --- | --- |
| D1 | How the runtime applies Chromium switches: one generic policy for any Chromium browser, or Proton-style per-executable entries | **generic**, detected by image or `--type=`, logged; per-executable entries only for a switch a single launcher needs | Stage 0 |
| D2 | V8 JIT on or off in guest Chromium | **`--jitless` first**; measure the JIT after Stage 1 | Stage 0 |
| D3 | A larger JIT pool for plays through a launcher (amends 0036) | **no change until measured**; if short, up to 768 MiB for launcher plays only, by a new decision | Stage 2 |
| D4 | Launcher windows vs the game's (amends 0075/0076, 0030's job wait) | **attribute presents and windows by process**: a launcher layer that is never a dialog over the game; the session ends with the game's process | Stage 1 (windows), Stage 2 (lifetime) |
| D5 | When the SCM and rpcss run | **only for a play whose launcher or title needs them** (a flag in the launcher's entry or the compat table), not every Play | Stage 0 or 1 |
| D6 | Host sign-in for these publishers (native API in the app, as for Epic and GOG) | **no**: the guest launcher signs itself in; no host session, no exception to 0004 | Stage 1 |
| D7 | Games bought in a launcher's own store (not Steam or Epic) | **out of scope**; later a Local import of a game the launcher installed | after Stage 3 |
| D8 | The first launcher and its Stage 2 title | **Rockstar Games Launcher**; Stage 2 with the smallest Rockstar title on Steam or Epic, RDR2 when its plan clears its walls | Stage 1 |
| D9 | How a launcher is installed | **downloaded on the phone from the publisher's official URL at the person's request**, Authenticode-checked; never in the IPA; one copy per launcher in the shared prefix (not one per game, unlike Proton's per-game prefixes) | Stage 0 |
| D10 | The text bar's scope | **shared with PLA-13's touch keyboard**; a secure field when the guest field is a password (when Chromium's accessibility tree says so, else always secure-capable) | Stage 1 |

## Linear issues

Umbrella: [PLA-254](https://linear.app/playportdev/issue/PLA-254). Each line is one issue in team PLA:

1. [PLA-291](https://linear.app/playportdev/issue/PLA-291) **Launchers: workstation reconnaissance under desktop Proton.** Process trees, services, pipes,
   switches and memory for the four launchers (Stage R).
2. [PLA-292](https://linear.app/playportdev/issue/PLA-292) **Runtime: an unhandled host fault in a child pseudo-process ends that process, not the app.**
   Generalises madeira-unix 0118/0119 (R10). Depends on PLA-229 and PLA-230 (Review 2026-10-13:
   PLA-230 done, PLA-229 done for i386; the x86-64 part is PLA-314).
3. [PLA-277](https://linear.app/playportdev/issue/PLA-277) **Runtime: a Chromium process policy.** One pseudo-process browser, `--no-sandbox`, in-process
   GPU and network, refused optional children, `[chromium]` log (R1, D1, D2).
4. [PLA-274](https://linear.app/playportdev/issue/PLA-274) **Runtime: measure a CEF app's pool, band, VA and footprint, and its websocket and TLS on the
   phone.** Stage 0 acceptance and R2.
5. [PLA-275](https://linear.app/playportdev/issue/PLA-275) **Runtime: run services.exe and rpcss for a play that needs them.** The SCM, out-of-process COM,
   `[service]` lines (R4, D5).
6. [PLA-213](https://linear.app/playportdev/issue/PLA-213) **raised: return dead pseudo-process image ranges to the pool head.** Now a launcher
   dependency. (Review 2026-10-13: done, madeira-unix 0138; reuse by later image copies only.)
7. [PLA-271](https://linear.app/playportdev/issue/PLA-271) **App: Settings › Launchers.** Install from the publisher's URL with an Authenticode check, Open,
   Reset, Uninstall, and the dev driver actions (Stage 1, D9).
8. [PLA-267](https://linear.app/playportdev/issue/PLA-267) **App: a text bar for guest windows.** iOS keyboard, AutoFill and paste to `WM_CHAR`, never
   logged; shares PLA-13's keyboard (D10).
9. [PLA-293](https://linear.app/playportdev/issue/PLA-293) **App: scroll, long press and a controller pointer for guest windows.** Extends 0075's input.
10. [PLA-273](https://linear.app/playportdev/issue/PLA-273) **Runtime and app: launcher windows and presents apart from the game's.** A launcher layer,
    attribution by process; a decision amending 0075/0076 (R3a, D4).
11. [PLA-294](https://linear.app/playportdev/issue/PLA-294) **Session root: a launcher play waits for the game's process and reports its exit.** Amends
    0030's job wait (R9, D4).
12. [PLA-278](https://linear.app/playportdev/issue/PLA-278) **Rockstar Games Launcher and Social Club: sign-in on the phone.** Stage 1 for the first
    launcher (D8).
13. [PLA-295](https://linear.app/playportdev/issue/PLA-295) **Rockstar: a Steam/Epic copy's Play through the launcher to first frame.** Stage 2; links the
    [RDR2 plan](2026-10-12-rdr2.md).
14. [PLA-270](https://linear.app/playportdev/issue/PLA-270) **Runtime: write-copy page answers as Windows gives them.** The `virtual_ios.c` equivalent of
    Proton's `WINE_SIMULATE_WRITECOPY` for UplayWebCore and Battle.net.exe; host check first.
15. [PLA-296](https://linear.app/playportdev/issue/PLA-296) **Ubisoft Connect: sign-in and a Steam/Epic copy's Play.** Lifts the Epic
    `ThirdPartyManagedProvider` refusal for Ubisoft when it passes (Stage 3).
16. [PLA-297](https://linear.app/playportdev/issue/PLA-297) **EA app: Qt WebEngine under the Chromium policy, its background service, and a Steam copy's
    Play** (Stage 3).
17. [PLA-298](https://linear.app/playportdev/issue/PLA-298) **Battle.net: sign-in, and a title without anti-cheat if one exists** (Stage 3).
18. [PLA-299](https://linear.app/playportdev/issue/PLA-299) **Graphics: GPU compositing for guest Chromium on the Vulkan backend.** ANGLE over DXVK or
    Vulkan, never DXMT (R3, decision 0100); after issue 10.
19. [PLA-272](https://linear.app/playportdev/issue/PLA-272) **Redactor and `pp secrets`: launcher launch tokens and session values.** Patterns from Stage R.

## What this plan could not determine

- Whether each launcher accepts `--single-process`, `--in-process-gpu` and
  `NetworkServiceInProcess`, or sets its CEF options from code. Its Chromium version, too.
  (Stage R. Rockstar, measured 2026-10-15: CEF 143. `--single-process` and a single renderer
  break its UI. `--in-process-gpu`, `--disable-gpu` and `--jitless` work. `NetworkServiceInProcess`
  has no effect.)
- Each launcher's services, and whether its UI comes up without them. (Rockstar: its service is
  required.)
- How much of Madeira's CEF failure set (render corruption, `KERN_MEMORY_ERROR`, the websocket
  failure) remains on today's runtime. Playport has never run a Chromium app on the phone.
- Whether any of the four sign-ins leaves the guest for a browser and comes back through a loopback
  or custom-protocol redirect, which Playport's web panel cannot return.
- How each launcher's offline mode behaves, and for how long, and which Steam and Epic copies run
  the launcher at all (notably Blizzard and Activision titles on Steam).
- Whether Ubisoft's or another launcher's current binaries are i386.
- The real pool, band and footprint figures. The table in R2 is an estimate.
