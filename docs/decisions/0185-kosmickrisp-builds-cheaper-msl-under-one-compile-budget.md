# 0185: KosmicKrisp builds cheaper MSL, under one compile budget

**Status:** accepted, 2026-11-13, by the owner (grilling session on cold shader compiles; spec [PLA-852](https://linear.app/playportdev/issue/PLA-852): "games
still need to be playable" with no cache). Not built yet. Tickets: PLA-853 (initialisers), PLA-854 (budget), PLA-856–PLA-858 (builtins), PLA-820 (output state). Evidence:
[cold shader compiles](../evidence/2026-11-13-cold-shader-compiles.md). Companion records:
[0186](0186-dxvk-skips-a-draw-whose-pipeline-is-still-compiling.md) (DXVK skips a draw that is
still compiling) and [0187](0187-pipeline-records-and-shader-preparation.md) (pipeline records).

## Context

- **What a game waits for.** A cold pipeline costs 100–300 ms on the phone, and up to 3.2 s for a
  large one.
  - 72–79 % of that is Metal's front end (MSL to AIR), 21–28 % the pipeline build, and 2–4 %
    Mesa.
  - A D3D11 game under DXVK waits for every new pipeline at its draw, so a level's first minutes
    froze THPS3+4 for 77–125 s at a time.
- **The cost is in what KosmicKrisp hands Metal, not in Metal being slow.** Three things make the
  front end costlier than it needs to be:
  - **Texture types.** `metal_stdlib`'s texture class templates cost 25–50 ms of instantiation per
    distinct texture type in each library, used or not. The compiler's own `__metal_*` builtins
    give the same AIR without it.
  - **Zero-initialised temporaries.** Every SSA temporary is predeclared as `T tN = T(0);`. That
    costs superlinearly on large libraries: −26 to −43 % without it on 0.5–0.8 MB kernels.
  - **Baked output state.** Whole pipelines put blend, write mask, alpha to coverage and alpha to
    one, and exact formats into the fragment MSL. So only 6–12 % of fragment libraries are Apple
    cache hits, against 62–70 % of vertex libraries.
- **Parallelism is capped.** Parallel builds give about 2× at best, and iOS ends MTLCompilerService
  above 150 MB.

## Decision

All of this is in `patches/mesa`, on by default in dev and release, with no flag.

- **No zero initialisers.** `nir_to_msl` declares SSA temporaries and registers without an initial
  value, as upstream Mesa's merge request 45954 does.
- **Texture builtins.**
  - `nir_to_msl` writes every texture and sampler operation KosmicKrisp emits with the compiler's
    `__metal_*` builtin types and calls, not `metal_stdlib`'s texture classes: sample, read, write,
    gather, compare, queries and atomics, for every texture kind.
  - Every operation is mapped before this ships.
  - A probe compile at device creation checks that the phone's compiler accepts the builtins. If
    it does not (an iOS update renamed one), the whole device emits today's class-form MSL.
- **Output state in fixed function.**
  - A whole pipeline sets blend factors and operations, the write mask, and alpha to coverage and
    alpha to one on Metal's pipeline, as the GPL link already does.
  - Its fragment outputs are declared by format class (float, sint, uint), not exact format.
  - Dual-source blending, logic ops and advanced blend stay in the shader.
- **One compile budget.**
  - KosmicKrisp keeps one process-wide limit on Metal builds in flight:
    `maximumConcurrentCompilationTaskCount` capped at 3, or 2 where the property is missing.
  - A build a draw is waiting for takes a slot before background builds: DXVK's skipped-draw
    compiles (0186) and shader preparation (0187).
  - `parallel_stages` (mesa 0053), the vertex and fragment libraries of one pipeline built at once,
    is on by default under that budget.
- **Gate.** Hollow Knight to first frame + 10, and the cold acceptance below.
- **Acceptance.** After Settings › Storage › Clear, the owner plays THPS3+4, Moonlighter 2 and
  Witcher 3 for about 10 minutes each. No freeze may be longer than 1 s after first frame. This gate
  covers 0185, 0186 and 0187 together.

## Why

- **The builtins are the largest lever.** An estimated −35 to −55 % of total cold compile time,
  since most game libraries are under 100 KB and their cost is mostly texture types.
  - It is undocumented compiler surface, so the device probe and the class-form fallback keep an
    iOS update from breaking compiles.
  - Mapping every operation up front means no shader silently keeps the slow form.
- **Dropping the initialisers is upstream's change**, tested on Apple's compiler. It removes the
  superlinear cost of large libraries.
- **Fixed-function output state** lets one fragment library serve every blend and format variant.
  Its gain is not sized for D3D11 titles yet, and it is built without a prior sizing step.
- **One budget,** because every source of parallel builds draws on the same compiler service and
  the same 150 MB limit. The game's draw must never wait behind background work.

## Costs

- **Every title's Metal caches go cold once.** Each of these changes changes the default MSL, so
  ship them together where possible.
- **More code to own:** a second form of every texture operation in `nir_to_msl`, kept in step with
  Apple's builtins.
- **More logic on the pipeline:** fixed-function output state for whole pipelines, and a
  format-class output declaration.
- **Metal's pipeline build stays.** These changes do not touch its 21–28 %. Only emitting AIR
  directly would remove the front end entirely, which is its own spec, started after this one
  lands.
