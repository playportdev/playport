# Hollow Knight: lossless compression back on Unity's render textures

Status: fix in `patches/dxmt` 0009, checked on the phone. King's Pass now runs
at 120 FPS at native 2736x1260 on a phone that is not yet hot. Once the phone
reaches thermal pressure level 20, the scheduler moves the game onto the E
cores and play falls to 80-90 FPS, so 120 FPS held for 10 minutes is not
reached yet. Dev IPA sha256
`658973e9c31ca12d1127ea6ce28fe77900e7dc6d8465e4abe8ee6696c1702c7e`
(Wine 11.18, `madeira-unix` 0027, `dxmt` 0008 and 0009).

## Cause

[2026-09-26-hk-gpu-passes.md](2026-09-26-hk-gpu-passes.md) found that the King's
Pass GPU frame is 29 encoders of fragment and bandwidth work at full
resolution. DXMT's `CreateMTLTextureDescriptorInternal` added
`MTLTextureUsagePixelFormatView` to every TYPELESS texture, and Unity creates
its render textures as TYPELESS. Apple's "Optimizing texture data" and
`MTLTextureUsage.pixelFormatView` documentation say that on GPU family 5 and
later, Metal does not apply lossless compression to a texture with that flag.
The documentation also says the flag is needed only for a view that changes
the component layout (the number, size or order of components). A swizzle
does not need it, and neither does a change between linear and sRGB.

A colour typeless family never changes the layout. The possible views are
UNORM, SNORM, UINT, SINT and the sRGB variant of the same layout.

## Fix (`patches/dxmt` 0009)

- Colour typeless textures no longer get `pixelFormatView`. Depth/stencil
  formats keep it, because their plane views such as X32_TYPELESS_G8X24_UINT
  change the format. Block-compressed formats also keep it; they are never
  losslessly compressed anyway.
- `DXMT_TYPELESS_PFV=1` in a game's environment puts the flag back on every
  typeless format, for comparison.
- A texture view that changes the format of a texture made without the flag
  (other than an sRGB pair) is logged as `[pfv-view]`, up to 32 lines. The run
  below logged none.

## Run

`pp perf --out .work/perf-runs/w1118-lossless --secs 160 --settings
'{"environment":[{"name":"DXMT_PASS_PROF","value":"1"}]}' --pad
first-frame+35:hk-new-game --pad first-frame+90:hk-walk --shot first-frame+150`.
This is the same route as `w1118-passprof2` in the GPU-passes record. The first
frame came at +10.91 s. The first-frame+150 screenshot shows King's Pass drawn
correctly.

Metal HUD, 5 s buckets (from `summary.txt`):

| phase | before (`w1118-passprof2`, 6fd0a397) | with 0009 (658973e9) |
|---|---|---|
| menu t=15-30 | 120 FPS, GPU 6.6 ms | 120 FPS, GPU 6.75 ms |
| King's Pass t=100-120 | 62-71 FPS, GPU 13 ms | **120.0 FPS, GPU 6.64-6.80 ms**, P cores 3.3-3.6 GHz, about 1.8 W |
| King's Pass t=130-165, after thermal pressure 20 | - | 80-91 FPS, GPU 7.5-10.9 ms, P 0-49 %, E cores 1.7 GHz carrying the whole game |

Per-pass fragment time in King's Pass frames, mean ms (before: reports 11-14;
after: reports 10-15):

| pass | before | after |
|---|---|---|
| 0: full-resolution RGBA8 clear, 2 draws | 0.45 | 0.04 |
| 8: scene, clear colour + depth, 8 draws | 1.63 | 1.10 |
| 10: scene, 21 draws, 11688 prims | 1.07 | 1.04 |
| 12: scene, 1 draw | 1.01 | 0.70 |
| 14: scene, 4 draws | 2.60 | 1.69 |
| 20-24, 27: full-screen one-quad passes | 2.5 total | 1.6 total |
| sum of fragment time per frame | 7.4-12.9 (mostly about 11) | 6.1-9.1 (mostly about 6.1) |

The pass times depend on the GPU clock, but the frame totals fell by about
40 % at similar clocks. The Metal HUD agrees: GPU time in King's Pass went from
13 ms to 6.7 ms.

## What is left

- **Thermals and CPU placement.** Thermal pressure reached level 10 at about
  110 s and level 20 at 130 s. At level 20 the P cores went to 0 %, and the
  game (the main thread about 22 Mi/f) ran on the E cores at 1.7 GHz: 80-90 FPS
  with frame times of 11-12 ms. Before that, the CPU drew about 1.8 W on the P
  cores at 3.3-3.6 GHz. Holding 120 FPS for 10 minutes needs less CPU work per
  frame, so the game fits the E cores or a lower P clock. The next step is to
  find which threads spend the CPU time in play, besides the main thread's
  22 Mi/f (72-74 Mi/f for all threads in the Mono record).
- **Remaining GPU work.** The full-screen blits that split the scene passes and
  the one-quad passes are still in the frame. They are leads for GPU power, not
  for the frame budget.
