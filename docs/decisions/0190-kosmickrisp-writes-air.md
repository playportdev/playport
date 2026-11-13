# 0190: KosmicKrisp writes AIR, and the pipeline record holds it

**Status:** accepted, 2026-11-13, by the owner (grilling session on spec
[PLA-864](https://linear.app/playportdev/issue/PLA-864)). Not built yet. Amends
[0187](0187-pipeline-records-and-shader-preparation.md): a pipeline record entry holds the form
it was compiled to, keyed by its final NIR. Builds on [0185](0185-kosmickrisp-builds-cheaper-msl-under-one-compile-budget.md),
whose cheaper MSL stays the fallback.

## Context

- **Metal's front end is most of a cold pipeline.** It compiles MSL to AIR, which is 72–79 % of a
  cold pipeline ([cold shader compiles](../evidence/2026-11-13-cold-shader-compiles.md)). A
  library loaded from a metallib with `newLibraryWithData` takes 0.01–0.02 ms on the phone, and
  the pipeline build does not grow ([GPL cold cache](../evidence/2026-10-22-kk-gpl-cold-cache.md)).
- **What Apple's tools write.** Apple's Metal tools 6.2 under Wine write AIR 2.8 for
  `-std=metal4.0` and for `metal3.2` alike: triple `air64_v28-apple-ios26.0.0`, opaque pointers,
  and attributes of LLVM 21 or later (`captures(none)`). They refuse `-std=metal4.1`. The phone on
  iOS 27 loads their metallibs.
- **DXMT's LLVM cannot be shared.** DXMT's converter is built on LLVM 15.0.7 with typed pointers,
  which LLVM removed in version 17. DXMT will be dropped eventually.
- **Bitcode is read backward-compatibly only.** The phone's Metal may refuse bitcode written by an
  LLVM newer than its own reader.
- **Most of a record's worth is the pipeline build.** Once AIR loads in microseconds, the cost
  left is Metal's pipeline build, which only Apple's purgeable cache saves. A separate AIR cache
  would save only generation.

## Decision

- **The AIR path.** KosmicKrisp turns NIR straight into AIR, writes the metallib itself and loads
  it with `newLibraryWithData`.
- **The form.**
  - It writes what Apple's tools write: AIR 2.8, Metal 4.0 language metadata, opaque pointers,
    and the same metallib header and tags.
  - A shader that needs an MSL 4.1-only feature (threadgroup float atomic add) takes the MSL
    fallback until a phone run proves its AIR.
- **LLVM.**
  - KosmicKrisp links its own LLVM statically into KosmicKrisp.framework, with only the
    components the generator needs (IR, the bitcode writer, Support).
  - Its `pins.lock` entry is the oldest LLVM release that reads Apple's 6.2 AIR. It moves only by
    a manual pick, the device probe and a Hollow Knight play.
  - The generator calls LLVM through the LLVM-C API, in C beside `nir_to_msl`, and runs no
    optimisation passes. LLVM's verifier runs in dev builds only.
  - KosmicKrisp owns a small metallib writer.
  - DXMT keeps its LLVM 15 until it is dropped.
- **Coverage.**
  - Before the AIR path is the default, it covers everything `nir_to_msl` emits on the default
    path. That includes every stage, the compute programs geometry and tessellation lower to, the
    internal kernels (generated at runtime), textures, subgroup and atomic operations, fp64
    lowering and 16-bit types.
  - The GPL path stays on MSL while it is experimental (0158).
- **The MSL fallback.** A library is built from MSL, as today, when:
  - the generator does not cover the shader (that shader alone, with the reason logged);
  - a probe metallib is refused at device creation (the whole device);
  - `newLibraryWithData` refuses the library (that library alone).

  A dev-only switch forces the MSL fallback for debugging.
- **The pipeline record holds AIR** (amends 0187).
  - Each entry holds the form it was compiled to: a metallib, or MSL on the fallback.
  - An AIR entry is keyed by the hash of the serialized NIR handed to the generator, the **AIR
    generation** and the options that change the output (math mode, workarounds, GPU family).
  - The AIR generation is a stamp that every generator-changing patch moves, as the MSL
    generation is for MSL.
  - KosmicKrisp looks a library up in the running game's record before generating it, and
    replay loads metallibs.
  - AIR entries are dropped when the AIR generation moves or the device refuses AIR. The caps,
    Storage, Clear and removal stay as 0187 sets them.
- **Mesa's disk cache** stores the metallib on the AIR path, in place of the MSL.
- **Proof.**
  - **Host:** the mesa host test's shaders, the RDR2 Fossilize corpora and desktop Proton
    captures of the acceptance titles are compiled both ways. Apple's tools validate every AIR
    library. Its signature and binding metadata must equal those of Apple's AIR from the MSL path,
    and a difference in the `air.*` intrinsics it uses is reported.
  - **Phone:** the Hollow Knight smoke, and the AIR path against the MSL fallback compared by
    eye.
- **Rollout.**
  - Behind a dev switch until coverage is complete, then the default in dev builds.
  - The default in release after cold runs of THPS3+4, Moonlighter 2 and Witcher 3 against
    PLA-852's baseline and the owner's sign-off. The gain is reported with no numeric target;
    no freeze may last longer than 1 s after first frame.

## Why

- **Matching Apple's own output** makes the MSL path's AIR the oracle, field for field, and the
  phone already loads that form.
- **A current LLVM of KosmicKrisp's own** outlives DXMT. LLVM 15 cannot even parse Apple's AIR,
  so sharing it would tie the generator to a toolchain on its way out.
- **The LLVM-C API** fits Mesa's C and survives pin moves better than the C++ API.
- **No optimisation passes:** NIR is already optimised, and Metal's pipeline build optimises
  again. Generation stays cheap and the linked LLVM small.
- **One per-game store** keeps one cap, one Clear and one replay. A key on the final NIR survives
  KosmicKrisp changes that leave the shader the same.
- **The per-shader fallback** lets coverage grow one ticket at a time, each one green on its own.

## Costs

- **Two LLVMs in the app** until DXMT is dropped, and a new pin to keep.
- **A second code generator** to keep in step with `nir_to_msl` and with Apple's AIR across iOS
  releases.
- **Undocumented AIR.** Apple publishes neither AIR nor the metallib format. The device probe and
  the MSL fallback keep an iOS update from breaking compiles, but then every title runs at MSL
  cost until the generator catches up.
- **Every title's Metal caches go cold once** when the AIR path becomes the default.
