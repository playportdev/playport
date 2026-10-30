# 2026-10-29: Social Club on Rockstar's own CEF, with and without single-process (PLA-476 chunk 1)

**Linear:** [PLA-476](https://linear.app/playportdev/issue/PLA-476),
[PLA-477](https://linear.app/playportdev/issue/PLA-477), [PLA-364](https://linear.app/playportdev/issue/PLA-364).
**Plan:** [2026-10-29-sc-stock-cef.md](../plans/2026-10-29-sc-stock-cef.md), chunk 1.

## Build and runs

- **IPA (dev):** `defe3d01ee144147ffcb11e8d11ea5c640a15493ddb0fa361bb8acae374ec33e` (`87dbf80`). It adds the dev
  runtime key `env.PLAYPORT_CEF_SWAP=0`, which leaves a client's CEF in place, as in the release IPA.
- **Settings:** RDR2's defaults (decision 0153), aspect 16:9 and `donorPoolMB=auto`, plus the arm's runtime keys.
  Decisions 0133 and 0138 were on, as by default.
- **a1** (`.work/ui-runs/20261029T135747-rdr2-p476a1`, host log `$PLAYPORT_BUILD/agent-notes/pla476/a1-live/`):
  `env.PLAYPORT_CEF_SWAP=0`.
- **a2** (`.work/ui-runs/20261029T142514-rdr2-p476a2`, host log `$PLAYPORT_BUILD/agent-notes/pla476/a2-live/`):
  `env.PLAYPORT_CEF_SWAP=0 env.PLAYPORT_SC_SINGLE=1`.
- **How the runs ended.** Both were ended by hand once the launcher showed its Error window (a1 ran ~6 min, a2
  ~5 min). In a1 the owner pressed the window's Confirm: the run's harness waited for the game's first frame and
  did not recognise the launcher's own window. The later runner (`agent-notes/pla476/arm.sh`) ends a run with no
  Story press by +360 s and never presses on an error.

## Results

| | a1: Rockstar's CEF | a2: Rockstar's CEF, single-process |
| --- | --- | --- |
| `[cef-swap]` | `PLAYPORT_CEF_SWAP=0: every client's CEF is left alone` | the same |
| `[sc-single] preflight … accepted` / `verified browser` / `[sc-rph]` | — | one each per helper start |
| `SocialClubHelper.exe` starts | 30 (one every 5 s) | 51 |
| their exits | 29 × `0x80000003`, 1 × `0xE0000008` | 50 × `0x80000003` |
| launcher | its Error window; alive | the same |
| game | never started | never started |

- **The single-process patch applied to Rockstar's helper.** The exact-build guard, `--single-process` and
  page-bridge installation logged at every helper start on stock CEF. This does not prove the bridge works:
  the helper failed during allocator startup, before a page or successful sign-in could exercise it.
- **Each helper still dies at its PartitionAlloc reservations.** In a2's second helper:
  - `jumbo#2`: chrome_elf.dll's glued pools, 32 GB at a 32 GB-aligned hint, "granted" as a soft pool at
    `0x7800000000` (PLA-477);
  - `jumbo#3`: 16 GB, its metadata region, real at `0x756eed0000`, over the soft range;
  - `jumbo#4`–`#6`: libcef.dll's pools, 32 GB at 32 GB-aligned hints, refused (`NO GAP FITS`, `0xc000000d`);
  - `jumbo#7`–`#8`: 64 GB − 64 KB with no hint (PartitionAlloc's reserve-and-trim fallback for an aligned block),
    refused (`0xc0000017`).
  - Then the helper exits with `0x80000003`.
- **The map when the helper asks** (a2's walk): `[0x707c1c0000, 0x73e20e0000)` 13.9 GB free (the furniture
  window) and `[0x73ffff0000, 0x79d0000000)` 23.8 GB free. Above them, RDR2's jumbo hold `[0x79d0000000,
  0x7c00000000)` and FEX's arena `[0x7c00000000, 0x8000000000)`. The JIT pool's RW alias is at `0x7007b14000`
  (`VM_FLAGS_ANYWHERE`), with the app's earlier mappings below it from `0x7000000000`.

## What a stock CEF needs here

Per the desktop recon ([cef-swap test](2026-10-16-cef-swap-test.md#stock-cefclients-reservations)) and
willfaust/Madeira's layout 2 (`virtual_ios.c`, `MADEIRA_SC_PA_POOLS`), a single-process helper asks for:

- three 32 GB blocks on 32 GB boundaries: chrome_elf.dll's pools, libcef.dll's pools, and Oilpan's cage;
- two 16 GB metadata regions;
- V8's sandbox (a 1.3 TB placeholder through `NtAllocateVirtualMemoryEx`, which V8 retries smaller);
- and 1 GB.

The window has two 32 GB boundaries, `0x7000000000` and `0x7800000000`. Upstream fits all of these by
reserving only the bottom of each block for real and laying out the band for it:

- the app holds `[0x7000000000, +4 GB)` before Wine starts, and the furniture floor moves above it;
- the JIT RW alias moves to `0x7900000000`;
- FEX's arena moves up (to `0x7c40000000` in the RDR2 geometry), so that Oilpan's cage sits in chrome_elf.dll's
  BackupRefPtr half;
- the metadata regions and RDR2.exe's 8960 MB hold sit in `[0x7400000000, 0x7800000000)`;
- V8's sandbox is a partial 8 GB reservation.

These touch shared placement code, but the new layout need not be enabled for every game. The port must
keep the existing layout when the Social Club layout is not selected. Whether an earlier app-wide hold is
needed to keep the low slot free remains to be tested; the probes did not establish that requirement.

## Not shown

The game's own helper never started, so nothing here shows whether two helpers (the launcher's and the game's,
alive together until the game's sign-in, decision 0130) can share one such layout.

## l1: the Social Club layout (chunk 2)

- **IPA (dev):** `2da3ea8ac26a463b5d64f16cc75eab90f012ff583770c26ddfcb9e39ffa461e7` (`1a7bd2f`).
- **Hollow Knight gate** (`.work/ui-runs/20261029T184335`): first frame +12.81 s; `rw=0x7000000000` (the JIT RW
  alias at its exec-held home, was `0x7007130000`).
- **RDR2 l1** (`.work/ui-runs/20261029T184429-rdr2-p476l1`): runtime keys `env.PLAYPORT_CEF_SWAP=0
  env.PLAYPORT_SC_SINGLE=1 env.PLAYPORT_SC_LAYOUT=1`, RDR2's defaults otherwise; run to first frame +300 s (+390 s
  from launch), no press.

| | a2 (no layout) | l1 (layout) |
| --- | --- | --- |
| `SocialClubHelper.exe` starts | 51, 50 × `0x80000003` | **1, alive to the end** |
| layout grants | — | all six: chrome_elf.dll's pools and metadata, libcef.dll's pools and metadata, Oilpan, V8's 8 GB step |
| soft-pool grants | 2 | **0** |
| launcher | Error window | **Sign In page; signed in online; cloud saves synced; RDR2.exe launched at +78 s** |
| RDR2.exe | — | 8960 MiB reserve served from the layout's hold; window and loading bar (≈30 % at +124 s, ≈80 % at +344 s) |
| game's Social Club | — | not initialised by +390 s: `socialclub.dll` never loaded in the game, no game helper, no sign-in |

- **The game was slow, not refused.** Its main thread runs Rockstar's self-modifying-code protector (FEX
  `[inv-census]`). In xs1 that thread passed ≈21,500 invalidations within a second and loaded `socialclub.dll`; in
  l1 it reached 16,384 at 18:46:37, 21,504 at 18:47:35 and ≈23,500 at the end. No layout refusal, no failed
  reservation and no fault is logged for the game.
- **CPU.** The single-process helper's `Chrome_InProcRendererThread` and its network and thread-pool workers were
  hot in l1 (576 % summed over 16 samples of the renderer thread, against 17 % over 1 in xs1, where Playport's
  CEF ran). Thermal went `nominal` → `fair`; P-core use fell from ≈5 cores at +100 s to ≈1 core at the end, E cores
  carried the rest at 2.11 GHz.
- **A 32-bit COM surrogate cannot start.** From +101 s the helper's thread activates CLSID
  `{4991D34B-80A1-4291-83B6-3328366B9097}` (BITS); rpcss starts `syswow64\dllhost.exe` ten times in 4 s, and each
  exits `0xC0000017`: its WoW64 4 GiB window does not fit (`NO GAP FITS size=0x100010000`). xs1 never activated it.
- **Open:** whether the game reaches its sign-in given more time, and whether the helper's CPU use or the failed COM
  activation delays it.

## l2, l3: longer runs on the same IPA (the loading-screen question)

Same IPA (`2da3ea8a…`), keys and defaults as l1; the runner ends a run with no Story press by +1500 s, otherwise
at first frame +600 s.

- **l1 re-read.** After about +105 s the sampled task CPU sums to about 60 % of one core. RDR2.exe's main thread
  (tid 35C) creates the same threads, in the same order, as in xs1, up to dsound's thread (18:46:34). It is not
  seen running afterwards, and logs nothing after 18:48:20. In xs1 the next steps were 7 more game threads,
  `Nsi`/`BCryptGenRandom`, a signature check of `socialclub.dll` and its load. So l1's long first loading bar is
  the game waiting before its Social Club, not a CPU-bound load. The "protector ≈60× slower" above came from sparse
  timestamps (xs1's log has no per-line times) and does not hold.
- **l2** (`.work/ui-runs/20261029T190705-rdr2-p476l2`): the launcher's helper took all six grants, then died at
  about +34 s with `0xE0000008`. `[chromium-oom]` names a 0x80-byte request. Just before that, a series of 512 MB
  reservations found no gap in `0x7c00000000..0x8000000000` (`[va-scan] FAILED`). l1's helper made the same series
  and lived, so this is nondeterministic. At its exit, kinds 1, 3 and 5 logged `view kept, slot stays owned`. Every
  restarted helper was refused (`[sc-layout] refused reserve … kind=7 c0000017`) and exited `0x80000003`. The launcher
  showed its "timed out loading" Error and the title ended at +54 s.
- **l3** (`.work/ui-runs/20261029T191039-rdr2-p476l3`): the launcher's helper lived. RDR2.exe started at 19:12:12,
  loaded `socialclub.dll` at 19:13:05 and signed in at +141 s. The launcher was ended (decision 0130), and Story was
  pressed at 19:13:40.
  - At the launcher helper's exit (19:13:25) kind 3 (`0x7400000000`, chrome_elf.dll's metadata) logged `view kept,
    slot stays owned`.
  - The game's own helper started at 19:13:27, passed the `[sc-single]` preflight and died 0.6 s later with
    `0xC0000005`: a NULL read (`SEGV … addr=0x0`) in kernel32 code called from chrome_elf.dll, before any 16 GB+
    reservation. No further game helper started.
  - The screen showed the Story loading painting (+198 s), then black with only the spinner from about +250 s to
    the run's end (+655 s). From 19:15:17 the task was idle (2–18 % of one core summed). Thermal went fair, then
    back to nominal; battery 80 % on power.
- **So the long loading in l3 is RDR2 waiting for its own Social Club,** whose helper crashed at start. Two
  problems in chunk 2's layout keep a helper from working after the first one:
  1. a dead helper's slot can stay owned when its views are kept (0226 by design), so a later helper is refused;
  2. the game's helper crashes on stock CEF before it asks for its pools (not yet explained).
  l1's earlier stall (before `socialclub.dll`, with the launcher's helper alive) is not explained by these.

## Host follow-up: early images and the retained-slot blocker

### The l3 crash is a generated NOEXEC fault, not a chrome_elf NULL dereference

Offline re-read of l3's `pull/s1-host.log` (same `2da3ea8a…` IPA, no new play):

- Lines 133385–133434: kernel32 maps at `0x73fba10000`; its syscall map notification has `pfn=0`.
  This is before emulator initialisation. The loader fallback cannot notify an export that has not been resolved.
- At FEX startup the helper's tracker `0x116cc8d80` registers its main image and ntdll, but **never kernel32**.
  Before the first miss it logs 181 executable-section inserts, none for kernel32; there is no kernel32 insert
  for a later removal to explain. The offline replay script exits 1 on this missing coverage.
- Lines 137359–137427: chrome_elf's TLS callback reaches `0x73fba465e0`, **kernel32!LoadLibraryExW**, RVA `0x365e0`
  (the shipped PE export table identifies it). Its bytes are an x64 `ff 25` import jump. Wine reports a committed
  image at `PAGE_EXECUTE_READ` (`0x20`), but FEX logs `[iOS-xquery] MISS` and `NoExec instruction in entry block`.
- FEX's decoder emits `NoExecOp` → `FAULT_SIGSEGV` → `GuestSignal_SIGSEGV`. Its dispatcher deliberately emits a
  load from zero to raise the fault. The logged host instructions `52800001 f9400021` are that trampoline
  (`mov w1,#0; ldr x1,[x1]`), not a NULL data load in chrome_elf or LoadLibraryExW. The helper then fails TLS init
  with `0xc0000005`, before its large reserves.

The source agrees: `load_arm64ec_module` loads the emulator and its kernel32/kernelbase dependencies before
resolving its notification exports. The loader fallback drops those early notifications. FEX `ProcessInit`
registers main, ntdll and queued syscall maps only; the missing syscall callback never queued these dependencies.
There was no post-init loader-list replay. This is a supported startup fix, independent of slot reuse; it does
not explain l1's earlier stall.

### Startup candidate and host checks

- **Candidate dev IPA:** `3fd1145d5b6e59db874083a716ee5d10af685eb476fa4e1ff03c866129348a5e`, at
  `$PLAYPORT_BUILD/out/20261029-215002-3fd1145d/Playport-26.5-3fd1145d.ipa`.
- **Change:** wine-pe 0055 replays the loader list after successful emulator `ProcessInit`/`ThreadInit`, before
  guest TLS callbacks, through the existing guarded `arm64ec_notify_image_map`/`NotifyImageMap` path.
  `loader_section` remains held, pinning the list and every image. This path takes the interval lock with the
  syscall-callback guard, **not** ImageTracker's exclusive code-invalidation lock. It inserts the image's existing
  executable sections only; no `NtProtectVirtualMemory`, map side effects or broader permissions are replayed.
  Main/ntdll/queued-map duplicates are harmless interval inserts. Off iOS the optional export is absent and this
  remains a no-op.
- **Regression:** `python3 -m unittest tools.tests.test_arm64ec_early_images tools.tests.test_sc_layout
  tools.tests.test_proc_end -v`: four tests pass. The startup harness compiles the shipped init phase, replays
  early dependencies and already-covered main/ntdll/queued images, checks duplicate/empty-list behaviour and
  that failed init terminates before notification. Its original phase fails `registered == 31`; the replay passes.
  The ownership harness compiles shipped 0224/0226 headers: kept views remain byte-for-byte unchanged and owned,
  another process cannot take them, an overlapping foreign live view defeats a native hold, and a subsequent
  helper is refused rather than soft-granted memory.
- **Full checks:** `./pp test` passed (including PlayportKit's 365 tests); `./pp build --variant dev` passed,
  **90/90 IPA verification checks**. The first build stopped before compilation because the patch was exported
  with eight context lines while the series checker compares default-three-context patch IDs. Re-exporting the
  identical source with default context made the applied and shipped patch IDs match; no build-tree source was
  edited or reset by hand. Logs/proof are retained under `$PLAYPORT_BUILD/agent-notes/pla476/build-series-failure/`.
- **Historical preflight blocker (resolved before l4 below):** device gates were unrun when the supervisor's
  preflight `pp phone status` exited 3 with zero phones on netmuxd. Charge/VPN could not be checked.
  No install, launch or input was issued then; no retry. Reconnection was sought and
  `$PLAYPORT_BUILD/agent-notes/pla476/l4.sh` was prepared for one locked, exact-IPA in-place install,
  HK first-frame+10 and a bounded stock-CEF RDR2 run using the existing `arm.sh`/landing watcher.
  This was the host-only checkpoint; l4 below supersedes its unrun startup-gate status.

### Why the dead-owner slots cannot simply be reclaimed

- In l3, parked tid `0204` waits at `0x740007c3e0`; in l2, tid `0208` waits at `0x74000483e0`.
  Both addresses lie in kind 3's real metadata range `[0x7400000000, 0x7590000000)` (6400 MiB).
- `ios_proc_end_note_parked` records host/guest registers, TPIDRRO, TEB and wait address. The teardown gathers these
  saved addresses and `ppe_view_fate` keeps any entire view they reference. `ppe_take_view` first transfers that
  view to the runtime (`ios_owner_peb=NULL`); this does **not** make its address free. 0226 then sees the retained
  view and intentionally leaves the slot owned. l2 additionally retains kinds 1 and 5; the slot log does not
  identify their exact saved register/view shape, so no claim is made that their bases alone prove a parked ref.
- Decisions **0132/0143** require these views stay wholly unchanged. 0134 releases a parked thread's exception
  registry/trampoline entries, not these retained views. No later accepted amendment found in this review removes
  the whole-view rule. Merely clearing the ledger, remapping the same address for a new helper, or shrinking to
  just referenced pages would violate that rule. A native hold must also fail rather than overwrite any other
  process's mapping. The new tests preserve these refusals; no slot/retention runtime code changed.

**Options, not decisions:** retain old views and design genuinely disjoint replacement slots, with fresh boot
holds and verified allocator placement; or obtain owner approval for a separately justified change to parked-thread
lifetime/retention. Neither is implemented. The current metadata view already occupies all 6400 MiB of its slot;
moving a future metadata grant into the free 8 GiB V8 slot consumes the space V8 later needs. For core pools the
only 32 GiB-aligned bases in this task's address band are `0x7000000000` and `0x7800000000`, both already assigned;
there is no obvious second full layout. Copying a kept view elsewhere while freeing its original address would
leave saved addresses dangling. These are constraints for an owner-approved design, not proof that every possible
geometry is impossible. No sign-in, helper termination/restart, game libcef refusal or payload policy was changed.

**Remaining gate after l4:** resolve safe subsequent-helper allocation under an owner-approved
design, preserving all retained views. The bounded startup fix is accepted below. Chunk 2 is **not complete**:
helper restart into a working browser, Story cabin, no Social Club/launcher `NO GAP FITS`/soft grant, and the
comparable **7343 MB ±10%** peak remain unpassed. No new gameplay or memory result is claimed by these host checks.

## l4: early-image startup accepted; chunk 2 still blocked

- **Exact dev IPA SHA-256:** `3fd1145d5b6e59db874083a716ee5d10af685eb476fa4e1ff03c866129348a5e`.
  The initial no-phone preflight was resolved by guarded `python3 tools/phonelib.py netmuxd-restart`:
  the stale workstation service was restarted, discovery returned one network phone (80% battery, 3 GB free).
  There is no current prerequisite blocker. The parent's locked l4 session completed exit 0; lock released.
- **HK:** `.work/ui-runs/20261029T220635-hk-p476l4`, first-frame+10 **passed**; first frame +10.58 s.
- **RDR2:** `.work/ui-runs/20261029T220726-rdr2-p476l4`, same stock-CEF/layout keys as l1–l3,
  completed the wait condition first-frame+420. This is not a Story/gameplay success assertion.

Line references below are to RDR2 l4's `pull/s1-host.log`:

- The **game's** helper is PID `0528`, main TID `052c`, PEB `0x701af34000`, executable tracker
  `0x11a5b4d80` (132725–132757, 133410). After ProcessInit/ThreadInit, replay inserts kernel32 intervals
  `[0x73fba14000, 0x73fba47766)` and `[0x73fba48000, 0x73fba49780)` into that tracker (133466–133489).
  The first covers l3's missing `LoadLibraryExW` address **`0x73fba465e0`**.
- Its chrome_elf TLS callback progresses through bcryptprimitives loading to allocator reservations
  (137056–137129). Kind 1 is granted; five 16-GiB metadata attempts are refused with `c0000017`, then an
  **actual guest breakpoint** at chrome_elf RVA `0x13a534` ends it with `0x80000003` (137117–137170).
  There are **zero NOEXEC/NoExec occurrences**. Positive interval coverage and allocator entry, not just
  diagnostic absence, establish the narrowly fixed startup gap; this helper still cannot initialise fully.
- The prior launcher helper (PEB `0x146cc0000`) retains kind 3's real metadata view
  `[0x7400000000, 0x7590000000)` (45346, 132085–132090). Parked TID `0204` waits at **`0x740002c3e0`**,
  inside it (131391). Later game-helper restarts are refused by existing decision-0138 policy
  (137727–155879), not successfully initialised. Decisions 0132/0143 still require the whole view unchanged.
- `NO GAP FITS` remains in the **launcher helper's renderer** attempts (54667–55357), separately from the
  game's 8960-MiB reservation/hold fallback (77355–77361, then served at `0x75d0000000`). No `[soft-pool]`
  lines occur. The no-Social-Club/launcher-`NO GAP FITS` gate therefore has not passed.
- Story was pressed at **22:10:00** (`p476l4/press.log:3`); final `screen-stop.png` is black with a spinner,
  not the cabin. No comparable cabin/gameplay memory acceptance against **7343 MB ±10%** is established.

**Acceptance:** independent read-only review found no issues and positively established both bounded startup
gates (HK first-frame+10; the game's helper beyond the missing-kernel32 NOEXEC into allocator startup).
Accept wine-pe 0055, its startup regression, series entry and associated build records as this increment only.
Existing full `pp test` and dev build passed (90/90 IPA checks); finalization reran only focused host tests and
name/secret/diff checks, with no new runtime implementation, build or phone input.

Finalization normalized only format-patch packaging (blank context/signature/EOF whitespace): stable patch-id
`66deface37bae9f2b9808d4d6b0b59c768445d14` is unchanged, isolated-scratch `git am` yields byte-identical source/tree,
and read-only `check_series` passes. The startup test's hunk parser now preserves valid empty context strictly
within counted hunks, not metadata; conventional and normalized blank context reconstruct identical source.
The baseline startup still fails the coverage assertion and the candidate passes. All **five** final focused
host tests, names, secrets and unstaged/staged diff checks pass; no configured build source was changed.

**Not accepted:** overall chunk 2, successful subsequent-helper/browser startup, Story cabin or memory gates.
No safe replacement slot geometry is established. The next gate is an **owner-approved design** for safe
subsequent-helper allocation; all existing slots/views, retention, termination and restart policies remain
unchanged. No chunks 3–6 were entered. Parent owns compatibility/Linear updates; no games were played during
this documentation/commit finalization.

## Review fixes

Commit `ad295c7` (PLA-476, [PLA-480](https://linear.app/playportdev/issue/PLA-480),
[PLA-482](https://linear.app/playportdev/issue/PLA-482)); dev IPA sha256
`b5ee00eba4b38fad7824d3a9af7e0b58c2a8b9a5e1d8bd0044f59b2d91248ca2` (90 IPA checks); full `pp test` passed.

What changed:

- 0225: `PLAYPORT_SC_LAYOUT` is read once at boot. A layout play whose boot cannot hold every slot is now
  refused in `virtual_init` (`[sc-layout] … launch refused`, `exit(1)`), not run on the host's moved map.
- 0226: routing checks `ppsc_ready` first (no `getenv` per allocation). The subject says
  `SocialClubHelper.exe`: the helper is matched by name, because 0150's exact-build verdict is a thread-local
  of the child's first thread, cleared once its image is mapped. A grant refuses a slot that overlaps a Wine
  reserved area (none do on iOS) and otherwise places its view with no-replace `VM_FLAGS_FIXED`, so a native
  mapping that takes the slot between hold release and view placement makes the grant fail with
  `STATUS_NO_MEMORY`, untouched. The V8 cage, like Oilpan, is granted only to the helper holding both core
  pools (every logged layout play asked for it after both). `ppsc_free` requires a current PEB.
- PLA-482 and retained-extent diagnostics, no new refusals: per-kind limited lines for helper commits in a
  reported tail, Oilpan commits below its report + 16 GiB, operations aliasing another slot the same helper
  owns; at owner exit a kept slot view with its owner and committed runs/bytes/highest end. New 0227
  (`Class: diagnostics`) logs `[proc-end] keep-ref …` naming the parked register that keeps a view.
- wine-pe 0055 `Class: ios-port`, patch-id unchanged. `wine_host.c`: `SC_LOW_SIZE` in error paths; a retry
  says the low hold went with an earlier attempt instead of "not held at exec".

Phone, one locked session each, same IPA:

- Hollow Knight (`app-367520`) first-frame+10 passed: first frame +11.33 s, RW alias `0x7000000000`
  (run `$PLAYPORT_BUILD/ui-runs/20261030T104015`).
- Heavy-VA smoke: Witcher 3 (`app-292030`, the intended title) is not installed and the phone has 3.4 GB
  free, so the supervisor chose Red Dead Redemption 2 (`app-1174180`) on dev defaults, layout off.
  First-frame+60 passed: first frame +85.14 s, the game's 8960 MiB jumbo hold at `0x79d0000000`, RW alias
  `0x7000000000` from the exec-time low hold, no `[sc-layout]` line, no `NO GAP FITS`, Launcher.exe exit 0,
  RDR2.exe kept running; the final screenshot shows the RDR2 title menu. The eight `[store-noalias]` lines at
  `libegl.dll` also occur in the l1 and l4 runs. 18 `[proc-end] keep-ref` lines appeared (0227).
  Run `$PLAYPORT_BUILD/ui-runs/20261030T104204`.

Not checked: any layout play (`PLAYPORT_SC_LAYOUT=1`), so the fail-closed boot, grant and diagnostic paths
were compiled and host-tested but did not run on the phone.

Review-2 fixes (0227 quiet under `MADEIRA_NO_DIAGNOSTICS` and prints `slot-view` for a freed slot view, 0226 tail line without the always-empty real-slot fields, 0055 re-exported, patch-id unchanged): dev IPA sha256 `fc42b29eff9fb1977a36783e95ba7ea0684509b3cc22593a3d4fbc2fbf87c6a1` (90 IPA checks); Hollow Knight first-frame+10 passed, first frame +12.04 s (run `$PLAYPORT_BUILD/ui-runs/20261030T112027`).

## l6: the second metadata slot

Commit `6213817` (madeira-unix 0228, PLA-476, [PLA-482](https://linear.app/playportdev/issue/PLA-482)): the
owner-approved disjoint ELF_META2 slot, real `[0x79c0000000, 0x7a00000000)` reporting the 16 GiB asked, for a
helper that owns ELF and no ELF metadata while another PEB owns kind 3. The RW alias is capped at 3 GiB
(`WINE_IOS_JIT_SIZE` ≤ `0xc0000000`, fail closed; the largest pool is `JitPool.maximumMB` = 896). **Kind 7 is now
ELF_META2 and a refused reserve logs `kind=8`** (l1–l5's `kind=7` refusals are historical). Operations past a
metadata kind's real end inside another slot the caller owns log `possible metadata overflow into kind=N`; a
straddle across real ranges is refused. The boot line names the spare. Dev IPA sha256
`d9612e9cb1b8fecb0dd02acd719fffd4a4cd62fe9ffc3ad4f94d011abeefd9f6` (90 IPA checks); full `pp test` passed
(tools/tests 822, PlayportKit 365).

One locked session, in-place install:

- Hollow Knight (`app-367520`) first-frame+10 **passed**: first frame +10.34 s
  (`$PLAYPORT_BUILD/ui-runs/20261030T113629-hk-p476l6`).
- RDR2 (`app-1174180`), keys `PLAYPORT_CEF_SWAP=0 PLAYPORT_SC_SINGLE=1 PLAYPORT_SC_LAYOUT=1`, run
  `$PLAYPORT_BUILD/ui-runs/20261030T113719-rdr2-p476l6`: first frame +39.56 s. No Story tab appeared, so the
  arm's deadline ended the run at launch +420 s (exit 143, SIGTERM). The log was pulled afterwards with
  `pp phone log` into the run's `pull/` (the app was not relaunched in between; nonce `ee22f009` at line 4).

Measured, line numbers in that `pull/s1-host.log`:

- 228: `RDR2 layout held: … FEX floor 0x7c40000000, second ELF metadata 0x79c0000000+0x40000000`.
- Launcher helper A (PEB `0x13da50000`): `grant kind=1/3/2/4` (45651–45942), `5` (54749), `6` (55174); no
  `grant kind=7`. Its PLA-482 lines: 16 `kind=3 … possible metadata overflow into kind=4` and 16
  `kind=4 … into kind=1` (first 45945, 46500). A ended with the launcher at the game's sign-in (+107.8 s,
  footprint 6341 MB): 131448 `keep-ref … view=0x7400000000+0x190000000 fate=2 tid=0208 ref#52/53=0x74000643e0`,
  131456 `kind=3 view kept`, 131457 `kind=3 committed runs=738 bytes=0x442b000 highest_end_off=0x8520000`, kinds
  1, 2, 4, 5 and 6 held again (131454–131460), 131461 `kept 8418 MB (5 view(s) …)`. Same shape as l5.
- The game's helper B (PEB `0x177954000`, child at 132027): `[sc-single]` preflight and verified browser
  (132011–132012). **136398 `grant kind=1`, 136400 `grant kind=7 … report=0x79c0000000+0x400000000
  real=0x79c0000000+0x40000000`** where l5 refused it; then `grant kind=2` (136458) and `kind=4` (136461) from
  libcef's TLS initialisation. No `chrome_elf.dll failed to initialize` (l5: line 138958) and no `refused
  reserve` at all.
- 137055: `refused memory operation owner=0x177954000 addr=0x7400002000 size=0x1000: outside owned real range`.
  The caller is libcef: guest RIP `0x73e5bb580b` = libcef RVA `0x1ea580b` (libcef at `0x73e3d10000`, 133952),
  `RDI=0x7400002000`, `R14=0x7400000000`, `R13` in libcef's data (137063–137065). The refused commit is followed
  by the trap at that RIP (`int3; ud2`, `[generated-fault-window]`), then 137091 `Unhandled exception 0x80000003 in thread 528`.
  B exits with no kept slot: `slot-view … 0x79c0000000+0x40000000 fate=0` (137240) and kinds 1, 2, 4, 7 held
  again (137244–137247).
- In A the same addresses were committed and accepted, because A owned kind 3:
  `op=0 0x7400002000+0x1000 in reported extent of kind=2 off=0x400002000 lands in its own kind=3 real range`
  (47461–47478; l5's A the same at 46596).
- `NO GAP FITS`: 26 from A's V8 sandbox probes (`[jumbo#1–40] peb=0x13da50000`, 55090–56000) and one for the
  game's 8960 MiB ask (78113), which the holdback then serves at `0x75d0000000` (78117–78118). l5 had 27. None from
  B. No `[soft-pool]` line.
- Footprint peak `fpMB=6328` (129174, the launcher's last seconds); xs1 7343 MB, l5 6307 MB. No jetsam and no
  app crash; the app ran until the arm's SIGTERM.
- Screenshots (`$PLAYPORT_BUILD/agent-notes/pla476/p476l6/shots/`, not committed): dark (loading) and black frames
  until about +106 s, then from about +129 s to the end **"SOCIAL CLUB ERROR — Social Club failed to initialize. Error
  code: 17"** with Accept/Cancel. Nothing was pressed (`landing: no Story tab seen; nothing pressed`).

Inferred, not shown: B's libcef uses `0x7400000000` as a pool base although B never received that address; it
was A's kind-3 report. Candidates: the address is derived from another pool rather than taken from the 16 GiB
reservation's result (`0x7800000000 − 16 GiB`, kind 1's report; or `0x7000000000 + 16 GiB`, inside kind 2's
report), or it is state B did not create. Either way a disjoint second slot is not used where libcef looks, and
kind 3's report address is load-bearing for the next helper. Next: read libcef around RVA `0x1ea580b` and the
code that sets `R14` on the workstation (HOST-DEBUGGING), before any new slot geometry.

Gates: HK first-frame+10 passed. The game's helper gets past l5's ELF_META refusal and chrome_elf initialises,
but the browser does not start (libcef CHECK) and the game shows Social Club error 17: no Story, no cabin. No
`NO GAP FITS` or soft grant from B, but A's 26 V8 `NO GAP FITS` remain (as in l1–l5). Memory ±10 % of 7343 MB is
not comparable without the cabin.

## l7: wait detach (decision 0166)

Commit `9611a34` ([decision 0166](../decisions/0166-detach-a-parked-threads-wait-then-unpin-its-view.md),
madeira-unix 0229, wine-unix 0202, 0227 now listing every parked ref): at a teardown each fully captured parked
thread's alert wait leaves the shared `RtlWaitOnAddress` queue and the waiter registry, and a view only such waits
named takes an unnamed view's fate. Dev IPA sha256 `5b38a50b857856f0c9f75f7badfe8682911a2764c7023712f377b6401f77d27e`
(90 IPA checks); full `pp test` passed (tools/tests 826, PlayportKit 365).

One locked session, in-place install (`.work/agent-notes/pla476/l7.sh`):

- Hollow Knight (`app-367520`) first-frame+10 **passed**: first frame +11.61 s
  (`$PLAYPORT_BUILD/ui-runs/20261030T122623-hk-p476l7`).
- The Witcher 2 (`app-20920`, i386): launcher first window +12.33 s, then the pad's A started `bin\witcher2.exe`,
  which faulted exactly as in the [2026-10-29 evidence](2026-10-29-witcher2-launch.md) (`i386 exception c0000005 at
  eip 02926f76`, `ecx 81625776`, `ebx 7ff00000`) and the "Program Error" box showed over the launcher, 60 s later
  too. Same outcome, no new crash. Its processes are i386, so their views are kept (`[view-owner] … i386, its views
  are kept`) and no `wait-detached` line appears (`$PLAYPORT_BUILD/ui-runs/20261030T122712-w2-p476l7`, log in
  `pull2/`).
- RDR2 (`app-1174180`), keys `PLAYPORT_CEF_SWAP=0 PLAYPORT_SC_SINGLE=1 PLAYPORT_SC_LAYOUT=1`, STORY_BY=420
  UNTIL=600 WAIT=900, run `$PLAYPORT_BUILD/ui-runs/20261030T122917-rdr2-p476l7`: first frame +39.60 s, the Story tab
  shown and pressed, then iOS ended the app at the 8192 MB limit during Story's loading (below). The run's own pull
  holds the log.

Measured, line numbers in that `pull/s1-host.log`:

- **Detaches:** 25 `wait-detached` lines in five teardowns, 24 `node=unlinked` and one `node=absent` (tid 018c,
  whose wait was in FEX's band), no `busy`. The launcher helper A (PEB `0x145048000`, pid 0x184), ended with the
  launcher at the game's sign-in (+104.2 s): its 10 parked threads at 132319–132328, among them **tid 0200
  `CompositorTileWorker1` (48670), `wait=0x7402240b30 node=unlinked`** (132326; parked at 131816 with
  `futex=0x141a401fc`), and the older threads 01a0 (`wine_threadpool_worker`, `0x70334dc938`) and 018c.
- **Kind 3 freed:** 132340 `wait-only peb=0x145048000 view=0x7400000000+0x190000000 fate=0`, then 132341
  `slot-view … fate=0 no parked ref`: with the waits dropped, no saved address of any parked thread, of any process,
  lies in kind 3. That closes l5/l6's older-thread gap for this run: 01a0 and 018c have no ref in it, and the 0227
  lines now list every parked ref (for example 132331 `keep-ref … 0x706f160000+0xfd0000` names three threads).
  132348–132353 **kinds 1–6 all held again**, kind 3 included. 132354 `kept 2124 MB (5 view(s) …)`; l6's A kept
  8418 MB. All 10 `wait-only` lines: 7 freed (fate 0, both kind-3 views among them) and 3 band views emptied (fate
  1), in A, Launcher.exe (`0x1407dc000`), an early exited child (`0x141a0c000`, 25196) and B.
- **The registry was cleared:** the last `[waiters] tid=0200` dump is at 130971 (9 in all, before the teardown);
  l6 had 168 dumps of tid 0208 up to 400 s.
- **The game's helper B** (PEB `0x15fdf0000`, pid 0x550, child of RDR2): 137540 `grant kind=1`, **137542
  `grant kind=3 … real=0x7400000000+0x190000000`** (the kind itself, not kind 7), then kinds 2, 4 (137585, 137588),
  5 (144768) and 6 (145056), as A got them. No `refused memory operation`, no `refused reserve`, no `chrome_elf.dll
  failed to initialize`, no `Unhandled exception` and no `generated-fault-window` in B. B ran its own compositor
  (tid 05e0 `CompositorTileWorker1`, 140402). The game's session root ended B at +224.4 s by the footprint rule
  (160594, decisions 0133/0153). Its teardown detached 7 waits (05e0's `0x7400013fd0` in kind 3), freed its kind 3
  (161113) and held kinds 1–6 again; 161127 `footprint 7623->7073 MB`.
- `[lock-orphan]`: three `SKIP 0x7c88fab2a0 … incoherent-as-SRW` lines at 55258–55260, in A's V8 probe, before
  any detach; none after. No hang: the game went on to Story.
- **Story:** the Story/Online menu was shown at about +121 s and A was pressed on Story at +134 s
  (`landing-123144.png`: the black menu with "Story" underlined and "Online" beside it). The 15-second screenshots
  then show the Story loading screen, a sepia tintype of snowy pines and cliffs with the loading spinner, at +220 s;
  the last one, at +258 s, is the phone's Home Screen. The cabin was not reached.
- **Memory:** footprint 6406 MB at +182 s, 7584 MB at +220 s, `fpMB=8030` at +229 s (161499); the phone's log:
  `memorystatus: S1Probe … exceeded mem limit: ActiveHard 8192 MB (fatal)` and `per-process-limit … 238s
  8387538KB` at 12:33:36, so the peak was the 8192 MB limit. xs1's peak was 7343 MB: at least +11.5 %, outside
  ±10 %. No crash report.
- `NO GAP FITS`: 89 lines. 26 from A's V8 sandbox probes (tid 0270, as in l6), 26 from B's (tid 0634, with B's
  `[jumbo#…] peb=0x15fdf0000` lines), one for the game's 8960 MiB ask (77697, served by the holdback at
  `0x75d0000000`), and 36 from i386 `dllhost.exe` (COM surrogate) starts whose WoW64 window found no 4 GiB gap
  (`[wow64-window] no fixed slot free: first fit failed`; requested by A's tid 01c8, 7, and B's tid 0594, 30). In l6
  the one such start fitted (123620). No `[soft-pool]` line.

Inferred, not shown: the extra memory is RDR2's Story load with the game's own Social Club now fully running
alongside (B was ended only at +224.4 s, after the 120 s rule, and freed 550 MB); the kept and freed views of the
teardowns are not it (A's teardown lowered the footprint 6649→5886 MB). The `dllhost.exe` window failures are the
map at that time, not decision 0166: a release only gives address space back, and the first failure (126074) comes
before the launcher's end.

Gates: HK first-frame+10 passed; The Witcher 2 unchanged. The game's helper gets kind 3 and reaches
allocator/browser startup with no refusal — **passed**. The game signs in and Story is pressed — **passed**; the cabin
— **not passed** (jetsam at 8192 MB during Story's loading). No SC/launcher `NO GAP FITS` or soft grant — **not
passed** (52 V8 probe lines from A and B, 36 i386 `dllhost.exe` window failures; no soft grant). 7343 MB ±10 % —
**not passed** (the limit was reached).

Amended 2026-10-30 (owner): a band view only detached waits named is now freed, the no-parked fate, not emptied
(l7's 3 `fate=1` views). Dev IPA sha256 `4f5f3b7cd32c6060f76e0c42188bed37ca62f72cc88c44b778d7e311f4cab4f2`, full
`pp test` passed; Hollow Knight first-frame+10 **passed**, first frame +10.86 s
(`$PLAYPORT_BUILD/ui-runs/20261030T125728`, no teardown in it); no RDR2 run with it yet.

## l8: component update off, pool diagnostics

Commit `fe20a23`: madeira-unix 0190's verified-browser rewrite appends `--disable-component-update` unless present
([decision 0150](../decisions/0150-dev-single-process-social-club.md), amended by the owner 2026-10-30);
madeira-unix 0230 and wine_host ABI 12 give a dev build a `[proc-mem] after teardown N` walk at the first 2 s sample
after each finished teardown; the donor pool's stats line gives the growth check's `level=`, `level_floor=`,
`level_resume=`, `spare_mb=` and, while stopped, `resume_wait=`; a `growth resumed` line gives its reason. Dev IPA
sha256 `2412a5150c97e1af9ef6b56dfb8627ea7ec9e5496f28a8efd517933eb167e71c` (90 IPA checks); full `pp test` passed
(tools/tests 827, PlayportKit 366). It also carries `7db5c9c` (a band view freed of its wait pins takes the
no-parked fate), whose first RDR2 run this is.

One locked session, in-place install (`.work/agent-notes/pla476/l8.sh`):

- Hollow Knight (`app-367520`) first-frame+10 **passed**: first frame +10.69 s
  (`$PLAYPORT_BUILD/ui-runs/20261030T132206-hk-p476l8`).
- RDR2 (`app-1174180`), keys `PLAYPORT_CEF_SWAP=0 PLAYPORT_SC_SINGLE=1 PLAYPORT_SC_LAYOUT=1`, STORY_BY=420
  UNTIL=600 WAIT=900, run `$PLAYPORT_BUILD/ui-runs/20261030T132255-rdr2-p476l8`: first frame +40.66 s, sign-in
  +102.2 s, Story pressed at 13:25:22 (about +121 s on the `[xp]` clock), then the run's own end at first
  frame+600 s with no jetsam. The cabin was not reached.

Measured, line numbers in that `pull/s1-host.log`, times on the `[xp]` clock:

- **No BITS activation:** 0 `dllhost`, 0 `size=0x100010000`, 0 `{4991D34B…}`, no rpcss start; RpcSs stays
  `listed, stopped` (7201). Both `[sc-single] verified browser` lines (40262 for the launcher's helper A, 129904
  for the game's helper B) end `… no proxy unless supplied, component update off`. A ran from +24.8 s to its end
  at +103.1 s, past the ≈63 s at which l1/l7's updater first asked for BITS. The rewritten command line itself is
  not logged.
- **Other `NO GAP FITS`:** 27. 26 are A's V8 sandbox probes (the `[jumbo#…] peb=0x144f2c000` asks, 54697–55269, as
  in l6/l7) and one is the game's 8960 MiB ask (77461, served by the holdback). None from B: it never got that far.
- **Teardowns (7db5c9c exercised):** 16 `wait-detached`, all `node=unlinked`; 5 `wait-only`, all `fate=0`,
  among them a FEX band view, `0x7c4df00000+0x100000` (129115, the launcher's): freed, not emptied, as `7db5c9c`
  intends. No `fate=1`. A's kind 3 (`0x7400000000+0x190000000`) freed (129143–129144).
- **The layout lost its kind 2:** at A's teardown (+103.1 s) all of A's slot views were freed (`slot-view … fate=0`,
  129134–129144), then 129151 `owner 0x144f2c000 exited; kind=2 slot NOT held again (something mapped it)`.
  Kinds 1 and 3–6 were held again. Kind 2 is the CEF slot, `0x7000000000+0x10000000`. Between its release and the
  re-hold, something native took part of it; no Wine view there is logged. In l5–l7 the same release was always
  followed by `held again` (5 times); this is the first miss.
- **The game's helper B died in its init:** started at 129894 (pid 04f4), its PEB at `0x7000924000` and image at
  `0x7000930000`, inside the lost kind-2 range. It got **no** `grant`; its six image protections were refused
  (130026–130031 `refused memory operation owner=0x7000924000 … outside owned real range`), its first write to its
  image's data faulted (130032 `bus-data-av … region=0x7000930000+0x1cc000 prot=1`, then `c0000005`), and it ended
  `0xc0000005` (130058). The game's later helper starts were refused by decision 0138 (`[game-sc] refused the
  game's Social Club helper start 2`, then more, 108 `SocialClubHelper.exe` creates from RDR2 in all); no re-sign-in
  came, so 0155 allowed none.
- **Story:** the screenshots show the Story/Online menu (+126 s from launch), the sepia tintype loading screen of
  snowy pines (+145 s), a darkening frame (+164 s), then from +203 s to the end only black with Rockstar's small
  orange loading icon in the corner; the last one is the Home Screen after the run ended. The cabin was not reached.
  The game's Social Club end never fired (the footprint stayed under 6992 MB).
- **Memory, aligned on the press (+121.4):** `[footprint]` phys/graphics at press−29 5823/1389, press−18 (just
  after A's teardown) 5052/1752, press 5094/1750, +20 5035/1752, +48 5270/1923, +60 5555/2160, +70 6050/2422,
  +80 6453/2646, then flat at 6448–6493 to the end (graphics 2642–2646). No step like xs1's or l7's (≈1.1 GB of
  graphics in under 1 s). Peak `fpMB=6496` at +641.6 s (154101), **−11.5 %** against xs1's 7343 MB. No jetsam
  line for S1Probe in the phone log; no crash report.
- **Teardown footprint, now with a post-teardown sample:** the launcher, a child and A were torn down at +103.1 s
  (129121 `6150->5957`, 129130 `5957->5943`, 129156 `6150->5055`; the two `6150` readings overlap); `fpMB` went
  6159 → 5049 in 0.3 s. `[proc-mem] after teardown 4` (130217, +105.6 s) against the last sample (125647, +94.0 s),
  resident+compressed: A (pid 0184) 1132 MB and the launcher (0070) 265 MB gone; the runtime row 200 → 281 MB
  (+81: the two processes' kept views; image 154 → 156, so no image view was kept, unlike l7's 240 MB libcef);
  RDR2.exe 758 → 2244 MB (its own load in those 11.6 s). `after teardown 5` (131671) follows B's exit (0 MB:
  `exited: freed image=0 private=1`), `after teardown 6` (132494) a small child's (runtime private 2670 → 2666).
- **Donor pool:** stats lines now carry `level=`. It fell from 35 % (+30 s) to 22 % (+90 s), 15 % (+180 s), and
  135451 `pressure: growth stopped (level 14% < 15%) spare_mb=3944` at +188.0 s (press+66.6) with 2954 MB live; it
  never resumed: every later line has `resume_wait="level N% < 20%"` with N 9–14, spare 3777–3996 MB (over the
  1920 MB the resume needs). Pool resident+compressed at install+210s 2544 MB (l7 2096, xs1 2733); live 3025 MB from
  then on. l7 stopped at +97.4 (level 13 %, 2582 live), xs1 at +193.2 (press+70, 3217 live).

Inferred, not shown: the lost kind 2 is a host allocation landing in the freed 256 MiB between its release and the
re-hold (the window is a few log lines long; the graphics footprint rose 1389 → 1752 MB around then); B then had
nowhere of its own and the layout refused its image. B's death, not memory, stopped Story's load: without the
game's Social Club the load waits on a black screen, as l5 did. The pool's stop is jetsam's system level, not the
spare memory: the level stays under 20 % while 3.8–4 GB are spare, in this run as in l7.

Correction to l1 above: the helper's own COM (combase) starts `syswow64\dllhost.exe` as a surrogate after rpcss
reports the class not registered; rpcss does not start it.

Gates: HK first-frame+10 **passed**. No `dllhost`/WoW64 `NO GAP FITS` — **passed**; V8 probe lines remain (26,
A only). The game's helper reaches allocator/browser startup — **not passed** (kind 2 not held again, B refused and
dead in init). The game signs in, Story is pressed — **passed**. The cabin — **not passed** (black loading screen
without the game's Social Club). 7343 MB ±10 % — **not comparable** (peak 6496 MB without the cabin or Story's
step).

## l9: slots held in place

What took kind 2 in l8 (its `pull/s1-host.log`): the release (129134 `slot-view … 0x7000000000+0x10000000
fate=0`) and the re-hold (129151) run in one `virtual_mutex` hold (`ios_proc_end_release_views_locked` deletes the
views, then calls `ppsc_owner_died_locked`), so no Wine allocation fits between them; B's PEB came much later
(129894). No log line names the mapping. Measured: once kind 2 was free, the kernel's anywhere placement used it,
as the dev `[ca-shmem-probe]`'s plain `mach_vm_allocate` got `0x7000b74000` (131286) and later `0x7000e5c000`…;
before the teardown the same probe got `0x14…`/`0x15…` addresses. Inferred: a native anywhere allocation from
another thread (not Wine's allocator) took the start of the range, `0x7000000000`…`0x7000924000`, in the
≈70 ms between the munmap and the re-hold; Wine then placed B's PEB and image above it.

Commit `2df65fe`: madeira-unix 0231. A freed view that is a whole slot view of the dead owner is released and held
in one step: the slot's PROT_NONE hold is mapped over it (`mach_vm_map` with `VM_FLAGS_FIXED |
VM_FLAGS_OVERWRITE`, which discards the pages), then the view is deleted without an unmap (`[sc-layout] owner …
exited; kind=N slot held in place`). Both teardowns (killed, and exited by itself, 0143) and 0166's wait-only views
go through the one view walk that does it; an owner's whole-grant release (`ppsc_free`) does it too. If the hold
cannot be mapped over, the old free-then-hold path runs, with its `held again`/`NOT held again` line. Host tests:
`tools/tests/test_sc_vm.py` `owner_held_in_place` (in place for slot views only, never unmapped, a second helper
gets the same kinds, the fallback) and the free cases. Dev IPA sha256
`9cdc96353899291d7e3fddca1e89551d7d900d1d6e8fe5d06255fe2cba352846` (90 IPA checks); full `pp test` passed
(tools/tests 828, PlayportKit 366).

One locked session, in-place install (`.work/agent-notes/pla476/l9.sh`):

- Hollow Knight (`app-367520`) first-frame+10 **passed**: first frame +10.32 s
  (`$PLAYPORT_BUILD/ui-runs/20261030T135842-hk-p476l9`).
- RDR2 (`app-1174180`), keys as l8, run `$PLAYPORT_BUILD/ui-runs/20261030T135937-rdr2-p476l9`: first frame
  +38.38 s, sign-in +101.8 s, Story pressed at 14:02:24.1 on the phone (`vpad` 146856, +130.9 on the `[xp]`
  clock), then iOS ended the app at the 8192 MB limit in Story's load step (below). The run's own pull holds the
  log; its result is `the app exited before the stop condition`.

Measured, line numbers in that `pull/s1-host.log`, times on the `[xp]` clock:

- **Slots:** at A's teardown (+103.3) six `owner 0x13fdd0000 exited; kind=N slot held in place` lines
  (129461–129478: kinds 2, 4, 6, 5, 1, 3), each right after its `slot-view … fate=0` line; kind 3 came through 0166's
  `wait-only … 0x7400000000+0x190000000 fate=0` (129474). No `held again`, no `NOT held` anywhere.
  A's teardown: `footprint 6353->5165 MB` (129483), so the pages were discarded. The dev probe's later plain
  anywhere allocations landed above the slots (`0x7015878000` at 145210, `0x703ae24000` at 149971).
- **The game's helper B** (PEB `0x1791f8000`, pid 04fc, 130255): `grant` kinds 1, 3, 2, 4 (134588–134633), 5
  (141553) and 6 (141886), each at its real range; no kind 7 (nothing was kept). 0 `refused memory operation`, 0
  `refused reserve`. `[sc-single] verified browser … component update off` (130212), libcef mapped (132134),
  chrome_elf (133427), no `failed to initialize` or unhandled exception; its `Chrome_IOThread` (135762),
  `CrBrowserMain` (135909) and `CompositorTileWorker1` (137463) started. B was alive to the end (no teardown; the
  `[proc-mem]` sample at +199.2 gives it 579 MB resident+compressed).
- **Story:** the screenshots (`.work/agent-notes/pla476/p476l9/`, seconds on the `[xp]` clock, ±2 s) show the
  Story/Online menu with Story underlined (the landing shot before the press), the sepia tintype loading screens of
  a snowy ridge (+141) and snowy pines (+161), a darkened blurred frame (+180), black with a small loading icon at
  the bottom right (+199), then the Home Screen (+225). The cabin was not reached.
- **The load step and jetsam:** `fast phys` 7174 (+208.7, 151719) → 7744 → **8106 MB** (+209.1, 151729/151739),
  with the phone's `IOGPUCommandDescriptor::prepare` faults for S1Probe (required ≈2.2 GB wired) at 14:03:43.02–.06;
  the host log ends there. The phone's log stream dropped at 14:03:43 and resumed 2 s later, so no `ActiveHard` line
  was captured; ReportSystemMemory then lists `Process S1Probe [7314] killed by jetsam reason per-process-limit`.
  No crash report.
- **Footprint aligned on the press (+130.9), `[footprint]` phys/graphics:** press−29.6 6307/1753; −27.3 (after the
  teardowns) 5149/1798; 0 5769/1849; +21 5711/1851; +47 6019/2048; +61 6160/2143; +70 6585/2269; +76 7054/2494;
  +78 7072/2494, then the step above at **press+78.2** (sign-in+107.3). l7's step came at press+94.2, xs1's at
  press+102.2 (sign-in+132.8). Peak at least 8106 MB, the limit: **≥ +10.4 %** against xs1's 7343 MB.
- **The game-SC end** (decisions 0133/0153: 120 s after the sign-in and 6992 MB) could not fire: the footprint passed
  6992 at +205.2 (title line), but sign-in+120 s is +221.8, after the step. In l7 it ended B before the step (−550
  MB), in xs1 inside it (−250 MB).
- **Donor pool:** `growth stopped (level 13% < 15%)` at +93.8 (127216, spare 4105 MB), `growth resumed (level 20% >=
  20%, spare 4770 MiB >= 1920)` at +103.6 after the teardowns (129877), stopped again at +107.4 (141747, level 13 %);
  never resumed after (`resume_wait="level 11–16% < 20%"`, spare 4064–4434 MB). Live 2327–2502 MB; resident+compressed
  2074 MB at install+180s (l8 2544 at +210, xs1 2733).
- **Post-teardown `[proc-mem]`:** `after teardown 4` (129650, +103.3) against the sample at +100.3 (128145),
  resident+compressed: A (pid 0184) 1102 MB, the launcher (0070) 341 MB and a child (0064) 22 MB gone; the runtime
  row 183 → 235 (+52; image unchanged, so no image view kept); RDR2.exe 2246 → 2250; all 4184 → 2762 (−1422).
  `after teardown 5` (147536) follows a small child's exit (`5749->5732`).
- **`NO GAP FITS`:** 53. 26 are A's V8 sandbox probes (54735–55295, `[jumbo#…] peb=0x13fdd0000`), 26 are B's
  (141713–143037, `peb=0x1791f8000`), one is the game's 8960 MiB ask (78008, served by the holdback). 0 `dllhost`.
- **Teardowns:** 17 `wait-detached` (16 `node=unlinked`, 1 `absent`); 8 `wait-only`, all `fate=0`; no `fate=1`.

Inferred, not shown: with its Social Club up, Story's load reaches the same step as xs1 and l7 (≈1 GB in under a
second, its graphics wiring) but from a baseline about 1.1 GB above xs1's (7174 against 6072 MB) and before 0153's
end can take B off; the step then crosses 8192 MB. The baseline gap is not split per process here (no `[proc-mem]`
for xs1).

Gates: HK first-frame+10 **passed**. The game's helper reaches allocator/browser startup — **passed** (all six
kinds, no refusal). The game signs in, Story is pressed — **passed**. The cabin — **not passed** (jetsam at the
8192 MB limit in Story's load step). No SC/launcher `NO GAP FITS` or soft grant — **not passed** (26 V8 lines each
from A and B; 0 `dllhost`; no soft grant). 7343 MB ±10 % — **not passed** (≥ 8106 MB, the limit).
