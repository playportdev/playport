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
