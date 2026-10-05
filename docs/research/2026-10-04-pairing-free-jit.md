# Can an independently sideloaded IPA avoid JIT pairing?

**Date:** 2026-10-04. **Kind:** desk research, not a phone result.
**Boundary:** distribute one Playport IPA; the recipient chooses their installer
(e.g. iLoader or AltStore). Stock, non-jailbroken current iOS; no mandatory
external JIT app, transferred secret or computer after installation.

## Conclusion

No published, deployable **native JIT unlock** meeting that boundary was found.
This is a finding about available mechanisms, not proof that no future exploit
or Apple policy change could provide one. The current debugger route needs
per-device trust. Changing the framework or embedding another helper does not
remove that requirement.

There are genuinely pairing-free execution architectures: a native interpreter,
or emulation hosted inside WebKit's JavaScript/WebAssembly environment. These
are substantial runtime changes, not another JIT activation API. Their game
compatibility and performance on our phone have not been tested.

## What the IPA can and cannot supply

- A development signature with `get-task-allow` permits an authorized debugger
  to attach. It does not turn the app or its extension into that debugger or
  grant unrestricted executable-memory allocation.
- An installer can create/place an RP record, but independent installers do not
  share a standard credential-delivery contract with Playport. The fact that an
  installer previously trusted the phone does not give every installed app the
  installer's secret credentials. The RP record is distinct from the ordinary
  USB/lockdown pairing record.
- A shared generic record bundled in the IPA cannot establish every recipient
  phone's trust. On-device generation avoids file handling but still needs the
  person to approve that host in Settings.
- “Any installer” also cannot mean any signing certificate: distribution or
  enterprise signing without `get-task-allow` cannot use the debugger route.
  An unsigned entitlement dictionary cannot override the final signing profile.

Our earlier StikDebug test did not omit pairing. The workstation generated the
RP file and placed it in StikDebug's Documents without a phone picker or Trust
prompt ([record, §2](../evidence/2026-09-24-stikdebug-url.md)). StikDebug's guide
also explicitly requires a record and documents iLoader's placement flow [1].
That explains a setup experience with no visible pairing-file step; it is not
an independent, pairing-free IPA.

## Candidate mechanisms

| Mechanism | Avoids Playport pairing? | Fits this distribution boundary? |
| --- | --- | --- |
| Embedded StikJIT/helper extension | No; already our design | No change to trust requirement [2] |
| Installer/desktop debugger | Can avoid importing credentials into Playport, if the external tool handles the complete JIT protocol | Requires an external authorized host; not self-contained [3] |
| Self-debugging with `ptrace(PT_TRACE_ME)` | Historically yes | Not a current route: the old trick was blocked [4, 5] |
| Add `allow-jit`/`dynamic-codesigning`, or buy a developer membership | Only with OS-authorized privileges | No general emulator entitlement is supplied by ordinary developer signing [6, 7] |
| Apple's alternative-browser-engine JIT | Yes, genuinely entitlement-based rather than pairing-based | Requires Apple approval, browser functionality/conformance and regional distribution; not a general Wine/emulator permission [7, 8] |
| Jailbreak / TrollStore / code-signing exploit | Some device/version-specific routes can | Not an independently sideloaded IPA on current stock iOS; TrollStore's published supported firmware ends at 17.0 [9] |
| Native interpreter / precompiled threaded interpreter | Yes; no runtime-generated native instructions | Feasible architectural direction, with major integration and performance risks [10] |
| WebKit-hosted JS/WebAssembly emulation | Yes; WebKit compiles the web code inside its own process | Genuine alternative architecture, not native JIT access for our existing process [11–14] |
| Ahead-of-time native game translation | Potentially for fixed, pre-signed workloads | Not a generic fix for games installed later, dynamic code and our current loader; no implementation evaluated |

### Why another helper or `ptrace` is not the missing switch

The historical self-JIT article describes `PT_TRACE_ME` setting debug state and
relaxing code-signature enforcement [4]. A primary UTM report documents iOS 14
no longer setting `CS_DEBUGGED` through that trick, with a code-signing kill [5].
UTM's current installation guide restricts the old untethered exceptions to
older OS/device combinations; newer stock versions use debugger-assisted JIT
or the interpreter-only SE build [10]. These are separate historical loopholes,
not evidence that a private API still unlocks our reference phone.

On our tested TXM hardware, the debugger also authorizes each executable page;
just setting a process flag would not demonstrate a working pool. Our
[architecture](../ARCHITECTURE.md#jit-activation) and the StikJIT integration
protocol describe the allocation/write/bless/detach sequence [2]. Any external
JIT alternative would need to support that sequence, not merely report a
successful debugger attach. AltJIT's documented ordinary attach workflow is
not, by itself, evidence of compatibility with this pool protocol.

An embedded extension solves the second-process/deadlock problem, not debugger
privilege. It currently reaches Apple's debugserver through the authenticated
RemotePairing tunnel; it does not attach directly with independently granted
system privileges.

### Browser JIT: real, but in the wrong execution environment

WebKit's own architecture documentation explicitly says its WebContent process
can JIT-compile JavaScript and is tightly sandboxed [11]. An embedded WKWebView
therefore offers a real no-pairing route for **web-hosted** emulation. It does
not lend that process's privileges or executable pages to the native app. A
native JavaScriptCore import is not a substitute for entering that authorized
WebContent environment.

There are two different possibilities:

1. **Interpret the guest in a Wasm-compiled emulator.** WebKit compiling that
   interpreter to native code does not eliminate guest-instruction interpretation.
2. **Translate guest blocks to Wasm modules at runtime.** v86 demonstrates this
   design, but its published CPU omits x86-64 extensions [12]. It is not a backend
   for our x86-64 titles.

Boxedwine documents browser-hosted Wine with an interpreted CPU; upstream targets
16/32-bit Windows applications and calls its web build slow [13]. The
experimental Boxedwine64 fork reports actual Wine64 GUI/OpenGL demos in desktop
Chrome/Safari using Memory64 and workers/shared memory, but explicitly has **no
64-bit guest JIT** [14]. Those are author-reported desktop/browser results, not
Playport or iPhone validation. Safari desktop results do not establish mobile
WebKit feature support, memory limits, stability or game speed.

This makes browser-hosted execution a credible research direction, not an
available replacement for Madeira + FEX + DXMT. It would require a different CPU
backend/execution environment, Windows runtime integration, memory model and
host/graphics bridge. No claim is made that modern x86-64 games are playable
through it on iOS.

### JIT-less is larger than replacing FEX

The current build uses FEX `9fbdc00b` (`FEX-2609_1`). Its thread creation selects
`CreateArm64JITCore`; the remaining `Interpreter/Fallbacks` files are not a full
CPU interpreter. Upstream removed its general IR interpreter in FEX-2310 [15].
There is no supported interpreter toggle to enable here.

More importantly, the debugger-authorized pool also holds **ARM64EC PE images,
patched trampolines and per-pseudo-process ntdll copies**, not just FEX output
([JIT pool use](../ARCHITECTURE.md#jit-pool-use)). Even an x86 interpreter would
leave the existing native PE-loading path needing unsigned executable memory.
A genuinely JIT-less build must address the loader/native runtime as well—for
example, execute an interpreted guest runtime or redesign native components as
code-signed Mach-O code. Neither has been implemented or benchmarked here.

Ahead-of-time translated blocks could only execute as native code if correctly
packaged and signed. Caching generated bytes/IR as ordinary data does not grant
execution permission. Re-signing arbitrary generated code on-device would also
need a suitable signing identity/private key, which an app cannot assume every
installer delivers. Bundling a signing private key in a public IPA is not an
acceptable solution. AOT also needs a strategy for unseen/dynamically generated
code and game updates; it is not a general Steam-library switch.

## Recommendation

- For the existing high-performance runtime, retain on-device trust setup and
  improve its UI; do not advertise an installer-independent pairing-free native
  JIT path that has not been demonstrated.
- If eliminating this setup is a hard product requirement, treat it as a
  **runtime architecture fork**, not a setup cleanup. First validate a small
  pairing-free interpreter/WebKit prototype on the actual iPhone, then one
  representative x86-64 title, before committing to a migration. Separately
  check native-runtime loading, graphics, memory limits, input and sustained
  speed. No performance factor is asserted without measurements.
- Installer-assisted credential provisioning may be an optional convenience,
  but cannot be the baseline when distributing only an IPA with arbitrary
  installation methods. Supporting it would also require revisiting the current
  UI-only workflow decision.

## Sources and verification boundary

Primary sources fetched/read on 2026-10-04; search summaries were used for
discovery, not as proof. Public project READMEs describe their authors' results.
No exploit, browser demo, alternative backend or phone play was run. No runtime
code, pins, patch series, setup UI or product decisions were changed.

1. [StikDebug pairing guide](https://github.com/StikDebug/StikDebug-Guide/blob/main/pairing_file.md)
2. [StikJIT integration](https://github.com/StikDebug/StikJIT/blob/main/INTEGRATION.md)
3. [AltJIT](https://faq.altstore.io/altstore-classic/enabling-jit/altjit)
4. [Historical jailed JIT / PT_TRACE_ME article (2020)](https://saagarjha.com/blog/2020/02/23/jailed-just-in-time-compilation-on-ios/)
5. [UTM #397: iOS 14 blocks the ptrace trick](https://github.com/utmapp/UTM/issues/397)
6. [Apple Platform Security: app code signing](https://support.apple.com/guide/security/app-code-signing-process-sec7c917bf14/web)
7. [Apple: alternative browser engines in the EU](https://developer.apple.com/support/alternative-browser-engines/)
8. [Apple: protecting JIT-compiled web-content code](https://developer.apple.com/documentation/browserenginekit/protecting-code-compiled-just-in-time) (read through Apple's DocC JSON endpoint)
9. [TrollStore supported versions and restricted entitlements](https://github.com/opa334/TrollStore/blob/main/README.md)
10. [UTM iOS installation, including SE](https://docs.getutm.app/installation/ios/), [iOS development/signing](https://github.com/utmapp/UTM/blob/main/Documentation/iOSDevelopment.md)
11. [WebKit multi-process architecture](https://docs.webkit.org/Deep%20Dive/Architecture/WebKit2.html)
12. [v86 CPU limitations](https://github.com/copy/v86/blob/master/Readme.md), [runtime Wasm translation](https://github.com/copy/v86/blob/master/docs/how-it-works.md)
13. [Boxedwine README](https://github.com/danoon2/Boxedwine/blob/master/README.md), [CPU emulation](https://github.com/danoon2/Boxedwine/blob/master/docs/CPUemulation.md)
14. [Experimental Boxedwine64 README](https://github.com/andrewnakas/Boxedwine64/blob/master/README.md)
15. [FEX-2310: removal of interpreter backend](https://fex-emu.com/FEX-2310/)

Repository inspection: `app/Sources/S1Probe/BuiltInJit.swift`,
`JitProvider.swift`, `OnDevicePairing.swift`, `JitSetup.swift`,
`app/Sources/PlayportJIT/JITHelper.swift`, `app/Sources/Relaunch/relaunch.c`,
`pins.lock`, and the built FEX tree's
`FEXCore/Source/Interface/Core/Core.cpp`. The pinned StikJIT source's
`JITSession.swift` reads the RP record before `tunnel_create_rppairing` and then
connects debugserver; no pairing-free activation branch was found there.
