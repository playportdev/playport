# KosmicKrisp: transform feedback, host test

**Date:** 2026-09-26. **Kind:** a workstation test only. No GPU ran any of it,
and nothing ran on the phone.
**Tree:** Mesa `82d4f86` plus `patches/mesa` 0001–0006, built from the pin by
`build/stages/mesa.sh` (stages `src host hosttest ios check`).
**iOS dylib:** 14,238,792 bytes, sha256
`9281a655a952ba4d68cdc212a68240c18ed1f619820e83d81a3de378e400f956`. Its imports resolve against iPhoneOS26.5.sdk, and the macOS
build of the same tree resolves too.

## Why

D3D11 stream output (for example `CreateGeometryShaderWithStreamOutput`) needs
`VK_EXT_transform_feedback` under DXVK. Upstream KosmicKrisp only has the
extension's limits; the extension itself, its features and its commands are
missing. Patch 0006 implements them on the geometry shader emulation of 0005
([record](2026-09-26-kosmickrisp-gs-fill-host.md)). This is how honeykrisp,
Mesa's driver for Apple GPUs on Linux, does transform feedback with poly.

## What 0006 does

- **Geometry shaders that capture.** poly's count shader (when counts are not
  static), a prefix sum of the counts, and its pre-GS program run before the
  geometry shader. Together they place each primitive in the buffers, clamp to
  the buffer size, advance the running offsets and update the stream queries.
  The rasterization shader then writes the captured vertices.
- **Vertex or tess eval shaders that capture.** With no geometry shader of
  their own, they get a passthrough geometry shader built into the pipeline,
  which takes over their capture layout.
- **Commands.** Buffer binding, Begin/End with counter buffers (GPU copies of
  the running offsets), and `vkCmdDrawIndirectByteCountEXT`, where a kernel
  turns the counter into an indirect draw.
- **Queries.** `VK_QUERY_TYPE_TRANSFORM_FEEDBACK_STREAM_EXT` keeps two reports
  (written, needed). Begin and end are indexed.
- **Features.** `transformFeedback`, `geometryStreams`, and the
  rasterization stream selection.

## How it was checked

`build/mesa-host-test/run.sh`, on the mock Metal bridge described in the 0005
record. `kk-host-test.c` now also builds seven pipelines that capture. For
each, it records:

- binding two buffer ranges and beginning two stream queries;
- beginning transform feedback, then the six kinds of draws;
- ending into counter buffers, resuming from them and drawing again;
- ending the queries, then a `vkCmdDrawIndirectByteCountEXT`.

It then submits the command buffer and reads the query results. For every
capturing pipeline, the test also fails unless one of its MSL vertex
functions stores to device memory, which is where the captured vertices are
written.

```
ok xfb-vs                  vertex shader, triangles, two buffers
ok xfb-vs-discard-lines    line strip, rasterizer discard, no fragment shader
ok xfb-vs-points           points
ok xfb-gs-dynamic          geometry shader with a data-dependent vertex count
ok xfb-gs-streams          two streams, stream 1 captured, stream 0 rasterized
ok xfb-gs-streams-rast1    the same, rasterizing stream 1
ok xfb-tess                capture from tess eval
all 24 pipelines built and drawn
```

The 17 pipelines of the 0005 record still pass.

**A bug the vertex-store check found, fixed in 0006.** KosmicKrisp lowers I/O
with `nir_lower_io`, which, unlike `nir_lower_io_passes`, does not mark the
stores that transform feedback captures. The link-time varying optimization
then removed a geometry shader's captured output, because the fragment shader
did not read it, so nothing was written. With the check in place, removing the
fix makes the test fail.

## What this does not show

- That the GPU writes the right bytes. The mock runs no GPU work, so the
  buffer contents and query results were not checked, only that the commands
  record and the queries report not ready.
- That the ordering between the compute passes, the render pass writing the
  buffers and a later draw reading them is correct on Metal. This relies on
  KosmicKrisp's existing barriers and on the application's pipeline barriers.
- Pipeline statistics queries are still not exposed. DXVK treats them as
  optional.
