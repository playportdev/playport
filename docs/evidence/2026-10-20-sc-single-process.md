**Linear:** PLA-364

# 2026-10-20: Single-process Social Club (madeira-unix 0190, decision 0150): host proof and the phone A/B to run

**Decision:** [0150](../decisions/0150-dev-single-process-social-club.md). **Patch:**
`patches/madeira-unix/0190-ntdll-dev-single-process-social-club.patch`, a port of willfaust/Madeira's
`61dce1d` (originally `0f40502`/`fcfb69a`) and `293cd39`. Built and tested in the side worktree
`scsingle` (decision 0117). No phone run and no desktop run: this records what the host shows and
the phone A/B the main checkout runs next.

## Build

| IPA sha256 | What | Hollow Knight first frame +10 | RDR2 |
| --- | --- | --- | --- |
| `5f76616797c866e2cab5bf6d3070e74911087cf6ced0f20da30b88dc4750f61f` | dev, main `22d8be9` + madeira-unix 0190 and the host gate | not run (side worktree) | not run |

`pp build` in the worktree: `verify-ipa: 88 checks passed, 0 failed`. The built `libntdll_unix.a`
holds the seven `[sc-single]` log strings. Of the build records, only the `lib/libntdll_unix.a` row is
committed. It names no build path; the main checkout's build confirms it. The `libdxmt_combined.a`
and `libidevice_ffi.a` rows are from trees the copy rebuilt clean, so they keep main's values. The
Wine PE records did not change.

## Host checks

- **`pp test`** (full, with Swift, as `app/Package.swift` changed) passed. It includes:
  - the C tests "Social Club single-process dev gate" and "release gate" (`app/tests/sc_single_test.c`):
    only exactly `1` enables it, and a `PLAYPORT_RELEASE` build never does;
  - `tools/tests/test_sc_single.py`, which runs eight scripts in `tools/tests/sc_single/`.
    - They read the new files from the patch itself, not from a build tree.
    - They execute the shipped x64 thunks against synthetic Win64 ABIs, from Madeira's six sc-rph host
      tests and their `.S` fixtures: render handler, render loop, RunState, IPC rebind, IPC split and
      UI close.
    - They also check the browser command line (`sc_browser_cmdline`) and the preflight.
- **The real helper, read and never run.** A host build of the patch's own `pp_sc_single.h` (byte for
  byte the patch's) ran `pp_sc_single_preflight` on the installed helper in the side worktree's
  prefix copy (TimeDateStamp `0x6a86d563`, SizeOfImage `0x244000`). It printed `[sc-single]
  preflight: exact helper build and all SHA-256 ranges accepted`, so all 48 ranges, the sections,
  the vtables and the zero tails matched.
  - In a copy with one bit flipped in a checked range (`RendererApp::RendererApp`, RVA `0x69a0`), it
    printed `preflight: code bytes differ; multi-process fallback`.
  - A bit flipped at RVA `0x173b90`, which no range covers, still passed. That is expected: the guard
    hashes only the code the thunks depend on, as upstream does.

## Desktop proof: skipped

Madeira-unix 0190 lives only in Playport's iOS ntdll. Desktop Proton cannot apply the page-bridge
thunks, so a desktop `--single-process` run would only repeat the recon's known
`SC_INIT_ERR_WEBSITE_FAILED_LOAD` ([recon R1](2026-10-15-rockstar-launcher-recon.md#4-r1-switches)).
Applying them there would need a new WriteProcessMemory injector. The supervisor ruled that out on
2026-10-20 (option C): the phone A/B is the test. So the recon's desktop figures remain the only
desktop numbers:

- multi-process: 9 processes, 4,392 MiB, 326 threads;
- `--single-process` without the bridge: 1 process, 1,110 MiB, 171 threads.

## The phone A/B (main checkout)

1. **Build and install.** Rebase `scsingle` onto `main` in the main checkout, `./pp build`
   (this confirms the committed `libntdll_unix.a` row), then `./pp install --no-build`.
2. **The Hollow Knight gate:** `./pp ui --play app-367520 --until first-frame+10 --shot`.
3. **Two RDR2 arms, one change between them.** Use the same pad script, `--until`, aspect and
   `set:donorPoolMB=auto` as the latest RDR2 runs (f3).
   - In **both** arms, turn off decisions 0133 and 0138:
     `--action set:endGameSocialClubAfterSignIn=false --action set:refuseGameSocialClubRestart=false`.
     0141 has no switch of its own and is inactive with 0133 off.
   - The two arms differ in the title's Runtime keys only. `--settings 'app-1174180:{"runtime":"…"}'`
     replaces the saved keys, so start from the saved keys:
     - **off:** the saved keys;
     - **on:** the saved keys plus `env.PLAYPORT_SC_SINGLE=1`.
   - The key is exported for the whole Play, so the launcher's helper and the game's helper both get
     it. `pp ui` ends the app before each run, so the off arm starts without the variable.
4. **What to read in `s1-host.log`.** Counts are per arm.

   | Line | Off arm | On arm |
   | --- | --- | --- |
   | `config: environment PLAYPORT_SC_SINGLE=1` | absent | present |
   | `[sc-single] preflight: exact helper build and all SHA-256 ranges accepted` | 0 | one per helper browser start |
   | `[sc-single] verified browser:` | 0 | one per helper browser start |
   | `[sc-rph] SocialClubHelper.exe at` (the thunks were written) | 0 | equal to `verified browser`; fewer means a browser ran single-process without its bridge (report it) |
   | `[sc-single] refusing verified helper --type= child` | 0 | the children Chromium tried (expected) |
   | `[sc-single] race:` | 0 | 0 (count separately if not) |
   | `preflight: …; multi-process fallback` and `cannot read helper` | 0 | 0 (anything else means another build or file) |
   | `[chromium] browser` and `[chromium] child --type=` for `SocialClubHelper.exe` | today's tree | none for the helper |
   | `[sc-runst]` (a fault in the helper's loop) | 0 | 0; quote the lines if present |

   - **Also compare:**
     - the number of live `SocialClubHelper.exe` processes, and their threads and `[proc-mem]`
       (image, private, fex);
     - the app's peak footprint, and whether and when a memory end or jetsam came;
     - the game's sign-in line that 0133/0141 watch, and whether the game shows signed in;
     - whether the Rockstar launcher's page loads.
   - Check `SC_INIT_ERR` in the game's and the launcher's Social Club logs in the prefix. Quote only
     the fixed tokens: these logs name the account.

## Not verified

- No Social Club page has loaded in single-process mode with this patch, on the phone or the
  desktop. Nothing here shows a sign-in kept or memory saved. The host fixtures run the thunks
  against synthetic ABIs, not a real CEF.
- The `pp_sc_single_mapping` flag is set on the child thread that maps the helper's main image. If
  the phone mapped it on another thread, the browser would run single-process without the bridge:
  the `[sc-rph]` count against the `verified browser` count in step 4 shows it.
- The release variant was not built. Only the C test shows the gate compiled out under
  `PLAYPORT_RELEASE`.

## Left out of the port, and why

- **Madeira's game-side libcef refusal** (`ios_sc_cef_refuse`) and **its PartitionAlloc pool
  layout** (`MADEIRA_SC_PA_POOLS`): outside 0150's scope. 0110's own CEF build stays in place.
- **Madeira's knobs** (`MADEIRA_SC_CEF`, `MADEIRA_JITLESS`, `MADEIRA_SC_CEF_FLAGS`,
  `MADEIRA_SC_RENDER_HANDLER`, `MADEIRA_SC_IPC_SPLIT`): one key, `PLAYPORT_SC_SINGLE`, turns on the
  whole set or none. That way no partial mode can run single-process without the bridge. The
  extra-flags argument is always empty.
- **Upstream's mismatch behaviour.** Upstream kept `--single-process` when its guard failed. Here a
  mismatch before the policy change keeps the multi-process policy, and a change between the
  preflight and the mapping refuses that load.
- Nothing was left out for touching a protection, licence, privilege or authentication check: the
  ported code changes only CefApp, MessageLoop and IPC wiring, plus bounded tracing.
