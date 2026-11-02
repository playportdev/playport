# 0089: OpenGL for i386: the route gate

**Status:** accepted 2026-10-11: host-side Zink serves i386. The budget was set and committed
(be3a61a) before the measurement. This carries out the OpenGL plan's chunk 3 gate
([the plan](https://linear.app/playportdev/issue/PLA-162), "Route decision"). The worker chose the
conservative options (owner away).
[PLA-162](https://linear.app/playportdev/issue/PLA-162). Amends
[0087](0087-opengl-through-zink-on-the-host.md), which left i386 open until this gate.
[Evidence](../evidence/2026-10-11-opengl-i386.md).

## Context

On x86-64, OpenGL is Mesa's Zink in the app, reached through Wine's opengl32 unix thunks
([0087](0087-opengl-through-zink-on-the-host.md), [0088](0088-opengl-window-surfaces-and-pacing.md)).
For an i386 game, those thunks are WoW64 thunks: they convert pointers through the child's window
(`patches/wine-unix` 0029). Every GL call then pays for an emulator exit, a WoW64 thunk and a unix
call. Immediate-mode engines (GoldSrc and its era) make tens of thousands of GL calls a frame.

The other route is the guest-side fallback: Mesa's WGL and Zink built as an i686 `opengl32.dll`
over Wine's i386 `winevulkan`. GL calls stay inside the emulated Mesa there, and only Vulkan calls
cross.

## The budget (set before measuring)

- **Measurement.** The `gl21` probe's `stress` mode (`tools/compat/probes/gl21.c`), in its
  "immediate" phase: each frame is a clear, 20,000 `glVertex3f` calls between one
  `glBegin`/`glEnd`, and `SwapBuffers`. The probe logs the phase's mean frame time
  (`gl21: STRESS immediate: … ms per frame`).
  - It runs on the phone from the imported title, with the game layer's frame limit Off. Pacing
    then caps it at the display's 120 Hz (8.3 ms) rather than 60 FPS.
  - It runs twice per machine on the same IPA.
- **Budget: at most 16 ms per frame for i386**, the higher of its two runs.
- **If i386 meets the budget,** host-side Zink serves i386 as well as x86-64.
- **If it does not,** the guest-side i386 fallback is the route for i386, and x86-64 stays
  host-side. That fallback is a separate chunk, not built here.
- **Reported, without a budget:**
  - the same phase on x86-64;
  - the "client-array" and "vbo" phases (the same 20,000 vertices as one `glDrawArrays`, from
    client memory and from a buffer object);
  - the time the draw calls took within each frame.

## Outcome

Measured 2026-10-11 on IPA `ddd76f9a…`, with the phone's thermal state nominal at each launch
([evidence](../evidence/2026-10-11-opengl-i386.md)):

| Machine | immediate, run 1 / run 2 (ms per frame) | draw calls within it | client-array, vbo |
|---|---|---|---|
| i386 | 8.42 / 8.39 | 4.36 / 4.39 ms | 8.34–8.35 ms (draw 0.01–0.05 ms) |
| x86-64 | 8.40 / 8.40 | 3.64 / 3.69 ms | 8.34 ms (draw 0.01–0.06 ms) |

- **i386 meets the budget: 8.42 ms against 16 ms**, so **host-side Zink serves i386** as well as
  x86-64. The guest-side i386 fallback is not needed and not built.
- Frames run at the display's 120 Hz on both machines. The 20,000 immediate-mode calls take about
  4.4 ms on i386 (about 220 ns a call) and 3.7 ms on x86-64.

What this means:

- **i386 OpenGL goes through opengl32's WoW64 thunks.** They convert the caller's pointers through
  its window (`patches/wine-unix` 0029). A pointer that is an offset into a bound buffer stays an
  offset, decided at each call from the context's binding. An i386 child gets opengl32's WoW64
  table (`patches/madeira-unix` 0116).
- **Limits on i386:**
  - Persistent buffer maps are refused, and logged. They need opaque-fd Vulkan export, which
    KosmicKrisp does not have. `GL_ARB_buffer_storage` is hidden from i386 contexts, as opengl32
    already does without it.
  - Query-buffer results (GL 4.4) are taken as client pointers.

  Neither is needed at the GL 3.3 ceiling.
- **Watch the per-call cost on real titles.** An engine that makes several times 20,000 GL calls
  a frame would spend proportionally longer: about 9 ms at 40,000 calls. The plan's chunk 4
  (GoldSrc) measures real titles.
