# KosmicKrisp graphics pipeline library: host results

**Linear:** [PLA-424](https://linear.app/playportdev/issue/PLA-424). **Plan:**
[kk-graphics-pipeline-library](../plans/2026-10-21-kk-graphics-pipeline-library.md).
**Where:** the workstation's host mock of KosmicKrisp (`build/mesa-host-test`), from the side copy
`.work/worktrees/kkgpl`. **Not run on the phone.**

## G1: `patches/mesa` 0096, linked at the draw (2026-10-21)

`MESA_KK_EXPERIMENTAL=gpl` advertises `VK_KHR_pipeline_library`,
`VK_EXT_graphics_pipeline_library` and `graphicsPipelineLibrary`. Without the flag, the host test
checks that the extension is absent. The run in `build/mesa-host-test/run.sh` sets the flag, and
every pipeline of the host test still builds and draws.

`check_gpl` builds libraries the way DXVK does: two vertex input libraries (R32G32B32A32_SFLOAT and
R8G8B8A8_UNORM attributes), one pre-rasterization library (`pass.vert`), a fragment shader library
with and without `color.frag`, and two fragment output libraries (R8G8B8A8_UNORM, and
R16G16B16A16_SFLOAT with blending). It links them, records two draws per link and submits them.
How many MSL libraries the mock compiled at each step:

| Link | at library creation | at link | at the first draw |
| --- | --- | --- | --- |
| the 7 libraries | 0 | | |
| fast, f32 attributes, RGBA8 | | 0 | 2 |
| fast, u8 attributes, RGBA8 | | 0 | 2 |
| fast, f32 attributes, RGBA16F blended | | 0 | 2 |
| fast, no fragment shader, RGBA8 | | 0 | 2 |
| optimized, f32 attributes, RGBA8 | | 2 | 0 |
| optimized, u8 attributes, RGBA16F blended | | 2 | 0 |

So G1 is correct on the mock but does not yet move compilation off the draw: a fast link compiles
the whole pipeline at its first draw, as a monolithic pipeline does at creation. G2 and G3 move the
vertex and fragment Metal libraries to library creation.

The mock checks the CPU side only: compiling, NIR validation in a debug build, the MSL translation
and recording. Rendering is checked only on the phone (plan G5).

The host test's Zink run crashed at exit (status 139) in this workstation's MangoHud implicit
Vulkan layer. With implicit layers disabled it passes, so `run.sh` now sets
`VK_LOADER_LAYERS_DISABLE=~implicit~` for it.
