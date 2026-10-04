# BREAKTHROUGH: 32-bit DirectX 9 Portal 2 is actually playable on an iPhone! 🔥

Not streaming. Not a mobile remake. The Windows game, running locally on a **non-jailbroken iPhone** through Playport, built on willfaust/Madeira. This was a beast to crack:

- **x86-32 → ARM64 was brutal.** iOS reserves the bottom 4 GB—exactly where 32-bit pointers expect to live. Patches to Wine/WoW64 and FEX put the guest in a relocated 4 GB window and translate memory accesses inline. No pointer truncation roulette!
- **DirectX 9 → DXVK → Vulkan → Metal.** Built 32-bit DXVK and hooked Wine's Vulkan bridge into **KosmicKrisp**, Mesa's Vulkan-on-Metal driver. PC graphics on Apple's GPU! 🚀
- **Real patches, not magic flags:** ported KosmicKrisp to iOS, added geometry shaders and wireframe/point fill for DXVK; fixed Vulkan pointer/memory mapping, shader storage, Steam callback ABI, controller routing and 32-bit audio.
- **Actual gameplay:** movement, BOTH portals, a solved laser puzzle, sound, controller input and save/reload. Around **60 FPS at 720p** in short tests; a **95-minute crash-free session**, settling near 50 FPS as the phone heated up.

**Huge milestone—not a full-campaign certification yet.** Loading/gameplay hitches and thermal slowdown still need work. But 32-bit Windows + DX9 on an iPhone? LET'S GO. 🔥
