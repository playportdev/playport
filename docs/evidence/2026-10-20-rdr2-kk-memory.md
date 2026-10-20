**Linear:** PLA-413 (and PLA-364)

# 2026-10-20: what KosmicKrisp holds during RDR2's Story load, and two cuts

**Plan:** `.work/plans/rdr2-story-memory.md`.
**Follows:** [rdr2-story-memory-levers](2026-10-20-rdr2-story-memory-levers.md), lever #4: the
KosmicKrisp and host overhead census.

**Status:** measured on the phone (dev builds), with a new census line.
- **Kept:** one cut. The shaders' MSL and NIR are kept compressed, which saves about 400 MB of host
  malloc (mesa 0048, 0049).
- **Not kept:** a second cut, resetting the Metal command allocators. It worked for Hollow Knight,
  but RDR2's long-lived command buffers defeated each of its three forms (section 4).

The Story load still ends at the 8,192 MB limit. It reaches the intro's title cards.

**Run conditions:**
- the phone was unattended (owner away), on external power at 80 %, with 4.7–5.7 GB free;
- the game's settings were at their lowest from the earlier work (`system.xml`);
- every RDR2 run used `--pad --action set:donorPoolMB=auto --action set:endGameSocialClubAfterSignIn=true`;
- PlayRDR2's box was closed with one pad A (decision 0076);
- A was pressed on the Story tab by hand, after a screenshot showed the tab selected and its prompt
  "Story (A)";
- nothing in the Online tab was answered.

**Where things are:** the runs are under `$PLAYPORT_BUILD/ui-runs/`, and the scripts, screenshots and
device logs under `$PLAYPORT_BUILD/agent-notes/pla413d/`.

## Builds and runs

| IPA sha256 | Mesa series | Hollow Knight first frame +10 | RDR2 runs (`ui-runs/…`) |
| --- | --- | --- | --- |
| `a3ca19186006fa973aaee454c252bfff321efbfd8808933a15afd95645c11b25` | 0046 (census) | passed (`20261020T045840`) | `…T045939-rdr2-m1` (landing only; see below) |
| `f5b642213489cabc1ea1079a94e97d18b89dfd72518b1dbdd1ec9a840fbfeccf` | 0046, 0047 (allocator census) | passed (`20261020T061008`) | `…T061102-rdr2-m6a` (landing), `…T061733-rdr2-m6b` (Story) |
| `3f9bfec07cf917758e86e6b102270b81fdf7d26d7ad1ba331da6200265f2f486` | + 0048, 0049 (MSL and NIR compressed) | passed (`20261020T063309`) | `…T063404-rdr2-m7a` (landing), `…T065003-rdr2-m7b` (Story) |
| `500381f60ad18d41b34ae80287ca05e10449f35c7a2d2f92b83d9781556c09a1` | 0046–0049, as committed | passed (`20261020T072258`) | `…T072409-rdr2-m10a` (landing) |

**Builds that were not kept:**
- `58d35fe5…`: the third form of 0050. It passed Hollow Knight (`20261020T070046`). RDR2's runs
  were `…T070141-rdr2-m9a` and `…T070930-rdr2-m9b`; see section 4.
- `4bd22b36…`: a first form of 0050. Hollow Knight ended 23 s after its start, with a null write in
  IOGPU under `vkBeginCommandBuffer` (`ui-runs/20261020T060041`). This build also had the dropped
  form of 0048, below.
- `ded9a76a…`: a second form of 0050. It passed Hollow Knight, but held 950 allocators (1,194 MiB)
  at RDR2's landing page (`…T064220-rdr2-m8a`).
- `9d712de3…`, `ff44be2b…` and `71679b71…`: they read a large pipeline cache from a file mapping,
  and kept its entries out of Mesa's disk cache. `ff44be2b` also set `TMPDIR` in `wine_host.c`,
  which was already set. All of it is dropped (section 2). Their runs were:
  - `…T051536-rdr2-m2a` and `…T052735-rdr2-m2b`;
  - `…T053816-rdr2-m3`, a Story run killed at the limit;
  - `…T055247-rdr2-m4a`.

**Each new Mesa build begins with a translation run.** The pipeline cache UUID and the disk cache
both include the driver's build ID. So the first RDR2 run after a Mesa change translates every
shader again: 1,986 shaders, 35–38 s on the CPU. Only the second run reads them back. The "a" runs
are those first runs, which stop at the landing page; the "b" runs are the Story runs.

## 1. The census: `MESA_KK_DEBUG=memory` (mesa 0046, 0047)

A dev build sets `MESA_KK_DEBUG=compile,memory` (`WineHostRuntime.swift`). At most every 10 s, a
queue submit then logs one line:

`[kk-mem] metal=… bos=… memory=N/MiB internal=… descriptor=… query=… command=… | shaders=N pipelines=N msl=MiB | cache raw=N/MiB precomp=N/MiB | allocators=N/MiB`

What the fields are:
- **metal** is `MTLDevice.currentAllocatedSize`.
- **bos** are KosmicKrisp's buffer objects, by what they back:
  - `vkAllocateMemory` (`memory`);
  - the driver's own (`internal`);
  - descriptor pools;
  - query pools;
  - command upload memory.
- **msl** and **precomp** are the shader source and NIR that the shaders and the pipeline cache keep.
- **allocators** are the Metal 4 command allocators, with the sum of their `allocatedSize`.

### At the landing page (m6b, before A; MiB)

| Part | MiB |
| --- | ---: |
| `vkAllocateMemory`, 93 allocations: the game's own memory | 1,060 |
| descriptor pools (23) | 201 |
| command upload memory (533 buffer objects) | 67 |
| query pools | 1 |
| Metal command allocators (40) | 112 |
| **Metal allocated (`currentAllocatedSize`)** | **1,378** |
| graphics ledger (`[footprint]`) | 1,508 |
| host: MSL kept by 3,129 shaders | 342 |
| host: NIR kept by 1,823 precompiled shaders | 131 |
| host malloc (`DefaultMallocZone`), used / allocated | 904 / 1,411 |

### What the graphics ledger is made of

The graphics ledger is Metal's allocations plus the command allocators' heaps:
- at the landing page, 1,378 + 112 = 1,490, against a ledger of 1,508;
- at the kill, 2,429 + 599 = 3,028, against a ledger of 3,016.

**At the landing page, 1.5 GB of graphics is the game's own memory, not driver overhead.**
- 1,060 MiB is the game's `vkAllocateMemory`.
- 201 MiB is its descriptor pools.
- The 3,136 pipelines it warms there take almost nothing in Metal's allocated size.

**Where the host-malloc jump at the landing page comes from: the warm-up's shader source and NIR.**
- Host malloc jumps from 67 to about 890 MB used during the warm-up.
- 474 MiB of that is the MSL and NIR the shaders keep, for serialization only.
- The zone keeps about 500 MB more allocated than it uses.

### During the Story load (m6b, landing page to the kill; MiB)

| Part | Landing | Kill | Δ |
| --- | ---: | ---: | ---: |
| the game's `vkAllocateMemory` | 1,060 | 1,658 | +598 |
| Metal command allocators | 112 | 599 | **+488** |
| command upload memory | 67 | 362 | +295 |
| KosmicKrisp's 128 MiB tessellation and geometry heap (`internal`) | 0 | 128 | +128 |
| graphics ledger | 1,508 | 3,016 | +1,508 |

**The ledger's growth is accounted for.**
- 40 % of it is the game's memory: +598 of the +1,508 MiB.
- 60 % is KosmicKrisp's: allocators, upload memory and its heap.
- **The allocators** never released anything: nothing in KosmicKrisp called
  `mtl_command_allocator_reset`.

## 2. RDR2 does not hand its pipeline cache file to the driver

The phone's `sga_vulkan_final_init.vkPipelineCacheWindows` was pulled and parsed
(`agent-notes/pla413d/cachecensus.py`):
- 497,024,955 bytes in Mesa's format;
- 4,938 entries;
- 3,115 KosmicKrisp shaders, with 342 MiB of MSL;
- 1,823 precompiled NIR shaders, with 131 MiB.

**The game rewrites the file with the new UUID after a translation run.** The 56-byte header file
changed after m1, m2a and m6a.

**But the driver never receives the file.** A build that logs every `vkCreatePipelineCache` with
16 MiB or more of initial data, whatever happens to it, logged nothing in RDR2's runs:
- `…T055247-rdr2-m4a`, a translation run;
- `…T061733-rdr2-m6b`, which read every shader back.

Yet m6b read every shader back (`deserialized=3328`), and no raw cache object was ever live
(`raw=0` throughout). So the shaders come back from Mesa's disk cache, in
`Library/Caches/kosmickrisp`, which KosmicKrisp filled when it translated them.

This is why the file-mapping change was dropped. It would have read a large initial blob in place
from a file mapping, and it never ran for this game. The same holds for keeping the blob's entries
out of the disk cache. Both are dropped from the series.

**Mesa main (`b39d173`, the pin) holds the same data.** A deserialized object keeps its own copy:
- the shader keeps its MSL;
- the precompiled shader keeps its NIR.

## 3. Cut 1: MSL and NIR kept compressed (mesa 0048, 0049)

**What changed:**
- **Shaders:** once a shader is compiled or deserialized, its MSL is compressed with zlib at level 1,
  and serialization inflates it again.
- **Precompiled shaders:** they keep their NIR the same way, and inflate it to compile or serialize.

**What it saves:**
- On the game's own cache file, MSL goes from 342 to 72 MiB, and NIR from 131 to 23 MiB.
- On the phone (m7a/m7b), `msl` is 57.4 MiB and `precomp` 21.3 MiB.

| Run | Host malloc used / allocated at the landing page (MB) | Footprint at the landing page (MB) |
| --- | ---: | ---: |
| m2a, m4a, m6a (translation runs, before) | 1,079–1,082 / 1,933–1,936 | 6,661–6,885 |
| m7a (translation run, with the cut) | 487 / 1,329 | 5,355 |
| m6b (Story run, before) | 904 / 1,411 | 5,538 |
| m7b (Story run, with the cut) | 718 / 1,275 at the kill (1,139 / 1,663 in m6b) | |

**In the Story run (m7b), the game got further before the kill.**
- Its own `vkAllocateMemory` reached 1,914 MiB, against 1,658 in m6b.
- The screenshots show the loading screens, then the intro's title cards.
- The app was killed at 06:58:58, about 3 min 50 s after A.

## 4. Metal command allocators reset: not kept

The forms below were tried as mesa 0050. The patch of the third form is kept in
`agent-notes/pla413d/dropped/`.

**The third form handled allocators this way:**
- It still shares an allocator between recordings.
- It counts the recorded command buffers that hold commands in each allocator. A command buffer
  takes the allocator at its begin and lets it go at its reset or destroy. Vulkan allows both only
  when the command buffer is not pending.
- With no holder left, the allocator is reset.
- An allocator past 16 MiB takes no new recording until it is reset.
- An allocator that held commands of a command buffer never committed is released instead of
  reset.

**Hollow Knight** passed its first-frame +10 check with it:
- the allocators at its end were 25 / 54.5 MiB, against 37 / 123.7 without the change;
- this is Hollow Knight on DXVK, which also runs on KosmicKrisp.

**Two earlier forms failed:**
- `4bd22b36`: Hollow Knight crashed.
- `ded9a76a`: it held one allocator per command buffer, 950 allocators and 1,194 MiB at RDR2's
  landing page.

**In RDR2 (`…T070930-rdr2-m9b`) it made things worse.**
- At the landing page the allocators were 33 / 89 MiB, against 40 / 112.
- During the Story load they grew to 106 allocators and 1,320 MiB:
  - the game's long-lived recorded command buffers keep allocators from ever reaching zero holders;
  - each sealed allocator stays at 16 MiB or more, and new ones are made.
- The app was killed 2 min 12 s after A, at phys 7,504 MB and a graphics ledger of 3,489 MB.

**Why one allocator per command buffer fails too.** RDR2 keeps about 950 command buffers recorded
at its landing page. Each Metal command allocator costs at least about 1.25 MiB, which is what the
second form showed.

**What a fix needs:** a reset that does not wait for every holder. It might come from:
- re-recording long-lived command buffers into transient ones, as KosmicKrisp's queue already does
  for re-submitted command buffers;
- or a time-sliced set of allocators, as Metal's own samples use (one per frame in flight).

That is a design change in KosmicKrisp's command buffers, left as the next lever.

## 5. The footprint at the kill, against sc2 (MB)

These are the last full `[footprint]`, `[kk-mem]`, `[malloc-zones]`, `[proc-mem]` and `[phys-map]`
lines before the kill. sc2 is from [rdr2-story-memory-levers](2026-10-20-rdr2-story-memory-levers.md),
section 4; m7b is the committed series, 0046–0049, on IPA `3f9bfec0`.

| Part | sc2 | m6b (census only) | m7b (MSL and NIR compressed) |
| --- | ---: | ---: | ---: |
| phys / compressed | 7,879 / 4,771 | 8,106 / 5,094 | 7,991 / 4,606 |
| graphics ledger | 2,875 | 3,009 | 3,081 |
| of it: the game's `vkAllocateMemory` | | 1,658 | 1,914 |
| of it: command allocators / upload memory / internal heap | | 599 / 362 / 128 | 630 / 147 / 128 |
| RDR2.exe private, committed / resident / compressed | 3,325 / 271 / 2,609 | | 3,469 / 328 / 2,737 |
| RDR2.exe in FEX's band | 1,418 / 84 / 267 | | 1,401 / 103 / 260 |
| JIT pool | 896 | 896 | 896 |
| host malloc used / allocated | 1,110 / 1,622 | 1,139 / 1,663 | **718 / 1,275** |
| how far it got | the second title card | the loading screens | the intro's title cards ("A few gangs still roamed…"), killed 3 min 50 s after A |

**What the m7b column shows:**
- **Host malloc fell by about 400 MB** used and 350–390 MB allocated.
- **The game used the room for its own memory.** Its `vkAllocateMemory` went 256 MiB further,
  1,658 → 1,914, before the same limit.
- **The load still needs more than the limit leaves.** Driver-side growth remains during the Story
  load: allocators +518 MiB and upload memory +80 MiB in m7b.

## Performance

- **Landing page and loading screens:** 48–54 fps (`[frames]`, m7b).
- **The intro cards:** 14 fps over the last 68 s before the kill, while the app's compressed memory
  grew to 4.6 GB.
- **Thermal:** the phone was already at `thermal: serious` at the launch of m7b, and stayed between
  `fair` and `serious`.
  - At the kill the P cores ran at 1.31 GHz; most of the CPU time was on the E cores
    (`[xp]` P=234 %, E=1,532 %).
- **The CPU cost of a translation run:** with no shader in the disk cache, the first run after each
  Mesa build translates 1,986 shaders, 35–38 s of CPU. The landing page footprint then peaks
  higher: in every such run but m7a (m1, m2a, m4a, m6a, m8a, m9a), the footprint reached 6,992 MB
  before the game's sign-in, so the launcher was ended before it (decision 0130).
  - In m1 the Story tab then showed "Buy Red Dead Redemption 2 Story Mode" with A. It was not
    pressed, and the app was ended.
- **The press can land on the Online tab.** In m1 an A sent at first frame +83 s, while the landing
  page was still fading in, opened the Online policies page. It was left with B, unanswered, and the
  Story tab was selected with RB.
  - From then on, A was pressed by hand only after a screenshot showed the Story tab and "Story (A)".
- **One run stalled** (`…T052735-rdr2-m2b`): frames stopped 20 s after the first frame, on the
  legal text screen, with no dialog. The app was ended after 5 min. The cause is not known.

## Not shown

- Gameplay with the character moving: no run passed the intro's title cards.
- What fills the rest of the footprint at the kill outside KosmicKrisp: RDR2.exe's private 3.5 GB,
  the JIT pool's 896 MB and the FEX band are unchanged by this work.
- A Story run on the committed IPA `500381f6` itself. It has the same patches as `3f9bfec0` (m7b),
  rebuilt; its Hollow Knight check passed.
- Whether the allocators' growth is the game's own long-lived command buffers, or KosmicKrisp
  recording more into them than it needs.

Games played: Red Dead Redemption 2 (`app-1174180`), Story mode only, and Hollow Knight
(`app-367520`) for the first-frame checks.
