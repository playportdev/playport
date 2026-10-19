# 2026-10-19: RDR2's blue band is its landing page: one A press starts the Story load, which runs the app into the 8,192 MB limit; a Metal capture of the band is refused by KosmicKrisp's counter heap

**Linear:** PLA-364 (related: PLA-413, PLA-416, PLA-420). **Plan:** `.work/plans/rdr2-blue-band.md` (test 1).
**Owner's approval:** 2026-10-19, an exception to PLA-401: one A (or Enter) press, only on the blue band.
Later that evening the owner lifted the input limit (Story mode only; no credentials or purchases).
The press run below still pressed only once.

## Builds and runs

| IPA sha256 | HEAD | Run | What |
| --- | --- | --- | --- |
| `c97f4cbc961279372168d24120b2c6a11684f75d14dce4483961bd5792fc3f6f` | 7fb568f (installed 21:57) | `20261019T224158` | RDR2, cut at first frame +2 s by the workstation's own command timeout; nothing pressed. Not used below |
| same | same | `20261019T224547` | **The press run:** `--pad --action set:donorPoolMB=auto --play app-1174180 --until first-frame+600 --wait 1500`, screenshots every 5 s from 90 s to 175 s after the launch, every 10 s from 180 s to 460 s, then every 60 s, device log kept |
| same | same | `gpu-runs/20261019T230942` | Hollow Knight `pp gpu capture --frame 600`: the tool's new bundle removal (below) |
| same | same | `gpu-runs/20261019T231602-rdr2` | RDR2 `pp gpu capture --frame 3000 --secs 150 --expect-gb 2`, the donor pool on Auto, no press |

- **The phone:**
  - before the press run: 49 %, not charging, 5.6 GB free;
  - after it: 58 % and charging, 5.0 GB free;
  - before the RDR2 capture: 5.8 GB free;
  - after it: 78 % and charging, 5.1 GB free.
- **The press:** `.work/agent-notes/pla364/press-on-band.py` followed the run's events and
  screenshots, and pressed A (`pp pad send "150 A" "500 -"`) once, when all of these held:
  - the game had signed in;
  - no guest dialog was up;
  - the screenshots had shown the band for at least 30 s without a break;
  - at least 120 s had passed since the first frame;
  - the newest screenshot, at most 15 s old, showed the band.

  The host log has the press at **22:50:20.594 to 22:50:20.744** (`vpad: step 1/2`). That was
  first frame +123 s, 85 s after the band first showed, and 92 s after sign-in. Nothing else was
  pressed. PlayRDR2's "Unable to launch game" box was up from +151.58 s to +153.61 s and was
  closed by a finger on the phone, before the press.
- **The device log** was kept for the whole play. `.work/agent-notes/pla413/phone-play.sh` now
  restarts `pymobiledevice3 syslog live` when its connection drops (PLA-420's log ended at
  "Connection was terminated abruptly"). Here it dropped twice at 22:52:34–44, was restarted
  both times, and ran to the end.
- **Raw data** is private, under `$PLAYPORT_BUILD`:
  - `ui-runs/20261019T224547/`: host log, events, 58 screenshots;
  - `agent-notes/pla364/run2/`: the device log, JetsamEvent reports, the Social Club logs,
    `press.log`/`press.json`;
  - `gpu-runs/20261019T231602-rdr2/`.

## Before the press: the first 60 s after the first frame

The first frame came at +120.16 s (launch +126 s). Sign-in was at launch +157 s (`app:launcher
signed-in`, ff +31 s); the launcher's tree ended at that point (footprint 6,464 MB).

| After the first frame | Screen |
| --- | --- |
| before it | the Rockstar launcher's splash: a grey R* logo on a dark window |
| −1 s | black, with Playport's "Gyro aim" notice |
| +9 s | black |
| +14 s | the red Rockstar Games logo, centred |
| +19 s | black |
| +24 s, +29 s | the game's legal and copyright text, two pages |
| +34 s on | the blue band: rows 297–439 of 737, the full width, flat (0,0,241), with two soft spots in it; black above and below |

**The shotgun-shell loading logo and bar did not show** in any 5-s shot. On desktop that screen
comes about 5 s after the game's sign-in, and the landing page follows within 30 s. Here the band
comes in its place, 3 s after sign-in.

**From ff +34 s to the press** (80 s), every shot was the same flat band. The game was idle:
- reads were 1–4 MB per 10 s (`[xp] rdKB`);
- CPU was 390–550 %;
- 52–55 fps;
- footprint 5,887 MB;
- no RDR2 thread was created after 22:48:53;
- the main WASAPI stream (slot 1) played continuous sound from 22:49:07 (mean 0.004, peak
  ~0.05), which the owner heard as music and birds;
- the dsound stream (slot 2) was silent.

## After the press: the game reacts and loads Story mode

| After the press | Screen (the strip only; black above and below it in every shot) |
| --- | --- |
| −7 s | the flat blue band |
| +3 s | **the strip turns flat purple** (128,31,251) |
| +13 s to +104 s | blocky blue, magenta and cyan patterns, changing from shot to shot: soft diagonal shapes at +13 s, fine noise later, about 16-px blocks |
| +64 s, +114 s to +135 s | flat blue (0,0,241) again |
| +148 s on | the Home Screen: the app had been ended |

The strip never left rows 297–439, so whatever the game drew went only into that strip.

**What the logs show, per 10 s (host log, `[xp]`/`[frames]`/`[footprint]`):**

| Window | Reads (MB) | CPU % | fps | Footprint (MB) | Graphics (MB) |
| --- | --- | --- | --- | --- | --- |
| 22:49:30–22:50:20, before | 1–4 | 390–550 | 52–55 | 5,888 | 1,599 |
| 22:50:20–22:51:20 | 1–41 | 700–860 | 49–52 | 5,537–5,560 | 1,571 |
| 22:51:20–22:51:50 | 16–115 | 860–880 | 46–49 | 5,690–5,918 | 1,673–1,841 |
| 22:51:50–22:52:30 | 219–309 | 1,050–1,810 | 43–50 | 6,394–7,807 | 2,071–2,980 |
| 22:52:30–22:52:40 | 29 | 2,876 | — | 8,033–8,185 | 3,202–3,322 |

- **Threads:** RDR2 (pid 0x414) created 5 threads after the press: two at 22:51:19 (one named
  `wine_threadpool_worker`), two at 22:51:37, one at 22:51:58. It had created none in the 2.5 min
  before.
- **Audio:** the dsound stream (slot 2) stopped at the press; it has no line after 22:50:16. The
  main stream went on playing sound until 22:52:17, then was near silent.
- **ACPI:** at 22:51:26, RDR2's thread 0460 made the ACPI firmware-table query: one `provider
  41435049 action 0` (enumerate), answered `c0000002` (not implemented), between two SMBIOS
  (`52534d42`) size-then-read pairs, both answered validly. On desktop this query comes only in
  runs that load Story mode, never on the landing page. In this run it came only after the press.
- **Social Club:** the game's `socialclub.log` adds `Cloud file registered: Player` twice, at
  SDK +195.3 s and +216.4 s (about 22:51:23 and 22:51:44). Before the press its last line was the
  sign-in.
- **Files (device-log FSEvents):**
  - `Red Dead Redemption 2/Profiles/<id>/Player` and `…/cloudsavedata.dat`, at 22:51:3x and
    22:51:5x: the save is being loaded;
  - Metal's `functions.data` cache at 22:51:2x–22:52:3x;
  - at the process's end (22:52:5x), `exit_file.dat` and the launcher renderer's cache files.
  - Before the press, from 22:49:30 on, there was no game file event.
- **The end:** the device log has `memorystatus: S1Probe [42220] exceeded mem limit: ActiveHard
  8192 MB (fatal)` at 22:52:41.175, which is press +141 s. The JetsamEvent report
  `JetsamEvent-2026-10-19-225246` names S1Probe with `per-process-limit` at 524,288 pages
  (8,192 MB). The donor pool refused 22 requests from 22:51:54 on ("no free run fits",
  live 2,675 MB); it had refused 2 before, at 22:48:34 and 22:48:41.

### The footprint at the jetsam

These rows are from the last `[proc-mem]` sample, 22:52:29. They are in MiB, as
committed/resident/compressed. The footprint line at that point is phys 7,805, internal 3,695,
compressed 4,508, graphics 2,980.

| Owner | image | private | fex |
| --- | --- | --- | --- |
| runtime | 185/55/114 | 3,782/15/76 | 3,096/0/59 |
| RDR2.exe (0x414), 73 threads | 70/2/37 | **3,263/421/2,386** | 1,526/148/154 |
| crashpad and others | small | small | 258–748 committed each, ≤266 compressed |
| all | 14,446/663/3,583 | | |

- **Graphics** (the Metal ledger) rose from 1,571 MB at the press to 2,980 MB at 22:52:29, and to
  3,322 MB at the last line, 22:52:39. That is +1.75 GB, the Story load's textures and buffers.
- **RDR2's private memory** reached 3.26 GB committed, 2.8 GB of it resident or compressed. The
  compressor carried most of it: compressed rose from 1.3 GB to 5.75 GB as the load ran.
- **The donor pool** served 2,671–2,675 MB live, outside that table, and was full from 22:51:54.
- **The jumbo hold** is a 8,960 MB `PROT_NONE` reservation (`[jumbo-hold] HELD`) and costs no
  footprint.
- **FEX:** RDR2's fex views are 1,526 MB committed, with 302 MB resident or compressed. The
  runtime's FEX band (3,096 MB committed) is almost all non-resident.

## The Metal capture of the band

- **The tool fix first** (commit 2360c48). `pp gpu capture` now:
  - refuses a capture when the phone's free space minus a 3.5 GB reserve is below `--expect-gb`;
  - deletes the `.gputrace` on the phone after a pull, once the phone's tree has the pulled
    copy's files, bytes and links (`afc.py rm-bundle`, which takes only a
    `Documents/…/NAME.gputrace` and never follows a link).
- **Hollow Knight** (`gpu-runs/20261019T230942`, KosmicKrisp frame 600):
  - first frame +10.57 s;
  - the bundle was 53 files, 808,846,148 bytes and 108 links;
  - it was pulled and removed, and free space went from 5.0 GB to 5.7 GB;
  - `pp phone ls` shows no `.gputrace` left in its folder.
- **RDR2** (`gpu-runs/20261019T231602-rdr2`):
  - first frame at +98.53 s, then the band;
  - **at frame 3000 KosmicKrisp's capture was refused:** `[kk] GPU capture refused (error 1):
    Capturing Metal 4 Counter Heap is not supported.`, 4 times, each followed by `[kk] frame 3000:
    capture refused (…/Games/Red Dead Redemption 2/kk-frame3000-….gputrace)`;
  - no bundle was written, and none is left on the phone.
- **Why it was refused:** RDR2 uses Vulkan timestamp queries. KosmicKrisp backs each timestamp
  query pool with an `MTL4CounterHeap` (`mtl_new_timestamp_counter_heap`, `kk_query_pool.c:236`,
  split by `patches/mesa` 0013). The iOS 27 Metal capture layer refuses to capture a device that
  has one. Hollow Knight makes no timestamp queries, so its capture works.
- **The box during the capture run:** PlayRDR2's box was up from +173.89 s to the stop. Nobody
  closed it, and it did not stop the game from reaching frame 3000.
  - `pp gpu` plays with `--quiet`, so the `dialog shown` mark reached the workstation only at the
    end. The watcher that would have pressed A on it (a controller's A is the box's Enter,
    decision 0076) never saw it.
  - For later runs, the box needs either a play without `--quiet`, or a pad script timed from the
    first frame.

## What this shows

- **The band is RDR2's landing page, and the game takes input there.** Within 3 s of one A press
  the strip changed. The game then did what a desktop Story load does:
  - it read hundreds of MB;
  - it started new threads;
  - it made the ACPI query;
  - it loaded the save's `Player` file.
- **The picture is wrong in the same way before and after the press.** Only one horizontal strip
  (rows 297–439, about 0.40–0.60 of the screen) ever shows anything:
  - the landing page is flat blue;
  - the loading screens are blocky blue, magenta and cyan patterns.

  The rest of the screen stays black, and no text or logo is drawn after the legal pages. This
  points at the game's renderer output, not a stalled state: a pass that writes only that band,
  with colours that look like a wrong texture format or a wrong channel mapping. That is
  inferred, not shown: the capture that would show it was refused.
- **Story mode cannot load in 8,192 MB as it stands.** The load added 1.75 GB of graphics and
  ~4.4 GB of compressed memory in 140 s, and was ended by the per-process limit before it
  finished.

## Not shown

- What draws the band, and why it is flat blue: the capture was refused.
- Whether the Story load would finish, and what it would draw, with more memory.
- Gameplay.
