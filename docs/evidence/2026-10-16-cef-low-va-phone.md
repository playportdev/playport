# Our low-address-space CEF on the phone: the Rockstar Games Launcher's Open (PLA-370 stage D)

**Linear:** [PLA-370](https://linear.app/playportdev/issue/PLA-370). Plan:
[CEF low-VA build](../plans/finished.md#own-low-address-space-cef), stage D. Decision
[0110](../decisions/0110-own-cef-build-for-a-clients-cef.md).

- **IPA:** dev, sha256 `2eefce7e28ef00777f9aa8049436afd61243feedbc0f40775d2a64c5046c07bb`, built from
  `1c7fa4d` (branch `dev/pla-291-rockstar-launcher`). It carries the verified CEF 143.0.14 payload under
  `cef/143.0.14/` and patches/wine-unix 0039, which opens it in place of Social Club's files.
- **Phone:** iPhone18,4, iOS 27.0.1; 73 % and charging, 3.8 GB free before the Open. The owner was
  attended.
- [M] measured in these runs, [I] inferred from them.

## Summary

- **The substitution works [M].** In the Social Club directory the guard read `libcef.dll`'s version
  resource as 143.0.14.0, and every CEF file the helpers opened came from Playport's build. Rockstar's
  files were not changed.
- **The helpers get past `chrome_elf.dll` [M].** The earlier phone runs' crash at helper start-up
  (`0x80000003` in `chrome_elf.dll`, PLA-369) did not occur: the browser process started, connected
  to Social Club in 0.9 s, and Social Club's UI moved to `LOADING` and `WAITING_FOR_PAGE_LOAD`.
- **The sign-in page was not reached [M].** About 4.7 s later, the browser and its network and storage
  service processes ended with a stack overflow (`0xC00000FD`). The two services, and later a second
  browser, each hit an access violation in Wine's `secur32.dll` and rethrew it about 1,330 times. The
  first browser's main thread overflowed its stack in ntdll. Social Club went to `FAILED`, and the launcher showed
  `SC_INIT_ERR_WEBSITE_FAILED_LOAD` and shut down.
- **The next blocker is Wine's `secur32`, not CEF's address space [I].** Every process that loads
  `secur32` fails to reach the LSA pipe `\pipe\lrpc\lsasspirpc`. The pipe is absent, and
  `load_auth_packages` logs `80090304` (`SEC_E_INTERNAL_ERROR`). The launcher survives that failure.
  Three of the CEF processes then dereference a null pointer inside `secur32`, and the exception
  never resolves. No band or pool exhaustion was involved: `refused=0` and `exhausted=none`.
  Later: the null read was a full FEX alias table, not `secur32`; see
  [the alias table on the phone](2026-10-16-alias-table-cap-phone.md) (PLA-373).
- **Delivery size [M].** The compressed dev IPA grows by 150,977,731 B: 558,603,570 B against the
  previous 407,625,839 B (`bf9175bf…`). Uncompressed, it is 2,309.1 MB.
- **Hollow Knight still works [M].** First frame at +10.60 s, with the screenshot showing the title menu.

## Runs

All runs used IPA `2eefce7e…`. The run directories are under the build area's `ui-runs/`.

| Run | What | Result |
| --- | --- | --- |
| `20261016T190538` | `pp install --no-build`, then `--play app-367520 --until first-frame+10 --shot` (one lock session) | JIT 2.33 s, runtime +3.37 s, first frame +10.60 s; the screenshot shows Hollow Knight's title menu |
| `20261016T190811` | `--settings 'launcher-rockstar:{"runtime":"env.FEX_SMCCHECKS=none"}'` | Saved |
| `20261016T190852` | `--action open-launcher:rockstar --until "mark:first window+240" --wait 600`, screenshots at 60, 150 and 230 s and at stop | Reached the until mark; the app did not crash; details below |
| `20261016T191348` | `--settings "launcher-rockstar:{}"` | Key cleared |

Runs 2 to 4 were one `pp phone lock` session. Decision 0109's Chromium switches were not saved as a
setting: madeira-unix 0152 adds them when the browser process is created, and the log shows them
(`[chromium] browser … added --in-process-gpu --disable-gpu --disable-gpu-compositing
--js-flags=--jitless`).

## The substitution [M]

The run logged 15 `[cef-swap]` lines (container paths shortened):

- `…/c:/windows/system32: libcef.dll has no readable version resource; left alone`. This was a
  probe of Wine's own `vulkan-1.dll`. That directory has no `libcef.dll`, so it was left alone, as
  designed.
- `…/c:/Program Files/Rockstar Games/Social Club: libcef.dll file version 143.0.14.0 matches; its CEF
  files come from Playport's build`.
- Then one line per file, at its first open: `resources.pak`, `chrome_100_percent.pak`,
  `chrome_200_percent.pak`, `chrome_elf.dll`, `icudtl.dat`, `libcef.dll`, `libEGL.dll`,
  `libGLESv2.dll`, `v8_context_snapshot.bin`, `vk_swiftshader.dll`, `vk_swiftshader_icd.json`,
  `vulkan-1.dll` and `locales/en-US.pak`. Each line reads "opened from Playport's build".

Social Club's own dependency check then read the substituted `libcef.dll` as
"Chromium Embedded Framework … 143.0.14.0", and its CEF directory validation passed.

CEF looks for a locale by checking that the path exists (`PathExists`), not by listing `locales/`.
The run opened only `en-US.pak`. No directory-listing redirection was needed.

## Social Club and the launcher [M]

Social Club's log counts milliseconds from its own start, which was 19:09:42, about 36 s after the
app launched.

| ms | State or event |
| --- | --- |
| 219 | SDK fully initialized |
| 226 | `WAIT_BROWSER_WINDOW` |
| 858–876 | IPC channel connected; "Browser subprocess running and connected" |
| 3,600 | `LOADING`, the launcher URL |
| 3,620 | `WAITING_FOR_PAGE_LOAD` |
| 8,290 | `OnChannelError`; "Main browser connection lost!" |
| 8,392 | `FAILED` |
| 24,546 | Shutting down |

The launcher's log then records `SC_INIT_ERR_WEBSITE_FAILED_LOAD` ("timed out loading both its online
and offline content"), shows its error dialog, and shuts down 15 s later ("Timed out waiting for
browser"). The launcher's own first window came at +30.86 s.

**Screenshots** (in the run directory, not published):
- 60 s: the launcher's error dialog, a dark panel with a close button and two button shapes. It has
  no text: Wine's d2d logs `DrawTextLayout` failures (`0x80004005`).
- 150 s, 230 s and stop: black, because the launcher had closed its window.

## The process tree [M]

The tree, by `NtCreateUserProcess`:
- `services.exe`;
- `Launcher.exe` with its crash handler, `LauncherPatcher.exe` (exit 0), a second `Launcher.exe`
  and its crash handler, `RockstarService.exe` (twice) and `dxdiag.exe`;
- the Social Club browser `SocialClubHelper.exe`, which started two utility children: the network
  service and the storage service;
- after the browser ended, the launcher started a second browser, which also failed.

| Process (thread in the log) | libcef base | End |
| --- | --- | --- |
| Browser 1 (`021c`) | `0x73dd2c0000` | `0xC00000FD` at ntdll on its main thread; no `secur32` loop logged on that thread |
| Network service (`02ac`) | `0x73c7fd0000` | `secur32` rethrow loop, then a stack overflow at ntdll |
| Storage service (`02bc`) | `0x73b4d90000` | `secur32` rethrow loop, then a stack overflow at ntdll |
| Browser 2 (`0338`) | `0x73a1b20000` | `secur32` rethrow loop, then a stack overflow at ntdll |

Every libcef image is 0xf66e000 bytes (246.4 MiB), matching our build's `SizeOfImage`.

**The failure.** The access violation reads address 0 inside `secur32.dll`'s copy in the JIT pool,
at guest offset `0x239bc`. The guest stack holds `ncalrpc` and `lsasspirpc`. The exception handler
then raises `AV EXEC` at the guest RIP, and the cycle repeats until the thread's 8 MiB stack runs
out. No `MMDeviceEnumerator` activity was logged; PLA-371's audio start-up is not involved.

## Memory [M]

These are app-wide figures: the run reports pool and band for the whole app, not per process.

- **Footprint (`fpMB`):**
  - +0.6 s: 1,224;
  - +37 s, before the helpers: 3,176;
  - +39.4 s, the browser starts: 3,987;
  - +41.9 s, the utilities start: 4,865;
  - +46.5 s: peak 5,168;
  - +276 s: 4,467.
- **JIT pool:** 896 MiB.
  - At the end: head 514 MB (418 live), tail 273 MB, room 110 MB, 321 images, 13 children.
  - `exhausted=none`, `tail_refused=0`.
- **Band:** 16,384 MB.
  - Peak used 11,252 MB; at the end 10,099 MB used, with the largest free 5,014 MB.
  - 103 threads, `refused=0`.
- **Per-process JIT code** (the last `[jit-pool] tail of pid` line):
  - the browser (`0218`): 144 MiB at its peak;
  - the network service (`02a8`): 32 MiB;
  - the second browser (`0334`): 128 MiB;
  - other processes: 16 MiB each.
- **Exited processes:** 7 `[view-owner]` lines. Each freed 30–50 MB and kept 152–476 MB of views.
- **libcef's image.**
  - Each process maps it on its own, at a different base, relocated (`STATUS_IMAGE_NOT_AT_BASE`), with
    "no pool copy": FEX translates its x64 code, so it is not copied into the JIT pool.
  - Wine on iOS maps image sections as private file mappings (`MAP_PRIVATE`), so clean pages can be
    shared through the page cache, while relocated or written pages are private to each process [I].
  - A per-process resident breakdown was not measured.
- **Large reservations:** not traced in this run (no `+virtual` channel). The only address-space
  failures logged are one `map_fixed_area out of memory for 0x7be50000-0x7bff0000` per process. The
  pool, band and helper start-up show no reservation failure.

## Not checked

- The sign-in page, the renderer processes and their PartitionAlloc and V8 reservations: no renderer
  started before the failure.
- Social Club's 30 s browser timeout (PLA-371): the browser connected in 0.9 s, so start-up time was
  not the limit in this run.
- The release variant: it carries no payload, and `pp verify --variant release` rejects one.
