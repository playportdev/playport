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
