# 2026-10-29: Social Club on Rockstar's own CEF, with and without single-process (PLA-476 chunk 1)

**Linear:** [PLA-476](https://linear.app/playportdev/issue/PLA-476),
[PLA-477](https://linear.app/playportdev/issue/PLA-477), [PLA-364](https://linear.app/playportdev/issue/PLA-364).
**Plan:** [2026-10-29-sc-stock-cef.md](https://linear.app/playportdev/issue/PLA-476), chunk 1.

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

## d1: same-IPA default baseline

The owner (2026-10-30) asked for a baseline before any change to the game-SC end (0141/0153): RDR2 on l9's IPA
with the dev default Social Club, so that l9's memory can be split per process against a run of the same shape.

- **IPA:** the installed `9cdc96353899291d7e3fddca1e89551d7d900d1d6e8fe5d06255fe2cba352846` (l9's), no reinstall.
- **Keys: `env.PLAYPORT_SC_SINGLE=1` only.** That is xs1's configuration (RDR2's defaults plus single-process), not
  the no-key dev default. Single-process is not a default: `pp_sc_single_enabled` takes only `PLAYPORT_SC_SINGLE=1`
  and is compiled out of release (0150, 0153; the plan's chunk 4 that would make it default is not done).
  `compat-defaults.json` gives RDR2 only `graphics: vulkan`. With no keys at all, the helper runs multi-process
  (7 helpers, as d2–d5/nd1), which is not l9's or xs1's process shape. The supervisor chose xs1's configuration so
  that the split against l9 compares the same shape. With `PLAYPORT_CEF_SWAP` and `PLAYPORT_SC_LAYOUT` unset,
  Playport's CEF is used (`[cef-swap] … libcef.dll file version 143.0.14.0 matches; its CEF files come from
  Playport's build`, 39120) and no layout runs (0 `[sc-layout]` lines). The other settings are the defaults: donor
  pool Auto, the launcher's end at the sign-in, the game-SC end at sign-in+120 s and limit−1200 MB, 0138's
  refusals and 0155's re-sign-in restarts.
- **Run:** `$PLAYPORT_BUILD/ui-runs/20261030T141431-rdr2-p476d1`. The script is `agent-notes/pla476/d1.sh`, which
  is l9's arm with `STORY_BY=420 UNTIL=600 WAIT=900` and one locked session. Before it, `pp phone status`: 80 % on
  power, 3.2 GB free, no holder. The result was `ok:false`, `the app exited before the stop condition`.
- First frame +33.31 s. The game signed in at +95.4 s (title clock; the log line is at `[xp]` +96.4). Story was
  pressed at `[xp]` **+123.5** (`vpad` 139809). Thermal went nominal → fair → serious.

Measured below, with line numbers in `pull/s1-host.log` and times on the `[xp]` clock. Footprints are
`[footprint]` phys/graphics/compressed MB, or `[xp]` `fpMB` where marked. `[proc-mem]` values are
resident+compressed MB.

**Footprint aligned on the press:**

| press+ | d1 (press +123.5) | l9 (press +130.9) | xs1 (press +120.9) |
| --- | --- | --- | --- |
| before the teardowns | −27.2: 5863/1732/842 (123351) | −29.4: 6307/1753/1067 (128268) | — |
| after the teardowns | −25.2: 5111/1740/535 (129485) | −27.3: 5149/1798/575 (129841) | — |
| ≈0 | +1.2: 5348/1794/515 (139865) | −1.1: 5772/1849/679 (146813) | −1.8: 5232/1827/923 (119687) |
| ≈+20 | +19.2: 5044/1795/504 | +21.1: 5711/1851 | — |
| ≈+46 | +45.8: 5388/2022/518 | +47.4: 6019/2048 | — |
| ≈+60 | +60.1: 5680/2132/843 | +61.4: 6160/2143 | — |
| just before the step | +74.3: **6470**/2454/1163 (144572) | +77.8: **7072**/2494/1417 (151694) | +99.8: **6071**/2409/1091 (126170) |
| the step | +74.8: 7689/3617/1492 (144651) | +78.2: fast 8106, then jetsam | +104.4: fast 6478 → 7169 (126407–126425) |
| after the step | peak `fpMB` **7896** at +86.3 (145106) | — | peak 7343 at +145.1 (129630) |

- **The step's timing:**

  | Run | Step | press+ | sign-in+ |
  | --- | --- | --- | --- |
  | d1 | +198.1 (`fpMB` 6469 → 6622 → 7689) | 74.6 | 102.7 |
  | l9 | — | 78.2 | 107.3 |
  | xs1 | — | 104.4 (l9's section gives 102.2 from another press reference) | 132.8 |

  The sign-in is on the title clock, the step on `[xp]`: ±1 s.
- **The step is graphics:** +1219 MB in under 0.5 s, of which graphics is +1163 (2454 → 3617).
- **Peak in the step: 7896 MB, +7.5 % against xs1's 7343** (inside ±10 %), 296 MB under the limit.

**The game-SC end (0141/0153):**

- **First end:** at +221.6 (145329: `the footprint reached 7834 MB … at +221.2 s`, sign-in+125.8), after the step.
  B (pid 04c4) was killed: `footprint 7872->7624 MB` (145828, −248). The phone then showed 7570–7610 MB.
- **What followed:**
  - 0138 refused B's restarts 2–9.
  - 0155's steam-language detector saw a re-sign-in at +258.1 (148357) and allowed restart 10 (+263.1, 148613).
  - The new helper (05b8) signed in at +283.9 (162404). The footprint rose 7621 → 8152 (+284.1, 162620) and stayed
    at 8123–8155.
  - **Second end** at +404.8 (169356, `8132 MB`): `8124->7809 MB` (169816).
  - A second re-sign-in came at +435.3 (172539). Restart 18 was allowed at +440.1 (172772).
  - Its helper (pid 0690) had 399 MB at +445.2 (183428). `fpMB` reached 8191 at +446.1.
- **Jetsam:** `memorystatus: S1Probe [7676] exceeded mem limit: ActiveHard 8192 MB (fatal)` at 14:22:34.78 (syslog
  79786), then `killed by jetsam reason per-process-limit` (81590). There is no crash report.

**The cabin, from the screenshots** (`.work/agent-notes/pla476/p476d1/shots/`; `[xp]` ≈ shot − 10 s, ±2 s;
described only):

- ≈+142 to ≈+162: sepia loading tintypes (mountains, then a barn).
- ≈+181: a dark sepia frame of a man by the cabin, with the loading icon.
- **≈+201: the cabin, rendered.** Arthur sits at a table inside the log cabin, by the window, with snow outside.
- ≈+248: black. ≈+280: black, with the game's spinner at the bottom right.
- ≈+299 to ≈+423: the title menu again (RDR2 logo, the snowy range, `Story`/`Online`, `Settings · Social Club ·
  Story · Quit Game`).
- ≈+441: black with the spinner. ≈+458: the Home Screen.

So Story reached the cabin. After the first game-SC end, the game left the cabin for its title menu.

**Per process at the same phases** (`[proc-mem]`, resident+compressed MB; RDR2.exe as image/private/fex):

| Phase | Run (line, `[xp]`) | `fpMB` | graphics | RDR2.exe | A | launcher | B | runtime | child | services+PlayRDR2 | all |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| before A's teardown | d1 121417, +86.2 (sign-in −10) | 5500 | 1379 | 895 (57/341/497) | 1023 | 327 | — | 184 | 119 | 112 | 2685 |
| | l9 128145, +100.3 (sign-in −2.6) | 6373 | 1777 | 2246 (57/1718/471) | 1102 | 341 | — | 183 | 115 | 169 | 4184 |
| `after teardown 4` | d1 126843, +97.6 | 5097 | 1740 | 2264 (57/1724/483) | gone | gone | 11 | 263 | 118 | 88 | 2772 |
| | l9 129650, +103.3 | 5132 | 1798 | 2250 (57/1732/461) | gone | gone | — | 235 | 115 | 142 | 2762 |
| at the press | d1 139754, press −1.7 | 5355 | 1794 | 2314 (57/1733/524) | | | 481 | 277 | 118 | 95 | 3312 |
| | l9 144632, press −12.3 | 5807 | 1768 | 2288 (57/1732/499) | | | 596 | 251 | 115 | 145 | 3415 |
| just before the step | d1 144530, step −1.0 | 6457 | 2420 | 3129 (55/2771/303) | | | 449 | 265 | 118 | 54 | 4042 |
| | l9 151258, step −9.9 | 6499 | 2240 | 2904 (47/2413/444) | | | 579 | 239 | 109 | 95 | 3944 |
| after the step | d1 145282, +217.9 | 7858 | 3728 | 3164 (52/2790/322) | | | 338 | 259 | 118 | 53 | 3958 |
| | l9: none (jetsam) | | | | | | | | | | |

Notes on the table:

- **A and B:**
  - A: d1 202/304/517 (image/private/fex); l9 296/276/530.
  - B at the press: d1 196/89/196; l9 293/50/253.
- **Teardowns** (the launcher, then A):
  - d1: `5870->5602` (124215) and `5868->4998` (124239), −872 in all.
  - l9: `6354->6075` and `6353->5165`, −1189 in all.
- **After the teardowns the two runs are 35 MB apart** (5097 against 5132).
- **The runtime row** went up by +79 in d1 and +52 in l9. Its image is unchanged in both, so no image view was
  kept.
- **The pre-teardown row is out of phase.** d1's last sample is 10 s before its sign-in, while RDR2.exe was still
  growing (429 → 640 → 895 over +76.7 to +86.2).

**Donor pool at the same phases** (live MB / resident+compressed MB, from the nearest `stats` line):

| Phase | d1 | l9 |
| --- | --- | --- |
| before A's teardown | growing; install+90 (+90.1): 2706 / 1915 | stopped at +96.3 (level 13 %); stats at the stop: 2587 / 1803 |
| after the teardown | growing; 2706 / 1915 | resumed at +103.6 (level 20 %), stopped at +107.4 (13 %): 2327 / 1867 |
| the press | growing; install+120 (+119.4): 2493 / 2083 | stopped; install+120: 2333 / 1876 |
| stop/resume | stopped at **+141.2, press+17.7** (140958, level 14 % < 15 %, spare 4260 MB): 2915 / 2529; no resume line in the run | (above) never resumed |
| just before the step | install+180 (+179.3): 2777 / 2292 | install+180: 2502 / 2074 |
| after the step | install+210 (+215.3): 2808 / 2327; `refused` 1 → 4627 | — |

Launch state of the phone (`donor-pool: setting=auto` line):

- d1: `sys_free_mb=1412`, `sys_level=43`.
- l9: `sys_free_mb=2530`, `sys_level=48`.

So l9 started with more free memory, yet its pool stopped 45 s earlier.

**The pre-step excess split.** l9 was 602 MB above d1 just before the step (7072 against 6470). Donor pages are
charged to the ended donor, not the app (ARCHITECTURE, donor pool). So:

```
footprint = graphics + [proc-mem] all − donor-backed (pool resident+compressed) + non-view memory
```

The last term (JIT pool, host and Metal heaps) is the residual.

| Component | d1 | l9 | l9 − d1 | M/I | Whose |
| --- | --- | --- | --- | --- | --- |
| `fpMB` at the press samples | 5355 | 5807 | **+452** | M | |
| graphics | 1794 | 1768 | −26 | M | game/phone, shared |
| B, the game's helper | 481 | 596 | **+115** | M | **stock CEF/layout** (image +97, fex +57, private −39) |
| RDR2.exe | 2314 | 2288 | −26 | M | game, noise |
| runtime row | 277 | 251 | −26 | M | noise |
| RDR2's child | 118 | 115 | −3 | M | noise |
| services (0020, 0028, 0034, 00e8) | 95 | 145 | +50 | M | not explained |
| exited rows + per-field rounding | 27 | 20 | −7 | M | |
| donor-backed (subtracted) | −2083 | −1876 | **+207** | I | pool state (l9 stopped at +96.3, d1 at +141.2) |
| non-view residual: JIT pool mapped (head+tail) | | | +48 | I | stock CEF/layout (more translated code: 777 against 729 MB, live 514 against 446) |
| non-view residual: the rest | | | +120 | I | not explained |
| **sum at the press samples** | | | **+452** | | |
| l9's drift from its sample (+118.6, `fpMB` 5807) to the press (`[footprint]` 5772; d1 5355 at both) | | | −35 | M | |
| load growth to the step: graphics (d1 +660, l9 +645) | | | −15 | M | shared |
| load growth to the step: non-graphics (d1 +455, l9 +655) | | | +200 | M total; split not measured | l9's last sample is 9.9 s before its step, and l9 grew 573 MB (graphics +254) in those seconds |
| **sum: excess just before the step** | | | **+602** | | |

How the residual and the sums work out:

- **Residual:** d1 5355 − 1794 − 3312 + 2083 = 2332; l9 5807 − 1768 − 3415 + 1876 = 2500, a difference of +168.
- **At the press samples:** −26 + 115 − 26 − 26 − 3 + 50 − 7 + 207 + 48 + 120 = 452.
- **Just before the step:** 452 − 35 − 15 + 200 = 602.
- **By owner:**
  - stock CEF/layout: 115 (M) + 48 (I) = **163**;
  - pool state: **207** (I);
  - shared graphics: −26 − 15 = −41;
  - process noise: −62;
  - services: +50;
  - not explained: +120 + 200 = **320**, of which 200 is load growth that no sample covers.
  - Sum: 163 + 207 − 41 − 62 + 50 + 320 − 35 = 602.

Inferred:

- **l9's step would have needed about 306 MB less.** d1's step rose 1426 MB from its pre-step 6470 to the 7896 peak.
  On l9's 7072 the same rise gives ≈8498, so l9 needed ≥306 MB less to fit, and ≈600 MB less for d1's 296 MB margin.
- **The pool part is phone and pool state, but not independent of l9.** The level rule is phone-wide, and l9
  started with more free memory. l9's own higher pre-sign-in footprint (6373 against d1's 5500–5863) plausibly
  pulled the level under 15 % sooner.
- **d1's whole-run jetsam is not the step.** 0155's allowed restarts brought a helper back at ≈7600–7800 MB twice,
  and each took about 400–530 MB.

**Other measured points:**

- 0 `NO GAP FITS`.
- 4 `[sc-single] verified browser` lines (A, B and the two restarted helpers).
- 34 `c0000005` lines.

**Gates:**

| Gate | Result |
| --- | --- |
| Story reaches the cabin | **passed**, on xs1's configuration and this IPA |
| Peak in the load step within 7343 MB ±10 % | **passed** (7896, +7.5 %) |
| Run without jetsam | **not passed**: jetsam at +446 after 0155's second allowed restart, from the title menu the game returned to after the first end |

Hollow Knight was not run in this session.

## l10: headroom for 0155, the footprint sampler, the pool's spare resume

The owner's decisions of 2026-10-30, as three commits, then one layout run with l9's keys:

- `b94a9eb`: [0155](../decisions/0155-allow-rdr2s-social-club-restart-after-a-re-sign-in.md) amended: a
  re-sign-in allows the helper's restart only when footprint + 600 MB < limit − 400 MB.
- `9289d2e`: a dev footprint-jump sampler (`Dev/FootprintJumpSampler.swift`, PlayportKit `FootprintJumpTrigger`,
  the dev-only `MemoryLedger` target). From limit − 2000 MB, at +300 MB over its last sample (5 s apart) or
  +300 MB in one 250 ms tick, it forces a `[proc-mem]` walk, a `donor-pool: stats` line and a `[fp-sample]` line
  (TASK_VM_INFO's other fields and the task's memory ledger).
- `c45af90`: [0105](../decisions/0105-memory-defaults-per-phone.md) amended: the donor pool also resumes on spare
  memory alone (≥ 1,920 MiB) under level 20 %; after such a resume at level R the level stop fires under R.

The FEX code-buffer roll (unexplained-320's reduction #3) was not changed: RDR2 asks for 128 MiB at its second
generation in every run, and d1 got 64 only because the pool's tail room was short then (`tail CAP: refusing
0x8000000 (cap 0x4000000 …)`, +73.82). Capping every game's buffer at 64 MiB is a runtime policy with a
measured cost (ml1052: retranslation churn when hot code does not fit), and a forced roll needs a new FEX request.
Neither is small; it is left for a decision.

- **IPA (dev):** `c635f8c00c3bcb55cf1618ef46a27ce16a0818e0532b7247492c47940481613e`, verify-ipa 90 passed.
- **Session:** `agent-notes/pla476/l10.sh`, one `pp phone lock` session. `pp phone status` before: 1 phone, 80 % on
  power, 3.1 GB free, no holder. In-place install (28 s, container kept).
- **HK first-frame+10: passed**, first frame +10.53 s (`$PLAYPORT_BUILD/ui-runs/20261030T152425-hk-p476l10`).
- **RDR2 l10:** `$PLAYPORT_BUILD/ui-runs/20261030T152516-rdr2-p476l10`, keys `env.PLAYPORT_CEF_SWAP=0
  env.PLAYPORT_SC_SINGLE=1 env.PLAYPORT_SC_LAYOUT=1`, `STORY_BY=420 UNTIL=600 WAIT=900`. Result `ok:false`, `the app
  exited before the stop condition`. First frame +43.82 s (title clock). The game signed in at +110.5 s. Story was
  pressed at `[xp]` **+148.6** (`vpad` step 1, 154735).

Times are on the `[xp]` clock and lines are in `pull/s1-host.log`. Values are measured (M) unless marked inferred (I).

**The sampler (M).**

- The ledger probe at the launch returned **rc=0**: the iOS sandbox lets a dev app read its own task ledger (2520).
- It armed and fired at the sign-in peak, +107.25 (6227 MB). It fired on the level rule at **+212.00** (6531,
  step −8.3) and **+217.01** (6912, step −3.2), with walks of 1394 and 696 ms.
- **No sample landed inside the step.** The one-tick jump (7172 → 7721 at +220.49) came 2.4 s before the log
  ends. Its forced walk prints only when it finishes, and the app was ended first (I). The next version should
  log the cheap `[fp-sample]` line before the walk.
- **The ledger closes phys_footprint** at each sample:
  phys = internal + internal_compressed − alternate_accounting(+compressed) + graphics + page_table + iokit +
  purgeable + media. At +217.01 that is 5966 + 1480 − 2486 − 485 + 2399 + 11 + 1 + 20 + 10 = 6916, against
  6930 (14 MB not in the listed entries).
  - **page_table is 9–11 MB and iokit_mapped 0–1 MB** at all three samples. The layout's holds cost no page
    tables worth counting; the X term of unexplained-320 is alternate accounting alone.
  - alternate_accounting(+compressed): 2175 at +107, 2879 at +212, 2971 at +217. The donor pool's
    resident+compressed was 1935, 2180 and 2187. So **240 → 699 → 784 MB of alternate-accounted pages are not the
    pool's**, and they grew during the load. What they are is not shown (I: GPU-shared or other entries).
  - wired_mem 1473 → 1730 → 1854.

**Per process at the samples** (`[proc-mem]` resident+compressed MB; image/private/fex):

| Point (line, `[xp]`) | phys | graphics | RDR2.exe 0368 | B 0508 | runtime | child 0378 | services | all |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| press, `after teardown 6` (154752, +149.24) | 5641 | 1786 | 2274 (57/1713/504) | 601 (293/84/224) | 261 | 111 | 110 | 3382 |
| step −8.3, `footprint 6531 MB` (158782) | 6662 | 2271 | 3023 (57/2499/467) | 585 (293/62/230) | 259 | 111 | 110 | 4111 |
| step −3.2, `footprint 6912 MB` (158961) | 6930 | 2399 | 3219 (57/2695/467) | 580 (293/59/228) | 258 | 111 | 110 | 4304 |

The non-view residual (phys − graphics − `all` + donor-backed) is 2412 at the press and 2414 at step −3.2. **From
the press to the step the growth is all in views and graphics** (graphics +613, RDR2.exe private +982, its fex
−37), not host memory (M).

**The donor pool (M).**

- The launch state was `sys_free_mb=2614`.
- **Stop:** +100.10, `growth stopped (level 14% < 15%)`, spare 4238.
- **Resumed on spare** at +103.29 (`spare 4149 MiB >= 1920, level 13% < 20%: on spare memory; the level stop now
  under 13%`).
- **Stopped** at +107.37 (`level 12% < 13%, the level at the resume on spare memory`). There was no flap between.
- After the teardowns, **resumed on spare** at +111.55 (level 17 %). **Stopped** at +115.49 (level 13 % < 15 %).
- It never resumed again. Every later line reads `resume_wait="level 11–15% < 17% (the last resume on spare
  memory)"` with spare 3764–4545.
- Live at the cap: **2687 MB**, against l9's 2587 and d1's 2809. Resident+compressed at step −3.2 was 2187,
  against l9's 2074 and d1's 2292 (install+180).
- **I: a flaw in the amended rule.** A spare resume at level 15–19 % sets R to that level, so the next spare resume
  waited for 17 %. Under 15 % the stop is the old rule anyway, so R should count as at most 15 %. With that, the
  pool would have resumed at +179.63 (level 15 %, spare 4545).

**FEX (M).**

- RDR2's second code generation was granted 128 MiB at +86.50 (`tail BIG: granting 0x8000000`).
- **There was no third generation before the step**, as in l9; d1 rolled at press+2.1.
- RDR2's fex row was 504 at the press and 467 at the step, against d1's 524 → 303.

**B, the game's helper (M).**

- PEB `0x16fbb4000`, pid 0508; `[sc-single] verified browser` at 137632.
- Grants kinds 1, 3, 2, 4 at 142041–142097, then 5 (148854) and 6 (149143). There was no refusal.
- `Chrome_IOThread`, `CrBrowserMain` and `CompositorTileWorker1` started (143480–145247).
- Story's load ran to its step: the game's SC was up (I, as l9).
- New in l10: an earlier helper, pid 0188 (PEB `0x13d854000`), died in its init (`chrome_elf.dll failed to
  initialize`, 45689). Its kinds 1 and 3 were held in place (46052, 46054). The next helper, A (0198), verified and
  ran.

**The step (M).**

- Before it: 6973/2431/1479 at +218.68 (ml358), then `fast` 6985 at +219.84.
- The step: 7172 at +220.16 and **7721** at +220.49, at press+71.9 and sign-in+110. Then `[footprint]` **8185 MB**
  (graphics 3560, compressed 2003) at +220.84; the launcher line says 8179 MB at +222.4 (title).
- The host log ends at 15:29:22.95. The syslog shows `IOGPUCommandDescriptor::prepare` wiring faults (≈2.1 GB) at
  15:29:21.2. The stream dropped at 15:29:23, so no `ActiveHard` or `killed by jetsam` line was captured, and there
  is no JetsamEvent or crash report.
- **I:** jetsam at the per-process limit, as l9.

**Footprint aligned on the press:**

| press+ | l10 (press +148.6) | l9 (press +130.9) | d1 (press +123.5) |
| --- | --- | --- | --- |
| ≈0 | +1.2: 5642/1786 | +1.0: 5769/1849 | +1.2: 5348/1794 |
| ≈+20 | +19.4: 5623/1787 | +21.1: 5711/1851 | +19.2: 5044/1795 |
| ≈+46 | +45.7: 5980/2026 | +47.4: 6019/2048 | +45.8: 5388/2022 |
| ≈+60 | +59.9: 6386/2177 | +61.4: 6160/2143 | +60.1: 5680/2132 |
| ≈+68 | +68.3: 6874/2367 | +69.6: 6585/2269 | +68.2: 6260/2356 |
| just before the step | +70.1: **6973**/2431; `fast` 6985 | +77.8: **7072**/2494; `fast` 7062 | +74.3: **6470**/2454; `fast` 6457 |
| the step's first move | 7172 (press+71.6) | 7174 (+77.8) | 6882 (+74.6) |
| peak | **8185** (limit), jetsam | ≥ 8106 (limit), jetsam | 7896 |

**The cabin (screenshots in `agent-notes/pla476/p476l10/shots/`, `[xp]` ≈ shot − 9 s; described only):**

- ≈+152: a sepia tintype of wolves in the snow.
- ≈+170: black.
- ≈+189: a sepia tintype of snowy cliffs over a frozen lake, with a small cabin.
- ≈+208: black with the loading icon at the bottom right.
- ≈+226 and +246: the iPhone Home Screen.

**The cabin was not reached.**

**The rest (M):**

- **Game-SC end:** none. Sign-in+120 s is +230.5, after the step. There were no `[game-sc]` lines, so no 0155
  allow and no headroom refusal.
- **NO GAP FITS:** 53. 26 come from A's V8 probes (60k), 1 from the game's 8960 MiB ask, 26 from B's (140k–150k).
  There were 0 `dllhost`.
- **Slots:** A's teardown held kinds 2, 4, 6, 5, 1, 3 in place (136838–136855); 0 `held again`/`NOT held`.
  Teardown footprints were `6270->5970` (launcher) and `6270->5019` (A).
- **Waits:** 17 `wait-detached` (16 `node=unlinked`, 1 `absent`) and 7 `wait-only`, all `fate=0`.
- 54 `c0000005` lines, 31 of them RDR2's own (036c).

**l10 against d1, just before the step.** As in d1's split:
footprint = graphics + `[proc-mem]` all − donor-backed + non-view residual.
The rows are l10's step −3.2 sample against d1's step −1.0 (144530).

| Component | d1 | l10 | l10 − d1 | M/I | Whose |
| --- | --- | --- | --- | --- | --- |
| phys | 6457 | 6930 | **+473** | M | |
| graphics | 2420 | 2399 | −21 | M | shared |
| RDR2.exe fex | 303 | 467 | **+164** | M | no third FEX generation before the step (d1 rolled at press+2.1 only because its tail room was short) |
| RDR2.exe image+private | 2826 | 2752 | −74 | M | game |
| B | 449 | 580 | **+131** | M | stock CEF (image +98, fex +41, private −8) |
| runtime, child, services, rounding | 464 | 505 | +41 | M | services +56 (0028's fex) |
| donor-backed (subtracted) | −2292 | −2187 | **+105** | M for l10; d1 is install+180 (I) | pool cap 2687 against 2809 (the R flaw above) |
| non-view residual | 2287 | 2414 | **+127** | M for l10 (ledger-closed); d1 by difference | host side: not page tables (≤ 11 MB); flat from the press (+80 there) |
| **sum** | | | **+473** | | −21 + 164 − 74 + 131 + 41 + 105 + 127 |

- Then l10 grew 55 MB more to its step and d1 13, so the excess at the step is ≈ +515.
- **d1's "+320 not explained" is closed:**
  - the 200 MB of unsampled load growth is the FEX row (+164 at the step, M), not host memory;
  - the non-view residual difference is 80–127 MB of host-side anonymous memory, with page tables and IOKit ruled
    out (M) and the rest not attributable without a host-region walk.
  - The new unknown is the 784 MB of non-pool alternate accounting, which offsets the residual.
- **l10 against l9 (I, phases differ):**
  - the pool held about 110 MB more (donor-backed 2187 against 2074);
  - the pre-step plateau was ≈90 MB lower (6973–6985 against 7062–7072);
  - but the step's first move started at the same 7172–7174 MB, and the peak again reached the limit.
- **What fits:**
  - d1's step rose 1426 MB from its pre-step value. On l10's 6973 that gives ≈8400, so l10 needed **≥210 MB** less
    (l9 ≥306).
  - The remaining owners are the FEX row (−164 if the third generation came before the step), B's stock CEF
    (−131), and the pool's R flaw (≈−100 if it had resumed at 15 %): ≈−395 together (I), enough for d1's margin
    less ≈100.
  - Ending B before the step (≈−580) remains the single largest lever.

**Gates:**

| Gate | Result |
| --- | --- |
| HK first-frame+10 | passed (+10.53 s) |
| The game's helper reaches allocator/browser startup | passed (kinds 1–6, no refusal, browser threads) |
| The game signs in, Story is pressed | passed |
| Story reaches the cabin | **not passed** (jetsam at the limit in the load step) |
| No SC/launcher `NO GAP FITS` or soft grant | **not passed** (26 V8 lines each from A and B; 0 `dllhost`; no soft grant) |
| Peak within 7343 MB ±10 % | **not passed** (8185 MB) |
| Slot release keeps the range held | passed (A's 6/6 and the dead early helper's 2 held in place) |
| Sampler: a sample inside the step | **not passed** (the walk did not finish before the kill) |
| Ledger self-probe | passed (rc=0, phys_footprint closed to 14 MB) |

## l11: the pool's R cap, the sampler's cheap line first

The owner's decisions of 2026-10-30 after l10, as one commit, then one layout run with l10's keys:

- `ab1ab5c`: [0105](../decisions/0105-memory-defaults-per-phone.md)'s amendment corrected the same day: after a
  resume on spare memory at level L the level stop counts from R = min(L, 15 %), so a resume at 15–19 % no longer
  makes the next one wait for that level (`DonorPoolSizing.Growth`; test
  `testL10ResumeOnSpareOverTheFloorCountsFromTheFloor` replays l10's lines and resumes at +179.63's 15 %/4545 MiB).
  The dev sampler now logs its cheap `[fp-sample]` line (TASK_VM_INFO and the ledger) first, on the tick, then the
  `donor-pool: stats` line and the forced `[proc-mem]` walk off it. A jump while the last walk still runs logs the
  cheap line alone (`FootprintJumpTrigger.Firing.walks`).
- **IPA (dev):** `a5f40ebb11cce35a7f915ca9459b78695c9b00d4cb4c331616f7bf99f827ca6f`, verify-ipa 90 passed.
- **Session:** `agent-notes/pla476/l11.sh`, one `pp phone lock` session. `pp phone status` before: 1 phone, 80 % on
  power, 4.0 GB free, no holder. In-place install (26 s, container kept).
- **HK first-frame+10: passed**, first frame +11.04 s (`$PLAYPORT_BUILD/ui-runs/20261030T154742-hk-p476l11`).
- **RDR2 l11:** `$PLAYPORT_BUILD/ui-runs/20261030T154831-rdr2-p476l11`, keys `env.PLAYPORT_CEF_SWAP=0
  env.PLAYPORT_SC_SINGLE=1 env.PLAYPORT_SC_LAYOUT=1`, `STORY_BY=420 UNTIL=600 WAIT=900`. Result `ok:false`, `the app
  exited before the stop condition`. First frame +40.72 s (title clock). The game signed in at +104.4 s. Story was
  pressed at `[xp]` **+132.0** (`vpad` step 1, 148931).

Times are on the `[xp]` clock and lines are in `pull/s1-host.log`. Values are measured (M) unless marked inferred (I).

**The sampler (M).**

- Ledger probe rc=0 (2541). Firings: `armed` +100.73 (6262 MB, walk 536 ms); `level` +201.27 (6563, step −5.5, walk
  866 ms); `level` +206.82 (6926, phys 6937 at the read); then **two jumps inside the step while that walk ran,
  each logged as its cheap line alone:** +207.00 (7272) and +207.25 (7587; phys 7738 by the time TASK_VM_INFO was
  read). The +206.82 walk never printed: the app was ended first (I), as in l10. **The in-step sample survived.**
- **The step is graphics (ledger, M):**

  | `[fp-sample]` | phys | graphics | internal+compressed | alternate (+compressed) | wired_mem |
  | --- | --- | --- | --- | --- | --- |
  | +201.27 (step −5.5) | 6563 | 2407 | 7117 | 3021 | 1791 |
  | +206.82 (the step's start) | 6936 | 2651 | 7349 | 3118 | 2024 |
  | +207.00 | 7272 | 2967 | 7393 | 3152 | 2368 |
  | +207.25 | 7738 | 3416 | 7470 | 3214 | 2818 |

  From +206.82 to +207.25 phys rose 802 MB: graphics +765, internal+compressed +121, alternate accounting −96
  (subtracted), page tables 11 MB throughout. The ledger closes phys to 5–17 MB at each line. wired_mem follows
  graphics (+794). The syslog's `IOGPUCommandDescriptor::prepare` faults (preparedBytes ≈2.3–2.4 GB,
  remainingBytes negative) run 15:52:23.6, which is `[xp]` +207.3: the step.
- Non-pool alternate accounting (alternate − the pool's resident+compressed): 697 MB at +201.27, 788 at +206.82
  (l10 699 → 784).

**Per process at step −5.5** (`[proc-mem] footprint 6563 MB`, 153531; resident+compressed MB; image/private/fex):
RDR2.exe 0358 2998 (58/2642/298), B 04f8 581 (292/68/221), runtime 258, child 0368 118, services (0020, 0028, 0034)
99, all 4074 (3332/742). Graphics 2407 and phys 6563 come from the cheap line logged just before the walk, which then
ran 866 ms while phys rose about 60 MB.

**The donor pool (M).**

- Launch `sys_free_mb=2712`, `sys_level=50`.
- It grew through the sign-in and both teardowns. **Stop** +117.53 (`level 14% < 15%`, spare 4194). **Resumed on
  spare** +119.43 at 13 % (`the level stop now under 13%`). That resume held for 56 s.
- **Stop** +175.45 (`level 12% < 13%`, spare 4105). **Resumed on spare** +179.63 at 13 %. **Stop** +189.57 (`12% <
  13%`, spare 4089). Then level 9–10 % with spare 3678–3984 to the end.
- No flap. **No resume at 15–19 % happened, so R = min(L, 15) was not exercised on the phone** (both resumes at
  13 %); it is covered by the host test only.
- Live at the cap **2812 MB** (l10 2687, d1 2809). Resident+compressed at the step's start (stats at +206.76):
  1890 + 440 = **2330** (l10 2187 at step −3.2; d1 2292 at install+180).
- I: the pool held more than l10 because its first stop came 17 s later (+117.5 against +100.1) and its 13 % resume
  held 56 s. The R fix did not cause it.

**FEX (M).**

- RDR2's second generation asked 128 MiB at +81.21 and got **64** (`tail CAP: refusing 0x8000000 (cap 0x4000000 …
  other processes 8)`, `exec alloc degraded 0x8000000 -> 0x4000000`), as d1.
- That buffer filled and **RDR2 rolled to its third generation at +134.00, press+2.0** (`[gen] alloc#3
  size=0x8000000 prev_size=0x4000000`, `tail REUSE`, 149112), as d1's press+2.1.
- RDR2's fex row: 561 at the press (+132.09), 237 at +137.04, 298 at step −5.5 (d1 303, l10 467).
- I: the roll was again pool-room timing at the second generation, not policy.
- B rolled to its third generation at +119.90.

**B, the game's helper (M).**

- PEB `0x178b24000`, pid 04f8; `[sc-single] verified browser` at 132446.
- Grants kinds 1, 3, 2, 4 at +107.42 (136799–136850), 5 at +109.54 (143807) and 6 at +111.82 (144105). No refusal.
- `Chrome_IOThread`, `CrBrowserMain` and `CompositorTileWorker1` started (138016–139804).
- l10's early helper death (`chrome_elf.dll failed to initialize`) did not recur: 0 lines.
- B at the press 605, at step −5.5 581 MB (l10 601 → 580).

**The step and the end (M).**

- Before it: `[footprint]` 6757/2503 at +205.18 (ml358), `fast` 6776 at +206.42.
- The step: `fast` 7040 at +206.76 (press+74.8, sign-in+102 on mixed clocks), the cheap lines above, then
  `[footprint]` 8028 (graphics 3672) at +207.22 and 8117 (graphics 3705, compressed 2105) after it; the last `[xp]`
  line is `fpMB` **8169** at +210.91 (15:52:30.73); the launcher line says 8157 MB at +213.0 (title).
- Frames kept coming after the step (`[frames]` n=9024 at 15:52:30.83, `kk-gpu` 23 fps).
- Phone-wide pressure at the step: the kernel killed idle daemons (`killing_idle_process`, 15:52:23.87) and logged
  `System will begin enforcing soft memory limits` from 15:52:24.2.
- The syslog has nothing from 15:52:25.4 to 15:52:31.36, when runningboardd logged `termination reported by launchd
  (1, 7, 9)` for the app: a SIGKILL. No `ActiveHard` line was captured and there is no crash report. **I: jetsam at
  the per-process limit**, as l9 and l10.

**Footprint aligned on the press** (`[footprint]` phys/graphics):

| press+ | l11 (press +132.0) | l10 (press +148.6) | d1 (press +123.5) |
| --- | --- | --- | --- |
| ≈0 | +0.1: 5852/1863 | +1.2: 5642/1786 | +1.2: 5348/1794 |
| ≈+20 | +20.2: 5486/1864 | +19.4: 5623/1787 | +19.2: 5044/1795 |
| ≈+46 | +46.7: 5818/2090 | +45.7: 5980/2026 | +45.8: 5388/2022 |
| ≈+60 | +60.8: 6009/2184 | +59.9: 6386/2177 | +60.1: 5680/2132 |
| ≈+68 | +69.0: 6551/2409 | +68.3: 6874/2367 | +68.2: 6260/2356 |
| just before the step | +73.2: **6757**/2503; `fast` 6776 | +70.1: **6973**/2431; `fast` 6985 | +74.3: **6470**/2454; `fast` 6457 |
| the step's first move | 7040 (press+74.8) | 7172 (press+71.6) | 6882 (press+74.6) |
| peak | **8169** (`fpMB`), then SIGKILL | **8185**, jetsam | 7896 |

**The cabin (screenshots in `agent-notes/pla476/p476l11/shots/`, `[xp]` ≈ the file time − 15:48:56; described
only):**

- ≈+137: a grey, blurred tintype of a snowy yard with a cross and a fence (loading).
- ≈+155: a sepia tintype of a rider in furs with a rifle, on a dark horse in the snow.
- ≈+173: a dim, blurred tintype of a rocky valley.
- ≈+191: a sepia tintype of a moose before snowy peaks, the loading icon at the bottom right.
- ≈+218 and ≈+236: the iPhone Home Screen.

**The cabin was not reached.**

**The rest (M):**

- **Game-SC end:** none. Sign-in+120 s is ≈+224, after the kill. 0 `[game-sc]` lines, so no 0155 allow and no
  `no headroom` line.
- **NO GAP FITS:** 53: 26 from A's V8 probes (+27–+29), 1 the game's 8960 MiB ask (`size=0x230010000`), 26 from B's
  (+110–+118). 0 `dllhost`.
- **Slots:** A's teardown held kinds 2, 4, 6, 5, 1, 3 in place (131687–131702); 0 `held again`/`NOT held`.
  Teardown footprints `6397->6150` (launcher) and `6397->5208` (A).
- **Waits:** 17 `wait-detached` (16 unlinked, 1 absent) and 7 `wait-only`, all `fate=0`.
- 53 `c0000005` lines, 33 of them RDR2's own (035c).

**l11 against d1 and l10.** footprint = graphics + `[proc-mem]` all − donor-backed + non-view residual. l11's only
walk near the step is step −5.5; d1's is step −1.0 (144530), l10's step −3.2.

| Component | d1 | l10 | l11 | l11 − d1 | l11 − l10 | M/I | Whose |
| --- | --- | --- | --- | --- | --- | --- | --- |
| phys | 6457 | 6930 | 6563 | **+106** | **−367** | M | |
| graphics | 2420 | 2399 | 2407 | −13 | +8 | M | shared |
| RDR2.exe fex | 303 | 467 | 298 | −5 | **−169** | M | the third generation came at press+2.0, as d1 |
| RDR2.exe image+private | 2826 | 2752 | 2700 | −126 | −52 | M | game; l11's sample is earlier in the load |
| B | 449 | 580 | 581 | **+132** | +1 | M | stock CEF |
| runtime, child, services, rounding | 464 | 505 | 495 | +31 | −10 | M | |
| donor-backed (subtracted) | −2292 | −2187 | −2324 | −32 | **−137** | M l10/l11; d1 install+180 (I) | the pool's later first stop (not the R fix) |
| non-view residual | 2287 | 2414 | 2406 | **+119** | −8 | M l10/l11 (±60 for l11's walk); d1 by difference | host side, flat |
| **sum** | | | | **+106** | **−367** | | |

- From the sample to the step l11 grew +213 (to `fast` 6776), l10 +55, d1 +13. **The excess over d1 just before
  the step is +306 (6776 against 6470), against l10's +515.** I: the 209 MB gained on l10 are the FEX roll (−169)
  and the pool (−137), less RDR2's later load growth.
- What remains over d1: B's stock CEF +132 and the host-side residual +119 (M), and about 55 MB of other noise
  across the phases (I).
- **What fits:** d1's step rose 1426 MB. On l11's 6776 that gives ≈8202, so l11 needed **≥10–30 MB** less (l10 ≥210,
  l9 ≥306). Its own step rose ≥1393 MB (6776 → 8169 before the log ended). I: l11 missed by tens of MB, and d1's
  296 MB margin needs about −330.
- Levers (I): ending B before the step (≈−580); B's stock-CEF cost (≈−132); the residual's host memory (≈−119, not
  yet attributable). The FEX roll and the pool are now at d1's values, by timing rather than by rule.

**Gates:**

| Gate | Result |
| --- | --- |
| HK first-frame+10 | passed (+11.04 s) |
| The game's helper reaches allocator/browser startup | passed (kinds 1–6, no refusal, browser threads) |
| The game signs in, Story is pressed | passed |
| Story reaches the cabin | **not passed** (8169 MB in the load step, then SIGKILL) |
| No SC/launcher `NO GAP FITS` or soft grant | **not passed** (26 V8 lines each from A and B; 0 `dllhost`; no soft grant) |
| Peak within 7343 MB ±10 % | **not passed** (8169 MB) |
| Slot release keeps the range held | passed (A's 6/6 held in place) |
| Sampler: a sample inside the step | **passed** (cheap lines at 7272 and 7587/7738 MB) |
| Pool: a spare resume at 15–19 % counts from 15 % | not exercised on the phone (both resumes at 13 %); host test only |
| 0155 headroom refusal | not exercised (no game-SC end before the kill) |

## l12: image cache copies, GPU off, avail-phys, VRAM 2304, a 64 MiB code buffer — Story reaches the cabin

Owner decisions of 2026-10-30 (after the stock-CEF cost research and the willfaust/Madeira memory reading), one commit
each, then one layout run with l11's keys:

- `edddbb4`, madeira-unix 0232 (diagnostic): `[proc-mem]` rows keep committed/resident/compressed and add
  `res_file=I/P/F res_anon=I/P/F` (image/private/fex), from mincore's `MINCORE_ANONYMOUS`/`MINCORE_COPIED`.
- `5987252`, [0116](../decisions/0116-tail-room-for-every-process-and-the-launchers-smc-checks.md) amended
  (madeira-unix 0233): a code-buffer grant is at most 64 MiB.
- `49e0bc7`, [0150](../decisions/0150-dev-single-process-social-club.md) amended again (madeira-unix 0190): the
  verified browser also gets `--disable-gpu --disable-gpu-compositing`.
- `79f42d7` and `2209aab`, [0142](../decisions/0142-rdr2-owner-test-defaults-heap-size-semaphores-and-afp.md)/
  [0153](../decisions/0153-rdr2s-settings-are-every-games-defaults.md) amended: RDR2's entry has `vram-mb=2304
  env.PLAYPORT_VK_HEAP_MB=2304`.
- `08021da`, [0168](../decisions/0168-social-clubs-helper-is-told-little-available-memory.md) (madeira-unix 0234,
  wine-unix 0203): `SocialClubHelper.exe` is told 300 MB available.
- `da73673`, [0167](../decisions/0167-large-x86-64-images-map-from-a-cache-copy.md) (madeira-unix 0235): x86-64
  images of 64 MiB or more with sections off the 16 KiB grid map from a copy in `Library/Caches/images`.

**Builds and session.**

- **IPA (dev):** `f2a0c7b88e574842dd61c25442ad973bef39cf8e659c89c1959f9ce51f816ede` (HEAD `da73673`), verify-ipa
  90 passed. `pp test` all passed.
- **Session:** `agent-notes/pla476/l12.sh`, one `pp phone lock` session. `pp phone status` before: 1 phone, 80 %,
  not on power, 3.4 GB free, installed `a5f40ebb…`.
- **Order:** Hollow Knight `pp perf` before (on `a5f40ebb`); in-place install (36 s, container kept); HK
  first-frame+10; HK `pp perf` after; RDR2 l12.

**Hollow Knight (M).**

- First-frame+10 **passed**: first frame +11.00 s (`$PLAYPORT_BUILD/ui-runs/20261030T170711-hk-p476l12`).
- `pp perf --secs 120 --cool 5 --pad first-frame+25:hk-new-game --pad first-frame+80:hk-walk`
  (`$PLAYPORT_BUILD/perf/p476l12-hk-before`, `…-after`):

  | | before (`a5f40ebb`) | after (`f2a0c7b8`) |
  | --- | --- | --- |
  | fps mean / p10 / median / min | 58.7 / 55.4 / 60.0 / 45.3 | 58.7 / 55.0 / 60.0 / 45.1 |
  | first frame | +11.73 s | +11.10 s |
  | code buffers | gen 2 = 128 MiB, no third | gen 2 = 64 MiB, **gen 3 (64 MiB) at about +35 s** |
  | block compiles (sum of `jit/s` × 5 s) | ≈66 k | ≈86 k (+30 %) |
  | the bucket with the compile burst | +30 s: 51.9 fps, 3755 jit/s | +35 s: 50.7 fps, 6224 jit/s |
  | wineserver requests per frame | 17.67 | 17.64 |
  | thermal, battery | nominal, 80→80 %, off power | nominal, 80→80 %, **on power** |

- **Hitches and frame/GPU times were not recorded in the after run:** its log says `hostio: Metal HUD off` (127
  HUD lines in the before run, 1 in the after), so it counted frames from `[frames]` lines. That is a tooling gap,
  not a measurement of zero.
- **0116 gate (I):** passed on frame rate; the hitch part is unverified. The roll costs one burst of about 20 k extra
  compiles and one 5-s bucket about 1 fps lower.

**RDR2 l12:** `$PLAYPORT_BUILD/ui-runs/20261030T171553-rdr2-p476l12`.

- Keys `env.PLAYPORT_CEF_SWAP=0 env.PLAYPORT_SC_SINGLE=1 env.PLAYPORT_SC_LAYOUT=1` (with the entry's `vram-mb=2304
  env.PLAYPORT_VK_HEAP_MB=2304` and every game's `avail-phys-cef-mb=300`), `STORY_BY=420 UNTIL=600 WAIT=900`.
- **Result `ok:true`, `until first-frame+600` reached.** First window +8.49 s, first frame +92.76 s (title clock),
  the game signed in at +109.5 s.
- Story was pressed at `[xp]` **+152.8** (`vpad` step 1). The `[xp]` clock starts at about 17:16:19.6; screenshot
  names are seconds after the launch, which is `[xp]` + 10.9.

**Image cache copies (0167, M).**

| `[xp]` | line |
| --- | --- |
| +15.23 | Social-Club-Setup.exe: no copy, read; **wrote 122 MiB in 122 ms** (14 runs) |
| +24.54 | libcef.dll (A's first load): no copy, read; **wrote 239 MiB in 308 ms** (31 runs) |
| +25.12 | libcef.dll mapped from its copy (`[img-map] … file-mapped 0xefbe000 read 0x0`) |
| +54.08 | RDR2.exe (first load): read; **wrote 115 MiB in 220 ms** (22 runs) |
| +61.66 | RDR2.exe (the game) mapped from its copy |
| +93.32 | libcef.dll mapped from its copy (the game process's own load, as l11's at +89.66) |
| +112.07 | libcef.dll mapped from its copy (B) |

- No copy failed, mismatched or was evicted. Three copies: 476 MiB in `Library/Caches/images`.
- **0232's split works:** every fex row has `res_file` 0.

**B, the game's helper (M; resident+compressed MiB, image/private/fex; `res_file`/`res_anon` of the image):**

| point | l11 (stock libcef read) | l12 (libcef from the copy) |
| --- | --- | --- |
| press | 605 (293/85/227) | 450 (171/78/201), image res_file 112, res_anon 58 |
| step −5 | 581 (292/68/221) | 392 (132/54/206), image res_file 74, res_anon 58 |
| **anonymous (footprint) at step −5** | **581** | **318** (58 + 54 + 206) |

- The launcher's helper A: image 173–310 with res_file 97–179 and res_anon 35–59, against l11's 297 all read.
- RDR2.exe's image row: 40 MiB anonymous at step −5 (res_anon 9 + compressed 31; res_file 3) against l11's 58.
- I: the copy takes about 235 MiB of B's footprint (293 → 58 image) and about 200 of A's while A lives. That matches
  the 210–230 estimate.

**GPU off (0150 amendment, M).**

- Both helpers logged `[sc-single] verified browser: … component update off, GPU off` (+24.86 A, +111.22 B).
- B still loaded `wined3d`, `dxgi`, `D3DCompiler_47`, `libglesv2` and `libegl` (+112.99–113.32). **`d3d11.dll` was
  not loaded** (l11: +108.39, 6 MiB read). B's private row is 54–78 against l11's 68–85.
- The launcher no longer presented through Vulkan before the game. Its UI came up as guest windows instead
  (`hwnd=0x2003a` 700×800 at +43.3, `0x3006a` 1280×600 at +52.8). So the first frame (+92.76) is the game's;
  l11's +40.72 was the launcher's.
- **Social Club rendered and signed in.** Screenshots, described only:
  - +43: the launcher's dark window with the Rockstar logo pattern;
  - +96: the game's red Rockstar logo;
  - the legal text with "Build 1491.50";
  - the title screen with "RED DEAD REDEMPTION II", a snowy forest, the Story/Online tabs and the prompts
    Settings, **Social Club (Y)**, Story and Quit Game.

  `launcher: the game signed in at +109.5 s`. No `SC_INIT_ERR` line.

**avail-phys (0168, M).**

- `[avail-phys] SocialClubHelper.exe sees at most 300 MB available: Chromium's critical level` at +25.45.
- The four logged answers (+25.70 to +35.87) were all A's (PEB `0x140268000`): 300 MB reported instead of
  5208–5527 MB.
- B's queries are not logged, because the line count is global (four). I: B got the same answer, by the same rule.
- A's private row did not fall (284–290 at +92–100, l11 272–277); B's is 14 MiB lower than l11's. I: any purge saving
  is within tens of MB, as estimated, and is not separable from GPU off.

**VRAM 2304 (M).**

- `memory plan: … video_mb=2304 override=vram-mb=2304`, `DXVK_CONFIG dxgi.maxDeviceMemory = 2304;
  PLAYPORT_VK_BUDGET_MB=2304`, and `[kk-memory] heap 0: size 2304 MiB reported in place of 8192 MiB` in each
  process.
- **Graphics ledger:** 1510 at the press (l11 1863); 2070 at step −5.4 (l11 2407 at step −5.5); 2166 just before the
  step (l11 2651); **3387** at the step's top (l11 3416 when the log ended, rising, killed); 3360–3449 after it.
- No "out of memory" dialog in any screenshot. The game's own settings screen was not opened.

**FEX (0116 amendment, M).**

- RDR2.exe (`E 364`):
  - gen 2 asked 128 MiB at +85.47 and got 64 (`tail CAP … cap 0x4000000`);
  - **gen 3 at +154.66 = press+1.9** (l11 press+2.0, d1 press+2.1), and gen 4 at +220.20 = press+67.4, 9 s before
    the step.
- RDR2's fex row: 498 at press−5.9, 236 at press+3.6, 281 at step −5 (l11 561 → 237 → 298; d1 → 303).
- **Every 128 MiB ask now rolls at 64.** The launcher's helper A rolled **24 generations** from +25.97 to +99.31
  (about one every 3 s; l11's A rolled 6 of 128). B rolled 13 from +112.99 to +175.12 (l11's B rolled 2).
- I: those rolls are FEX compile load during the sign-in and the menus. The Story press came 20.8 s later on the
  `[xp]` clock than l11's (+152.8 against +132.0), with the sign-in 5 s later; A's and B's rolls are the likely
  cause, not measured.

**The donor pool (M).**

- Launch `sys_free_mb=3187`, `sys_level=49`.
- No stop during the sign-in. **The first stop was at +219.54** (level 14 % < 15 %, spare 3919); l11's was at +117.53.
- Resumed on spare at +221.46 at 13 %, stopped +223.58 (12 % < 13 %). Then the pool was full (`no free run fits`
  from +220.20, 1521 refusals).
- Live **3104 MB** at the cap (l11 2812, d1 2809). Resident+compressed at the step's start 1989 + 609 = **2598**
  (l11 2330).
- No resume at 15–19 %: R = min(L, 15) is still not exercised on the phone.
- I: the lower sign-in peak (5686 MB at the launcher's end against l11's 6397) kept the level at 15 % or above for
  100 s longer.

**The step, the sampler, the end of the game's SC (M).**

- **Before the step:**
  - `[footprint]` 5675/2070 (phys/graphics) at +223.91;
  - `fast` 5720 at +224.25 (press+71.5), creeping to 5872 at +227.54.
- **The step:** `fast` 6198 → 6615 → 6841 at +229.32 (press+76.5), `[footprint]` **7190** (graphics 3387,
  compressed 1805) at +229.87. The highest `fpMB` was **7200** at +229.87.
- **The sampler** fired once, `armed` at 6904 MB (+230.03, inside the step), and its walk took 16.4 s. Its ledger:

  | field | MB |
  | --- | --- |
  | phys_footprint | 6996 |
  | internal | 5716 |
  | internal_compressed | 1516 |
  | alternate_accounting | 2724 (+807 compressed) |
  | page_table | 11 |
  | graphics | 3371 |
  | wired_mem | 2980 |

- **The game-SC end (0141/0153):** `the footprint reached 7185 MB … ending the game's own Social Club at +236.4 s`
  (title) = `[xp]` +229.87, sign-in+127. It ended B (pid 0500, footprint `7173->6908 MB`, −265). All six slots were
  held in place.
- **0138** then refused 18 restart attempts. The game stayed in the cabin, unlike d1's return to its title. There
  was no re-sign-in line, so **0155 was not exercised** (no allow, no no-headroom line).
- After the step the footprint stayed **6.9–7.2 GB to the end** (+741; 7096–7178 at +650–740). Graphics was
  3360–3450. The pool was 3077 live, its resident falling to 283 and compressed rising to 2326 as the phone
  compressed it.
- **No jetsam:** the run ended on its own stop at first-frame+600.

**The cabin (screenshots in `agent-notes/pla476/p476l12/shots/`, `[xp]` ≈ name − 11; described only).**

- +232 (just after the step) through +707: **Arthur sits on a bed in the log cabin**, in a blue coat and black hat.
  There is a snowy window behind him, a table with a tin cup, shelves on the right and a stove at the front right.
  At +319 he lifts a hand to his face.
- The cabin was reached and held for at least 475 s.
- **Cabin frame rate (`[kk-gpu]`, M):** median 22.3 fps from +240 to +300, 21.4 from +300 to +450, 20.9 from +450 to
  +700. d1's cabin was not measured long enough to compare (its game went back to its title).

**The rest (M).**

- **NO GAP FITS 53:** 26 from A's V8 probes (+20–30), 1 the game's 8960 MiB ask (+70), 26 from B's (+110–120).
  0 `dllhost`. Unchanged.
- **Slots:** A's teardown (+110.31) and B's end (+229.87) each held all six kinds in place. 0 `held again`, 0 `NOT
  held`. B got kinds 1, 3, 2, 4 at +112.36, 5 at +114.39 and 6 at +116.78, with no refusal.
- **Teardown footprints:** `5687->5460` (launcher), `5687->4731` (A), `7173->6908` (B).
- **Waits:** 31 `wait-detached`, 13 `wait-only` (two teardowns: A and B). c0000005: 67 lines (l11 53).
- **RDR2.exe was placed lower than in l11:** first load at `0x153f50000` and the game's at `0x154950000`, against
  l11's `0x7240000000` and `0x717b760000`. I: the address-space state differed; it was not investigated.

**Footprint aligned on the press** (`[footprint]` phys/graphics):

| press+ | l12 (press +152.8) | l11 (press +132.0) | d1 (press +123.5) |
| --- | --- | --- | --- |
| ≈0 | +0.0: 5102/1510 | +0.1: 5852/1863 | +1.2: 5348/1794 |
| ≈+20 | +20.3: 4834/1511 | +20.2: 5486/1864 | +19.2: 5044/1795 |
| ≈+46 | +46.9: 5184/1738 | +46.7: 5818/2090 | +45.8: 5388/2022 |
| ≈+60 | +60.9: 5333/1845 | +60.8: 6009/2184 | +60.1: 5680/2132 |
| ≈+68 | +67.1: 5463/1941 | +69.0: 6551/2409 | +68.2: 6260/2356 |
| just before the step | +71.1: 5675/2070; `fast` 5872 | +73.2: 6757/2503; `fast` 6776 | +74.3: 6470/2454; `fast` 6457 |
| the step | 5872 → **7190** (+1318), press+76.5 | 6776 → ≥8169, press+74.8 | 6457 → 7896 (+1426), press+74.6 |
| after | 6.9–7.2 GB, cabin | SIGKILL | cabin, then its title |

**l12 against l11 at step −5** (l12 `[proc-mem]` +224.57 with `[footprint]` +223.91; l11 as in its table;
footprint = graphics + `[proc-mem]` all, anonymous − donor-backed + non-view residual):

| Component | d1 | l11 | l12 | l12 − l11 | M/I | Lever |
| --- | --- | --- | --- | --- | --- | --- |
| phys | 6457 | 6563 | 5675 | **−888** | M | |
| graphics | 2420 | 2407 | 2070 | **−337** | M | VRAM 2304 (I: also the load's timing) |
| B (anonymous) | 449 (counted with file pages) | 581 | 318 | **−264** | M | image −235 (0167), private −14 and fex −15 (GPU off, avail-phys; not separable) |
| RDR2.exe fex | 303 | 298 | 281 | −17 | M | both rolled before the step (0116) |
| RDR2.exe image+private (anonymous) | 2826 | 2700 | 2688 | −12 | M | image −18 (0167), private +6 |
| runtime, child, services, rest | 464 | 495 | 458 | −37 | M | |
| donor-backed (subtracted) | −2292 | −2324 | −2598 | **−274** | M | the pool's first stop 102 s later |
| non-view residual | 2287 | 2406 | 2458 | +52 | M (±60 walk) | |
| **sum** | | | | **−888** | | |

- l11's `all` had almost no file pages (stock libcef read, B 0 file), so its row compares with l12's anonymous
  total. d1's 449 for B and its residual include about 130 MiB of Playport libcef's file pages (I,
  b-stock-cef-cost).
- **Just before the step l12 was 5872 against d1's 6470 (−598) and l11's 6776 (−904).** The step itself rose 1318
  (d1 1426). The game-SC end then took 265 off inside it.
- **Peak 7190–7200 against d1's 7896.** The margin to 8192 MB was about 990 MB, against d1's 296.
- I: about two thirds of the gain is policy that holds in any run: B's image (−235), graphics (about −340), RDR2's
  image (−18). About a third is the pool's later stop (−274), which follows phone state and the lower sign-in peak.
  Without the pool term, l12 would still have peaked at about 7470 MB.

**Gates:**

| Gate | Result |
| --- | --- |
| HK first-frame+10 | passed (+11.00 s) |
| HK `pp perf` before/after (0116) | fps passed (58.7/58.7); hitches **not measured** in the after run (HUD off) |
| The game's helper reaches allocator/browser startup | passed (kinds 1–6, no refusal) |
| The game signs in, Story is pressed | passed |
| Social Club renders with GPU off (0150) | passed (sign-in, Social Club prompt, Story tab) |
| **Story reaches the cabin** | **passed** (+232, held to the run's end) |
| No SC/launcher `NO GAP FITS` or soft grant | **not passed** (26 V8 lines each from A and B; 0 `dllhost`) |
| **Peak within 7343 MB ±10 %** | **passed** (7200 MB) |
| Slot release keeps the range held | passed (A 6/6, B 6/6 held in place) |
| Sampler: a sample inside the step | passed (one `armed` firing at 6904 MB, ledger) |
| Image copies: written once, mapped after (0167) | passed (3 written, 0 failures; B's image res_anon 58) |
| Pool: a spare resume at 15–19 % counts from 15 % | not exercised (the resume at 13 %) |
| 0155 headroom refusal | not exercised (no re-sign-in after the game-SC end) |

## l13–l14: repeat of l12, HK hitches

Same IPA as l12, `f2a0c7b88e574842dd61c25442ad973bef39cf8e659c89c1959f9ce51f816ede` (HEAD `da73673`), no code
change, no install (`pp phone status`: installed `f2a0c7b8…`, 80 %, on power, no JIT timeout). Session
`agent-notes/pla476/l13.sh` (HK `pp perf` with the HUD, then l13), then `l13b.sh` (l13 again, l14). M = measured,
I = inferred. The `[xp]` clock is the log's; press = the `vpad` step 1.

**What went wrong first (tooling, M).**

- The first session ran l13 with the Metal HUD still on from the `pp perf` that preceded it. The HUD overlays the title
  screen's Story prompt, so `landing.py` saw no Story tab and pressed nothing (`no Story press by launch +420 s`).
  The title screen was reached (first frame +112 s); that run (`20261030T183016-rdr2-p476l13-hudon-nopress`) is
  kept, not analysed.
- My tool call then timed out and killed the session during l14 (`…183820-rdr2-p476l14-killed`, no result).
- The two runs below are a second session, with `--action hud:off` added in `arm13.sh` (l12 ran with the HUD off
  because its HUD setting had been undone by the smoke run in between). Otherwise the same keys:
  `env.PLAYPORT_CEF_SWAP=0 env.PLAYPORT_SC_SINGLE=1 env.PLAYPORT_SC_LAYOUT=1`, `STORY_BY=420 UNTIL=600 WAIT=900`.

**Hollow Knight `pp perf` with the HUD on (M).** `pp perf --secs 120 --cool 5 --pad first-frame+25:hk-new-game --pad
first-frame+80:hk-walk` on `f2a0c7b8…` (`$PLAYPORT_BUILD/perf/p476l13-hk-after`; its log says `hostio: Metal HUD on`),
compared with l12's before run on `a5f40ebb…` (`p476l12-hk-before`, HUD on):

| `--compare --window 0:120` | before (`a5f40ebb`, 128 MiB buffers) | after (`f2a0c7b8`, 64 MiB buffers) |
| --- | --- | --- |
| fps | 58.7 | 58.7 |
| frame interval p50 / p99 / p99.9 (ms) | 16.67 / 25.01 / 66.69 | 16.67 / 25.01 / 50.02 |
| hitches > 25 / 50 / 100 ms (window) | 177 / 11 / 4 | 203 / 11 / 4 |
| hitches, whole run | 203 / 11 / 4 | 245 / 11 / 4 |
| GPU ms (HUD) / GPU % | 6.2 / 46.9 | 7.1 / 51.4 |
| fps p10 / min | 55.4 / 45.3 | 55.0 / 45.4 |
| Mi per frame / srv per frame | 73.3 / 18.98 | 72.5 / 19.0 |
| phone power (mW), charger | 3718, off power | 4341, **on power** |

- **Gate (0116):** frame rate and the tail (> 50 ms, > 100 ms, p99, p99.9) are equal or better. The count of 25–50 ms
  frames is 14 % higher in the window (+42 over the run). GPU time is 0.9 ms higher, but the after run was on power
  (a different phone power state; I: not a regression of the buffers). I: the extra short hitches are the compile
  burst of the third 64 MiB generation (l12: ≈ +20 k compiles at about +35 s). The before run has hitch data, so this
  is a comparison of two measured runs. **Passed on the stated measures; the 25 ms count is a cost.**

**RDR2 l13 and l14 against l12.** Run dirs: l13 `$PLAYPORT_BUILD/ui-runs/20261030T184300-rdr2-p476l13`, l14
`…T185058-rdr2-p476l14`, l12 `…T171553-rdr2-p476l12`.

| | l12 | l13 | l14 |
| --- | --- | --- | --- |
| result | `ok:true`, first-frame+600 | **`launch=failed`, the app ended at +374.7 `[xp]`** (see below) | `ok:true`, first-frame+600 |
| first frame (title clock) | +92.76 | +108.66 | +96.66 |
| game signed in `[xp]` | +110.3 | +127.3 | +116.1 |
| Story pressed `[xp]` / after sign-in | +152.8 / 42.5 s | +171.3 / 44.0 s | +149.3 / 33.2 s |
| game-SC end (0141/0153) `[xp]` | +229.9, 7185 MB, press+77 | +280.6, 7010 MB, press+109 | +268.3, 7051 MB, press+119 |
| **peak `fpMB`** | **7200** (at the step) | **7627** (+367, after the 0155 restarts); at the step 6885–7010 (+274–281), 7282 at +322 | **7058** (at the step, +265) |
| footprint just before the step (`[footprint]`/fast) | 5675 / 5872 | 5659 (+271) | 5638 / 5761 (+247–250) |
| at the step | 7190 @ press+76.5 (+1318) | 6885 @ +274.7, press+103 (+1226) | 6935 @ +252.9, press+103; 7056 top (+1295) |
| graphics before → at the step | 2166 → 3387 | 2163 → 3471 | 2123 → 3316 (3370 after) |
| pool: first growth stop | +219.5, level 14 %, press+67 | +273.9, level 8 %, press+103 | +247.3, level 14 %, press+98 |
| pool: spare resume | +221.5 at 13 % (stop again at 12 %) | +278.5 at **8 %** (spare 3320 ≥ 1920) | +249.5 at 14 %, stop again at 8 % at +252.9 |
| pool live (cap) / resident+compressed at the step | 3104 / 2598 | 3290 / **2790** | 3256 / **2748** (2784 at +267) |
| B (image/private/fex MiB) press → step −5 | 171/78/201 → 132/54/206 | 169/77/201 → 168/57/195 | 170/79/194 → 171/56/215 |
| B image res_file / res_anon (MiB) | 112/58 → 74/58 | 110/58 → 111/53 | 112/58 → 113/58 |
| RDR2 private+image+fex at step −5 | 2648+43+281 | ≈ 2014+57+288 at +247, 2750+57+288 at +272 | 2602+57+274 |
| RDR2 `[gen]` | gen 2 at press−67, gen 3 at press+1.9, gen 4 at press+67 | gen 2 press−71, gen 3 +2.2, gen 4 +88 | gen 2 press−61, gen 3 +2.2, gen 4 +90 |
| A / B `[gen]` (highest allocation number) | A 23, B 24 | A 22, B 25 (and a third at 23) | A 28, B 30 |
| 0155 | not exercised | **exercised** (below) | not exercised |
| `NO GAP FITS` | 53 | 103 (after the 0155 restarts) | 53 |
| jetsam | none | **the app was killed at +374.7** (I: jetsam) | none |

- **The cabin (screenshots, described only).** l14: black with a loading spinner, then Arthur sits on a bed in the log
  cabin in a blue coat and black hat (window, shelves, a table with a tin cup behind him), unchanged through the last
  shots (+650, +750 after the launch); `[kk-gpu]` median 19.7 / 19.9 / 20.3 fps over +255–300 / +300–450 / +450–700
  (l12: 22.3 / 21.4 / 20.9). l13: the same cabin at +297 s after the launch (dimmed), a black screen with a spinner at
  +345, and the Home Screen at +399 (the app was gone).
- **Pool and peaks (M).** The pool did not stop early in either repeat: the first growth stop came at press+98 (l14)
  and press+103 (l13), l12's at press+67. Both l13 and l14 stopped with the pool about 150–190 MiB fuller than l12
  (resident+compressed 2748 and 2790 against 2598), yet l14's step peaked at 7058, 142 below l12's. The step began
  25 s later after the press than in l12 (press+103 against +76.5): the load step's own start is not fixed to the
  press. The spare resume (decision 0153/l10 rule) ran in both repeats: at 14 % in l14 (then stopped again at 8 %), at
  8 % in l13 (spare 3320 MiB, `level 8 % < 20 %`). R = min(L, 15) at a 15–19 % level did not occur in any run
  (levels were 14 and 8); the resume used the spare-memory rule.
- **Donor-backed term at step −5 and its peak (M).** l12 2598 / 2598; l13 2773 (+269.6) / 2837 (+322, resident 2047 +
  compressed 790); l14 2748 (+247.6) / 2784 (+266.9). The question "does the cabin margin hold when the pool stops
  early" was **not tested**: the pool stopped late, not early, in both repeats.
- **Against l12, the policy terms held (M).** Graphics at the step 3316–3471 (l12 3387). B's image stays at about
  58 MiB anonymous (res_anon 53–58) with 110–113 MiB file-backed at the step in both repeats; l12's file part had
  dropped to 74 by then, so B is 25–50 MiB larger in total here (421 and 442 against 392). RDR2's fex row 274–288
  (l12 281).
- **Time to the press (M).** The press came 33–44 s after the sign-in: l12 43 s, l13 44 s, l14 33 s. l13's sign-in
  was 17 s later than l12's and l14's 6 s later. The highest generation number of the two launcher helpers was 23 and
  24 (l12), 22 and 25 (l13), 28 and 30 (l14), so the count of 64 MiB rolls does not track the delay.
- **l13: the game-SC end, 0155, and the death (M, the cause I).**
  - The game-SC end fired at +280.6 (7010 MB) and ended one of three helper processes; 0138 refused 7 restarts.
  - At +314.1: `re-sign-in after end (steam-language)` → `restarts allowed: the sweep stops (allow 1, decision
    0155)`. **No `no-headroom` line.** The helper restarted five times (`restart allowed start 9`–`13`, +318.6 to
    +362.2), 10 s apart; the footprint went to 7122 (+320.6), 7282 (+322), 7421 (+324.7), 7590 (+366), max `fpMB` 7627;
    compressed 3.9 GB, graphics 3.6 GB, 556 threads, band 10957 MB used.
  - The log stops at +374.69 with `fpMB=7461`, with no crash file and no result: pp ui reported `launch=failed` and the
    app restarted. The limit is 8192 MB, so this is not a plain footprint-limit kill. I: jetsam on system memory or a
    lower phys-footprint threshold; not determined.
  - I: 0155's allow let Social Club come back at 7.0 GB and its restart loop cost the 600 MB that ended the run.
    (In l14 the sweep refused every restart (100 of them in the run) and the game stayed in the cabin to
    first-frame+600; in l12 18.)

**Verdict.** Story reaches and holds the cabin in two of two runs that kept the game's Social Club ended (l12, l14:
peaks 7200 and 7058). l13 reached it too, but the allowed re-sign-in's helper restarts then lost the app at 7.5–7.6 GB.
The cabin margin without the pool's early stop is **not shown** to be a problem (l14's pool stopped at the step, with
a step 142 MB lower), but 0155's allow path is a hazard at that footprint.

## Games observed (l13, l14)

- Hollow Knight (367520): works; `pp perf` 58.7 fps on the HUD run (`p476l13-hk-after`).
- Red Dead Redemption 2 (1174180): dev stock-CEF probe, Story cabin reached and held in l14 (peak 7058 MB, 20 fps),
  l13 reached the cabin and then ended (app killed at +374 s after Social Club restarts). A dev experiment, no
  change to the compatibility status.

## l15–l16: probe refusal, avail-phys per process, image-cache v2, one start per allow — neither run reaches Story

IPA `b1a239f2717c8fa6b0f0d4810d2d2862b858f6534cf1b875febd827292ff3451`, built from HEAD `1413ed9`:
- madeira-unix 0236: the helper's impossible V8 reserves are refused before the map walk;
- 0237: the avail-phys log limit is per process;
- 0238: the image-cache key carries the ctime, and each use runs a 16-point sampled check;
- 0239 (0155 amendment 2): one start per allow.

`./pp test` passed; `verify-ipa` 90/0.

The session (`agent-notes/pla476/l15.sh` under one `pp phone lock`):
- status: 80 %, on power, 2.4 GB free;
- in-place install (29 s);
- HK first-frame+10;
- RDR2 l15 and l16 with l12's keys, `STORY_BY=420 UNTIL=600 WAIT=900`.

The arm (`arm15.sh`) is `arm13.sh` plus `set:endGameSocialClubAfterSignIn=true set:refuseGameSocialClubRestart=true`: the
owner had played RDR2 by hand just before, with the game-SC end off. Both RDR2 runs were ended by the arm's
deadline (no Story press by +420 s), and `pp ui` pulled no host log. The logs were pulled afterwards with
`pp phone pull` (`s1-host.prev.log` is l15, `s1-host.log` is l16), and both are copied into the run dirs. M = measured,
I = inferred.

- **HK (M):** first-frame+10 passed, first frame +11.78 s (`$PLAYPORT_BUILD/ui-runs/20261030T202011-hk-p476l15`,
  IPA sha checked).
- **l15** (`…/20261030T202106-rdr2-p476l15`):
  - **The launcher's helper A died** at +89.66 `[xp]` in Chromium's out-of-memory exit (`0xE0000008`,
    `[chromium-oom] request 0x3c0 bytes`, a small allocation). This was after the game's first frame (+83.7 title
    clock) and before any sign-in.
  - The launcher started a new helper (+91.5; kinds 1–6 granted). At +99 its 1280×600 window was shown over the
    game (`a dialog is shown over the game`). The shots show a dark card with a red button and no text from +106 to
    the end.
  - The game never signed in: there is no `signed in` line and no game helper start.
  - Cause of A's out-of-memory: not determined. No refused reserve or commit was logged before it, and its V8
    setup was normal: 26 probes refused, kind 6 granted.
- **l16** (`…/20261030T202901-rdr2-p476l16`):
  - The game signed in at +104.5. The launcher ended, and A's exit line counted `26 impossible probes refused`.
  - **The game's helper B died** at +115.6, also in Chromium's out-of-memory exit (`request 0 bytes`), before it
    signed the game in:
    - after the kind-6 grant, V8's 1 GiB range (hint `0x60800000000`, offset 0 within 16 GiB) took the jumbo
      "plain" candidates. All were occupied, and the kernel pick gave `0x72b0370000`;
    - V8 dropped that pick and tried twice more. Its padded `0x13fff0000` reserve then found no gap: the window was
      `free=5751 MB maxhole=4203 MB`. That gave 4 `NO GAP FITS` lines, and the out-of-memory exit followed;
    - in l12/l14 the same 1 GiB took the "guard" candidate `0x7100000000` on its first try (hint offset 4 GiB).
  - 0138 then refused 60+ restarts, and the game stayed on its black loading spinner (shots from +126 to the end).
  - l13's five restarted helpers died the same way (I: one mechanism, V8's code range by the random hint's
    offset and the window's state).
- **Whether 0236 caused either death (I):**
  - 0236 refuses only ≥ 16 GiB unhinted asks, and ≥ 8 GiB once the helper owns kind 6. B died at the 1 GiB step, before
    any (b) refusal: its count was `6`, the ladder only.
  - A's death came 60 s after its last refusal.
  - So neither failure points to 0236, 0237 or 0238; it is not excluded either. The owner's hand play just before
    the session is a confounder: settings, and the phone's memory and page cache.
  - These are the first first-helper out-of-memory deaths in l3–l16 (l2 had one).

**Against l12/l14 (M unless marked).**

| | l12 | l14 | l15 | l16 |
| --- | --- | --- | --- | --- |
| result | cabin, ff+600 | cabin, ff+600 | **no sign-in**; deadline +420 | **no Story** (B died); deadline +420 |
| first frame (title clock) | 92.8 | 96.7 | 83.7 | 87.8 |
| game signed in | +110.3 | +116.1 | none | +104.5 |
| A / B `NO GAP FITS` | 26 / 26 | 26 / 26 | **0 / —** | **0 / 4** (`0x140000000`, the code-range fallback) |
| refusal counter (exit line) | — | — | A 26; A's restart 2 logged, alive at the end | A 26, B 6 |
| kind-6 grants | A, B | A, B | A, A's restart | A, B |
| V8 probe walks / kind 5 → kind 6 grant | walks A 6.8 s, B 13.1 s | walks as l12 | no walk; A 0.30 s (+27.83 → +28.13) | no walk; A 0.31 s, B 0.35 s |
| SC renders / signs in | yes / yes | yes / yes | launcher pages rendered (R★ windows); then a blank card / no | yes / yes, then B died |
| avail-phys lines | 4, all A's | — | 4 A, 4 A's restart | 4 A (`0x14692c000`), 4 B (`0x17bcac000`) |
| peak `fpMB` | 7200 | 7058 | 5564 | 5737 |
| graphics at the end | — | — | 1510 | 1542 |
| game-SC end / 0155 / 0239 | end, no allow | end, no allow | none | none (B died; 0138 refused 60+) |
| jetsam | none | none | none | none |

- **Image cache v2 (M).**
  - l15's writer first deleted the three `v1-…` copies (`deleted v1-… (an older version's copy)`).
  - It then wrote the v2 copies: Social-Club-Setup.exe 122 MiB in 118 ms, libcef 239 MiB in 290 ms, RDR2.exe
    115 MiB in 173 ms. The v2 names carry the ctime (`…-1793376429.0752…`).
  - Every later map logged `16 sampled points equal the file`: l15 A's second map, the game, A's restart; in l16
    every map, including B's.
  - There was no difference line and no rewrite.
- **avail-phys per process (M):** the game's helper's answers are now logged (l16 B: 4210, 4028, 4080 and 4048 MB
  reported as 300). The cap is unchanged.
- **The cabin, the game-SC end and 0155:** not reached, so not exercised. 0239's one-start rule is untested on the
  phone.

**The l13 cascade, revisited (M, from the l13 log).**
- The five starts the one allow let through (+318.6 to +362.2) each died 10–15 s after starting in the same
  out-of-memory exit (`request 0 bytes`). At Story, the window's largest hole was 515 MB, so V8's
  `0x13fff0000` code-range reserve failed.
- The game restarted the helper 0.3 s after each exit.
- The game had left Story before the restarts, about 7 s after its GetCurrentGameLanguage burst:
  - cabin frames run to +318.6;
  - empty 60 fps frames start at +319.5;
  - DirectSound's mixer thread starts at +320.0.
  This is d1's sequence.
- Hence 0155 amendment 2 (one start per allow, owner 2026-10-30).

**Verdict.**
- The V8 probe gate is met for the launcher's helper in both runs, and for B's 26 old lines: 0 `NO GAP FITS` from A.
- B's 4 lines are a new fallback: V8's code-range reserve, not the probes.
- The helper's 1 GiB code range now looks like a separate hazard. Its placement depends on V8's random hint and
  on the window. It killed a first helper in l16, A died differently in l15, and neither run reached Story.
- The chunk-2 cabin and peak gates are not shown on this IPA.

## Games observed (l15, l16)

- Hollow Knight (367520): works; first-frame+10 at +11.78 s on `b1a239f2…`.
- Red Dead Redemption 2 (1174180): dev stock-CEF probe on `b1a239f2…`; neither run reached Story. In l15 the
  launcher's Social Club helper died before the sign-in; in l16 the game's helper died after the sign-in and the
  game stayed on its loading spinner. A dev experiment, no change to the compatibility status.

## l17–l18: repeat on b1a239f2

The same installed IPA as l15–l16, `b1a239f2717c8fa6b0f0d4810d2d2862b858f6534cf1b875febd827292ff3451` (HEAD
`1413ed9`). There was no code change, no build, no install and no HK run. `pp phone status`: installed `b1a239f2…`,
80 %, on power, no JIT timeout. Nobody played by hand before the session. The session was
`agent-notes/pla476/l17.sh` under one `pp phone lock`: a 300 s idle gap (the phone was warm), then l17 and l18 with
`arm15.sh`, l12's keys (`env.PLAYPORT_CEF_SWAP=0 env.PLAYPORT_SC_SINGLE=1 env.PLAYPORT_SC_LAYOUT=1`) and
`STORY_BY=420 UNTIL=600 WAIT=900`. Each run's host log was pulled before the next launch. M = measured, I = inferred.
The `[xp]` clock is the log's.

- **l17** (`$PLAYPORT_BUILD/ui-runs/20261030T204959-rdr2-p476l17`): `ok:true`, `until first-frame+600`; `pp ui`
  pulled the log.
- **l18** (`…/20261030T210408-rdr2-p476l18`): `pp ui` returned `ok:false`, `the app exited before the stop
  condition`, at +361.5 s after its launch. **The app had not exited (M).** The phone's network link dropped:
  `pymobiledevice3` gave `Device is not connected` from 21:10:20 to 21:10:33, and `pp phone status` after the run
  and again three minutes later showed the same app pid alive. `pp ui` pulled no log, so the session pulled it with
  `pp phone log` (`pull/`). A second locked session (`agent-notes/pla476/l18-tail.sh`) then let the game run to the
  planned first-frame+600 (`[xp]` +717), took a shot, pulled the log again (`pull2/`, a superset of `pull/`), and
  ended the app with `pp phone kill`. The figures below come from `pull2/`.

**Against l12, l14, l15 and l16 (M unless marked).**

| | l12 | l14 | l15 | l16 | l17 | l18 |
| --- | --- | --- | --- | --- | --- | --- |
| result | cabin, ff+600 | cabin, ff+600 | no sign-in | no Story (B died) | **cabin, ff+600** | **cabin**; `pp ui` stopped at +361.5 on a link drop; the game ran on to `[xp]` +717 |
| thermal at launch | nominal | serious | — | — | nominal (serious later) | serious |
| first frame (title clock) | 92.8 | 96.7 | 83.7 | 87.8 | 80.7 | 112.3 |
| game signed in `[xp]` | +110.3 | +116.1 | none | +104.5 | +96.2 | +130.2 |
| Story pressed `[xp]` / after sign-in | +152.8 / 42.5 s | +149.3 / 33.2 s | — | — | +123.6 / 27.4 s | +160.8 / 30.6 s |
| `0xE0000008` / `[chromium-oom]` | none | none | A, `request 0x3c0` | B, `request 0` | **none** | **none** |
| A's fate | ended at sign-in | ended at sign-in | OOM exit +89.7 | ended at sign-in | ended at sign-in (+96.2) | ended at sign-in (+130.5) |
| B's fate | game-SC end | game-SC end | never started | OOM exit +115.6 | game-SC end (+224.7) | game-SC end (+285.6) |
| refusal counter (exit line) A / B | — | — | 26 / — | 26 / 6 | **26 / 26** | **26 / 26** |
| logged refusals A / B | — | — | 2 / — | 2 / 2 | 2 / 2 (512, 256 GiB) | 2 / 2 (512, 256 GiB) |
| `NO GAP FITS` A / B / game | 26 / 26 / 1 | 26 / 26 / 1 | 0 / — / 1 | 0 / 4 / 1 | **0 / 0 / 1** | **0 / 0 / 1** |
| V8 1 GiB code range A | guard → `0x7300000000` | guard → `0x7100000000` | guard → `0x7200000000` | guard → `0x7300000000` | guard → `0x7200000000` | guard → `0x7300000000` |
| V8 1 GiB code range B | guard → `0x7300000000` | guard → `0x7100000000` | — | **plain ×6 → kernel pick `0x72b0370000`** | guard → `0x7300000000` | guard → `0x7300000000` |
| the Story step `[xp]` (`fpMB`) | press+76.5 (→ 7190) | press+103 (→ 7056) | — | — | +224.3–224.7, press+101 (5929 → 7058) | +283.8–284.1, press+123 (5848 → 7167) |
| game-SC end `[xp]` | +229.9, 7185 MB | +268.3, 7051 MB | none | none | +224.3, 7063 MB, press+101 | +285.6, 7170 MB, press+125 |
| 0138 refusals after the end (highest start) | 18 | 100 | — | 60+ | 110 | 90 |
| 0155 / 0239 lines | none | none | none | none | **none** (no allow, no `restart allowed start`) | **none** |
| peak `fpMB` (to +400) | 7200 | 7058 | 5564 | 5737 | 7407 (+310.8) | 7407 (+380.5) |
| peak `fpMB` (whole run) | 7200 | 7058 | 5564 | 5737 | **7468** (+768.9) | **7645** (+668.9) |
| jetsam | none | none | none | none | none | none |

- **The code range (M).** Each helper's 1 GiB ask follows its kind-6 grant within milliseconds: `[jumbo] hinted
  reserve <hint> … failed (0xc000000d) — offset-preserving retry`. V8's hints are 4 GiB aligned. Of the 12 asks from
  l12 to l18, the 11 whose hint had an offset of 4, 8 or 12 GiB within 16 GiB took `cand guard
  slot=0x7400000000` and got `0x7000000000` plus that offset on the first try. l17's hints were `0x55e600000000` (A, 8 GiB) and
  `0x574f00000000` (B, 12 GiB); l18's were `0x582700000000` (A, 12 GiB) and `0x2fd700000000` (B, 12 GiB). The only
  offset-0 hint (l16's B, `0x60800000000`) took `cand plain` and failed, and that helper died. I: a code-range hint
  at offset 0 within 16 GiB is the trigger for l16's death. If V8's hint offset is uniform, about one helper in four
  would take that path. l15's A death is not explained by the code range: its ask got the guard slot
  `0x7200000000`.
- **The OOM deaths did not repeat (M).** Neither run logged `0xE0000008` or `[chromium-oom]`. Both helpers signed in
  and ended by policy: A at the game's sign-in, B by the game-SC end. Each refused 26 impossible probes, and the only
  `NO GAP FITS` line in each run is the game's own 8960 MiB jumbo walk (`ml1027 size=0x230010000`, the game's
  thread). avail-phys logged four answers per helper, each reported as 300 MB.
- **The cabin (screenshots, described only).**
  - l17: the launcher's "Connecting to Rockstar Games Services" card and the dark R★ window, then the legal text and
    the title screen (snowy mountains, Story/Online). Sepia loading art follows from +140 (a river, a camp, a
    locomotive, a Valentine sign), then a white fade at +232. **Arthur stands on a snowy log cabin's porch** in a
    blue coat and black hat, beside a window, with snow-covered pines behind, from +354 to the last shot (+756).
    The view changes slightly between shots, and `[kk-gpu]` ran at 10–17 fps at the end.
  - l18: the same launcher cards, a red R★ tile, then the title screen (a snowy camp) at +147–166. Loading art
    follows (a rider, a camp, a cabin), then black with a spinner from +258. After the link drop the arm took no more
    shots. The tail session's shot at `[xp]` +717 shows **the same porch view of Arthur**, and `[kk-gpu]` was
    17–21 fps.
  - l12 and l14 showed Arthur sitting on a bed inside the cabin. These runs show the porch; I: a different moment of
    the same opening, not a different place.
- **Peaks (M).** The Story step was 1100–1300 MB tall, as in l12 and l14. The game-SC end fired at the step in both
  runs (7063 and 7170 MB). After it, the footprint settled at 7.1–7.4 GB, and it kept rising slowly late in the run:
  7468 MB at +769 (l17) and 7645 MB at +669 (l18), both after the l12 and l14 window ends. Both stay inside the
  7343 MB ±10 % band and under the 8192 MB limit. I: the late growth is the game's (B was gone); not analysed.
- **0155 / 0239:** no re-sign-in allow happened, so 0239's one-start rule is still unexercised on the phone.
- **Jetsam (M):** none. The system log has no kill of the app, and no JetsamEvent report from the day was pulled.
  The only kills were of system daemons, for being idle or over their own limits.

**Verdict.**
- l15–l16's helper OOM deaths **did not repeat** on the same IPA: 0 of 4 helpers, against 2 of 3 in l15–l16.
- Story reached and held the cabin in both runs: l17 to first-frame+600, and l18 to `[xp]` +717.
- 0236's refusal held for all four helpers (26 each), with 0 V8 `NO GAP FITS`, so the chunk-2 `NO GAP FITS` gate is met
  for A and B in both runs.
- I: l16's B death fits the offset-0 code-range path, which neither run hit. l15's A death (`request 0x3c0`)
  remains unexplained. It came after the owner's hand play, which is a confounder that l17–l18 did not have.
- **Tooling:** a dropped network link makes `pp ui` report `exited` while the app keeps running, and it then pulls
  no log.

## Games observed (l17, l18)

- Red Dead Redemption 2 (1174180): dev stock-CEF probe on `b1a239f2…`. Story reached the cabin in both runs: peaks
  7468 and 7645 MB, 10–21 fps at the end, no jetsam. A dev experiment, no change to the compatibility status.

## l19: diagnostics

l19 (IPA `5db127bd…`, `$PLAYPORT_BUILD/ui-runs/20261030T215326-rdr2-p476l19`, l12's keys) ran the PLA-364
log-only diagnostics, recorded in [2026-10-30-rdr2-kk-audio-diagnostics](2026-10-30-rdr2-kk-audio-diagnostics.md).
For this plan's gates it adds the following.

- HK first-frame+10 passed (`…/20261030T215237-hk-p476l19`). The game's helper got kinds 1–6. Story was pressed.
  No SC or launcher `NO GAP FITS` was logged. Peak 7631 MB, no jetsam.
- The heavy scene (I: the cabin) ran 42 s. Then the game stayed on a black spinner to the end, after
  `[game-sc] re-sign-in after end: no headroom (7585 MB), restart stays refused`. l17 and l18 logged no re-sign-in.

## l20–l21: decision 0169 gate

M = measured, I = inferred. Chunk A's phone gate on decision 0169 (madeira-unix 0243; the game's own helper is not ended).
IPA `$PLAYPORT_BUILD/out/20261030-223218-6b5be569/Playport-26.5-6b5be569.ipa`, sha256
`6b5be56936ad84eed375304e65f937ecfacf662c135ce50ee3124b26b924841d` (dev, head `dc73497`: 0243 `211070e`,
app `6bae711`, decision 0169 `dc73497`).

### Session

One locked session, `$PLAYPORT_BUILD/agent-notes/pla476/l20.sh` (lock session `c9ccc3508fb9`, rc 0;
output `$PLAYPORT_BUILD/agent-notes/pla476/l20-lock.out`).

- `pp phone status` before: 80 %, on power, Network connection, unattended on, 2.9 GB free. No JIT timeout.
- In-place install of 6b5be569 (container kept); the status after it shows the hash.
- **HK** `$PLAYPORT_BUILD/ui-runs/20261030T225730-hk-p476l20`: ok, first frame +11.33 s.
- **RDR2** through `$PLAYPORT_BUILD/agent-notes/pla476/arm20.sh`: arm15 without `set:endGameSocialClubAfterSignIn` and
  `set:refuseGameSocialClubRestart`. hud:off and donorPoolMB=auto are kept. Keys
  `env.PLAYPORT_CEF_SWAP=0 env.PLAYPORT_SC_SINGLE=1 env.PLAYPORT_SC_LAYOUT=1`, STORY_BY=420,
  until first-frame+600, wait 900. There was a 180 s idle between the two runs.
  - **l20** `$PLAYPORT_BUILD/ui-runs/20261030T225818-rdr2-p476l20`: ok, until first-frame+600. `pp ui` pulled the host log.
  - **l21** `$PLAYPORT_BUILD/ui-runs/20261030T231556-rdr2-p476l21`:
    - `pp ui` ended at +337 s with "the app exited before the stop condition" (`ok:false`). The phone's syslog
      capture logged `Device is not connected` at 23:21:53, the same second. This is a PLA-540 network drop: the
      app was still running (`app_pid` 13013).
    - The script let the app run to launch +760 s, took a tail shot, pulled the host log again into `pull2/`
      (170547 lines; its `[frames]` run to +772), then ended the app.
    - The analysis uses `pull2/s1-host.log`.
- No pp perf was run. Shot sheets: `$PLAYPORT_BUILD/agent-notes/pla476/l20-sheet.png`, `l21-sheet.png` (not for
  publication). Analysis scripts: `$PLAYPORT_BUILD/agent-notes/pla476/l20-analysis/` (`summ.py`, `cabin.py`, `bproc.py`,
  `lang.py`, `sheet.py`).

### The switches: how the stored value was cleared

- There is no unset action. `set:KEY=` stores an empty string, which reads as `false`: stored, but not unset
  (UIDriver `set`, `GameSocialClubEnd.stored`). The arm therefore sets neither key.
- l19 set both keys without `--keep-settings`, so its session recorded them for undo. The app's first launch outside
  that session put them back. The same mechanism is on record at l17's start: an `app:settings-restored` event
  listing both keys (session `94ef06adff01`, in l17's `events.jsonl`). None of this session's `events.jsonl`
  files has that event. `pp phone status` showed the app already running (pid 12416) before this session, so I
  infer that launch did l19's undo.
- The launch line confirms the state (M). Both runs log
  `launcher: the game's own Social Club is not ended under the Social Club layout (decision 0169)`
  (l20 line 35, l21 line 40). Neither run logs `ends too` or `helper starts after the first are refused
  (decision 0138)`, nor any `[game-sc]` line.

### Per run

Times are on the `[xp]` clock (≈ launch clock). fps, phys, graphics and compressed are min/median/max from Story
+150 s to the log's end. Peak is the `[xp]` fpMB maximum and the `[footprint]` peak.

| | l12 | l14 | l17 | l18 | l19 | **l20** | **l21** |
| --- | --- | --- | --- | --- | --- | --- | --- |
| IPA | earlier | earlier | b1a239f2 | b1a239f2 | 5db127bd | 6b5be569 | 6b5be569 |
| game-SC end (B) | +230 | +265 | +224 | +286 | +248 | **none (0169)** | **none (0169)** |
| restarts refused | ≥100 | ≥100 | ≥110 | ≥30 | ≥80 | **0** | **0** |
| sign-in / Story press | +110 / +153 | +116 / +149 | +96 / +123 | +130 / +160 | +112 / +140 | +96 / +124 | +100 / +128 |
| Story to ff+600 | cabin | cabin | cabin | cabin (log to +436) | **left Story ≈+290, spinner** | **cabin** | **cabin** |
| cabin fps | 20.3 | 19.8 | 16.5 | 15.1 | (59: spinner) | 17.8 | 16.2 |
| phys median / max MB | 7083 / 7161 | 6939 / 7004 | 7272 / 7468 | 7359 / 7461 | 7539 / 7614 | **7742 / 7930** | **7811 / 7996** |
| fpMB max (of 8192) | 7200 | 7058 | 7468 | 7438 | 7622 | **7960 @+793** | **8006 @+651** |
| graphics median / max MB | 3509 / 3588 | 3501 / 3574 | 3870 / 4052 | 3899 / 4001 | 3963 / 3994 | 3947 / 4130 | 3918 / 4116 |
| compressed median MB | 3907 | 1936 | 4057 | 3786 | 4434 | 4338 | 4238 |
| NO GAP FITS lines | 53 | 53 | 1 | 1 | 1 | 1 (game) | 1 (game) |
| B code range | guard → 0x7300000000 | guard → 0x7100000000 | guard → 0x7300000000 | guard → 0x7300000000 | guard ×3 fail → retry 0x7100000000 | guard → 0x7100000000 | **plain ×6 fail → sc-aligned 0x7100000000** |
| helper OOM 0xE0000008 | none | none | none | none | none | none | none |
| Playport jetsam | none | none | none | none | none | none | none |

### Gates

#### The 0169 line; no game-SC end; no restart refusal (M): passed

- l20 and l21 each log the 0169 line once at launch.
- Neither logs a `[game-sc]` line, a 0138 refusal line or a `game-social-club-ended` event.
- There are exactly two `[sc-rph]` helper starts per run (A at +25, B at +97 / +101) and two kind-6 grants. The
  game started no third helper.

#### B alive through Story, and what it costs (M, with the delta inferred)

- B is pid 04fc (1276), the pid that 0153 ended in l17–l19. It ran from +97 / +101 to the end in both runs: 59–60
  threads at the last `[proc-mem]` sample (+658 / +712). It had no exit line.
- B's resident + compressed in `[proc-mem]` (image + private + FEX):
  - l20: 447 MiB at +159, then 326 / 332 / 315.
  - l21: 444 at +163, then 402 / 313 / 315.
  - In l17–l19, B held 362–438 MiB at its last sample before the end.
- Footprint against l17/l18 (same graphics profile): phys median +380 to +540 MB and max +460 to +530 MB.
  - I: most of this is B's ≈315 MiB staying resident. Run-to-run and IPA differences account for the rest:
    graphics max is +80–110 MB, and compressed is similar.
  - l19 sat on a spinner, so its numbers are not comparable.

#### Story cabin to ff+600 (M; shots described, not published): passed in both

- **l20.** Shots:
  - menu at 0124;
  - sepia loading art 0142–0196;
  - black with a loading glyph at 0215;
  - Arthur at the snowy cabin's window/porch from 0282, unchanged in framing through 0382, 0427, 0562, 0638,
    0710, 0788 and `screen-stop.png` (ff+600).
- **l21.** Shots:
  - menu at 0123;
  - loading art 0141–0196;
  - black with a loading glyph 0214–0234;
  - the cabin at 0284, 0339 and 0382;
  - shots stop at the network drop. The tail shot `tail-232840.png` (launch +760 s ≈ ff+680) shows the same cabin
    view.
- `[frames]` advance steadily to the end in both runs: 17.8 and 16.2 fps in the cabin. l21's frames go on past the
  drop to +772, so I infer the cabin held throughout.
- There was no black spinner (l19's failure), no overlay and no sign-in card.

#### Peak against 8192, and jetsam (M)

- **Peaks:** l20 fpMB 7960 ([footprint] peak 7930), 232 MB under the limit. l21 fpMB 8006 (peak 7996), 186 MB
  under; `fp-sample` limit_remaining min 362.
  - These are the highest of the series: +340 to +570 over l17–l19. The decision-0153 headroom no longer applies,
    because nothing ends B.
- **Jetsam:**
  - No JetsamEvent report for 2026-10-30 (`crash ls` lists none newer than 2026-10-20).
  - The syslog shows no Playport kill, only system daemons: `killing_idle_process` at +100 s, and
    `nanoprefsyncd` highwater.
  - l21's syslog capture ends at 23:23:10, when `pp ui` ended. The 6 min after that are covered only by the app
    log, which ran on with frames and was ended by the script.
- **Thermal:** l20 fair at +182, then serious at +414. l21 fair at +43, then serious at +68.
- **Donor pool:** 4096, growth stopped at +191 / +203 (pressure level). No pool failures.

#### V8 1 GiB code range, per helper (M)

| run | A (launcher SC) | B (game SC) |
| --- | --- | --- |
| l20 | `cand guard slot=0x7400000000 -> 0x7100000000 st=0` | `cand guard slot=0x7400000000 -> 0x7100000000 st=0` (hint 0x5cb900000000, retry → 0x7100000000) |
| l21 | `cand guard … -> 0x7100000000 st=0` | `cand plain` 0x7c/0x78/0x74/0x70/0x6c/0x68 00000000 all `st=0xc0000018`, then **`cand sc-aligned base=0x7100000000 st=0`** (hint 0x88800000000, offset 0 in 16 GiB → plain path; retry → 0x7100000000) |

- Every result base is 0x7100000000, which is 4 GiB-aligned.
- l21's B is l16's failing case: a hint at offset 0 takes the plain path and every slot is taken. In l16 that
  path fell to the kernel's unaligned `0x72b0370000`, then 4 NO GAP FITS, then an OOM exit. Here 0243's sc-aligned
  candidate landed on the first try. V8 asked for no second code range (no further `[jumbo]` lines).
- **NO GAP FITS per PEB:** A 0, B 0 in both runs. The single line per run is
  `[mmap-place] ml1027 NO GAP FITS size=0x230010000`, followed by `0360:err … size 230000000`: the game's own
  8960 MiB walk (RDR2 thread 0360, pid 035c), as in l15–l19.
- **Refusal counters (0236):** A logged 2 refusals, and its exit line reads `26 impossible probes refused`. B logged
  2 refusals (512 GiB, 256 GiB); it never exited, so it has no count line.
- B's `allocate_virtual_memory_body out of memory … size 20000000` (22 per run) are the same count as l17–l19 (I:
  V8 probe asks Wine reports, not failures of the helper).

#### Helper OOM 0xE0000008 (M): none

- No `code=e0000008` or `exit_code=0xe0000008` in either run.
- The only SocialClubHelper end is the launcher's (A, pid 388, exit 1067 at the sign-in end, as in every run).

#### Re-sign-in (M, with one inference)

- The game never asked. There is no sign-in card or overlay in any shot after Story, and no third helper start.
- After +150, GetCurrentGameLanguage was called once (at +690), in both l20 and l21. That is the same as l17.
  - l19's re-sign-in came with a burst (4 calls at +270), after its end.
  - I: with B alive the game has no reason to sign in again. 0155's watch is not armed, because the end is off.

#### Graphics ledger (M)

- `[footprint]` graphics in the cabin:
  - l20: median 3947, max 4130, end 3992.
  - l21: median 3918, max 4116, end 3913.
  - l17/l18: 3870 / 3899, max 4052 / 4001.
- `[kk-mem]` in the cabin:
  - metal 3020–3255 MB (l17 2979–3083);
  - memory=118/1694 (l17 117/1662);
  - command 1806–2044 / 804–1026 MiB (l17 1730–1940);
  - allocators 45 / 781 → 870 MiB, flat from +690 (l17 735 → 825).
- The same profile as l17–l19. KosmicKrisp's command memory (PLA-364) is unchanged by chunk A, as expected.

### Verdicts

| Gate | l20 | l21 |
| --- | --- | --- |
| HK first-frame+10 | passed (+11.33 s) | — |
| 0169 line, no game-SC end, no refusal line | **passed** | **passed** |
| B alive through Story | **passed** (≈315 MiB) | **passed** (≈315 MiB) |
| Story cabin held to ff+600 | **passed** | **passed** (shots to +382 and tail ≈ff+680; frames throughout) |
| Peak under 8192 / no jetsam | **passed, thin**: 7960 (232 MB headroom) | **passed, thin**: 8006 (186 MB headroom) |
| V8 code range aligned, helpers 0 NO GAP FITS | **passed** (guard/guard) | **passed** (guard / plain → sc-aligned) |
| No helper OOM | **passed** | **passed** |
| No re-sign-in | **passed** | **passed** |

### Residual risks

- **Headroom.** With B alive, the cabin peaks at 7960–8006 of 8192 MB, 186–232 MB under the limit, against
  560–730 MB in l17–l19.
  - A heavier scene than the opening cabin, or longer play, is untested and may reach jetsam.
  - The KosmicKrisp retire path (mesa 0132–0133, opt-in) is the planned offset.
- l21's 0243 sc-aligned path ran once, in one shape: the plain ladder full, then the first aligned base free.
  The case where every aligned base is taken was not exercised on the phone.
- l21 lost its `pp ui` connection at +337 s (PLA-540). Shots between +382 and the tail are missing, and the
  syslog jetsam coverage ends at 23:23:10. The app log covers the rest.
- Thermal serious early in l21 (+68 s).

### Games observed (l20, l21)

- Hollow Knight (367520): works, first-frame+10 at +11.33 s, IPA 6b5be569…,
  `$PLAYPORT_BUILD/ui-runs/20261030T225730-hk-p476l20`.
- Red Dead Redemption 2 (1174180), dev stock-CEF probe under decision 0169 (no game-SC end), IPA 6b5be569…:
  - l20 (`$PLAYPORT_BUILD/ui-runs/20261030T225818-rdr2-p476l20`) and l21 (`$PLAYPORT_BUILD/ui-runs/20261030T231556-rdr2-p476l21`):
    signed in, Story, the cabin held to first-frame+600 at 16–18 fps;
  - peak 7960 / 8006 MB of 8192, no jetsam.
  - Dev experiment; no status change.
