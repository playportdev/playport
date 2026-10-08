# Vulkan performance: KosmicKrisp's sample-mask lowering on DXVK (not kept)

**Date:** 2026-10-08. **Plan:** [Vulkan performance](../plans/2026-10-06-vulkan-performance.md)
(PLA-72), chunk 12, the first lead of the [standing](2026-10-08-vulkan-perf-standing.md).
**IPAs (dev):**

- `4e6e930d5289b1a6d54bd61468eee97dd2b28122883039d827465c3ae09f87d7` (commit `ca12f08`, HEAD's
  runtime): the sizing pair;
- `7d7c983b6ac866c8030917cfde9021b45dbaa3e083d5b4f7a35458200d6d64e0` (commit `606d2e7`,
  `patches/mesa` 0020): the gate and the change's pair;
- `e6bd82a47dfc322706aa142f255c2aa743979977febc33b39e8999342ce4071c` (commit `377e7cb`, 0020
  reverted; same artifacts as `4e6e930d…`): installed at the end.

**Result: not kept.** Neither removing `KK_WORKAROUND_7`'s discard (the existing switch) nor
`patches/mesa` 0020 (no sample-mask lowering when the mask covers every rasterized sample) moved
DXVK's GPU time a frame at native/free. 0020 was reverted, file and series line in one commit
(`377e7cb`). The lowering is not DXVK's +29 % GPU-time gap over DXMT.

## The lead, from the code

- DXVK masks the D3D11 sample mask to the rasterized samples
  (`dxvk_graphics.cpp:384`), so a one-sample pipeline has the mask `0x1`. vkd3d-proton passes D3D12's
  `0xFFFFFFFF`.
- KosmicKrisp's `kk_lower_fs` (`kk_shader.c`) lowers every static mask other than `UINT16_MAX`
  into the fragment shader:
  - `msl_lower_static_sample_mask`: a `[[sample_mask]]` output of `sample_mask_in & mask`;
  - unless workaround 7 is disabled and the shader has no early fragment tests, a `discard_if` at
    its end for a sample the mask clears.
- `workarounds.rst` (KK_WORKAROUND_7, macOS 26.0.1): Metal ignores the sample mask output for the
  stencil of a multisample (≥ 2 samples) depth/stencil attachment, with no colour attachment and a
  depth-only shader that writes a static mask. KosmicKrisp's iOS/macOS 27 list does not turn it off
  (`BITFIELD64_MASK(7)` covers 1–6 only).
- With one sample and bit 0 set, both are no-ops on the result. The cost was the open question: a
  shader that can discard may lose early depth and hidden-surface removal (inference).
- Sample mask and rasterization samples are static pipeline state on KosmicKrisp (no extended
  dynamic state 3 for either), and the fragment shader key already holds both.

## Runs

Phone iPhone18,4, iOS 27.0, on the charger at 100 %. Route v2 (`hk-new-game` at `first-frame+25`,
`hk-walk` at `first-frame+80`), `--secs 130`, `--shot first-frame+128`, no `--cool`, settings
`{"screen":"native","frameLimit":0,"graphics":"vulkan"}` plus the run's `graphicsOptions`. Run
directories are `$PLAYPORT_BUILD/perf-runs/<name>`.

### Session 1 (IPA `4e6e930d…`): both runs void

- **`vk-nat-dxvk-wa7-ctl` (no option) froze.** The last `[frames]` line is at about
  `first-frame+37`, in the new-game menu; the `[waiters]` census then shows `parked=42 over60s=38`;
  no crash. This is the signature of the [D3D12 freeze](2026-10-08-vulkan-perf-standing.md#the-d3d12-freeze-vk-st-n60-vkd3d-1)
  (PLA-93), here on DXVK, with no vkd3d-proton in the process. Not investigated in this chunk.
- **`vk-nat-dxvk-wa7-1` (`MESA_KK_DISABLE_WORKAROUNDS=7`) is void**: its log has
  `hostio: Metal HUD off` (PLA-82), so it has no GPU ms. Two facts from it, not used:
  - it rebuilt 32 Metal render pipelines in more than 20 ms (`[kk-compile] render`), where the
    control built none: the switch changed the MSL, and KosmicKrisp's pipeline-cache key (which
    holds the disabled workarounds) missed;
  - its end screenshot shows the Knight at the same spot as every other run, but without the
    scene's dark overlay, at 78–86 FPS in the window. The rerun with the same option drew the
    overlay as the control did. This is not explained.

Decision: the one allowed rerun of the pair, in a second locked session.

### Session 2 (IPA `4e6e930d…`): the sizing pair

Control `vk-nat-dxvk-wa7-ctl-2`, then `vk-nat-dxvk-wa7-2` with `MESA_KK_DISABLE_WORKAROUNDS=7`. The
second run's log has `graphics options: MESA_KK_DISABLE_WORKAROUNDS=7`, and its shaders came from
the cache the void run had filled for that key. The switch removes only the discard; the static
`[[sample_mask]]` write stays.

### Session 3 (IPA `7d7c983b…`, `patches/mesa` 0020): gate and the change's pair

**The change** (`606d2e7`): the mask is lowered only when
`(sample_mask & BITFIELD_MASK(rasterization_samples))` leaves a rasterized sample out, which drops
both the discard and the static write for DXVK's `0x1`. `MESA_KK_DEBUG=any_sample_mask` restored
upstream's test, and the flag joined the pipeline-cache UUID, so the pair ran on one IPA.

**Gate:** every play reached `first-frame+10`.

| play | run | first frame | end screenshot |
|---|---|---|---|
| Hollow Knight, default (DXVK) | `ui-runs/20261008T132036` | +10.48 s | black: still compiling (20 Metal builds of 150–250 ms, the last at the shot), frames flowing |
| Hollow Knight, DXMT | `ui-runs/20261008T132133` | +10.48 s | title menu |
| Hollow Knight, D3D12 | `ui-runs/20261008T132224` | +9.53 s | title menu |
| Portal 2, default (DXVK, i386) | `ui-runs/20261008T132315` | +5.90 s | "powered by Source" |

The new MSL missed Apple's Metal compiler cache on the first play, which 0019's usage-only change
had not. The change's pair drew King's Pass correctly with the same flags.

**The pair:** control `vk-nat-dxvk-sm-ctl` (`MESA_KK_DEBUG=any_sample_mask,compile`, upstream's
lowering; its log has the option) then `vk-nat-dxvk-sm-1` (0020's default). The control rebuilt no
Metal pipeline over 20 ms: its MSL is the one every earlier IPA compiled. The change's run rebuilt 12.

## Window t = 85–125 s (`pp perf --compare … --window 85:125`)

CPU mJ/f is CPU mW / FPS. Thermal and budget columns from `summary.json`.

| run | lowering | thermal start → states | pressure onset (max) | budget min / first | FPS | p99 ms | ≥25/50/100 | GPU ms | gpu% | Mi/f | CPU mW | sys mW | CPU mJ/f | sys mJ/f |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `vk-nat-dxvk-wa7-ctl-2` | write + discard | serious → fair → serious | t = 0 (20) | 404 / t = 1 | 45.9 | 50.0 | 615/19/6 | 11.33 | 65.3 | 80.3 | 159 | 3807 | 3.46 | 82.9 |
| `vk-nat-dxvk-wa7-2` | write only | serious | none | 1483 / t = −20 | 49.7 | 41.7 | 573/15/4 | 11.04 | 66.8 | 80.8 | 168 | 3293 | 3.38 | 66.2 |
| `vk-nat-dxvk-sm-ctl` | write + discard | fair → serious | t = 25 (20) | 667 / t = 22 | 48.5 | 54.2 | 605/33/5 | 11.58 | 68.9 | 78.9 | 171 | 4580 | 3.52 | 94.4 |
| `vk-nat-dxvk-sm-1` | none (0020) | serious | none | 1483 / t = −22 | 46.4 | 50.0 | 631/19/8 | 11.71 | 67.4 | 84.2 | 166 | 3417 | 3.57 | 73.6 |

Reference: the standing's `vk-st-nat-dxvk-1` 11.84 ms, `vk-st-nat-dxmt-1` 9.19 ms,
`vk-st-nat-vkd3d-1` 9.52 ms.

### GPU ms in 5-s buckets, t = 65–100 (GPU ms / FPS / thermal pressure)

| run | 65 | 70 | 75 | 80 | 85 | 90 | 95 | 100 |
|---|---|---|---|---|---|---|---|---|
| `vk-nat-dxvk-wa7-ctl-2` | 6.40 / 76.6 / 20 | 12.44 / 74.7 / 20 | 16.11 / 50.1 / 20 | 11.46 / 47.0 / 20 | 10.63 / 44.7 / 20 | 10.28 / 45.2 / 20 | 10.09 / 49.1 / 20 | 10.05 / 49.6 / 20 |
| `vk-nat-dxvk-wa7-2` | 6.60 / 77.3 / – | 24.36 / 40.5 / – | 15.84 / 54.7 / – | 10.92 / 51.3 / – | 10.25 / 49.1 / – | 9.54 / 51.7 / – | 9.51 / 51.7 / – | 9.20 / 50.5 / – |
| `vk-nat-dxvk-sm-ctl` | 6.47 / 63.5 / 20 | 11.83 / 77.6 / 20 | 14.98 / 55.6 / 20 | 11.51 / 53.8 / 20 | 9.88 / 43.6 / 20 | 9.74 / 41.2 / 20 | 9.79 / 49.1 / 20 | 9.87 / 52.0 / 20 |
| `vk-nat-dxvk-sm-1` | 6.32 / 120.0 / – | 9.44 / 32.7 / – | 10.84 / 39.3 / – | 10.07 / 42.9 / – | 10.03 / 43.6 / – | 9.71 / 47.8 / – | 9.55 / 48.0 / – | 9.81 / 49.2 / – |

### End screenshots

`shot-ff128.png` in each run directory, described here and not published. All four valid runs show
the same dark King's Pass cave, the Knight under the stalactites, the overlay and the radial light
drawn the same way. In `vk-nat-dxvk-sm-1` the Knight is in a hit animation (the game's own effect).

## Reading

1. **Fact:** with upstream's lowering against 0020, GPU ms is 11.58 against 11.71 in the window, and
   9.7–10.0 ms in every bucket from t = 85 on both runs. 0020 removes the discard and the static
   `[[sample_mask]]` write from DXVK's one-sample shaders and saves no GPU time.
2. **Fact:** removing only the discard gave 11.33 → 11.04 ms (−2.6 %), with buckets 0.4–0.9 ms lower
   from t = 80. The control ran under thermal pressure 20 and a 404 mW budget from t = 0, and the
   switch's run under none, so that difference is within the pair's thermal bias. The one-IPA pair
   above, where the hotter run was again the control, shows no difference.
3. **Flag:** in both pairs the control reached thermal pressure 20 and the changed run did not, so
   the sys mJ/f and FPS columns (−20 %, −22 %) are budget-confounded and are not read as gains. GPU ms
   is the deciding column, and it did not move.
4. **Inference:** DXVK's gap is not the shader's discard or sample-mask write. Apple's GPU keeps its
   early depth and hidden-surface removal with them here, or King's Pass's sprites draw with no depth
   test, where neither matters. The 2.6-ms gap to DXMT (and to vkd3d-proton on the same KosmicKrisp)
   is elsewhere: the next DXVK-specific lead is the depth store in pass 20 of the
   [King's Pass capture](2026-10-08-vulkan-perf-kings-pass-capture.md), or a per-pass GPU time
   on KosmicKrisp, which no tool gives yet.
5. **Not chased:** the DXVK freeze in session 1 has the D3D12 freeze's signature (PLA-93), so that
   issue is not vkd3d-proton's alone.

## Games observed

| title | IPA | run directory | outcome |
|---|---|---|---|
| Hollow Knight (367520), DXVK native/free | `4e6e930d…` | `perf-runs/vk-nat-dxvk-wa7-ctl` | **froze** at about `first-frame+37` in the new-game menu: no frames, `[waiters] parked=42`, no crash (PLA-93's signature) |
| Hollow Knight (367520), DXVK native/free, `MESA_KK_DISABLE_WORKAROUNDS=7` | `4e6e930d…` | `perf-runs/vk-nat-dxvk-wa7-1`, `vk-nat-dxvk-wa7-2` | 130 s each, King's Pass, no crash (`-1` void: Metal HUD off, PLA-82) |
| Hollow Knight (367520), DXVK native/free | `4e6e930d…` | `perf-runs/vk-nat-dxvk-wa7-ctl-2` | 130 s, King's Pass, no crash |
| Hollow Knight (367520), DXVK default, DXMT, D3D12 (gate) | `7d7c983b…` | `ui-runs/20261008T132036`, `…T132133`, `…T132224` | `first-frame+10` each |
| Portal 2 (620), DXVK i386 (gate) | `7d7c983b…` | `ui-runs/20261008T132315` | `first-frame+10` |
| Hollow Knight (367520), DXVK native/free, upstream lowering and 0020 | `7d7c983b…` | `perf-runs/vk-nat-dxvk-sm-ctl`, `vk-nat-dxvk-sm-1` | 130 s each, King's Pass, no crash |
| Hollow Knight (367520), DXVK default | `e6bd82a4…` | `ui-runs/20261008T133618` | `first-frame+10`, title menu |
