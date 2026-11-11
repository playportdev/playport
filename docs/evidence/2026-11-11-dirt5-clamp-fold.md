# DIRT 5 (Xbox): the clamp's Inf/NaN test folded; a float target keeps its colour

**Linear:** [PLA-815](https://linear.app/playportdev/issue/PLA-815/dirt-5-xbox-9pjgm0t0827v).
**Date:** 2026-11-11. **Title:** DIRT 5, Xbox store copy `xbox-9PJGM0T0827V` (PC Game
Pass, GDK `game_release.exe`). **Phone:** the test iPhone18,4, iOS 27.2, dev app,
Vulkan (Direct3D 12 through vkd3d-proton), 720p rows,
`MESA_KK_EXPERIMENTAL=soft_fp64,clamp_float_output,zero_init`.

## The fault

`patches/mesa` 0150 added `clamp_float_output`: in the format-aware fragment
output pass, a float colour output that is Inf or NaN becomes 0, the D3D12 render
target conversion. It built both tests with float compares:

```c
nir_def *nan = nir_fneu(b, value, value);
nir_def *inf = nir_fge(b, nir_fabs(b, value),
                       nir_imm_floatN_t(b, INFINITY, value->bit_size));
```

The builder made them with no float controls, so NIR folded them as if the value
were finite. The compare was false for the shader's finite colour, `bcsel` chose
the replacement, and the shader's own colour was never read. A fragment shader
drawing into an RGBA16F or RG11B10F target wrote the replacement instead of its
colour, so those targets were black. The passes that write the swap chain's
non-float format still drew, which is why the race could look right while the
float-target surfaces were black.

## The change

`patches/mesa` 0153 tests the exponent bits instead:

```c
const uint64_t exponent = value->bit_size == 16 ? 0x7c00 : 0x7f800000;
nir_def *non_finite =
   nir_ieq_imm(b, nir_iand_imm(b, value, exponent), exponent);
```

The integer test does not depend on float controls and keeps the clamp's value:
a real Inf or NaN still becomes 0, a finite colour passes through.

## Host test

`build/mesa-host-test/kk-host-test.c` adds two float-target pipelines, RGBA16F and
RG11B10F, that draw `color.frag` (which writes its varying). Without the switch
the fragment MSL must read `in.vary_00` and test no exponent; with
`MESA_KK_EXPERIMENTAL=clamp_float_output` it must read the varying and test each
component's exponent (`& uint(2139095040u)`). `build/mesa-host-test/run.sh` runs
both and checks that exactly the two float-target fragment libraries differ from
the default run's MSL.

The hosttest of 13:55, before the phone build:

```
default=191 clamp=191
2
ok float-target
ok float-target clamp_float_output
```

`.work/run/mesa/hosttest/clamp.log` line 48 is `ok float-target
clamp_float_output`; the default run's `ok float-target` has no exponent test, and
the two runs' MSL differ in exactly two of the 191 libraries.

## On the phone

Dev IPA `4b900be4630385380da2d3e6de799c1def066e36145f271974b7e4d1a80cb1a5`
(HEAD `075c04c5` plus 0153 and the host test), installed in place at 14:01. Run
`.work/ui-runs/clampfix-start`:

```
+4.95 s game started
+5.75 s first window
+274.52 s first frame
```

The first frame is late because this MSL change recompiles the affected shaders
(`[kk-compile] totals ... failed=0`); it is not a warm-cache number. The title
runs at 60 FPS; the garage and race at 13–15 FPS at thermal Serious. The
screenshots are `.work/ui-runs/clampfix/s1.png`–`s14.png` (1600x737, the HUD strip
included):

* `s1`: the title screen's race artwork, in colour.
* `s2`: the save-conflict dialog.
* `s3`: the garage with the autosave notice.
* `s4`: Video Options over the garage's bright windows.
* `s5`–`s8`: the profile's nickname, nationality and number screens over the
  garage; the car and its green wheels draw in colour.
* `s9`–`s12`: the DIRT podcast by Donut intro and the Bruno event's car.
* `s13`: the Henningsvaer Reverse event splash.
* `s14`: the Henningsvaer Reverse race at the start line: wet track, puddles
  reflecting the buildings and sky, the start structure's glass roof showing the
  sky through it, coloured cars and HUD; 15 FPS, 63.9 ms, thermal Serious.

The race's glass roof is transparent and the puddles reflect; the event splash is
in colour. The event intro camera that showed the flat white sky and black banner
shapes in `faketier-intro.png`, and a driven lap, were not captured here: the race
is at the start line.
