# Architecture

How the runtime fits into one iOS process, what the app adds around it, and
how the patch series are organised. The layout and the working rules are in
[AGENTS.md](../AGENTS.md).

## Pins

Playport pins one Madeira commit and carries its changes as ordered patch
files, never commits into a copy of Madeira's history
([decision 0001](decisions/0001-superproject-on-madeira.md)). DXMT and FEX
(with FEX's rpmalloc) are built from their own upstreams with Madeira's ports
rebased as `patches/*-port` series (decisions
[0007](decisions/0007-dxmt-on-upstream.md), [0008](decisions/0008-fex-on-upstream.md)).
`pins.lock`'s header says what each row means.

## One process on iOS

Everything runs inside the app's single Mach process. iOS allows no `fork`,
no `exec` of a second binary and no JIT without a debugger, so Madeira folds
Wine's multi-process design into threads:

| Piece | What it is | Where it comes from |
| --- | --- | --- |
| App shell | SwiftUI app: the product UI, host I/O and, in a dev build only, the UI driver and the scripted pad (`Dev/`) | `app/Sources/S1Probe`, `app/PlayportKit`, `app/HostIOKit` |
| `wine_host` | the small versioned C ABI between the app and the runtime: `wine_host_init`, `wine_host_session_start`, `wine_host_session_launch` / `_wait` / `_stop`; JIT pool acquisition; prefix registry seeding | `app/Sources/WineHost` |
| wineserver | a thread of the app, not a process (`libwineserver.a`, entry `wineserver_main`) | Madeira `build/wineserver` + wine `server/` |
| Wine unix side | `libntdll_unix.a` (loader, virtual memory and the JIT pool, signals, sync, the crypto unixlibs), `libwin32u_unix.a` (win32u with FreeType and a virtual monitor) | Madeira `build/ntdll-unix`, `build/win32u-unix`, WineHQ wine plus Madeira's fork (`patches/wine-port`) and Valve's Wine commits (`patches/wine-valve`) |
| Crypto statics | GnuTLS 3.8.9, Nettle/Hogweed 3.10.1, GMP 6.3.0, linked statically for bcrypt, secur32 and crypt32 | Madeira `build/gnutls-ios` tracked tarballs |
| Display driver | Winios (`Winios.m`), compiled into the app from staged source; `IOSDisplayShim` exports `macdrv_functions`, which DXMT's unix side finds with `dlsym` to get one `CAMetalLayer` per swap chain | Madeira `app/Madeira/Winios`, `IOSDisplayShim.{h,m}` |
| DXMT unix slice | winemetal's unix side and airconv (DXBC to Metal AIR), with the LLVM 15.0.7 libraries airconv needs (`libdxmt_combined.a`) | DXMT fork + Madeira `build/dxmt-ios` recipe |
| Wine PE side | the `arm64ec-windows` and `aarch64-windows` DLL sets, `nls/` data | WineHQ wine plus Madeira's fork (`patches/wine-port`) and Valve's Wine commits (`patches/wine-valve`) |
| FEX | `xtajit64.dll` (FEX's arm64ec PE, `libarm64ecfex.dll`): translates x86-64 guest code into the JIT pool | FEX-Emu/FEX plus Madeira's port |
| DXMT PE side | `d3d11.dll`, `dxgi.dll`, `winemetal.dll` (and `d3d10core.dll` in the arm64ec set) | DXMT fork |
| XInput | Wine's builtin `xinput*.dll`, reading Madeira's controller snapshot through win32u | Madeira `app/Madeira/Winios/WiniosGamepad.c`, Wine `dlls/xinput1_3` |

Each Windows "process" is a pseudo-process: a thread running `__wine_main`
with its own PEB and private ntdll copy. Two consequences follow and are
permanent properties of the design:

- **Guests are x86-64 only.** WoW64 needs allocations below 2 GB, and iOS
  reserves the low 4 GB as page zero, so no 32-bit guest can run.
- **A crashing child cannot be isolated.** A fault in any pseudo-process is a
  fault in the app. Orderly `TerminateProcess` of live children works and is
  tested; a crashing child is an app crash by construction.

`wine_host_init` sets the runtime's environment before the unix side starts
(`wine_host.c`). Three switches look optional and are not: without
`MADEIRA_USD_TIME=1` `GetTickCount` never advances, without
`MADEIRA_REAL_SUSPEND=1` `SuspendThread` does not suspend, and without
`MADEIRA_WIN32U=1` ntdll registers no win32u syscall table and every
NtUser/NtGdi call fails silently.

Madeira's own sources and logs use `mythic` and `ml###` markers; the build
keeps its Madeira checkout under `run/unix/mythic` for that reason.

### JIT activation

iOS 26 and later on this hardware grant executable memory only through a
debugger. The app asks for a region by executing `brk #0xf00d` with `x16=1`;
the attached debugger's script has debugserver allocate it RX, writes the
blessing marker `0x69` to byte 0 of every 16 KiB page, and returns the
address. The app maps an RW alias of the region and asks the debugger to
detach (`x16=0`).

Every app process needs its own activation (`JitProvider.swift`): the
blessing does not outlive the process. An app process plays one title
(see One session per process under Product UI), and its Play attaches the
helper. A process cannot
be its own debugger (debugserver suspends the whole task on every stop), so
something outside the app attaches: the app's own extension, on the phone
([decision 0011](decisions/0011-no-workstation-jit.md)). The debugger
dependency is accepted and disclosed.

### JIT methods

What attaches is the player's choice, Settings › Setup check › *JIT method*
(PlayportKit `JitMethod`, [decision 0051](decisions/0051-jit-from-another-app.md)),
in both variants. All three end in the same protocol, so
`wine_host_jit_pool_acquire` does not know which one served it.

| Method | What a Play does | Script |
| --- | --- | --- |
| Built-in (default) | starts the helper extension (below) | `playport-universal.js` |
| StikDebug | opens `stikdebug://enable-jit?bundle-id=…&pid=…&script-name=universal.js`; once the pool is blessed, waits up to 60 s for Playport to be in front before the runtime starts | StikDebug's `universal.js` |
| Another app | waits only: LiveContainer's *Launch with JIT*, SideStore, StikDebug by hand | `universal.js`, set in that app |

- A debugger already attached is used whatever the method (`jit: debugger
  already attached`): LiveContainer's *Launch with JIT* attaches before the
  app runs, and `universal.js` waits at its first `brk`.
- Inside LiveContainer (`LC_HOME_PATH` set), LiveContainer cannot start the
  extension: Built-in is not offered, a stored one reads as Another app, and
  `BuiltInJit` refuses to start the helper. StikDebug there needs
  LiveContainer's *Use LiveContainer's Bundle ID*.
- With StikDebug or another app, Playport's pairing and LocalDevVPN are not
  setup steps (PlayportKit `SetupChecklist`), and a Play waits for JIT
  without them. The restart after a game (`AppRestart`) still needs the
  pairing. Without it, or inside LiveContainer, Playport asks to be closed
  and launched again.

### Built-in JIT

The outside process is the app's own extension. `PlugIns/PlayportJIT.appex`
(`app/Sources/PlayportJIT`, declared in `app/xtool.yml` `extensions`) is a
second process in the same bundle. It embeds StikJIT, StikDebug's MPL-2.0
framework, unmodified (`build/stages/stikjit.sh`, [LICENSING.md](LICENSING.md#stikjit)),
and runs it with Playport's own universal-protocol script,
`app/PlayportJIT/playport-universal.js` (`StikJIT.Script.custom`);
StikJIT's bundled scripts are not staged.

```text
Playport (S1Probe or Playport)                 PlayportJIT.appex
  JitProvider.acquire (title thread)
    BuiltInJit: +[NSExtension extensionWithIdentifier:error:]
                -beginExtensionRequestWithInputItems:error:  -->  started; entry.c relaxes the
                  (input item: anonymous NSXPCListener endpoint)    XPC decoder's class check
                                                        <--  connects back (JITHost / JITHelping)
    enableJIT(pid, pairing file bytes)                  -->  StikJIT.enableJIT(targetPID:, .custom(js))
    wait for CS_DEBUGGED                                       tunnel 10.7.0.1 (LocalDevVPN), DDI
    wine_host_jit_pool_acquire: brk x16=1, x16=0  <-- debugserver -->  prepare region, bless, detach
    reply; -_kill: the helper                           <--  reply(nil or error)
```

- The extension point is borrowed (`com.apple.ar.viewer`) with a
  `FALSEPREDICATE` activation rule, so nothing but the app starts it. There is
  no public API for starting an arbitrary extension; the four NSExtension
  methods are private and looked up at run time. An iOS update can break
  either; that is accepted for a sideloaded app.
- The helper cannot read the app's Documents and a free team has no App
  Group, so the pairing file's bytes cross XPC and live in the helper's
  temporary directory for one call. The DDI cache is in the helper's own
  Library.
- On iOS 27, missing credentials open a root-owned setup sheet
  (`JitSetup.swift`, [decision 0033](decisions/0033-on-device-pairing.md)).
  `OnDevicePairing.swift` publishes idevice's pairable-host identity with
  Bonjour, shows a random code, and keeps the returned record in memory. Setup
  connects LocalDevVPN, prepares the helper with that in-memory record, and
  commits it to the Keychain only after readiness. A pending Play resumes after
  the sheet dismisses; Pair again leaves the old record in place until the new
  one is ready. File import remains an advanced fallback. While the code is
  shown, it also floats in a picture-in-picture window (`PairingCodeWindow.swift`,
  `UIBackgroundModes` audio) over Settings; Open Settings opens Settings' top
  level, the closest link iOS 27 allows (no link reaches Developer Mode).
- StikJIT's calls block; the helper runs them one at a time on one serial
  queue, and the app serialises its own calls (readiness check, reset, a
  title's enable). A title's enable cancels a readiness call in progress
  rather than wait behind it, and the launch cancels its enable, ending the
  helper, once it stops waiting for it.
- xtool packs the extension from a SwiftPM library product and links it with
  `-e _NSExtensionMain`. `PlayportJITEntry/entry.c` defines that symbol in
  the executable and hands on to Foundation's; `-ObjC` keeps the principal
  class, which nothing references by symbol.
- The extension has its own bundle ID (`dev.playport.app.PlayportJIT`)
  and so its own free-team App ID and profile, one of the ten App IDs a free
  team may register per week. It takes no device slot.

### JIT pool placement

FEX writes all translated code into one pool. The pool must lie in whole
16 KiB pages in `[4 GiB, 2^36)`: iOS maps nothing below 4 GiB, and StikJIT
blesses each page by sending its address as 9 hex digits
(`ScriptRunner.makeBlessCommands`), so a page at or above 2^36 would be
blessed at the wrong address. That also keeps it out of the guest's address
window `[0x7000000000, 0x8000000000)`, where pool code hangs its first call.
`selfcheck_pool_placement` (`app/Sources/WineHost/selfcheck.c`) holds these
rules; `wine_host_jit_pool_acquire` refuses a placement that breaks one, and
the start-up self-check below checks them again. The only low range that can
hold the pool is `[the executable's end, the thread stacks)`, and libmalloc
places its start-up heap somewhere in that range before any app code runs; in
about one launch in four no piece large enough was left.

`wine_host.c` therefore reserves the pool's address space at exec time: a
1440 MiB zero-fill array (`host_pool_reserve`) in the executable's
`__DATA,__bss`, which the kernel maps with the image, so nothing can be placed
inside it first. Untouched, it costs no memory footprint. It holds a pool of up
to 896 MiB plus 64 MiB of slack and starts where the executable ends, which the
slide moves (`0x103ea8000` to `0x10a3f8000` seen on the phone).
`wine_host_jit_pool_acquire` frees the pool's range at its start just before
debugserver allocates, and debugserver's first-fit allocation lands there.

The rest of the reservation is given back afterwards, except the **executable
window**, `[0x140000000, 0x15c000000)` (`selfcheck_exe_window_split`): an x86-64
executable that is not DYNAMIC_BASE must load at its ImageBase, the linker's
default `0x140000000`, and one with its relocations stripped cannot load anywhere
else (Jurassic World Evolution's 422 MiB `JWE.exe`). Without the hold that range
is taken before the runtime starts: libmalloc puts a 64 MiB `VM_RECLAIM` region
and about 110 MiB of read-only regions just above the reservation's end, and the
session root (`playport-session.exe`, linked at the default base) took
`0x140000000` itself. The reservation reaches past the window from the lowest
slide seen and ends at `0x1643f8000` from the highest, under the lowest main-thread
stack seen (`0x16d0c4000`). The host names the window in `WINE_IOS_EXE_WINDOW` and
logs `executable window: 0x140000000-0x15c000000 held …`; above a pool whose range
reaches it (896 MiB at a high slide) it logs `not held`. ntdll gives the window
only to `map_image_view`'s attempt at such an executable's preferred base
(`patches/madeira-unix` 0089; Madeira's `ios_exe_win_claim`, logged `ml977:
RELEASED`), and holds the image's interval again for its next launch in the session
(`ml988`); the session root and relocatable executables are placed by the scan. A
refused base of such an executable logs `[exe-base]` with what holds it.

#### Mode A: the old `0x119000000` floor

Until 2026-09-28 the pool also had to start at or above `0x119000000`, a rule
taken from the reference (Madeira `StikJITHelper.allocatePool`). It was found
on 2026-04-30 (Madeira `d032ac9`), when x86-64 code first ran there: with a
128 MiB pool at `0x114000000` to `0x117xxxxxx`, FEX's dispatcher "branches to
zero memory before the first compiled block runs" (mode A), and at
`0x119000000` or above it did not. The dispatcher is the pool's first tail
carve, its last 16 KiB page, and its only way to `CompileBlock` is a
literal-pool load, `ldr x4, <literal>; blr x4` (FEX `Dispatcher.cpp`, the
`NoBlock` path; the literals are `dc64` words at the end of the dispatcher,
written after the code that loads them). A literal that reads zero branches to
zero before any block exists. That is mode A: the literal's store never
reached the pool.

No fixup assumes a distance or an alignment. Every label the dispatcher binds
(`Emitter::Bind`) is pc-relative inside its own 16 KiB buffer, computed from
RX addresses at both ends and well within each instruction's reach (1 MiB for
`ldr` literal, `b.cond` and `adr`), so the same code is correct at any
address; host functions
are reached through the absolute `dc64` words, never a relative branch; and
the buffer is page-aligned wherever the pool is. A failed bind (FEX ignores
`Bind`'s result) leaves the `ldr`'s offset 0, which loads the `ldr` itself:
nonzero, so not mode A either.

What broke in April was the write path. The FEX PE, `xtajit64.dll`, is built
for Windows, where `__APPLE__` is not defined, so its emitter's `WritePtr` was
the identity: every instruction, literal and fixup was stored to the RX
address, faulted, and was replayed through the RW alias by ntdll's Mach store
emulator (`signal_arm64_ios.c`; "trap mode"). Some of those stores were lost.
Mode B, found the same day, is the same loss: seven `stp` of a
`SpillStaticRegs` site kept the page's stale words, which a scan in FEX's
`ThreadInit` still rewrites (`patches/fex-port` 0015, 0017, 0020). The fork's
`db4f32768` (2026-05-11, `patches/fex-port` 0020) records that the FEX PE's
stores to the RX address "are silently absorbed" (at each seven-store site
one never landed) and that writing through the RW alias instead always lands. Why the loss tracked the pool's address was never
isolated: a handful of launches in one day at one pool size. Since
2026-07-06 (fork `61f11e3cc`, turned on in `6084de076`) the PE's `Buffer`
writes through the RW alias itself (`WritePtr` is `RXAddr + WriteOffset`
under `FEX_IOS_HOST`, `WriteOffset` from `WINE_IOS_JIT_RW` and
`WINE_IOS_JIT_RX`), so emitted code no longer goes through the trap at all.

On the phone the floor guards nothing now
([evidence](evidence/2026-09-28-mode-a.md)): a pool at `0x106000000` with
its dispatcher at `0x11dffc000`, both inside April's failing range, and the
new default placement both play Hollow Knight to its first frame, and the `SpillStaticRegs` scan finds no broken site in either. What
could bring mode A back is the trap path, and the start-up self-check
asserts the property it lacked: a word written through the RW alias reads
back through the pool.

Blessing touches every page, so the whole pool is in the app's footprint from
then on, and every MiB of it is a MiB the game cannot have. Every Play therefore
gets 512 MiB, the least the games measured need, whatever the memory limit
(PlayportKit `JitPool`, [decision 0036](decisions/0036-one-512-mib-jit-pool.md),
which replaced 0019's eighth of the limit); the reservation still holds 896 MiB,
which a dev build's simulated pool may use (above 768 MiB at the cost of the
executable window at some slides). The limit itself comes from the
`com.apple.developer.kernel.increased-memory-limit` entitlement: 8 GB once Game
Mode is on. Of the build's signers only the patched xtool keeps it
([BUILDING.md, "Signing"](BUILDING.md#signing); other signers:
[DISTRIBUTION.md, section 6](DISTRIBUTION.md#6-signing-tools-and-the-memory-limit)).
The app reads its memory limit at start and at every Play (`MemoryLimit.swift`),
shows it and the pool it gives (*JIT memory*) in Settings › Setup check, and refuses a Play
whose title needs more (PlayportKit `MemoryNeed`) before the pool is acquired.

### JIT pool use

The pool never grows. PE images with native code (a full copy of each ARM64EC,
ARM64X or ARM64 image, x18 trampolines included), guest JIT blocks (Mono's, V8's) and each pseudo-process's private
ntdll copy take its **head**, from the bottom up; FEX's code buffers take its
**tail**, from the top down, up to 128 MiB each while the room between them
allows. A guest JIT region's writes are routed through the **anonymous-alias
table** (4096 entries). A dead process's code buffers are reused; of its head
ranges only guest JIT blocks are, since its image ranges have lost execute
permission by the time they are freed and are dropped. Nothing is returned.

A pure x86-64 image (AMD64, no CHPE metadata: a game's executable and DLLs)
gets no copy (`patches/madeira-unix` 0090, logged `[jit-pool] x64 image …: no
pool copy`): FEX translates its code at its PE addresses and never ran the
copy. Its EXEC stays logical, in Wine's page protection, and its host pages
are R or RW, as the copy path left them. Madeira had tried this twice and
reverted it (its ml457/ml458 notes); both trials predate the writable backing
of RWX sections (ml957), the likely cause, and the phone showed no regression
([evidence](evidence/2026-10-07-pool-x64-images.md)): Hollow Knight's head
fell from 138 to 83 MiB, Jurassic World Evolution's from 480 to 68.

- Madeira-unix 0034 counts them (`ios_jit_pool_stats`), and
  `wine_host_pool_stats_read` passes the counts to the app. While a title
  runs, `LaunchCoordinator` logs a `title: pool: size_mb=… head_mb=… tail_mb=…
  alias=… exhausted=…` line whenever the use moved, and marks one when the
  launch ends; `pp ui` puts the last one in its result event as `pool`.
  Hollow Knight reaches head 187 MiB, tail 145 MiB and 61 alias entries;
  The Witcher 3 head 206 MiB and tail 145 MiB
  ([jit-pool](evidence/2026-09-28-jit-pool.md)).
- **A child process** (madeira-unix 0039 made them start again after the
  wine-11.18 port) takes about 19.6 MiB of head, its ntdll copy (4 MiB) and
  its own copies of every image it loads, the parent's system DLLs included,
  and at least FEX's first 16 MiB code buffer. An 896 MiB pool holds 24 light
  children alive at once, and about 43 started one after another, since a
  dead child's images are not reused
  ([launcher-stress](evidence/2026-09-28-launcher-stress.md), measured with
  a test title since removed, [decision 0035](decisions/0035-no-dev-test-title.md)).
- **Running out** is an image, guest JIT block or ntdll copy with no room in
  the head (the load fails with `STATUS_NO_MEMORY`), a code buffer of 1 MiB
  or less refused by the tail (FEX then faults at `0xdead`), or a region with
  no alias-table slot. A launch that ran out ends as its own outcome,
  *ran out of JIT memory* (`pool=exhausted:<head|tail|alias>` in its result
  line), whatever the game's exit code. For a game still running 10 s later
  the launch ends without it (`still-running after_s=N`), and the restart
  that follows ends the game with the process
  ([decisions 0022](decisions/0022-stop-a-game-that-ran-the-pool-out.md),
  [0030](decisions/0030-one-title-per-process.md)); the new process says why
  in an alert. A dev build's Settings can set the
  pool (*Simulated JIT memory*, `set:jitPoolSimulatedMB=184`) to drive it.

### The FEX host band

FEX keeps its host state in one 16 GB range, `[0x7c00000000, 0x8000000000)`,
which ntdll reserves at start and serves only to FEX's requests (the
`[fex-arena]` lines). Every emulator thread takes about 50 MB of it: its
rpmalloc heap's two 16 MB spans (one for small blocks, one for medium),
a call-return stack of 16 MB and two guard pages, and a 2 MB L1 lookup cache.
The L2 cache and its table for the 8 GB `VirtualMemSize` are off on iOS, so
they take nothing. Call-return stacks are placed from the top of the band
down (`patches/fex` 0010), and rpmalloc's spans from the bottom up, so the
stacks leave no holes between 16 MB-aligned spans. Hollow Knight holds
3.3 GB with 50 threads, and 3.5 GB with DXVK's six compiler threads on the
Vulkan backend ([fex-band](evidence/2026-09-28-fex-band.md)).

- Madeira-unix 0038 counts the band's views (`ios_fex_band_stats`), and
  `wine_host_band_stats_read` passes the counts to the app. A launch logs a
  `title: band: size_mb=… used_mb=… largest_free_mb=… span_slots=… threads=…
  refused=…` line whenever the use moved by 256 MB or the thread count by 4,
  and marks one when the launch ends; `pp ui` and `pp perf` put the last one
  in the result event as `band`. `span_slots` is the free 16 MB-aligned
  blocks, what a new rpmalloc span needs; `refused` counts requests the band
  could not serve (a thread that cannot start). The first refusal, and a dev
  build at 16, 32, 48… threads and at the launch's end, write the band's map
  as `[band-map]` lines.
- FEX logs each thread's start and exit as `[band]` lines: what rpmalloc
  mapped for it, and what the live threads hold (`patches/fex` 0009,
  `patches/rpmalloc` 0001).
- rpmalloc names none of its mappings on iOS (`patches/rpmalloc` 0002): the
  name hook logged, the log allocated, and the nested allocation made a new
  heap or span before the first was recorded, 231 levels deep, which took
  3.7 GB of the band on Hollow Knight's second thread.

### Known runtime limits

Four limits of the runtime are known, and no title measured so far reaches
any of them ([runtime-limits](evidence/2026-09-28-runtime-limits.md)). So
each one fails loudly or is counted, rather than handled in full.
Madeira-unix 0035 counts them (`ios_runtime_limit_stats`, read through
`wine_host_limit_stats_read`), and a launch logs them as `title: limits:
wx_dropped=… x18_images=… x18_sites=… split_lock=…` lines, the same way as the
pool's use. `pp ui` and `pp perf` put the last line in the result event as
`limits`.

| Limit | What happens | Count |
| --- | --- | --- |
| A W+X request that `mprotect` grants with EXEC but without WRITE (`mprotect_exec`'s fast path) | The request fails with `EACCES`, and `NtProtectVirtualMemory` returns `STATUS_ACCESS_DENIED` (madeira-unix 0036). Before 0036 it returned success with WRITE gone (the `ml999` report). On a TXM phone `mprotect` never grants EXEC, so W+X goes to the JIT-pool path, which serves it through the pool's RW and RX aliases. | `wx_dropped` |
| x18 instructions in an image whose trampolines are out of B/BL reach (±124 MiB) of its `.text`, whose budget did not fit, or past the end of the trampoline space | Those instructions are not patched: one that runs after iOS has cleared x18 faults, and the Mach exception handler emulates it with the thread's TEB, one fault each time. The trampolines sit on the page after each image's copy, so only a `.text` larger than about 124 MiB could be out of reach. No trampoline islands are placed inside images. | `x18_images`, `x18_sites` |
| The anonymous-alias table's 4096 entries (guest JITs: Mono, V8) | A region with no slot ends the launch as *ran out of JIT memory* (`pool=exhausted:alias`, [JIT pool use](#jit-pool-use)). Hollow Knight peaks at 61 entries, so the table is neither grown nor turned into a map. | `alias_full` in `pool` |
| Misaligned exclusives (`LDXR`/`LDAXR` then `STXR`/`STLXR`) and `CAS` in native ARM64EC code | The Mach exception handler emulates each one on its single thread (ml431, `signal_arm64_ios.c`). That serializes them with each other, but not with plain stores from other threads, so a split lock can tear, as it can on AMD. | `split_lock` |

The x86 guest's own split locks are FEX's: a `LOCK` operation that crosses a
16-byte or cache-line boundary runs as two CAS loops that can tear.
`StrictInProcessSplitLocks`, which would take a global lock for them, is off
(FEX's default). FEX does not count them in a way the runtime can report.

### Start-up self-check

Every Play checks the assumptions the runtime makes about the phone and
refuses a launch that breaks one, instead of failing somewhere later
(`SelfCheck.swift`, `wine_host_selfcheck`, the rules in `selfcheck.c`). It
runs twice:

| When | What it checks | A failure |
| --- | --- | --- |
| before JIT is asked for | the host page is 16 KiB (StikJIT's page and the pool's granularity); a fresh pthread key's value is found in one of the first 512 raw TSD slots off `TPIDRRO_EL0`, where the translated code reads the TEB (ntdll's own probe, `loader_ios.c`, finds the TEB's slot the same way) | `launch=refused selfcheck=page` or `tsd`, nothing spent |
| once the pool is blessed, before `wine_host_init` | the pool's placement (JIT pool placement above); a word written through the RW alias reads back through RX | `launch=failed selfcheck=pool-…` or `alias` |

Each verdict is a `title: selfcheck:` line with the facts, such as
`ok page=16384 tsd=key 293 slot 293 pool=0x10609c000+896MiB rw=0x7000000000`,
and an alert says which assumption failed. `pp ui` and `pp perf` put
the last verdict in their result event (`selfcheck.report`), with the TEB's
slot from ntdll's `[teb-tsd]` line (`selfcheck.teb`).

## The app's host pieces

### Product UI

Every launch shows the product UI (`app/Sources/S1Probe/UI/`), the only way
into the app's functionality
([decision 0012](decisions/0012-the-ui-is-the-only-entry-point.md)),
landscape and driven by a controller
([decision 0034](decisions/0034-a-gamepad-first-ui.md)): Home, Library and
Downloads switched with LB and RB, Settings behind ≡ or the gear, one focus
ring and a footer naming each button (`UI/AppShell.swift`, `UI/Pad/`). Touch
works everywhere. The controller reaches the screens through `PadRouter`
(HostIOKit `PadNavigation` turns its snapshots into presses) until a game
starts, when HostIO takes it for the guest. At every start an opening
animation covers the shell (`UI/AppOpening.swift`, `UI/OpeningView.swift`):
placeholders where Home's cards will be fall into the app's porthole icon
(1.8 s, skipped after the restart after a game and with Reduce Motion), it
holds on the icon until each store has listed its games and Home's art has
loaded, 4 s from the start at most, then Home's cards fly out of it into
place. It names no store, takes no presses, and logs `opening:` with the time
it took. Text is typed on the
controller keyboard and choices made in pickers (`UI/Pad/PadModal.swift`,
the key layout and cursor in PlayportKit `PadKeyboard`), which take every
press while they are up; the system keyboard is not used. The current page and screen are
`AppNavigation`, a SwiftUI/focus adapter for PlayportKit `AppRoutes` (host-tested).
Each screen transition remembers its origin, section/panels and focused item;
Back closes local panels first, then restores that origin. A game opened from
Home returns to Home, and one opened from Settings › Storage returns to that
section and row, not Library. This history lasts for the UI process, not across
the restart after a game. A dev build's UI driver (`Dev/UIDriver.swift`,
`S1_MODE=ui`) uses the same model calls the buttons make; its `pad:` action
sends presses into the same router a controller feeds. A game's page
(`UI/GameDetailView.swift`) has Play or Install, the achievements and
Options on the ring, and its Game options panel over it (`AppNavigation.gamePanels`),
where Y puts a setting back to its default (`PadFocus.resetFocused`). Settings
(`UI/SettingsView.swift`) is a list of sections (PlayportKit `SettingsSection`) with the
shown one beside it; its Graphics values change with left and right, and its Downloads
switches are PlayportKit `DownloadPreferences`, which the download queue reads.
Downloads (`UI/DownloadsView.swift`) shows the queue `UI/SteamInstalls.swift` runs,
PlayportKit `DownloadQueue`: installs, updates (queued by themselves when Steam has a newer
build) and repairs, one at a time, in an order Y changes. The queue is written to the
container after every change; a launch holds every job, and the process after the
restart ([decision 0029](decisions/0029-restart-after-each-game.md)) lets go of every hold
but the player's Pause and runs it once Steam is signed in. A release build compiles none of `Dev/`
([decision 0009](decisions/0009-dev-and-release-builds.md)).

- **Catalogue** (`app/PlayportKit`, tested on Linux): rebuilt by *adoption*
  each time the app comes to the front, from the prefix's `C:\Games`. A folder
  with an install receipt is that Steam app and build, even if its name matches
  the bundled cohort list (`Titles/titles.json`). Without a receipt, a folder
  named as a cohort entry gets that pin ([decision 0005](decisions/0005-title-cohort.md));
  any other folder with a
  Windows executable is found, and reads *Ready* too (no compatibility labels,
  [decision 0034](decisions/0034-a-gamepad-first-ui.md)). A cohort entry also gives the launch
  arguments and `madeira.cfg` keys for the staged pin or a Steam receipt for that exact
  app and build, never a newer build sharing the folder; its screen no longer sets a launch's. A
  launch's screen, frame limit and Direct3D come from the game's own launch
  settings (its Game options), else the global Settings; with none, 720 rows
  at 60 FPS, on Vulkan for detected DX12 games and DXMT otherwise
  (`LaunchSettings.defaultScreen`, `defaultFrameLimit`, `GraphicsBackend.default`).
  Steam installs naming `REDprelauncher.exe` launch the game's nested executable
  instead; Unreal bootstraps also prefer the shipping EXE. This avoids unvalidated
  launcher install/UI chains and extra JIT cost, not an inability to start children:
  the session root and job support them (0030). GUI launcher support still needs
  GDI presentation/first-frame integration and validation of its dependencies
  ([launcher feasibility](evidence/2026-10-02-launcher-feasibility.md)).
  Adoption records best-effort Direct3D 8–12 evidence from the selected EXE's
  normal/delay library and API-function imports (including interposers), its
  reachable local DLLs and guarded dynamic-loading references. The bounded scan
  does not count unrelated shipped renderers or read launcher-specific metadata
  ([decision 0046](decisions/0046-static-direct3d-evidence.md)). Unknown is not
  DX11; multiple detected APIs do not identify the active renderer. Launch API
  flags take precedence over inference, and explicit graphics choices still win
  ([decision 0044](decisions/0044-vulkan-default-for-dx12.md)).
  Game options show the same inherited backend as Play. Native and no limit are a player's choice. FEX's memory
  ordering comes from a dev build's Game options over the game's profile (the
  release app runs the profile, and the Steam API emulator), Proton's FEX
  settings for its Steam app ID and executable (PlayportKit `FEXProfile`,
  [decision 0021](decisions/0021-fex-ordering-per-game.md)), as `FEX_*`
  environment variables, with the host CPU features FEX cannot read on iOS
  (`HostCPU.swift`) in `FEX_HOSTFEATURES`. Beside when a title was last
  played, the catalogue keeps its play time, the sum of its sessions
  (PlayportKit `PlayTime.swift`). A session is on disk while the game runs
  (`session.json`, beaten every 5 s by `UI/PlayClock.swift`): the game's end
  adds it before the restart after the game, and a session a process left
  (a crash, the app ended from outside) is added by the next process.
- **Launch** (`LaunchCoordinator.swift`): the Play button resolves the title
  and sets up host I/O, then acquires the JIT pool and runs `wine_host_init`,
  `wine_host_session_start`, `wine_host_session_launch` and
  `wine_host_session_wait`, once per app process. The scene turns landscape to
  `GameSurface`, covered by the launch's steps until the game's first frame.
  On Play the page's text and controls zoom, blur and fade (0.6 s) as the
  launch screen's fade in; the hero art does not change (it fills the screen,
  dimmed as the launch screen had it, behind both: the shell draws the page's,
  `PageArt`, and both use `GameHeroArt`). On the first frame the launch
  screen's text flies on the same way, the art fades, and the
  game fades in at its own size (`UI/LaunchTransition.swift`; fades only
  with Reduce Motion). The game presents under a black cover, never a
  transparent Metal layer.
  Each step is a `title: +<s> s` line in the log (and a `mark` event in a
  driven launch). How a launch ends is in "Restarting after a game" below.
- **Launch environment.** A Steam game (a title with a Steam app ID) runs
  with Steam's game id, `SteamAppId`, `SteamGameId` and `STEAM_COMPAT_APP_ID`
  set to its app ID as Steam sets them and Proton passes them to Wine
  (PlayportKit `SteamGameID`, [decision 0020](decisions/0020-steam-game-id.md)),
  so Valve's per-game fixes in `patches/wine-valve` apply. The backend's
  variables go over them, and the player's for the game over both; the launch
  logs Steam's with their values (`title: environment: Steam's …`) and only the
  names of the player's.
- **One session per process, one title as its root's child**
  ([decisions 0027](decisions/0027-titles-as-children-of-a-session-root.md),
  [0030](decisions/0030-one-title-per-process.md)).
  The runtime runs one Wine session per process: the wineserver thread and
  ntdll's unix side initialise once, so a second `wine_host_init` aborts the
  app (the wineserver's `init_registry`), and so does a second `__wine_main`
  (ntdll's `init_files`). A process therefore plays one title and then
  restarts ([decision 0029](decisions/0029-restart-after-each-game.md)). Its
  one `__wine_main` is the session root, `playport-session.exe`
  (`app/SessionRoot`, x86-64, kernel32 and user32 only). It brings up user32
  first, as explorer does, so the desktop window and the shared GDI handle
  table are its own and every PEB cloned from it has the table. It starts the
  title as its child in a job with the title's arguments, working directory
  and environment (Steam's game id, FEX's and the backend's variables over
  the root's), reports when the job is empty (a launcher that exits after
  starting the game has not ended the title), and then idles
  (`session_protocol.h`: request and reply files in
  `C:\users\playport\AppData\Local\Playport\session`, written only for a
  Play). Once the pool is blessed, a Play in the same process is refused
  (`launch=refused session=spent`), and after a restart that failed the
  game's page offers Close Playport. CS_DEBUGGED stays set after the detach,
  so `JitProvider` cannot tell a new attach from the old one: a pool is
  blessed once per process.

### Restarting after a game

[Decision 0029](decisions/0029-restart-after-each-game.md). When a launch ends
and the JIT pool was blessed in this process, `TitleLaunch` hands over to
`AppRestart` (`app/Sources/S1Probe/AppRestart.swift`):

1. The session root has already flushed the registry (`RegFlushKey` in
   `playport-session.c`, before it reports the title's end).
2. `Documents/restart.json` records the request: its time, the PID, and the
   `LaunchMessage` for an end that was not clean.
3. `app/Sources/Relaunch` (C, over idevice's FFI from `build/stages/idevice.sh`)
   opens RemotePairing's tunnel at `10.7.0.1:49152` with the RP pairing file,
   connects to CoreDevice's app service through RSD, and sends
   `launchapplication` for the app's bundle with `terminateExisting`. This is
   the chain StikJIT's JIT session uses, with a different last request.
4. `dtappserviced` ends the process and launches a new one, whether or not the
   sender is still connected
   ([evidence](evidence/2026-09-29-coredevice-relaunch-without-client.md)).
   The new process logs `restart: new process pid N, M ms after pid P asked`,
   shows the saved message once in an alert over the library, and deletes the
   record. A record older than a minute is dropped.

From the game's end until the phone replaces the process (about half a
second), the app shows black, with no text or spinner
([decision 0034](decisions/0034-a-gamepad-first-ui.md)); `AppRestart.restarting`
stays for the driver and the download queue.

A launch refused before the pool was blessed does not restart: its alert
shows over the page it was started from. The restart waits while the app is in
the background. If the request fails, the process stays, an alert says
why, and the process plays nothing more. In a dev build, a driven run hands
its variables and remaining actions to the new process (`Dev/DriverContinuation.swift`).

### HostIO

The host I/O layer turns iOS input and lifecycle events into what a Windows
game expects. Its decisions (key map, pointer mapping, pads, lifecycle order)
live in `app/HostIOKit` and are unit-tested on Linux; the C side is
`app/Sources/HostIO` (`host_io.h`); `app/Sources/S1Probe/HostIO.swift` wires
them to UIKit, GameController and AVFAudio.

- **Keyboard and pointer** go to Winios through its event ring:
  `winios_post_key`, `winios_post_client_pointer` (absolute 0..65535 across
  the foreground window's client area, `MOUSEEVENTF_*` flags) and
  `winios_post_focus`.
- **Controllers** go into Madeira's controller snapshot
  (`Sources/WinIOS/WiniosGamepad.c`, four slots under one lock), through the
  app's writers in `Sources/HostIO/hio_pads.c` (`host_pad_set`,
  `host_pad_disconnect`, `host_pads_release_all`), which the GameController
  handlers, the dev build's scripted pad and Winios's focus-loss drain call.
  `hio_pad_state` is the XInput gamepad value for value, and the snapshot
  numbers a packet only when a slot changes.
- **XInput DLLs** are Wine's builtins. Wine's `xinput1_*.dll` read HID devices
  that `winebus.sys` creates, which cannot run in this process; Madeira's Wine
  asks win32u first (`NtUserGetGamepadState`, `ios_gamepad_query` in
  `libwin32u_unix.a`, which reads the snapshot) and starts the HID discovery
  thread only when no slot is connected. `xinput1_3` and `xinput1_4` carry
  Microsoft's ordinals from Wine's specs, which games that import
  `XInputGetState` and `XInputSetState` by ordinal 2 and 3 need. Rumble is not
  implemented (the capabilities report none).
- **Lifecycle** (`HostIOKit/Lifecycle.swift`):
  - focus loss goes to Wine first, while held keys are still down, then every
    held key, mouse button and pad control is released, so a game never keeps
    a key down that the player let go of while the app was away (pad controls
    are released by Winios's drain once the loss has reached the game);
  - going to the background or an audio-session interruption stops the
    output unit, so the game's WASAPI clock stalls instead of running on
    unheard; leaving the foreground alone (Control Center, a notification)
    does not;
  - audio resumes only when the app is active, in the foreground and not
    interrupted, whichever clears last;
  - the background GPU gate closes first on `didEnterBackground` and opens on
    `willEnterForeground` (next section).
- **Audio host-suspend.** The host owns the iOS audio session.
  `ios_audio_host_suspend(1)` stops the runtime's single RemoteIO unit under
  its device lock, and `ios_audio_host_suspend(0)` restarts it only if a
  client still has it started
  ([madeira-unix 0012](../patches/madeira-unix/0012-audio-let-the-host-app-suspend-and-resume-the-proces.patch)).
- **Main thread.** Every host I/O entry point is a ring push, a few atomic
  stores or an audio unit start/stop, so the main thread may call it. Runtime
  work stays off the main thread (Apple's hang threshold is 250 ms).

HostIOKit's tests and the controller block's C test (`pp test`) check these
decisions without a phone.

### The in-game menu

Holding the controller's Home button half a second over a running game opens
Playport's menu (`UI/InGameMenuView.swift`, decision 0034). HostIO reads Home
on every pad (its system gesture is off while a game runs) and on the dev
build's scripted pad (`HOME`); `HostIOKit.QuickMenuControl` turns the
snapshots into the open, the menu's presses and the close. Behind the menu
the game is paused:

- **Input.** Every pad source reaches the guest's slots through one gate
  (`HostIOKit.GuestPadGate`, `HostIO.publish`): while the menu is up the slots
  rest, and after it a button still down from the menu (the A that chose
  Resume) stays up for the game until it is let go. Key and mouse-button
  downs, touches and mouse motion are dropped; a key let go still reaches it.
- **Audio.** `Lifecycle` holds the RemoteIO units while the menu is up, as it
  does for the background.
- **Threads.** The session root (`app/SessionRoot`) takes controls while the
  title runs, from `wine_host_session_control` through its session directory
  (`control`, answered in `control-reply`, `session_protocol.h`).
  `PP_CONTROL_PAUSE` calls `SuspendThread` on every thread of the job's
  processes, so the wineserver holds each one only at a safe point
  ([madeira-unix 0010](../patches/madeira-unix/0010-wineserver-hold-a-really-suspended-thread-only-at-a-.patch));
  a thread in a server wait is not woken, one in host code is held once it is
  back in guest code. `PP_CONTROL_RESUME` resumes them. The retries of a hold
  deferred for long back off
  ([madeira-unix 0048](../patches/madeira-unix/0048-wineserver-back-off-the-retry-of-a-hold-deferred-for.patch)).
  Nothing the host's main thread needs is held by a suspended thread, as no
  thread is held inside host code.

The rows: Resume (also B, ≡ and Home); Screenshot, the last presented
drawable's texture (`PacedMetalLayer.lastPresented`; DXMT's layer is not
framebuffer-only) to Photos (`NSPhotoLibraryAddUsageDescription`), and in a
dev build also to `Documents/Screenshots`; Performance overlay, the game
layer's `developerHUDProperties` switched now, for this game only (the
setting stays as Settings has it); the controller and its battery; Quit game.
Quit game resumes the threads and sends `PP_CONTROL_CLOSE`: the root posts
WM_CLOSE to the job's visible unowned top-level windows (all of them if none
is), as closing a window does on Windows, so the game saves and exits, and it
ends the job 10 s later if the game has not. The game's end restarts Playport
([Restarting after a game](#restarting-after-a-game)) and the new process
shows Home; a game still running 25 s after the request (the root itself
stuck) restarts Playport anyway. A quit game's exit code raises no alert.
The menu lies over the game surface, which ignores the safe area: its
content keeps clear of the Dynamic Island on either side through the
window's own insets (`WindowInsets`).

### Background GPU gate

iOS refuses GPU work from a background app. A Metal command buffer committed
after the `didEnterBackground` handler returns ends with
`kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted` and runs
none of its commands, and the game is not told: DXMT retires the chunk anyway,
so a readback of a copy made in that buffer returns success over memory the
copy never wrote.

[dxmt 0002](../patches/dxmt/0002-winemetal-hold-Metal-commits-while-the-app-is-in-the.patch)
puts a gate in DXMT's one unix-side commit function, exported as
`winemetal_host_gpu_gate(int open)`:

- `0`, called from `didEnterBackground` before anything else, closes the gate,
  then waits up to 100 ms for already committed buffers to be scheduled and
  returns how many were not;
- `1`, from `willEnterForeground`, opens it and returns 0;
- while the gate is closed, commits wait in the calling thread, so the game
  stalls instead of losing work.

Leaving the foreground alone does not close the gate: an inactive app that is
still on screen may use the GPU. The call costs a few milliseconds on the main
thread. `pp verify` requires the gate symbol in the executable.

### Winios hooks

`libwin32u_unix.a` calls the `winios_*` hooks from `load_display_driver()`.
They are defined by Madeira's app-side Winios driver, which Playport compiles
into the app from staged source (`Sources/WinIOS/Winios.m`, from the Madeira
pin with `patches/madeira-winios`: the host owns `winios_phase`, and posts
pointer and focus events; focus changes reach the window's owner thread).
`Sources/WinIOS/WiniosGamepad.c`, unmodified, defines the host-controller
snapshot `libwin32u_unix.a` reads for Wine's XInput; the app writes it through
`Sources/HostIO/hio_pads.c` (see HostIO above).

Two parts of Madeira's reference app are not used. `wineios.drv` has no build
recipe at the pin and is not in wine's configure; audio does not need it,
because mmdevapi loads `winepulse.drv` by name and the unix side answers with
the linked `audio_null_ios` table. The native D3D12 path is not built or
shipped: the one winemetal unix slot that would reach Apple's converter
(`madeira_ir_convert`) is a Playport stub that returns
`STATUS_NOT_IMPLEMENTED` (`app/Sources/WineHost/d3d12_converter_absent.c`;
[LICENSING.md](LICENSING.md)). Both appear as `gap` rows in
`app/artifacts.tsv`.

### Prefix registry seeding

A Wine prefix normally gets its COM registrations from `wineboot`, which runs
setupapi's `register_fake_dll` over every builtin. The app never runs
wineboot (one process, no services), and without the registrations
`CoCreateInstance(CLSID_MMDeviceEnumerator)` fails with `REGDB_E_CLASSNOTREG`.

`app/tools/prefix-registry.py` does the registration at build time: it reads
every `WINE_REGISTRY` resource (widl-generated ATL registrar scripts) in the
staged `arm64ec-windows` DLLs, interprets them with the rules of Wine's
registrar, and writes `app/registry/system.reg` and `user.reg` in
wineserver's file format. They ship as `Runtime/registry/`. On every launch,
`prefix_registry.c` appends each section the prefix's hives do not have yet,
before the wineserver loads them. A key they have is left alone, except the
user profile keys below, which the seed marks with a `;; playport:top-up` line:
for those it appends a section with the seed's values the key lacks. So a
fresh install, an existing prefix and an update that ships more DLLs all end up
registered, and no value the prefix holds is overwritten. The rest of
`wine.inf` (fonts, services, file associations) is not applied, except the
`http` and `https` handlers, which name Playport's URL opener (below). Regenerate the seed after any staged
`arm64ec-windows` DLL changes; the build's `stage` step fails until it matches.

The seed also carries the user profile wineboot would create: the
`ProfileList` values, the AppData `User Shell Folders` and the
`Volatile Environment` from which ntdll sets `%USERPROFILE%`, `%APPDATA%` and
`%LOCALAPPDATA%`. ntdll and shell32 create these keys empty, hence the marked
value top-up. The guest user is `playport`: `wine_host.c` sets `USER` to
it and, on every launch, creates `C:\users\playport\AppData\{Local,LocalLow,Roaming}`,
`C:\users\playport\Documents`, `C:\users\playport\Saved Games`,
`C:\users\Public` and `C:\ProgramData` if they are missing. shell32 fails a
known-folder lookup whose directory does not exist, so without them a Unity
title's persistent-data path (`LocalLow`) is empty and it cannot save, and
Witcher 3 finds no `Documents\The Witcher 3` for its settings and saves.

The seed also carries the Media Foundation transform registrations
(`MediaFoundation\Transforms`) that the staged decoder, converter and
resampler DLLs make in `DllRegisterServer` with `MFTRegister` rather than in
a registrar script: `MFTEnumEx`, and so a source reader, finds a decoder only
through them. `MFTS` in `prefix-registry.py` holds their tables as the wine pin
has them.

### A game's web pages

A game that opens an http or https page (`ShellExecute`, `start`, Unity's
`Application.OpenURL`; an Epic game's EOS sign-in opens
`https://www.epicgames.com/activate?userCode=…`) gets Playport's web panel over
the running game (decision [0064](decisions/0064-game-web-sheet.md)). shell32
reads `HKCR\https\shell\open\command`, which the seed (marked for top-up) sets to
`"C:\windows\system32\playport-url-opener.exe" "%1"`. The opener
(`app/UrlOpener/playport-url-opener.c`, freestanding x86-64, built by
`stages/session-root.sh`, P9-url-opener) hands the URL to the host through one
unix call table (`url_opener_protocol.h`, `url_opener.c`), which madeira-unix 0092
gives the module exported as `playport-url-opener.exe`, and exits. The app's
`UrlOpenerHost`, armed by the launch for its title, checks and rates it
(PlayportKit `UrlOpenRequest`, `UrlOpenRate`), logs `url: … open <host><path>
(<kind>) for <title>`, and hands it to `GameWebSheet` on the main actor: a
`WKWebView` with its own non-persistent data store, the game's input held
(`HostIO.holdGuest`) but its threads running. Epic's activate page on an Epic
game's play loads through Epic's `/id/exchange` with a fresh exchange code
first, with desktop Safari's user agent, so only the consent is left, and stays
on https `epicgames.com`; any
other page asks first. The runtime's process lines print the opener's URL with
its query masked (madeira-unix 0093). An i386 game's `system32` is `syswow64`,
where the opener is not staged yet.

### Trusted roots

A game's own TLS (the EOS SDK's libcurl, Unity's web stack) checks a server
against the Windows ROOT store. Wine fills that store from the host's roots
(crypt32's unix side, `enum_root_certs`), and iOS has no call that lists them,
so the runtime ships them: `Runtime/certs/cacert.pem`, Mozilla's root store as
published in curl's CA extract, a Playport input locked by date and sha256
(pins.lock `ca-bundle`, `build/stages/ca-bundle.sh`; refreshed by hand before
each release, BUILDING.md "The trusted roots"). `wine_host.c` names it in
`MADEIRA_CA_BUNDLE` and logs `trusted roots: PATH`; crypt32 logs
`load_root_certs: N root certs imported`. Each Wine process that opens the
ROOT store syncs the bundle into the prefix's
(`HKLM\Software\Microsoft\SystemCertificates\Root`), and Wine's own
bookkeeping (`HKLM\Software\Wine\HostImportedCertificates`) removes a root a
later bundle drops. Every Wine process of a session shares the one unix side,
so it walks the list for each, not once (`patches/madeira-unix` 0088): a
second process that found it consumed would delete every imported root.

### Media

Titles that play video (Hollow Knight's cinematics are H.264/AAC MP4 clips
inside Unity's `.resource` files, played through Media Foundation's source
reader) reach GStreamer through Wine's winegstreamer, as on Linux: the MP4
byte stream handler (`mfmp4srcsnk`, whose `winedmo` demuxer has no unix side
here) hands the stream to winegstreamer's media source, and the H.264 and AAC
decoder MFTs (`msmpeg2vdec`, `msauddecmft`) are winegstreamer's decoders.
winegstreamer's unix side is one prelinked object in the executable
(`build/stages/gstreamer.sh`): Wine's unix sources and the plugins it
registers after `gst_init` (`patches/wine-unix` 0005), taken from GStreamer's
own iOS release, with only the call table exported, so the libraries
GStreamer carries cannot collide with the app's. `load_builtin_unixlib` hands
that table to `winegstreamer.dll` (`patches/madeira-unix` 0031). GStreamer
loads nothing from disk: its registry is disabled. FFmpeg (`libav`) decodes
H.264 and AAC. VideoToolbox's decoders (the `applemedia` plugin) are
registered but ranked below it, because they hold frames back and stalled
winegstreamer's transforms.

### madeira.cfg switches

The runtime reads one `key = value` file, Madeira's `madeira_cfg.h` format,
from `$MADEIRA_DOCS_DIR`, else `$HOME/Documents`. Because `wine_host` sets
`HOME` to the prefix, the file is `Documents/prefix/Documents/madeira.cfg` in
the app container. Each process reads it once at start-up, so a change takes
effect at the next launch. Nothing writes the shared file: a title's keys
come from its cohort entry.

**Per-title keys.** A cohort entry's `config` (titles.json) gives keys for
that title's launches only. `LaunchCoordinator`
writes `Documents/prefix/Documents/title-cfg/<install folder>/madeira.cfg` as
the shared file followed by those keys (the reader keeps a key's last line)
and points `MADEIRA_DOCS_DIR` there before the runtime starts, so the shared
file is never edited (PlayportKit `TitleConfig`). The runtime's own
`MADEIRA_DOCS_DIR` outputs (`fex-jit-dump.bin`, `madeira-retire-trace.txt`)
land in that directory for such a launch. The first title in a process fixes
the guest's screen (`TitleScreen.configure`).

**`inproc-sync` is off by default**
([madeira-unix 0014](../patches/madeira-unix/0014-madsync-make-in-process-sync-opt-in.patch)).
With Madeira's in-process NT sync (madsync) on, a thread blocked in madsync
never makes the server wait that would run a system APC. iOS delivers no
`SIGUSR1`, so the asynchronous completion that copies a named-pipe read's data
never runs and the read returns 0 bytes. `inproc-sync = 1` turns it back on for experiments
(wine-unix 0006 fixed its crash at start on the wine-11.18 port). It stays off
([decision 0023](decisions/0023-in-process-sync-stays-off.md)): the server's
round trips are under 1 % of Hollow Knight's main thread, and The Witcher 3's
frame is GPU-bound. `pp perf`'s `server.txt` has the requests per frame.

### Guest network tables

There is no `nsiproxy.sys` device in the one-process runtime. `nsi.dll` falls
back to the in-process unix table for enumeration and keyed reads (wine-pe
0030, madeira-unix 0095). Wine's NDIS/IP providers read interface/link metadata
and IPv4/IPv6 addresses with `getifaddrs` and ioctls; wine-unix 0019 reads both
families' routes through a bounded Darwin routing-message decoder. LUIDs use
Wine's interface-index convention, and i386 calls translate owner-local guest
pointers. TCP connections retain wineserver's socket ownership. Connectivity
comes from these tables, not wine-pe 0029's former unconditional LAN fallback.
Change notifications and unavailable kernel statistics remain unsupported.
[Checks and limits](evidence/2026-10-07-nsi-adapters.md).

### Native Steam client

`app/SteamClient` is a host-side Swift Steam client (CM over WebSocket, QR
and credential login, PICS, depot manifests and CDN chunks, a journalled whole-title installer). The app
links `SteamClientKit` and calls it directly; secrets live in the Keychain
only. Host Steam secrets never enter the guest
([decision 0004](decisions/0004-steam-session-boundary.md)).

- **One service.** `SteamService` (`Sources/SteamClientKit/Service/`) owns
  the session: pairing, silent restore, token renewal (daily), the owned-games
  list, PICS metadata and sign-out; the UI is its only caller.
- **Sign-in** is one screen with two ways (`UI/SignInView.swift`,
  SignIn.dc.html). *On this phone*: the account name and then the password on
  the controller keyboard; `BeginAuthSessionViaCredentials` takes the password
  encrypted with the account's RSA key (`GetPasswordRSAPublicKey`,
  `Crypto/RSA.swift`), then Steam wants an approval in the Steam Mobile app
  (`PollAuthSessionStatus`) or a Steam Guard code
  (`UpdateAuthSessionWithSteamGuardCode`). The password is held only for that
  one call and never stored, shown or logged; the keyboard draws it as dots.
  Leaving for the Steam app to approve keeps the attempt: the poll reconnects
  and picks the same session up. *Another device*: a QR code that a device
  signed in to the Steam app scans and approves; switching to Steam on the
  same phone suspends that poll and Steam expires the attempt, so leaving the
  foreground cancels it. Both store the refresh token the same way, in the
  Keychain.
- **Files.** Non-secret only: `Library/Application Support/Playport/steam/`
  and the art cache in `Library/Caches/Playport/art/`. Sign-out revokes the
  token and deletes both; installed games and saves are untouched.
- **Launch.** `suspendForLaunch()` refuses further Steam work in the process
  before the runtime starts and closes the session, unless the game's tickets
  are armed: then the CM stays logged on for them alone
  ([0062](decisions/0062-steam-live-session.md)).
- **For games** ([plan](plans/finished.md#steam-for-games)): at each launch
  `SteamAPISwap` puts gbe_fork's `steam_api(64).dll` (`Runtime/steamapi/`) in
  the game's folder and `SteamStub` takes SteamStub 3.1 x64 off its
  executable, each keeping the game's file as `.orig`. Achievements, stats and
  Steam Cloud saves sync only while the session is up, never during a play.
  A game whose saves changed on the phone and on Steam asks once at Play
  which side to keep, for all its files in one `syncCloud(resolve:)` call;
  until then it does not start. The side not kept stays in
  `Documents/Cloud Backups/` for 30 days (`Cloud.Backups`). The game's
  encrypted app ticket, fetched after Play before the suspension, is the one
  host secret a Steam game gets: a `ticket=` line in the emulator's
  `configs.user.ini` while it runs, removed at exit, the next launch, app start
  and sign-out ([0017](decisions/0017-encrypted-app-ticket.md)). Its auth
  session and web API tickets come from the host during the play
  ([0062](decisions/0062-steam-live-session.md)): at Play `prepareTicketSession`
  fetches the app's ownership ticket, checks Steam's game connect tokens and puts
  the session in the game; the emulator (gbe 0006) asks through the unix call
  table `playport_steam_unix_call_funcs` (`WineHost/steam_ticket.c`, given to a
  `steam_api` module by madeira-unix 0087, x86-64 and WoW64), and
  `SteamTicketBroker` builds each ticket, reports it in `ClientAuthList`, and
  ends them all at `endPlay` before the restart. A dropped CM is reconnected
  for it at most once a minute. Only ticket bytes, a handle and a state cross.
- **An Epic game** starts signed in, as Epic's launcher starts it
  ([0059](decisions/0059-epic-exchange-code.md)): after Play the host fetches a
  five-minute exchange code and, when the catalogue asks, a five-minute ownership
  token; the code goes on the command line (`-AUTH_PASSWORD=`, with
  `-epicusername`, `-epicuserid`, `-epicsandboxid`), the token into
  `playport-epic.ovt` in the game's folder (`-epicovt`), removed at exit, the next
  launch, app start and sign-out. Without them the page offers Try again, and Play
  offline for a game that allows it.
- **A GOG game** whose build names a Galaxy client gets the local Galaxy service
  while it runs ([0063](decisions/0063-gog-galaxy-sign-in.md)): `GalaxyListener`
  (GOGClientKit) listens on `127.0.0.1:9977` from Play to the launch's end while GOG
  is signed in, and `GalaxyService` answers the SDK's frames: its auth request, bound
  to the client ID and secret kept in the install record, gets a refresh token minted
  for that client; achievements, stats, leaderboards and play time go to
  `gameplay.gog.com` with the game's access token, which stays on the host. The log's
  `galaxy:` lines name each request and its status.

## Patch series

Every patch is a `git format-patch` file listed in its target's `series`, with
the trailers `Class:`, `Evidence:` and `Offered-upstream:`. The classes are:

- `upstream-bug`: a defect in the upstream code that Playport's tests found;
- `build-fix`: the pinned upstream does not build from a clean checkout;
- `linux-build`: needed only because Playport builds on Linux with no Apple tools;
- `host-app`: an interface Playport's host app needs;
- `diagnostics`: logging that measures what a component does, with no
  change to what it does;
- `ios-port`: Playport's own port to iOS of a component whose upstream runs
  only on macOS (so far `patches/mesa`, KosmicKrisp);
- `feature`: a capability the upstream lacks and Playport needs, such as
  KosmicKrisp's geometry shaders, which DXVK requires;
- `madeira-port`: in `patches/wine-port`, `patches/dxmt-port`, `patches/fex-port`
  and `patches/rpmalloc-port`, one of Madeira's commits rebased onto the
  component's upstream (trailers `Madeira-commit:` for the original and
  `Rebased: clean` or `Rebased: resolved`), or the rebase's own follow-up; and
  at the end of `patches/madeira-unix`, Madeira's own `*_ios.c` replacements
  ported onto the `wine-port` base.
- `valve`: in `patches/wine-valve` only, one of Valve's commits from
  ValveSoftware/wine's bleeding-edge branch (decision
  [0049](decisions/0049-latest-pins.md); `proton_11.0` before it) picked onto the
  `wine` pin with `patches/wine-port` applied (trailers `Valve-commit:` for
  the original and `Picked: clean` or `Picked: resolved`). The pins.lock
  `wine-valve` row is the Valve commit the series was picked from.
  Which of Valve's commits are taken, and why the others are not, is in
  decision [0018](decisions/0018-valve-wine-as-a-series.md) and its evidence
  record. The Wine trees apply `wine-port`, then `wine-valve`, then
  `wine-unix` or `wine-pe`.

To make one, commit the change in the build's tree for its target (the pin
plus the series as commits, under `.work/run/`) and write it out as the next
file of the series, then add its name to `series` and its trailers:

```sh
git -C TREE -c core.abbrev=7 format-patch -1 --zero-commit --no-signature \
    --start-number N -o patches/TARGET HEAD
```

Write the patch before the next `pp build`: a tree that is not its pin plus
its series is checked out again from the pin, which drops uncommitted edits
(commits stay in the tree's reflog). Each patch's subject, message and
trailers say what it changes and why, and its `Evidence:` trailer names the
record that proved it. Where each series is
applied is in [BUILDING.md](BUILDING.md#the-pipeline). No patch has
been offered upstream yet ([LICENSING.md](LICENSING.md#other-projects)).
