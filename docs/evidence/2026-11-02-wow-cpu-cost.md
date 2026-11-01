# World of Warcraft's CPU cost and hitches on the phone, 2026-11-02

**Linear:** [PLA-610](https://linear.app/playportdev/issue/PLA-610) (parent PLA-516), PLA-515.
Branch `dev/pla-610-wow-perf`. Phone: iPhone18,4, iOS 27.2. Earlier record:
[2026-11-01-wow-x64-fex.md](2026-11-01-wow-x64-fex.md).

**Status:** with the patches below, WoW's x64 client reaches its first window at +21 s and its login screen within
45 s of Play (about 400 s before), signs in, and plays in the world at 55–60 FPS with a frame p99 of 45 ms and one
725 ms frame window at the world load (before: p99 176 ms and 16-frame windows of 6–18 s in the owner's plays).

## Before: the owner's plays on IPA `bfc99fa3…` (2026-11-01, 22:55–23:18)

The phone log of that session (pulled 23:18, kept in `$PLAYPORT_BUILD/hud-diag/`) showed, outside menu pauses:

- frame windows of 16 frames: median 16.7 ms a frame, p99 176 ms, worst 6–18 s; the hitch windows were bursts of
  FEX `NoExec` blocks on the client's on-demand code pages (41/s, 1.2/s outside hitches);
- CPU: in-process wineserver thread 56 % of a core, main thread 49 %, render thread 25 %, Mach exception thread 17 %;
- 9,000 Mach-emulated reads a second of noaccess-split pages on average (up to 50,000 in hitches): 90 % from ARM64EC
  ntdll's `memcpy` byte loop (`memcpy+0x190`, `ldrb w11,[x8],#1`), called by FEX's disk cache applying a cached
  block's relocations (`ApplyPackedCodeRelocations` → `ReadLiveGuestData`, under FEX's code lock);
- 1,000–2,000 KUSER_SHARED_DATA reads a second at 0x7ffe0000, 97 % of them kernel32's `GetTickCount`
  (`ldr w0,[x8]`), out of the read stubs' branch reach;
- 10–25 k wineserver requests a second: per event the client's Net_Queue threads create, three round trips
  (`create_event`, `get_inproc_sync_fd`, `close_handle`), ~6,400 events a second;
- self-modifying stores to R-X pages: each a guest access violation and a code invalidation of 60–190 µs, almost
  all in FEX's call-return stack reset (three Wine calls);
- the read stubs' 2,048-site table filled after 40 minutes because FEX frees and reuses its code buffers, and the
  JIT sites' emulated reads went from ~2,000 to ~17,700 a second;
- shader builds: 42 on the main thread in the owner's plays (15.4 s), 2.9 % of the hitch time; vkd3d-proton's and
  KosmicKrisp's caches keep every shader across plays (no rebuild of any of 138 hashes), so these are first-meeting
  costs only, not changed here.

## The patches

| patch | what |
|---|---|
| fex 0093 | a disk-cache hit reads its patchable fields (and the CRC relocation, and a full-SMC block's CRC) through `DiskCache::GuestCodeBytes`, the view's read-only alias |
| madeira-unix 0284 | read stubs: every 256th read of a pc retries; a freed FEX code buffer's sites are dropped and their stub slots reused (`[split-stub] code buffer … freed: N sites dropped`) |
| wine-pe 0063, madeira-unix 0285 | ntdll exports `ios_user_shared_data`, the loader writes the real mapping into it (`[kusd] … reads KUSER_SHARED_DATA at …`), kernel32/kernelbase read through it |
| fex 0094 | the call-return stack reset is one `MEM_DECOMMIT` on iOS (Wine's decommit there maps fresh read/write zero pages) |
| fex 0095, madeira-unix 0286 | the per-page `NoExec` lines and the declined-SEGV/`[fault-pc]` lines are sampled |
| wine-unix 0204, `build/ppsync` | `create_event` posts the new event's in-process sync with its access; `NtCreateEvent` caches it; ppsync's hand-off scans to a high-water mark |

## After: IPA `ebd36bc6f288d4bd06996e746c51abc1bc02a01311ea28fc70f9a95c638e4f31`

| run | what |
|---|---|
| 20261102T000258 / 000347 / 000416 | HK first frame +10.8 s, ran +10 (`[kusd] session ntdll reads KUSER_SHARED_DATA at 0x7038000000`; `[srv]` shows `create_event=9` with no `get_inproc_sync_fd`); exchook `done ok`; ymmctx noavx `done ok` |
| 20261102T001808 | WoW: login screen in the screenshot 45 s after Play |
| 20261102T002112 | WoW: first window +21.2 s; sign-in by the text bar; character select with the account's character; 15 min |
| 20261102T003731 | WoW: sign-in, Enter World, in the world (the client's movement-keybinding dialog up), 18 min |

| measure | before (owner plays) | after, character select (002112) | after, in the world (003731) |
|---|---|---|---|
| frame median / p90 / p99 | 16.7 / 25.7 / 176 ms | 16.7 / 21.6 / 28.2 ms | 16.7 / 23.9 / 45.3 ms |
| worst 16-frame window, per frame | 1,161 ms (18.6 s) | 530 ms | 725 ms (world load) |
| noaccess-split emulated reads | 4,800–9,300/s | 360/s | 840/s |
| KUSER_SHARED_DATA emulated reads | 1,200–1,900/s | 41/s | 61/s |
| wineserver requests | 10,000–25,000/s | ~10,000/s | ~9,100/s (no event churn in this scene) |
| CPU: main / wineserver / exception thread | 49 / 56 / 17 % | 33 / 29 / 10 % | 44 / 35 / 13 % |
| code invalidation per SMC access violation | 61–190 µs | 21 µs | 30 µs |

The run ended with no `[ppsync] hand-off missed` line.

**Left open:** the client's own stores into R-X pages (1,000–1,800 a second, each a guest access violation the client
handles, then an invalidation: 57 s of 1,077 in the world run) and its int3/illegal pairs (~550/s); each is one
exception by the client's design. Gameplay beyond the world's first scene (movement, combat, other zones) is not
measured: the keybinding dialog held the character in place.

Screenshots stay in the run directories. Neither secret is in any run directory; as in every run, `cmd/apps.out`
holds the signing identity.
