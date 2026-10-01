# KosmicKrisp: geometry shaders and fillModeNonSolid, host test

**Date:** 2026-09-26. **Kind:** a workstation test only. No GPU ran any of it,
and nothing ran on the phone.
**Tree:** Mesa `82d4f86` plus `patches/mesa` 0001–0005, built from the pin by
`build/stages/mesa.sh` (stages `src host hosttest ios check`).
**iOS dylib:** 14,189,560 bytes, sha256
`ca2a3baebab8881564bb2a932ffb5441ebf72b1b41b07c510222962819ddc994`.

## Why

DXVK `52fe923` requires `geometryShader` and `fillModeNonSolid` to create a
device ([research](../research/2026-09-26-d3d-backends.md),
[decision 0014](../decisions/0014-vulkan-through-kosmickrisp.md)). Upstream
KosmicKrisp advertises neither. Patch 0005 implements both instead of hiding
them from DXVK.

## What 0005 does

- **Geometry shaders**, the way honeykrisp (Mesa's Vulkan driver for Apple
  GPUs on Linux) does them, with Mesa's `poly` library, which KosmicKrisp
  already uses for tessellation:
  - The stage before the geometry shader (vertex, or tess eval) runs as
    compute and writes its outputs to memory.
  - The geometry shader runs as compute, once per input primitive and
    instance.
  - A rasterization shader derived from the geometry shader is the Metal
    vertex function.
  - Direct and indirect draws are handled. Indirect draws are sized on the
    GPU by a new `libkk_gs_setup_indirect` kernel, and their dispatches use
    `dispatchThreadsWithIndirectBuffer`.
- **Line fill:** Metal's `setTriangleFillMode:`.
- **Point fill:** Metal has no point fill mode, so such a pipeline gets an
  internal geometry shader. It culls each triangle as the rasterizer would,
  then emits the triangle's three vertices as points.
- **Not done:** transform feedback (D3D11 stream output) and geometry shader
  statistics queries. `poly` has the code for both; KosmicKrisp exposes
  neither.

## How it was checked

`build/mesa-host-test/run.sh` builds the patched tree for Linux (debug, so
NIR validation runs). KosmicKrisp's Metal stubs are replaced by a mock
generated from them (`make-mock-bridge.py`). The mock provides:

- a device reporting Apple GPU family 10 and iOS 27;
- heaps backed by host memory, with GPU address equal to CPU address;
- commits that complete at once.

It records every MSL library the driver compiles, and fails the run if any
contains an untranslated intrinsic. `kk-host-test.c` drives the driver
through the Vulkan API.

Result:

```
device: Mock Apple A19 Pro GPU, geometryShader 1, tessellationShader 1, fillModeNonSolid 1, provokingVertexLast 1
ok no-gs                   ok gs-passthrough          ok gs-dynamic-count
ok gs-lines-out            ok gs-points-out           ok gs-instanced
ok gs-adjacency            ok gs-strip-restart        ok gs-primid-clip
ok gs-no-fs                ok gs-dynamic-points       ok tess-gs
ok line-fill               ok point-fill              ok point-fill-strip-primid
ok tess-point-fill         ok gs-line-fill
all 17 pipelines built and drawn
MSL libraries: 82
```

Each pipeline was built, and draws were recorded and submitted with it:
direct, instanced with a base, indexed, indexed with primitive restart, and
indirect (plain and indexed).

Two bugs this test found and 0005 fixes:

- Without the NIR cleanup on the rasterization shader, MSL translation
  asserted on leftover derefs.
- A draw with an adjacency topology before a geometry shader asserted in the
  primitive-type mapping.

## Also checked

- With 0005, KosmicKrisp sets every feature DXVK `52fe923` marks as required:
  51 core and extension features, compared by a script against
  `dxvk_device_info.cpp`.
- The iOS dylib builds from the pin, and every import resolves against
  iPhoneOS26.5.sdk (`check-macho-imports.py`). The macOS build of the same
  tree also resolves.

## What this does not show

- **That the GPU draws the right pixels.** The MSL is generated but no Metal
  compiler has compiled it; there is none on Linux. The kernels and the
  rasterization shaders have not run.
- **That the indirect grid layout is right.** It assumes Metal's
  `MTLDispatchThreadsIndirectArguments` (threads per grid, then threads per
  threadgroup) matches poly's "indirect local" grid. The SDK header says so,
  but it is unverified on a device.
- **That DXVK runs on KosmicKrisp.** That needs the Wine and DXVK steps of
  decision 0014, and then a device run.
