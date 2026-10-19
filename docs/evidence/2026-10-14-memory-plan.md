# One memory plan for guest RAM and the video budget

**Date:** 2026-10-14. **Branch:** `research/extended-memory`.
**Linear:** [PLA-352](https://linear.app/playportdev/issue/PLA-352) (under
[PLA-216](https://linear.app/playportdev/issue/PLA-216)).
**Plan:** [donor memory](../plans/finished.md#guest-ram-from-donor-processes), queue item 3.
The owner was away and the phone was in unattended mode. Where there was a choice, the
conservative option was taken (see "Choices").

**Setup:**

- iPhone18,4, iOS 27.0.1, 11,734 MiB physical RAM. Battery 36 % on battery at the start;
  the owner then put the phone on the charger (52–53 %).
- IPA `Playport-26.5-21347e47.ipa`, SHA256
  `21347e47434d8483d37353d352f0b6795ad66a0894ef5e1c328376b2ac4a3c7d` (commit `9e900b8`),
  installed with `pp install --no-build`.
- Session scripts, logs and run directories are under
  `$PLAYPORT_BUILD/agent-notes/donor-memory/runs/pla352/`, with `pla352-session.sh` and
  `pla352-hk-dxmt30.sh` beside it. Each session ran as one `pp phone lock -- sh`.

## What changed

PlayportKit `MemoryPlan` reads the app's limit L once per Play. It reads it after the JIT
pool and a dev build's donor pool, just before `wine_host_init`. It then passes two values
through the environment:

- the guest's RAM as `MADEIRA_TOTAL_PHYS_MB` (ml992's own override, so no Wine patch);
- the video budget as `PLAYPORT_VRAM_MB`, read by ml1042 in
  [patches/dxmt 0011](../../patches/dxmt/0011-dxmt-the-app-s-memory-plan-for-the-video-budget-sign.patch).
  It is read after madeira.cfg `vram-mb`, and the old formula stays as the fallback.

A title's `totalphys` or `vram-mb` wins. This is how PLA-269's per-title values reach the
runtime through the cohort `config`. One `memory plan:` app-log line carries every input and
output.

**Constants.** Runtime overhead is 2,048 MiB, re-measured with the 512 MiB JIT pool. Kingdom
Come's census in [the widen evidence](2026-10-14-donor-pool-widen.md) gives JIT 512 + FEX
band 473 + images 132 + host about 820 = 1,937 MiB. The old value, 2,560, was measured with
the 896 MiB pool. The guest heap's share is 4,096 MiB, and the margin is 512 MiB.

**Guest RAM.**

- Above a 6 GiB limit, the guest is told L.
- At or under 6 GiB, it is told max(L − 2,048, L/2), rounded down to 256 MiB.
- A pool adds at most min(granted, P − L) and never raises the video budget.

**Video budget.** L − 4,096 − 2,048 − 512. The floor is 1,024 MiB, or 768 MiB at or under a
4 GiB limit. DXMT still caps it at Metal's recommended working set.

| Tier (L, MiB) | Guest RAM | Video | Before (guest / video) |
| --- | ---: | ---: | --- |
| 12 GB, Game Mode (8,192) | 8,192 | **1,536** | 8,192 / 1,536 |
| 12 GB before Game Mode, or 8 GB entitled (6,144) | 4,096 | 1,024 | 6,144 / 1,024 |
| 8 GB entitled (6,046) | 3,840 | 1,024 | 6,046 / 1,024 |
| 8 or 12 GB unentitled (3,355) | 1,536 | 768 | 3,355 / 1,024 |
| 6 GB unentitled (3,064) | 1,280 | 768 | 3,064 / 1,024 |
| 4 GB unentitled (2,090) | 1,024 | 768 | 2,090 / 1,024 |

Only the 12 GB rows are measured limits. The others come from public crash ceilings, as in
the PLA-351 research. The table is `MemoryPlanTests.testPerTier`.

**Opt-in keys, off by default:**

- **`vram-budget-event = 1`.** DXGI's budget-change event is signalled once at registration
  and whenever the ml1075 trim moves the budget, from a thread that polls every 500 ms. This
  is DXVK's behaviour. Without the key, DXGI still answers `DXGI_ERROR_UNSUPPORTED`.
- **`vulkan-vram-plan = 1`.** The app adds `dxgi.maxDeviceMemory = <plan>` to `DXVK_CONFIG`.

## Phone results

| Run | Backend | First frame | Plan line | What DXGI/Vulkan reported |
| --- | --- | --- | --- | --- |
| `hk-dxmt` | DXMT | +12.39 s | L 8,192 → guest 8,192, video 1,536 | `ml1042 video memory budget = 1536 MB (… Metal recommends 8192 MB; from Playport's memory plan)`; `ml992: MADEIRA_TOTAL_PHYS_MB=8192 -> 8192 MB` |
| `hk-dxmt-30` | DXMT | +11.34 s | the same | the same; the shot at first frame +30 shows the title menu |
| `hk-vulkan` | Vulkan | +11.19 s | the same (clamp off) | DXVK: `Heap 0: 8.0 GiB (DEVICE_LOCAL)`, `Budget: 6.0 GiB`, then `6.27 GiB` at the second device |
| `kcd-off` (`pp perf --no-hud --secs 240`, pool off) | DXMT | +28.33 s | the same | `ml1042 … = 1536 MB (process limit 8192 MB, footprint now 1496 MB …; from Playport's memory plan)`, `1 queries so far` |

- **Hollow Knight on DXMT.**
  - The gate run reached first frame +10, with frames flowing: 1,088 presents and 20,821
    draws by the stop. Its +10 shot was black.
  - With DXMT's shader cache cold, 286 shader conversions ran. HK had been on Vulkan in this
    branch's earlier runs.
  - One longer look (`--until first-frame+30`) showed the title menu drawn in full.
  - Unity registered no budget-change event on either backend.
- **Hollow Knight on Vulkan.** First frame +11.19 s; the +10 shot shows the title menu.
  - By DXVK's DXGI code, an exact 8 GiB heap is reported as 8,160 MiB dedicated and 8,160
    MiB shared. `QueryVideoMemoryInfo.Budget` is the heap budget, about 6.0–6.3 GiB (90 % of
    `os_proc_available_memory`, mesa 0004).
  - That is **5.3× DXMT's 1,536 MiB**. Hollow Knight's own log, which would show what Unity
    read, was not pulled.
- **Kingdom Come, pool off.**
  - Continue was read and pressed through the committed flow. The `wait-text "Rattay"`
    check did not read the word, but the shot 45 s after Continue shows Rattay's street,
    with the HUD compass and a townswoman.
  - Peak `fpMB` was 7,738 (earlier off runs: 7,682–7,914). No crash, no jetsam.
  - `pp perf`: FPS mean 35.1, median 22.9 over 240 s. Thermal went nominal → serious on
    the charger, after a 10-minute cool-down.
  - The game read the budget once, so the trim and the event cannot matter to it.
- **The game-side log line** ("8,192 MiB physical RAM and 1,536 MiB dedicated video
  memory" in earlier KCD evidence) was not pulled in this run. The values the runtime
  handed out are the ones above.

**Before and after on the reference phone:** the same numbers. Guest RAM is 8,192 and the
DXMT video budget is 1,536. They now come from one plan and are fixed at Play, not at the
first DXGI query. Vulkan is unchanged by default: 8 GiB heap, about 6 GiB budget.

## Choices (owner away)

- **Environment, not madeira.cfg.** Writing plan keys into madeira.cfg would point every
  title's `MADEIRA_DOCS_DIR` at a `title-cfg/` directory. That changes where legacy
  `madeira-*.txt` files and runtime outputs are read and written.
- **The plan keeps the reference phone's numbers.** It does not raise the budget with the
  smaller measured overhead: Kingdom Come's peak sits about 280–510 MiB under the limit.
- **The pool never raises the video budget.** It raises guest RAM only by P − L, which is 0
  on this phone at Play.
- **The plan runs in release builds too.** It replaces DXMT's formula, which runs there. On
  the reference phone the outputs are unchanged. On ≤ 6 GiB limits it lowers the guest's
  RAM. Untested on such a phone; the owner decides this at merge.
- **The event and the Vulkan clamp stay off by default.** The event hung RDR2 when it never
  fired (Madeira rdr77/78), and RDR2 cannot be tested here. Lowering DXVK's reported VRAM
  from 8 GiB to 1.5 GiB is untested for every Vulkan title. The heap budget
  (VK_EXT_memory_budget) is not clamped: that needs a mesa patch, left as a follow-up.

## Not checked

- The event firing: no tested title registers it, so it is build-verified only.
- `vulkan-vram-plan = 1` on the phone.
- A limit of 6 GiB or less, and a pool that raises guest RAM.
