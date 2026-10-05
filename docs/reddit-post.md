# Reddit post draft: Playport 0.3.0, 32-bit games

Suggested subreddits: r/sideloaded, r/iosgaming, r/EmulationOniOS, and
r/linux_gaming for the technical angle. Post as a video post with the body as
the first comment, or as a text post with the video inline. v0.3.0 was
published on 2026-10-05, so the release link works.

Video: the owner's screen recording of the release app, 2026-10-05, 92 s,
landscape 2736x1260 at 60 FPS with sound, 93 MB (well within Reddit's limits).
It is kept outside the repository: the game's art is not ours to publish here.
It shows Playport's Home, Play with "Waiting for JIT", Valve's intro, LOAD GAME,
the load, then a test chamber with both portals placed, with
Apple's Metal performance HUD reading about 60 FPS.

---

**Title:** 32-bit Windows games now run on a non-jailbroken iPhone: Portal 2 at ~60 FPS, with Direct3D 9 drawn through KosmicKrisp (Playport 0.3.0)

**Body:**

[video: Portal 2 played on an iPhone with a DualShock 4, from Playport's Home
to a test chamber; the HUD in the corner is Apple's Metal performance HUD]

This is the actual Windows build of Portal 2 from Steam, running **locally on a
non-jailbroken iPhone** in Playport. No streaming, no PC in the loop, no mobile
port. Playport 0.3.0 is out, and its big news is that **32-bit games work now**.

**Why 32-bit was the hard part**

A 32-bit Windows game expects to live in the lowest 4 GB of memory. On iOS that is
exactly the range every app is forbidden to touch. So 32-bit games were simply
impossible until now.

Playport now gives each 32-bit game its own 4 GB window higher up in memory.
Wine's WoW64 layer and FEX (the x86 to ARM64 translator) were patched to place the
game there, and FEX adds the window's base to every memory access as it translates
the code. The game thinks it is on a normal 32-bit PC.

**The graphics: Direct3D 9 → DXVK → Vulkan → KosmicKrisp → Metal**

iOS has no OpenGL for Wine and no Direct3D 9 path to Metal, so we went through
Vulkan. DXVK turns Direct3D 9 into Vulkan, and **KosmicKrisp**, Mesa's new Vulkan
driver for Apple GPUs, turns Vulkan into Metal. We ported KosmicKrisp to iOS and
added what DXVK needed (geometry shaders, wireframe and point fill), plus a disk
shader cache so the second launch skips the shader compiles.

**How well it runs**

- About **60 FPS at 720p**: a 5-minute human play (portals, tunnels, a death and a
  reload) averaged 58.4 FPS.
- A **95-minute session** with saves and loads and no crash. When the phone gets
  hot after a long session, it settles near 50 FPS.
- Both portals, physics, sound, controller, saves and **Steam Cloud** sync all work.
- Old 32-bit games do their math on the x87 FPU. Running it at native 64-bit
  precision (Valve's Proton default on ARM64) cut Portal 2's main-thread work by
  about 40 % and kept the phone cooler.

**What it is not (yet)**

Portal 2 is the only 32-bit game tested so far. Other 32-bit Direct3D 9 games go
the same way, but expect rough edges. There are short hitches on level loads, and
heat still costs frames in long sessions. Tell us what you try!

**Get it**

- Release (IPA, full source, notices): https://github.com/playportdev/playport/releases/tag/v0.3.0
- Sideload with your own Apple ID; JIT is enabled by the app's own helper. Bring
  your own Steam games.

Playport is open source (GPL-3.0-or-later) and built on willfaust/Madeira (Wine,
FEX-Emu and DXMT in one iOS process). Huge thanks to everyone behind Wine, FEX,
DXVK and Mesa/KosmicKrisp.
