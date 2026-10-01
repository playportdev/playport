# The Witcher 3 with a 384 MiB JIT pool

**Status:** one run, a quick check. **Date:** 2026-09-30. Plan:
[performance follow-up](../plans/2026-09-28-performance-follow-up.md), step 5.
**IPA:** dev,
`4c73e9c7b894f4f7ed5bd9221ee863a1165122feaaf502fa7c3f64bf3235566d`, the Wine
PE set without DWARF ([record](2026-09-29-pe-debug-strip.md)). **Phone:**
iPhone Air (`iPhone18,4`), iOS 27.0, on battery (55 %).

## Run

Settings' *Simulated JIT memory* at 384 MiB (`set:jitPoolSimulatedMB=384`),
then, in the same lock session,
`pp perf --title app-292030 --secs 300 --cool 15 --settings '{"screen":"720","frameLimit":0}'`
with `witcher3-continue` and `witcher3-walk`: the Kaer Morhen save, walking the
room for four minutes. The launch logged `jit pool: 384 MiB … (simulated
pool)`. A 512 MiB run before it never launched: the phone locked itself during
the 15-minute rest (`the app did not launch within 20 s: the phone is most
likely locked`). It was not repeated, since 384 answers for 512 too.

The comparison is the 896 MiB `w3-base-2` run of the same day
([record](2026-09-30-witcher3-counters-maxinst.md)), which played 150 s.

## Result

| | 896 MiB (`w3-base-2`) | 384 MiB (`w3-pool384`) |
|---|---|---|
| pool at the save's load (head / tail / room) | 151 / 33 / 713 MiB | 151 / 33 / 201 MiB |
| pool at the end (head / tail / room) | 157 / 161 / 579 MiB | 157 / 161 / **67 MiB** |
| exhaustion, refused tail, alias full | none | none |
| FEX real compiles | 69,060 | 68,853 |
| walk 60–150 s: FPS, ≥50 ms frames, Mi instructions/frame, CPU mW | 30.0, 9, 505, 1592 | 30.0, 10, 506, 1567 |
| walk 150–300 s: FPS, ≥50 ms frames | – | 30.0, 31 |
| the app's memory (Metal HUD), walking | 5725 MiB | **4752 MiB** |

- **The game uses 318 MiB of pool** for its images (157 MiB) and FEX's code
  (161 MiB), whatever the pool's size. The 384 MiB pool held that for five
  minutes, with 67 MiB to spare and FEX compiling the same amount of code.
- **Performance is the same:** frame rate, work per frame and CPU power.
  The later walk's 31 frames of 50 ms or more have no counterpart in the
  896 MiB run, which ended at 150 s.
- **A smaller pool gives memory back:** the app's footprint is 970 MiB less.
  That is about twice the 512 MiB the pool shrank by. This record does not show
  why; the pool's two mappings of the same memory would each count, but that
  was not checked.

## Not established

- Whether 318 MiB holds for a long session. FEX's code buffer grows with the
  code a game runs, and this was one room of one save for five minutes. So this
  run does not justify making the pool smaller than 512 MiB. Nor does it
  justify taking the limit-based sizing (512–896 MiB,
  [decision 0019](../decisions/0019-jit-pool-sized-from-the-limit.md)) down.
- The 512 MiB run, a repeat, and Hollow Knight (which the strip left at a
  132 MiB head).
