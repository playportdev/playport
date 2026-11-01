# Does iOS keep x18 under macOS 26.4's custom x18 ABI? (2026-11-01)

**Linear:** spec [PLA-516](https://linear.app/playportdev/issue/PLA-516) (World of Warcraft's
Windows ARM64 client; decisions [0170](../decisions/0170-native-arm64-guests.md) and
[0176](../decisions/0176-native-arm64-images-live-in-the-jit-pool.md)).

**Status: on the phone (iOS 27.2) the verdict is `UNTIL-SWITCH`, and the installer refuses an app
carrying `com.apple.security.custom-x18-abi-toggle`, so the runtime keeps rewriting x18 readers.**
Results: [on the phone](#on-the-phone-ios-272). The probe was written in the side copy
`.work/worktrees/x18abi` (decision 0117), branch `dev/pla-516-x18-abi`, and ran from the main
checkout. The same sequence ran natively on a Mac (macOS 27.2),
[below](#on-macos-272-the-same-sequence-natively). Below: what the sources say, what the Mac and
the phone showed, what was built, how to run it and how to read it.

## On the phone (iOS 27.2)

iPhone18,4 on iOS 27.2, dev IPA `b2b970695d0d6999b4796ecae9473bc5a391c07471024ae0fea2aff8cda16500`
(merge `7f509e23`, madeira-unix 0272), run `20261101T135242`, with
`--settings 'dir-arm64:{"arguments":"x18","runtime":"x18-abi=1"}'`. The probe exited 42.

- **No entitlement: `UNTIL-SWITCH`.** Plain, x18 was zero after the 20 ms spin, `getpid`, the
  forced switch and the `udf`, and the TEB after the Wine calls (the dispatcher's reload). Armed
  (bit 48 set by `msr` from guest code), x18 and the bit survived `getpid`; the spin (preempted),
  the forced `thread_switch`, `NtYieldExecution`, `Sleep(50)` and the `udf` round trip cleared the
  bit and x18 came back zero. The `udf` handler's context still held the sentinel. The probe's
  last line: `x18-abi: UNTIL-SWITCH …; armed: none=kept+bit spin=zero getpid=kept+bit switch=zero
  yield=TEB sleep0=TEB+bit sleep50=TEB udf=zero`. So the kernel honours the bit as the sources say,
  and drops it at the first context switch of an unentitled task.
- **The libsystem path is absent.** Every `[x18-abi]` line in `s1-host.log` was `no update_tpidr`:
  `os_set_custom_x18_abi_enabled` and `os_custom_x18_abi_enabled` resolve, but the `update_tpidr`
  commpage pointer is NULL in an iOS app, so 0272 never calls the setter (it would jump to 0).
  Only a direct `msr TPIDR_EL0` sets the bit there.
- **With the entitlement: refused at install.** xtool drops a key it has no type for when it signs
  for a free team; with a local type for the key (no App ID capability), the dev IPA
  (`d24b8ef835e4a3b7d45ed70901cdb2ec9c657cb59788e0b8fc0a136bc0eea601`) carried it, and
  `verify-ipa` already failed `profile: allows every entitlement the signature carries`. installd
  refused it: `ApplicationVerificationFailed: Failed to verify code signature of …/S1Probe.app :
  0xe8008015 (A valid provisioning profile for this executable was not found.)`. The installed app
  stayed as it was (container kept); the entitlement and the xtool change were reverted, and the
  dev app reinstalled without them. A free-team profile cannot list the key, so the entitled run
  cannot happen on this phone with this signing.
- **`pp install` recorded the refused IPA as installed.** Its recovery for a timed-out install
  found the app and the (unchanged) profile on the phone and wrote the refused IPA's sha256 to the
  install record. `build/install` now stops at an `AppInstallError` from installd, naming it.

So nothing from [What a positive result would allow](#what-a-positive-result-would-allow) can be
dropped: x18 must survive preemption, and only the entitlement gives that.

## What the sources say

Windows on ARM64 keeps the TEB in x18. Darwin zeroes x18 at every return to user mode, so the
runtime rewrites every instruction of a native ARM64 child that reads x18 (madeira-unix 0252,
0263–0265, 0270). From Apple's open-source xnu at tag `xnu-12377.121.6`:

- **The function.** `libsyscall/os/x18.c`: `void os_set_custom_x18_abi_enabled(bool)` and
  `bool os_custom_x18_abi_enabled(void)`. The flag is bit 48 of `TPIDR_EL0`
  (`MACHDEP_TPIDR_FLAG_PRESERVE_X18`, `osfmk/arm64/machine_machdep.h`). The setter
  `__builtin_trap()`s when asked for the state the thread is already in, and writes the bit
  through `update_tpidr`, a commpage routine (`_COMM_PAGE_TEXT_ATOMIC_TPIDR_EL0`).
  `__libkernel_init` sets that pointer from the `pfz=` string the kernel passes every process
  (`bsd/kern/kern_exec.c`); without it the pointer is NULL. The call returns nothing and sets no
  errno. Its header comment (`libsyscall/os/arch/arm64.h`) says a thread switches in before
  running code that uses x18 and switches out before calling system code; switching out destroys
  x18.
- **What the kernel does with the bit.** `osfmk/arm64/locore.s`, `exception_return`: x18 is
  zeroed, then reloaded from the saved state when `TPIDR_EL0` bit 48 is set. Nothing else is
  checked there, so the bit alone keeps x18 across syscalls, faults and interrupts on the same
  thread.
- **Context switches.** `osfmk/arm64/pcb.c`, `machine_switch_cpu_data`: the outgoing thread's bit
  is saved only when its task has `preserve_x18_entitled`; the incoming thread gets the bit back
  only if its saved flag is set, otherwise bit 48 is cleared, and x18 comes back as 0.
- **The entitlement.** `osfmk/arm64/machine_task.c`, `machine_task_process_signature`:
  `preserve_x18_entitled` is `com.apple.security.custom-x18-abi-toggle`, or
  `ml_satisfies_x86_64_requirements` (a stub that returns false in the open source; macOS's real
  one is presumably the cross-architecture entitlement check [INFERENCE]). `preserve_x18_always`
  is `com.apple.private.custom-x18-abi` or `com.apple.private.uexc`. Keeping x18 for a binary built
  against an old SDK applies to `PLATFORM_MACOS` with an SDK below 13.0 only, so linking with an
  old iOS `-platform_version` does not keep x18 on iOS.
- **Old devices.** With `__ARM_KERNEL_PROTECT__` the kernel uses x18 itself and refuses a task with
  any of the entitlements. The phone (iPhone18,4, A19 Pro) is presumably not such a device
  [INFERENCE].
- **The SDK.** The toolchain's `iPhoneOS26.5.sdk/usr/lib/libSystem.B.tbd`
  (`$DARWIN_SDK/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/`) exports
  `_os_set_custom_x18_abi_enabled`, `_os_custom_x18_abi_enabled` and `_update_tpidr` from
  `libsystem_kernel`. The header marks the functions `API_UNAVAILABLE(ios)`.
- **The entitlement on Apple's side.** On wine-devel (Brendan Shanks, 2026-08-07,
  [thread](https://list.winehq.org/hyperkitty/list/wine-devel@list.winehq.org/thread/CKG5CEN2BE5VRXZ7O7NX4YUSBH3247WH/)),
  every one of these features needs a restricted entitlement: `com.apple.developer.cross-architecture-support`
  for paid accounts, and `…-unmanaged` for free ones. These are capabilities of a macOS App ID.
  The developer API that xtool generates (`Sources/DeveloperAPI/Generated/Types.swift`) has no
  such capability, and a profile without it cannot carry the entitlement.

**What to expect.** A free-team app has no x18 entitlement. The sources predict that the bit keeps
x18 across kernel entries while it holds, and that the first context switch clears both the bit and
x18. The probe's verdict for that is `UNTIL-SWITCH`. That alone is not enough to stop rewriting:
guest code is preempted at arbitrary points.

## On macOS 27.2: the same sequence natively

The Mac was an M1 Pro on macOS 27.2 (26B123), with Apple clang 21. The program was a C version
of the probe's x18 phase (`x18_run`, the same asm with Mach-O names). It ran three modes:
plain; with the bit set by `msr`; and with the bit set by `os_set_custom_x18_abi_enabled(true)`
looked up with dlsym. In each mode it ran: nothing; spins of 20 ms and 1 s; a raw `getpid` svc;
a raw `thread_switch` waiting 50 ms; `sched_yield`; `usleep(50000)`; and a `udf` stepped over by
a SIGILL handler. It was built three times, each ad hoc signed (`codesign -s -`):

- **No entitlement.** dlsym found the setter, the getter and `update_tpidr` (non-NULL), and
  `os_custom_x18_abi_enabled()` went from 0 to 1 after the call. Plain: x18 was zero after
  everything but `none`. With the bit, by `msr` or by the API alike, x18 was kept, and the bit
  stayed set, across the 20 ms spin, `getpid`, `sched_yield` and the signal round trip. It was
  zero, with the bit cleared, after the 1 s spin (preempted), the `thread_switch` wait and
  `usleep`. That is `UNTIL-SWITCH`, as the sources say. The signal handler's `mcontext` had the
  sentinel in x18 in both modes.
- **`com.apple.security.custom-x18-abi-toggle`.** The binary ran, ad hoc signed; AMFI does not
  restrict this entitlement on macOS. With the bit, x18 was kept, and the bit stayed set, across
  every operation: the 1 s spin, the forced context switch, and `usleep`. That is `PRESERVED`.
- **`com.apple.developer.cross-architecture-support-unmanaged`.** The binary was killed at exec
  (exit 1). The kernel log said: `AMFI: … Code has restricted entitlements, but the validation of
  its code signature failed`. It needs a provisioning profile.

So the open question for the phone is not the API. It is whether an iOS app signed by the free
team may carry `com.apple.security.custom-x18-abi-toggle`. On iOS the installer checks the
executable's entitlements against the provisioning profile, and a free-team profile lists only
its own capabilities. An app carrying the key was therefore expected to be refused at install,
and the phone [refused it](#on-the-phone-ios-272). The probe below measures the unentitled case,
which the Mac predicted, and the phone showed, to be `UNTIL-SWITCH`.

## What was built

- **madeira-unix 0272** (`Class: diagnostics`, default off). With `madeira.cfg` `x18-abi = 1`,
  `init_syscall_frame` of every native ARM64 child thread runs `pp_x18_abi_thread_start`, on the
  thread itself, after the Mach exception handler has registered it. That function looks up the
  setter, the getter and `update_tpidr` with `dlsym(RTLD_DEFAULT)`, and calls the setter once, only
  if the thread is not already in the mode (which would trap) and the pointer is set (otherwise the
  call would jump to 0). It then logs one line to the runtime's log (`s1-host.log`):

  `[x18-abi] tid T teb P: called: os_set_custom_x18_abi_enabled=… os_custom_x18_abi_enabled=… update_tpidr=…; enabled 0 -> 1, TPIDR_EL0 … -> … (bit 48 0 -> 1), errno 0 -> 0 (PLA-516)`

  The other outcomes are `missing`, `no update_tpidr` and `already on`. The latest result is also
  kept in `pp_x18_abi_last`.
- **The `arm64` probe's `x18` phase** (`tools/compat/probes/arm64.c`). With `x18` as its
  arguments, after its other checks, it sets x18 to a sentinel and then runs each of: nothing; a
  20 ms spin on the generic timer; a raw Darwin `getpid` (`svc #0x80`, x16 = 20); a raw Mach
  `thread_switch(0, SWITCH_OPTION_WAIT, 50)` (x16 = -61, a forced context switch); the Wine
  calls `NtYieldExecution`, `Sleep(0)` and `Sleep(50)`; and a `udf` that a vectored handler steps
  over. After each it reads x18 back. The sequence runs once plain and once armed, with
  `TPIDR_EL0` bit 48 set from guest code just before, as `update_tpidr` would set it. The bit is
  read before and after each operation and cleared again afterwards. x18 is read only by stores
  relative to SP, which the x18 patcher leaves alone (`tools/tests/test_x18_abi.py` runs the
  patcher's classifier over the probe's words). The phase never changes the exit code: 42 still
  means every earlier check passed.
- **Host checks.** `tools/tests/test_x18_abi.py` checks four things: the header calls only when
  safe (a fake libsystem); the patch's wiring; that the patcher leaves the probe's x18 words
  alone; and that the phase is opt-in. The x86-64 build of the probe, run with `x18` under
  desktop Wine, exits 42 and logs `x18: skipped, not an aarch64 build`.

## Running it (main checkout, after the branch moves there and installs)

```sh
./pp phone put "$PLAYPORT_BUILD/compat/probes/arm64/arm64.exe" Documents/Import/arm64/arm64.exe
./pp ui --action uninstall:dir-arm64 --action import:Import/arm64
./pp ui --settings 'dir-arm64:{"arguments":"x18","runtime":"x18-abi=1"}' --play dir-arm64 --wait 180 --shot
./pp phone pull Documents/prefix/drive_c/Games/arm64/arm64.log <run>/arm64-log
```

## Reading it

- `s1-host.log`: one `[x18-abi]` line for each native thread. `called … enabled 0 -> 1 … bit 48 0 -> 1`
  means the libsystem path works on iOS 27.2. `missing` means the symbol is not exported at
  runtime. `no update_tpidr` means there is no commpage routine.
- `arm64.log`:
  - `x18: TEB …; x18 at the phase start …` gives the TEB against the x18 the thread had. `zero`
    is the expected value; `TEB` would mean the runtime's dispatcher reload was still in effect.
    It also shows the runtime's bit, which a context switch has probably cleared by then.
  - Each `x18: plain|armed OP: x18 V (kept|TEB|zero|other), bit 48 B -> A` line gives one result.
  - The last line is `x18-abi: VERDICT; plain: …; armed: …`. The verdicts are:
    - `PRESERVED`: x18 and the bit survive the forced context switch.
    - `UNTIL-SWITCH`: kept across kernel entries; a context switch clears both.
    - `IGNORED`: the bit does not keep x18 even across `getpid`.
    - `NOT-ZEROED`: the kernel left x18 alone without the bit.
  - Without the bit, the Wine calls (`yield`, `sleep0`, `sleep50`) report `TEB`, because
    `__wine_syscall_dispatcher` reloads x18 from the TLS slot. They say nothing about the kernel.

## What a positive result would allow

With `PRESERVED` (the bit keeps x18 across a context switch under the free-team signature), a
native ARM64 child thread could run with x18 = TEB, as on Windows. Two things would be needed:
the switch made at every entry to and exit from guest code (the dispatcher return, signal and
Mach-exception resume, thread start), and x18 set to the TEB there. Then the runtime could drop:

- the x18 patcher for native children: 0263's every-reader classifier, its trampolines, and the
  sites budget;
- 0265's and 0270's re-patching of code a child decrypts at `FlushInstructionCache`;
- 0259's single-step of a patched instruction, and the trampoline-aware cases of 0253 and 0261;
- the Mach handler's emulation of `[x18, #imm]` with x18 = 0 for those threads.

Each of those has been a WoW blocker in turn (0270 alone took the patched sites over the phone's
image from 40,590 to 55,679). The x18 rewriting is most of the rewrite of the game's memory that
0175's amendment discloses to players.

With `UNTIL-SWITCH`, nothing can be dropped. The one lever left is the entitlement that turned the
Mac's result into `PRESERVED`: `com.apple.security.custom-x18-abi-toggle` in
`app/S1Probe.entitlements`, plus whatever xtool needs to keep a key the profile does not list
(it already needs a local patch for `increased-memory-limit`). The phone's installer refuses that
key from a free-team app (0xe8008015, [above](#on-the-phone-ios-272)) and keeps the installed app.
