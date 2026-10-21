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

## G2: `patches/mesa` 0097, the vertex shader compiled on its own (2026-10-21)

A vertex shader alone in its pre-rasterization library is now compiled when the library is made,
and its Metal library is built then. Its MSL depends on no other library:

- **Vertex fetch from the draw's layout.** `kk_flush_dynamic_state` uploads one
  `struct kk_vertex_fetch` per attribute slot (format word, stride, divisor) from the dynamic
  vertex input state. The new last field `kk_per_draw_data::vertex_fetch` points at it. The
  base address and robustness clamp stay in the root table. The format word covers every format
  KosmicKrisp advertises for vertex buffers: 8, 16 and 32-bit channels, 10-10-10-2, 11-11-10 and
  the format's swizzle (BGRA too).
  - **Where the layout lives.** The plan said "root draw data". Growing the root table's `draw`
    part would move every field after it, push constants included, so every pipeline's MSL would
    change. The layout therefore sits in its own upload, and per-draw data points at it.
    Per-draw data is uploaded without the new field unless the bound vertex shader reads it.
- **Point size and varyings.** The shader always writes a point size; the topology class goes on
  the Metal pipeline at link time. Its user varyings, and those of the fragment shader linked to
  it, are declared as 4-component values (`nir_to_msl_options::vec4_user_varyings`).

A fast link's first draw compiles only the fragment shader and builds the pipeline with the vertex
library already built. The link cache keys these links without the vertex input state and with
only the topology's class, so the same libraries with another vertex layout compile nothing.

`check_gpl` adds a B8G8R8A8_UNORM vertex input library and a pre-rasterization library with
`VK_POLYGON_MODE_POINT`. It also adds a vertex and fragment pair, `gpl-varyings.vert` and
`.frag`, whose fragment side reads 2 of the 4 components of a float output and of a flat `ivec4`
output. The test checks every count in this table. The run is `MESA_KK_EXPERIMENTAL=gpl
MESA_KK_DEBUG=compile` (`.work/run/mesa/hosttest/gpl.log`):

| Link | at library creation | at link | at the first draw |
| --- | --- | --- | --- |
| the 11 libraries (3 vertex shaders) | 3 | | |
| fast, f32 attributes, RGBA8 | | 0 | 1 |
| fast, u8 attributes, RGBA8 (same libraries otherwise) | | 0 | 0 |
| fast, BGRA8 attributes, RGBA8 | | 0 | 0 |
| fast, f32 attributes, RGBA16F blended | | 0 | 1 |
| fast, no fragment shader, RGBA8 | | 0 | 1 |
| fast, point fill (fallback) | | 0 | 6 |
| fast, varyings pair, RGBA8 | | 0 | 1 |
| optimized, f32 attributes, RGBA8 | | 2 | 0 |
| optimized, u8 attributes, RGBA16F blended | | 2 | 0 |

The log has `[kk-compile] gpl vertex built` 3 times and `[kk-compile] link separate-vertex` 4
times. Fallbacks to the whole compile are `link full fallback=point-fill count=1`, plus
`link full fallback=xfb count=1` for the earlier transform feedback pipeline without
rasterization.

**What did not change.** `run.sh` now checks that, with the flag on, every MSL library of the
non-GPL pipelines is byte-identical to the run without it. Against G1's output (same host test,
`patches/mesa` up to 0096):

- the flag-off MSL (158 libraries) and the Zink MSL (25) are byte-identical;
- the optimized links' four libraries are byte-identical to G1's.

**Metal front end.** `msl-compile.sh` (Metal Developer Tools 6.2 under Wine,
`-std=metal4.0 -target air64-apple-ios26.0`, fast math) compiled all seven new libraries to AIR
with no errors: three vertex libraries, the three fragment shaders of the fast links, and the
varyings pair's fragment shader.

**Varyings.** The separate vertex shader declares `float4 vary_00 [[user(vary_00)]]` and
`int4 vary_01 [[user(vary_01)]]`. The fragment shader linked to it declares the same types, with
`[[flat]]` on the integer, and reads `.xy`. Without the 4-component declaration it would declare
`float2` and `int2`, which Metal would refuse to link. The optimized link (monolithic) still
compacts varyings as before: for `pass.vert` and `color.frag` it also declares
`float4 vary_00`. `metal -c` compiles one stage at a time, so it cannot check that the two stages
link into a pipeline. Only the phone can (plan G5).

**Fallback reasons** (counted on `[kk-compile] link` lines):

- `stages`: tessellation or geometry shaders;
- `xfb`: transform feedback;
- `point-fill`: `VK_POLYGON_MODE_POINT` on triangles;
- `multiview`: a view mask other than the library's;
- `vertex-format`: an attribute format outside the fetch (none that KosmicKrisp advertises);
- `varying-type`: a fragment input of another type than the output;
- `varying-indirect`: an indirectly indexed varying;
- `fragment-clip-input`: a fragment shader that reads clip or cull distances;
- `vertex-compile` and `vertex-library`: the vertex shader's own compile or library build failed.

**GPU cost, not measured.** The runtime fetch is about 100 ALU operations per 4-component
attribute: a uniform branch over three load widths, then every conversion computed and one chosen
with selects. For `pass.vert`, with one attribute, the vertex MSL is 932 lines, against 69 in
the optimized link. This applies only to fast
links, until DXVK swaps in the optimized pipeline. Plan G5 measures it on the phone.
