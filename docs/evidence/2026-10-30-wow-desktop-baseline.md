# WoW retail under desktop Wine: login and character select on Direct3D 12, login on 11 (2026-10-30)

**Linear:** [PLA-509](https://linear.app/playportdev/issue/PLA-509) (spec
[PLA-516](https://linear.app/playportdev/issue/PLA-516)). Uses the install from PLA-517
([evidence](2026-10-30-battlenet-install.md)). A workstation baseline, never shipped
([HOST-DEBUGGING.md](../HOST-DEBUGGING.md)).

**Status:** the x64 client reaches WoW's login screen on Direct3D 12 (vkd3d-proton) and with
`-d3d11` (DXVK), and with the owner signing in it reaches **character select on Direct3D 12**
([owner run](#owner-sign-in-run)).

## Setup

| | |
|---|---|
| game | WoW retail `wow` 12.1.5.70575, "Version 12.1.5 (70575) (Release x64) Oct 22 2026" on the login screen; `_retail_/Wow.exe` 80,243,408 B, sha256 `14b70997cf6c7971a4fcd533b7f421316b6a3da0c8da3710425a8dd20e356a29`; region us, enUS |
| install | `wow-install/wow` in the integration worktree's build area (`.work/worktrees/battlenet/.work/` in the main checkout), run in place; nothing copied |
| Wine | Wine 11.20 (system), a scratch 64-bit prefix under `$PLAYPORT_BUILD/agent-notes/wow509/prefix` (made in side worktree `bnet-517`'s build area, since moved to the integration worktree `battlenet`'s) |
| D3D12 / D3D11 | vkd3d-proton 3.0.0 (build `21a49c97`) and DXVK 2.6.2-23-g3cb664e1 (`dxgi`, `d3d11`, `d3d10core`), both from Proton 10.0-4b, in the prefix's `system32`, `WINEDLLOVERRIDES=d3d12,d3d12core,dxgi,d3d11,d3d10core=n` |
| driver | Mesa 26.2.5 RADV, AMD Radeon RX 9070, Vulkan loader 1.4.363, kernel 7.3.0 |
| display | an agent-owned headless sway (`WLR_BACKENDS=headless`, its own Wayland and IPC sockets, Xwayland `:1`), 1920x1080; the game on Xwayland; no physical output; stopped after each run. The owner's niri session was not used |
| other | `winebrowser.exe` disabled and `BROWSER=/bin/false`; MangoHud off (`MANGOHUD=0`); `VKD3D_SHADER_CACHE_PATH` in the build area (by default vkd3d-proton writes `vkd3d-proton.cache` into the game's folder, which the first runs did; deleted) |
| input | none from the host. A small Win32 program in the prefix (`SendInput`, HOST-DEBUGGING.md "Input") pressed Escape, typed console commands and clicked Quit in some runs |

The scripts (`run.sh`, `in-sway.sh`, `owner-niri.sh`, `sendkeys.c`, `caps.c`), logs and
screenshots stay in `$PLAYPORT_BUILD/agent-notes/wow509/` (runs in `runs/<name>/`); the
screenshots show Blizzard's artwork and are described here, not committed.

## Does the client accept the install?

Yes. No repair or redownload prompt, no "Battle.net required" error, no launcher check.

- **First start** (run `d3d12-1`): a Win32 list box titled "World of Warcraft" asks for the
  language and region (English (US), Español (AL), … Русский, three CJK entries), OK/Cancel.
  It comes because `WTF/Config.wtf` has no `portal`/`textLocale`. With a `Config.wtf` of
  `SET textLocale "enUS"`, `SET audioLocale "enUS"`, `SET portal "US"` (what that box writes,
  run `d3d12-2`) the client goes straight on: the intro cinematic plays, then the login screen.
  (inference: a Playport launch should write these three values, as the store's region and
  locale are known; for PLA-514/PLA-519.)
- **Login screen** (run `d3d12-3`, 330 s in, the cinematic not skipped): the Midnight login
  scene with the "Email or Phone" and "Password" fields, "Remember Account", "Log In", and
  Menu / Create Account / Quit, version line as above. A first-start "Screen Narrator" prompt
  (Enable/Disable) and a photosensitivity notice come over it once. Later runs set
  `playIntroMovie "14"`, `showScreenNarrationDialog "0"`,
  `accessibilityScreenNarrationEnabled "0"` and `showPhotosensitivityWarning "11"` (the values
  the game wrote on a clean exit) and reach the login screen 30–60 s after start.
  `-windowed` gives the same in a 1920x1080 window titled "World of Warcraft".
- The console (`-console`, the grave key) at the login screen shows the glue log:
  `Switching to screen="AccountLogin"`, `Overlay is disabled. Only internal builds and public
  China builds have it.`, `Attempt to get account state failed` (inference: the launcher's
  account-state call, which a direct start does not have).
- **A clean exit:** clicking Quit ends the process with exit code 0 after `GxShutdown`.
- **What the game writes in its folder:** `Logs/` (`gx.log`, `cpu.log`, empty others; a killed
  run keeps `gx.log` only up to device creation), `WTF/Config.wtf`,
  `WTF/SavedVariables/*.lua`, `WTF/Account/SavedVariables/*.lua` (glue settings, no account
  yet), `Cache/ADB/enUS`, `Cache/WDB/enUS/*.wdb` (empty creature/quest caches),
  `Interface/AddOns/` (empty). In the prefix's registry it writes
  `HKLM\SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft\InstallPath` (the
  `_retail_` folder) and a binary `HKCU\Software\Blizzard Entertainment\Battle.net\Identity`
  value (a per-machine identity made before any sign-in; not quoted here).
- `-gluescript`/`-gluescriptFile` (in the client's command-line help strings) are refused in
  this release build: "CommandLine Parse Error: gluescriptFile(0): Invalid argument".

## Direct3D 12 needs

`Logs/gx.log`, RADV through vkd3d-proton (run `radv-d3d12`):

```
Adapter 0: "AMD Radeon RX 9070 (RADV GFX1201)" 16GB … dx11:true dx12:true
GpuInfo: sm:dx_6_0, rt:DXR 1.1, vrs:2, bary:1, mesh:1 pull:1
D3d12 Device Create
DXGI_FEATURE_PRESENT_ALLOW_TEARING:true
D3d12 Device Create Successful (229.9 ms)
Using shader family dx_6_0
UAV format support BGRA8:true RG16F:true RGBA16F:true
Detected Graphics Defaults: 7 (CPU = 7, GPU = 7, MEM = 7) WindowSize: 1920x1080
```

The console's `gxApi` says `"D3D12"`, default `"auto"`. The device reports feature level
12_2 and shader model 6.8 (a `CheckFeatureSupport` program, `caps.c`, in the same prefix).
vkd3d-proton logged no warning or error; it applies a built-in workaround for `Wow.exe`
(`adding config 0x10000000000000`). Frames: the intro cinematic at about 60 fps (MangoHud's
overlay, run `d3d12-2`; MangoHud was off in later runs).

**What WoW asks of the device.** WoW has two shader families on Direct3D 12, `dx_6_0` (DXIL)
and `dx_5_0` (DXBC), and logs ray tracing, variable rate shading, barycentrics and mesh
shaders as separate optional features. Capping vkd3d-proton's shader model on RADV with
`VKD3D_SHADER_MODEL` (one run each, nothing else changed):

| shader model reported | 6.0 | 6.1 | 6.2 | 6.3 | 6.4 | 6.5 | 6.6 | 6.8 |
|---|---|---|---|---|---|---|---|---|
| shader family | dx_5_0 | dx_5_0 | dx_5_0 | dx_5_0 | dx_5_0 | **dx_6_0** | dx_6_0 | dx_6_0 |
| ray tracing / barycentrics | none / 0 | none / 0 | none / 0 | none / 0 | none / 0 | DXR 1.1 / 1 | DXR 1.1 / 1 | DXR 1.1 / 1 |

So WoW's DXIL family needs **shader model 6.5** at least (and more, below); under it the
client runs the DXBC family on the same Direct3D 12 device. VRS (2) and mesh shaders (1)
stayed on at every shader model.

**Against KosmicKrisp** (decision [0032](../decisions/0032-vkd3d-proton-as-a-series.md):
feature level 12_0 and shader model 6.6 with Playport's patches, no 64-bit buffer atomics, no
float controls, no compute derivatives). The capture layer's KosmicKrisp profile
(`build/mesa-host-test/vk-capture-layer`, `PP_CAPTURE_PROFILE` with the host mock's device
report of 2026-10-18, as in the [RDR2 evidence](2026-10-17-rdr2-vulkan-needs.md),
`PP_CAPTURE_SPOOF=1`) made RADV look like KosmicKrisp. Proton's vkd3d-proton was used:
Playport's x86_64 build (`run/vulkan-pe/build-vkd3d`) did not load under desktop Wine
(`LoadLibrary` error 998 from its `DllMain`; not investigated, the phone uses the aarch64 and
arm64ec builds), so Playport's 12_0/6.6 was imitated with `VKD3D_FEATURE_LEVEL=12_0
VKD3D_SHADER_MODEL=6_6`.

| | RADV | KosmicKrisp profile | profile + 12_0 / SM 6.6 (as Playport's build reports) |
|---|---|---|---|
| feature level / shader model | 12_2 / 6.8 | 11_1 / 6.0 | 12_0 / 6.6 |
| tiled / conservative raster / ROV | 4 / 3 / yes | 0 / 0 / no | 2 (the env override; KosmicKrisp has no sparse) / 0 / no |
| ray tracing / mesh / VRS / sampler feedback | 1.1 / 1 / 2 / 0.9 | none | none |
| barycentrics, native 16-bit ops, min precision, doubles | yes, yes, 16-bit, yes | no, no, none, no | no, no, none, no |
| wave ops (lanes) | yes (32–64) | yes (32) | yes (32) |
| 64-bit atomics: typed resources / group shared / descriptor heap | yes / yes / yes | no / yes / yes | no / yes / yes |
| binding tier, typed UAV loads, int64 ops, depth bounds, enhanced barriers | 3, yes, yes, yes, yes | the same | the same |
| WoW `GpuInfo` | `sm:dx_6_0, rt:DXR 1.1, vrs:2, bary:1, mesh:1` | `sm:dx_5_0, rt:None, vrs:0, bary:0, mesh:0` | `sm:dx_5_0, rt:None, vrs:0, bary:0, mesh:0` |
| shader family | dx_6_0 | dx_5_0 | **dx_5_0** |
| result | login screen | login screen | login screen |

- **WoW runs on Direct3D 12 under the KosmicKrisp profile** (runs `kk-stock`, `kk-fl12`): the
  device is created ("Apple A19 Pro GPU" 8GB, vendor 0x106b), graphics defaults 3 (GPU 3),
  the DXBC family, and the login scene renders normally; vkd3d-proton logged no warning or
  error; Quit exits 0. Neither feature level 12_0 nor 64-bit atomics is required for this.
- **Even with shader model 6.6 reported, WoW keeps the DXBC family.** It is not the vendor (the
  same with the spoof off, run `kk-nospoof`) nor the `GxCompatAllowSM6` CVar (set to 1 in
  `Config.wtf`, run `kk-allowsm6`). The cap that gates it is not found; the caps that differ
  between RADV at SM 6.5 (dx_6_0) and the profile at 6.6 (dx_5_0) are native 16-bit shader
  ops (vkd3d-proton wants FP16 denorm preservation, which KosmicKrisp does not report), min
  precision, doubles, typed-resource 64-bit atomics and the wave lane range (32 only).
- **The profile is optimistic about 64-bit atomics:** it ANDs only Vulkan 1.0 features, so
  RADV's `shaderBufferInt64Atomics`/`shaderSharedInt64Atomics` (Vulkan 1.2) pass through, and
  vkd3d-proton reports group-shared and descriptor-heap 64-bit atomics that KosmicKrisp does not
  have (0032). WoW's DXBC family cannot use 64-bit atomics (Shader Model 5), so the result
  above stands on the phone, but a DXIL run there could hit 0032's compile failures.
- The 2026-10-18 device report predates later `patches/mesa`; a fresh report from the host mock
  may differ.

**Missing graphics features on KosmicKrisp**, for linked issues (not filed here):

1. WoW's DXIL shader family (`dx_6_0`): not selected at shader model 6.6 under the profile; it
   needs SM ≥ 6.5 plus a cap still to be found (candidates above). Without it WoW runs the DXBC
   family, which renders the login screen. Impact on in-world rendering and speed unknown.
2. Ray tracing (DXR 1.1): WoW's optional ray-traced effects are off.
3. Variable rate shading (tier 2): off.
4. Barycentrics: off.
5. Mesh shaders: off.
6. 64-bit buffer/shared atomics: not needed by the DXBC family; would matter for item 1.
7. A tooling gap: the capture layer's profile does not AND Vulkan 1.2 features (64-bit
   atomics, FP16/int8), so it overstates KosmicKrisp there.

## `-d3d11`

Accepted (run `d3d11`, `-console -d3d11`):

```
Force API D3D11
Adapter 0: "AMD Radeon RX 9070 (RADV GFX1201)" 16GB … dx11:true dx12:false
Unable to load "d3d12.dll"
Disabled Settings: WORK_OPTIMS
GpuInfo: sm:dx_5_0, rt:None, vrs:0, bary:0, mesh:0 pull:1
Dx11 Device Create Successful (232.6 ms)
Using shader family dx_5_0
Detected Graphics Defaults: 5 (CPU = 7, GPU = 5, MEM = 7) WindowSize: 1920x1080
```

The login screen renders the same; the console's `gxApi` shows `D3D11`. Quit exits 0.
**The choice sticks:** the clean exit wrote `SET GxApi "D3D11"` (and `hwDetect "0"`) into
`Config.wtf`, so the next start without `-d3d11` is D3D11 again until the line is removed.
The same happens without asking: when `d3d12.dll` failed to load (the x86_64 build above,
`LoadLibrary(d3d12.dll) Failed (HR:0x000003E6)`), WoW fell back to D3D11, `dx12:false`, and
saved `GxApi "D3D11"`. (inference: a phone launch should pin `GxApi` in `Config.wtf`, or a
one-time D3D12 failure leaves the title on D3D11.)

## Gamepad mode

The console at the login screen: `GamePadEnable` is `"0"` ("Whether GamePad input should be
enabled"), `GamePadCursorAutoEnable` is `"1"`. `Wow.exe` also has `GamePadEmulateShift`,
`GamePadEmulateCtrl`, `GamePadEmulateAlt`, `GamePadEmulateTapWindowMs`. So the mode exists and
is off by default. Whether it covers login was not tested: no controller can reach the headless
sway, and the login screen needs typed email and password. (inference: with no on-screen
keyboard, a controller cannot complete login; character select is the step to try.) The owner's
run covers it.

## Warden before sign-in

Nothing observable. Before sign-in the client makes no Warden-related file (`Cache/` holds only
the empty ADB/WDB caches), `WowConnection.log` and `Connection.log` stay empty, and the
prefix's registry gains no service or driver (only the two Blizzard values above).
(inference: Warden's module is sent by the server after authentication, so what it checks, and
whether the Wine session is flagged or disconnected, can only be seen after signing in: the
owner's run below saw no disconnect in its short stay at character select.)

## Owner sign-in run

**Result (2026-10-30 15:24–15:27, run `owner-d3d12-152448`):** the owner signed in on the niri
display and reached character select on Direct3D 12. From the run's `Logs/` (no account,
character or realm data quoted):

- `gx.log`: `GpuInfo: sm:dx_6_0, rt:DXR 1.1, vrs:2, bary:1, mesh:1`, `D3d12 Device Create
  Successful (230.1 ms)`, `Using shader family dx_6_0` (RADV, as in the sway runs).
- The console's `gxApi`: `"D3D12"` (owner's check, and `General.log`).
- `Aurora.log`: `Logon complete.`, `Received AuthedToWoW result="ERROR_OK (0)"`, `Session with
  Battle.net established.`; `Connection.log`: `Handle Auth Response: 0`, `Glue Authed To WoW:
  0`, `Handle Char Enum` (the character list) twice, about 50 s at character select.
- No disconnect or error box before Quit: `Disconnect: 13` comes after `Glues Shutdown()`, i.e.
  from Quit; exit code 0. Warden: nothing visible in that time; a session in the world was not
  part of this ticket.
- Not tried: the gamepad (`GamePadEnable 1`) and `-d3d11` sign-in.

The procedure, kept for a rerun: the owner cannot reach the agent's sway session, so this run
shows WoW on the owner's niri display through niri's Xwayland (`xwayland-satellite`), with the
same prefix, DLLs, overrides and `Config.wtf` as the sway runs (by the owner's instruction;
HOST-DEBUGGING.md's sway-only rule stands for agent runs).

1. Check niri's X display: `ps -o args -C xwayland-satellite` names it (`:0` on 2026-10-30;
   niri's Wayland socket was `wayland-1`). If it differs, prefix the command with
   `OWNER_DISPLAY=:N`.
2. From the main checkout, in a terminal on the niri desktop:

   ```sh
   bash .work/worktrees/battlenet/.work/agent-notes/wow509/owner-niri.sh          # Direct3D 12
   bash .work/worktrees/battlenet/.work/agent-notes/wow509/owner-niri.sh d3d11    # optional, D3D11
   ```

   It runs, with `WAYLAND_DISPLAY` unset and `DISPLAY=:0`:
   `WINEPREFIX=<that dir>/prefix WINEDEBUG=-all
   WINEDLLOVERRIDES="d3d12,d3d12core,dxgi,d3d11,d3d10core=n;winemenubuilder.exe=d;winebrowser.exe=d"
   BROWSER=/bin/false MANGOHUD=0 VKD3D_DEBUG=info VKD3D_LOG_FILE=<run dir>/vkd3d.log
   VKD3D_SHADER_CACHE_PATH=<that dir>/vkd3d-cache wine ./Wow.exe -windowed -console` in the
   install's `_retail_`, after copying the agent runs' `Config.wtf` (region, locale, prompts
   answered, no `GxApi`). The window "World of Warcraft" opens at the login screen in 30–60 s.
3. Sign in with email and password (and the authenticator if asked). Leave **Remember Account
   unchecked** (otherwise `Config.wtf` stores the account name).
4. At character select, note: whether the realm and character list load; any disconnect or
   error box (its text and code, e.g. `WOW51900319`) and how long after sign-in; the renderer
   (press the grave key, type `gxApi`, Enter). Stay about 5 minutes at character select;
   entering the world is not part of this ticket.
5. Gamepad, with a controller connected: in the console type `GamePadEnable 1`, Enter, close the
   console, and note whether the controller moves the cursor or selects a character, and
   whether anything at the login screen reacted before sign-in.
6. Quit with the Quit button (a clean exit; the script then stops the prefix's wineserver and
   prints `gx.log`'s device lines). No Wine process is left.
7. Record, for this file: the date, the renderer and shader family lines, sign-in success, time
   at character select, disconnects or error codes, the gamepad result. **Do not record** the
   email, account name, BattleTag, character or realm names. After sign-in the install's
   `WTF/Account/<account>/` and `Cache/WDB` hold account data: never copy them into the
   repository; run `pp secrets` before quoting any log.

## Checks

- No Wine, sway or helper process of these runs is left (`wineserver -k` per prefix; the
  headless sway exits after each run).
- `./pp names` and `./pp secrets`: clean, after merging `dev/pla-516-battlenet`.
