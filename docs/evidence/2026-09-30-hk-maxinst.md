# Hollow Knight: FEX block size 500 against 5000

**Status:** one A/B/B/A block, no difference found. **Date:** 2026-09-30.
Plan: [performance follow-up](../plans/finished.md#performance-follow-up-after-the-runtime-audit),
step 2. **IPA:** dev,
`4c73e9c7b894f4f7ed5bd9221ee863a1165122feaaf502fa7c3f64bf3235566d`.
**Phone:** iPhone Air (`iPhone18,4`), iOS 27.0, on battery (88 → 75 %).

## Runs

`pp perf --secs 300 --cool 15` at `{"screen":"720","frameLimit":60}`, with the
game page's Block size at 500 (`"maxInst":500`) or Default (5000), in the order
5000, 500, 500, 5000. Each launch logged the value it got in its FEX line
(`maxinst=500*` for the page's choice), and FEX logged it too, in
`[mono-cfg] … Multiblock=1 MaxInst=500 => HOOKS ARMED`: Hollow Knight's Mono
path stays on at 500, which it needs. Directories:
`$PLAYPORT_BUILD/perf-ab/mi*`.

| run | FPS | p99 / p99.9 ms | ≥25 / ≥50 ms | Mi instructions/frame | CPU mW | GPU ms | FEX compiles |
|---|---|---|---|---|---|---|---|
| `mi5000-1` | 60.0 | 25.0 / 29.2 | 501 / 0 | 63.4 | 538 | 6.32 | 145,633 |
| `mi500-1` | 60.0 | 25.0 / 29.2 | 438 / 0 | 63.0 | 537 | 6.31 | 146,387 |
| `mi500-2` | 60.0 | 25.0 / 29.2 | 470 / 0 | 67.3 | 560 | 8.80 | 141,172 |
| `mi5000-2` | 60.0 | 25.0 / 29.2 | 507 / 0 | 63.5 | 540 | 6.32 | 147,131 |

The steady columns are the roam loop, 120–300 s after the first frame. The
compiles are FEX's real compiles over the whole run, from its last
`[CB_SUMMARY]`. The loading and route before 120 s have 7–8 frames of 50 ms or
more in every run, 3–4 of 100 ms or more, and the same 696–700 ms scene-load
stall, at either size.

`mi500-2` played somewhere else: its Knight was in the lumafly room at
150 s, and its GPU time (8.8 ms) and instructions show a different scene. It
is left out.

## Result

At 500 instructions a block FEX compiles as many blocks (146,387 against
145,633 and 147,131) and runs the same work per frame (63.0 against 63.4 and
63.5 Mi) at the same CPU power, with the same first-use and loading tails. On
this title, at this mode, the block size changes nothing that these runs
resolve. So FEX's 5000 stays, and no per-title setting is proposed. One title
does not settle a global default, and The Witcher 3 was not run.

The compile count's insensitivity suggests that Hollow Knight's blocks already
end well under 500 instructions (at branches, with multiblock joining them),
so the ceiling rarely binds. 1000 and 2000 were not run: the plan adds them
only if 500 shows an effect.
