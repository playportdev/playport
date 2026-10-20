# 2026-10-20: RDR2's blue band was a 124×11 10-bit drawable: a second swap chain reconfigured the shared CAMetalLayer, and the game kept presenting its 1280×720 one; with the layer configured again per swap chain (mesa 0045) the landing page renders. Also: KosmicKrisp captures with no timestamp counter heap (mesa 0044)

**Linear:** PLA-364 (related: PLA-413, PLA-416). **Plan:** `.work/plans/rdr2-blue-band.md`.
**Follows:** [rdr2-landing-press](2026-10-19-rdr2-landing-press.md), whose capture KosmicKrisp's counter heap
refused.

## Builds and runs

The phone was unattended (owner away). Every IPA got the Hollow Knight gate (`--play app-367520
--until first-frame+10`) before RDR2. Battery 80 % on external power throughout; free space 4.6–5.7 GB.

| IPA sha256 | What it is | Hollow Knight first frame | RDR2 run (`$PLAYPORT_BUILD/...`) |
| --- | --- | --- | --- |
| `778caa686fa44e38173dd8b7601e517a53370f7f0c7d74700e51ef292aadf2ca` | `patches/mesa` 0044 | +9.94 s (`ui-runs/20261019T233729`) | `gpu-runs/20261019T233910-rdr2-landing` (capture, frame 3000); `ui-runs/20261019T235712-rdr2-solid`; `ui-runs/20261020T000341-rdr2-os26wa`; `ui-runs/20261020T002050-rdr2-wideusage` |
| `f7dd61f786060cf9c63f384d0a0b03653382174260387451776f8811cfd94521` | 0044 + a throwaway: workaround 6 in fragment shaders too | +9.63 s | `ui-runs/20261020T003926`, `…T004342`, `…T004824-rdr2-exp-fswa6` |
| `4ce56e10eed77206823052499c4081701e6a5e3aa4bf5ce6fa0dd6346eadb24c` | 0044 | +10.04 s | `gpu-runs/20261020T005938-rdr2-landing2` (capture, frame 3000) |
| `116d6ec1…` | 0044 + a throwaway: `MESA_KK_DEBUG=solid` also into a B8G8R8A8 target | +9.86 s | `ui-runs/20261020T011454-rdr2-exp-solidsc` |
| `23dda743…` | 0044 + a throwaway: `[kk-draw]` for the draws that do not blend every channel | +9.85 s | `ui-runs/20261020T012441-rdr2-exp-draws` |
| `855c6140f9153a67899e48192c3d373a0b97c8c4a154262ba8b10aa8c480d234` | 0044 + a candidate: no HDR colour spaces on iOS (not shipped) | +9.87 s | `ui-runs/20261020T013619-rdr2-sdr` (A pressed at first frame +77.6 s) |
| `879fc40503e301b306ade96dd03ac34b9fd898d30cd9be5a0734a3016c9b3170` | 0044 | +9.85 s (`ui-runs/20261020T014832`) | — |
| `06d534182cfec6f56a638d628af5da1e6193d5ebd237933a95a3c3f243ae12f8` | 0044 + a first 0045: only the layer's pixel format put back | +7.65 s (`ui-runs/20261020T015739`) | `ui-runs/20261020T015835-rdr2-layerfmt` |
| `f03e22d3b26794928aabaa5bbdd2b31ff8cc099eb75ad215fdc493f6fc6be418` | 0044 + 0045 as committed | +8.94 s (`ui-runs/20261020T021101`) | `ui-runs/20261020T021150-rdr2-layercfg` |

PlayRDR2's "Unable to launch game" box was closed by one pad A each time (decision 0076), from a
watcher on the run's events (`dialog shown`), in plays without `--quiet`.

## 1. The capture now works (`patches/mesa` 0044)

- While a capture is armed, a timestamp query pool makes no Metal counter heap; its writes store
  `0xffffffff00000000` in one 32-bit store. The run logs it five times:
  `[kk-query] timestamp pool of 8192 queries: no Metal counter heap while a GPU capture is armed`.
- `pp gpu capture --title app-1174180 --frame 3000 --secs 100 --expect-gb 2`: `[kk] frame 3000: A new
  capture will be saved`, then `capture ended`; 1,298 files, 1,360,537,530 bytes, pulled and removed
  on the phone (free 5.0 GB after). The second capture (`--expect-gb 1.5`, because the phone had
  5.4 GB free) was 1,334,729,350 bytes.
- The host test `capture-timestamp-pool` (`build/mesa-host-test/kk-host-test.c`) makes a 5,000-query
  pool with `MESA_KK_GPU_CAPTURE_FRAME=3000` on a mock that aborts at any counter heap, and records,
  submits and destroys it; without the variable the same pool aborts at its counter heap.

## 2. What the landing frame is

`pp gpu read` on the first capture: 3 command buffers, 7 passes, 28 draws.

| Pass | What (from the calls and the heap snapshots) |
| --- | --- |
| compute | timestamp-pool resets (8,192 and 4,096 threads) |
| render 1280×720 B8G8R8A8, clear | empty |
| compute | three buffer-to-texture copies: Y 1920×448 and two chroma planes 960×224, R8Unorm |
| render, 11 draws | the video quad (triangle strip, 4 vertices), then Scaleform UI draws |
| render, 11 draws | Scaleform UI draws |
| compute | two timestamp writes |
| render into the drawable, 6 vertices | KosmicKrisp's WSI blit (`vk_meta`, 2048×1024 viewport) |

There is no 3D scene: the landing page is a Bink video strip and UI drawn straight into the swap-chain
image.

The capture's heap snapshots were read with a script that maps GPU addresses to heap files
(`.work/agent-notes/pla364b/gpumem.py`). Everything the video quad reads is right in memory:

- **The video frame:** the Y staging buffer holds the panorama (a snowy town); the two chroma planes
  match it. Converted on the workstation with the shader's own matrix, they give the right picture.
- **The shader** (MSL from the capture's store): Y, Cr and Cb sampled with one sampler,
  full-range BT.601 matrix from a uniform buffer, optional 3D LUT (off), in-shader alpha blend.
- **Its uniform buffer** (144 bytes): rows (1.402, −0.714, 0), (0, −0.344, 1.772), offset
  (−0.704, 0.531, −0.889), Y row (1, 1, 1), texture scale (1, 0.982), LUT flag 0.
- **Its descriptors:** the three textures' resource IDs (Y 0x409b, Cr 0x409e, Cb 0x40a1), sampler 3,
  LOD bias 0.
- **Its vertices:** x 0–1280, y 276.48–558.08, UV 0–1, colour white; orthographic 1280×720
  projection.
- **The Scaleform draws:** XY16i vertices with per-draw matrices and colour transforms; the top
  and bottom overlays are BC3 textures 2548×496 and 2548×248, the font atlas R8 2048×2048.

So the frame asks for the right picture, and the GPU produces a flat band. The difference is in what the GPU
does with these inputs, which no replay here can show.

## 3. What the band is not

| Change | Result |
| --- | --- |
| `MESA_KK_DEBUG=solid` (1,858 pipelines retranslated, so not a stale pipeline cache) | the same band; the flag leaves B8G8R8A8 passes alone, and every landing draw is one |
| `MESA_KK_DEBUG=wide_usage` (no lossless compression on the R8 planes and targets) | the same band |
| workaround 6 (coherent device accesses) in fragment shaders too | the same band, after about 400 s of Metal compiles per run |
| `MESA_KK_DEBUG=os26_workarounds` | the launcher stalled before the game (`no stop condition within --wait`); no result |
| solid also into B8G8R8A8 (throwaway) | the legal page's text block is a magenta rectangle; the landing band turns **cyan (64,239,255)**, not magenta |
| `[kk-draw]` for draws that do not blend all channels (throwaway) | none of the game's landing draws: all are blended with write mask 0xf; the only such draws are the WSI blits |
| no HDR colour spaces offered on iOS (candidate patch) | the same band, then the same noise after A; `system.xml` still says `hdr true` |

- **The game's settings** (`system.xml`, pulled from the phone): `<hdr value="true" />`,
  `textureQuality` Ultra, `API` Vulkan, 1280×720, vSync 1. HDR is on. `pp gpu read` gives the game's
  target as B8G8R8A8 and the drawable as Metal format 94 (BGR10A2Unorm, the layer format of
  `VK_FORMAT_A2R10G10B10_UNORM_PACK32`). Offering no HDR colour spaces did not change the band;
  the saved setting may keep HDR on whatever the surface offers. This is not shown.
- **The cyan under "solid":** every game draw writes magenta (1,0,1), and the band still shows
  (0.25, 0.94, 1.0). So the band's red and green are not what the last game draw wrote. Blue
  passes through: 0.945 normally, 1.0 under solid. Something after the game's draws changes the
  swap-chain image's red and green, or the screenshot's source is not the image the draws wrote.
  This is inferred, not shown.

## 4. The cause: two swap chains on one layer (`patches/mesa` 0045)

The 0045 logging (`[kk-wsi] create chain …`) shows the game's swap chains on its window's surface,
in `ui-runs/20261020T015835-rdr2-layerfmt`:

```
[kk-wsi] create chain format=58 colorspace=0 124x11 images=3 old=0
[kk-wsi] create chain format=44 colorspace=0 1280x720 images=3 old=0
[kk-wsi] create chain format=58 colorspace=0 124x11 images=3 old=0
[kk-wsi] layer format back to the presenting chain's: format=44 colorspace=0 chain=1280x720
```

- **The chains:** format 58 is `A2R10G10B10_UNORM_PACK32` and 44 is `B8G8R8A8_UNORM`. After its
  1280×720 B8G8R8A8 chain, the game makes another 124×11 A2R10G10B10 chain on the same surface and
  goes on presenting the 1280×720 one.
- **What went wrong:** KosmicKrisp's Metal WSI configures the surface's one CAMetalLayer (drawable
  size, pixel format, colour space) only when a chain is made. From then on every drawable was
  124×11 and 10-bit, while the blit into it was built for 1280×720 B8G8R8A8.
- **What the phone showed:** the 124×11 drawable stretched over the screen:
  - the band is about two drawable rows (143 of 737 screen rows; 11 rows give 67 each);
  - the "16-px blocks" of the loading noise are drawable columns (1600 / 124 = 12.9 px);
  - the colours are B8G8R8A8 bits read as 10-bit channels. Magenta under solid,
    0xFFFF00FF, reads (0x0FF, 0x3C0, 0x3FF) / 1023 = (64, 239, 255): the cyan measured.
- **The first fix** (`ui-runs/20261020T015835-rdr2-layerfmt`) put back only the pixel format. The
  screen went black, since the drawable stayed 124×11.
- **The committed 0045** configures the layer again, as the presenting chain made it, whenever
  the layer's drawable size or pixel format is not that chain's. That means size, image count,
  format, colour space, opacity, present mode and framebuffer-only.

**Result** (`ui-runs/20261020T021150-rdr2-layercfg`, IPA `f03e22d3`):
- the landing page renders: the RED DEAD ONLINE logo in white and red, the snowy panorama
  strip, the tab bar "Story / Online" (LB/RB) and the prompts "Social Club", "Play" and
  "Quit Game";
- the pad's A at first frame +77.6 s pressed Play on the Online tab, which opened the "Rockstar
  Games Online Policies" page (EULA, terms, privacy and a Submit button). It renders correctly, and
  nothing was accepted;
- the app stayed up to the stop (first frame +200 s).

The earlier sections stay as the record of how the band was narrowed down; the inference at the
end of section 3 is now shown.

## 5. Story load and memory (the run without 0045, `ui-runs/20261020T013619-rdr2-sdr`)

- In `ui-runs/20261020T013619-rdr2-sdr`, A at first frame +77.6 s started the Story load. The strip
  went to blocky blue, magenta and cyan noise; the app ended about 100 s later.
- At that point the footprint was phys 7,768 MB (peak 7,781), compressed 4,751 MB and graphics
  2,882 MB.
- The game's graphics menu could not be used to lower Texture Quality (Ultra in `system.xml`):
  nothing on the landing page renders readably.
- Frame rate: 53 fps on the landing page and early in the load (640 frames per 12 s), falling to
  40 fps before the end.

## 6. Story mode with 0045 (IPA `f03e22d3`)

- **`ui-runs/20261020T022120-rdr2-story`:** the landing page was already on the Story tab: RED DEAD
  REDEMPTION II logo, panorama, prompts "Settings", "Social Club", "Story" (A) and "Quit Game". The
  scripted LB moved it to Online, and A opened the Online Policies page, which stayed up to the
  stop. Nothing was ticked or submitted.
- **`ui-runs/20261020T022900-rdr2-story`:** A alone at first frame +77.6 s, on the Story tab,
  started the Story load with no policy page. The loading screens render correctly: sepia
  artwork (a rider, a creek, a forest lake) with the spinner, from about +90 s after the press.
- **The end:** the app was ended about 90–100 s after the press, at phys 8,055 MB (peak 8,055),
  compressed 4,644 MB and graphics 3,268 MB: the 8,192 MB limit, as on 2026-10-19.
  The landing page offers "Settings", for lowering Texture Quality (Ultra in `system.xml`) before
  the load; that was not done in this session.
- **Frame rate in the load:** 1,280 frames per about 24 s, 53 fps.

## Not shown

- Gameplay: the Story load still ends at the memory limit.
- Whether lower in-game graphics settings make it fit.
