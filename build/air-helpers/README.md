# AIR helpers without Apple's tools

DXMT's unix slice links three helper modules into converted shaders:
`air_msad` (DXBC `msad`), `air_samplepos` (DXBC `samplepos`) and
`air_tessellation` (DXMT's D3D11 tessellator on Metal mesh shaders). Upstream
writes them in Metal Shading Language, which only Apple's `metal` compiles.
Here they are hand-written LLVM 15 IR (`air_*.ll`), assembled by LLVM 15.0.7's
`llvm-as` and embedded with `xxd -i`, exactly where the fork's meson would put
Apple's output. `pp build` runs the `llvm` and `air` stages of
`air-helper-port.sh`; `host` builds a Linux airconv for checking a title's
shaders (below).

    build/air-helpers/air-helper-port.sh ROOT [llvm air host]

| Stage | What it does |
| --- | --- |
| `llvm` | LLVM 15.0.7 host tools (`llvm-as`, `llvm-dis`, `llvm-link`, `llc`, `opt`, `llvm-tblgen`) |
| `air` | `air_*.ll` → `air_*.air` → `shader-headers/air_*.h`: the whole build route |
| `host` | airconv built for x86_64 Linux with these helpers: `host/scan-port` (`probe/airconv_scan.cpp`) |

## How the port stays faithful

- **Apple's output is the reference, not a reading of the source.** Every
  float operation carries the same `fast` flags and the same AIR intrinsic
  Apple emits (`air.fast_ceil.f32`, `air.fast_clamp.f32`, `air.convert.*`,
  half-precision `air.floor`/`air.ceil`). Where Metal rewrites the source
  (the half-precision `i / (inner + 1)` becomes a hoisted reciprocal and a
  multiply, which can round differently near 0.5 and so change which
  triangles form) the port writes Metal's form.
- **Integer min/max and `absdiff`** use the AIR intrinsics Metal emits.
  Plain `icmp`+`select` would be turned by airconv's InstCombine into
  `llvm.umin`/`llvm.smin` on narrow and vector types, which no Apple-compiled
  helper contains.
- **Shift counts are masked** to the operand width as Metal does (`& 31`),
  `isnan` is an integer bit test that survives fast math, and a conditional
  `clz` is evaluated only on its branch, as in the source.
- **Convergence**: `simd_all`, `simdgroup_barrier` and every function
  reaching them are `convergent`, and the calls stay outside the
  `thread_index < count` branch.

## Typed pointers

airconv parses helpers into an LLVM context with opaque pointers off. In
opaque-pointer mode LLVM 15's `llvm-as` writes a module that context rejects;
airconv then prints "Failed to parse air bitcode", and with LLVM assertions on
(as the fork builds LLVM) the unchecked `Expected` aborts the whole
conversion. The `air` stage therefore assembles with `-opaque-pointers=0`.

## When the fork changes a helper

The port was proved against the Apple-compiled helpers of 3Shain/dxmt v0.74
(differential execution, about 2.6 × 10¹⁰ checks, and a float-operation audit;
the proof tooling is in git history before its removal). It holds for the
helper sources at the dxmt pin: when a rebase changes
`src/airconv/shaders/*.metal`, the `.ll` files must change with it by hand,
following the rules above. What it cannot show is how the device's Metal
compiler lowers this AIR; a tessellated draw on the device is that check.

## A title's shaders

`pp shaders` (`probe/title_shaders.py`) runs every DXBC shader a title ships
through the `host` stage's airconv (`scan-port`, `probe/airconv_scan.cpp`),
before the title ever reaches the phone:

    pp shaders TITLE_DIR OUT [--match REGEX]

It builds `scan-port` on first use (and again when the dxmt pin or the host
sources change) into the build's AIR helper cache, from the dxmt tree `pp
build` cloned, and passes that cache's LLVM 15 as `--llvm`. `--scan SCAN`
uses another `scan-port`, for example one built by hand:

    DXMT_BUILD_ROOT=DXB build/air-helpers/air-helper-port.sh ROOT llvm air host
    pp shaders TITLE_DIR OUT --scan ROOT/host/scan-port --llvm ROOT/llvm15/bin

It finds the DXBC containers inside the title's files (engines keep them in
their own cache formats), keeps one copy of each, and converts them as DXMT
does on the device: vertex, pixel and compute shaders alone, geometry shaders
through both halves of the geometry mesh pipeline, hull and domain shaders
through the tessellation pipeline. `--llvm` also runs LLVM's verifier on
every standalone result. Offline the title's real shader pairings are unknown,
so a geometry, hull or domain shader passes when it converts with any
first-stage shader of the title. Compressed caches are not searched; the
summary lists the files that held containers. What it cannot check is the
device's Metal compiler.

The `host` stage needs a `DXB` whose fork checkout has its
`include/native/directx` submodule; a `git clone --shared` of a built tree
needs that directory linked in.

## Licence

The `.ll` files are translations of DXMT's `src/airconv/shaders/*.metal`,
which are MIT (Copyright (c) 2023 Feifan He), and carry the same terms.
