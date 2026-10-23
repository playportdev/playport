# Jit activator

A standalone iPhone app: choose a visible developer app, launch it and activate
JIT in that process. The Russian setup screen imports a RemotePairing file and
connects the app's own packet tunnel. It does not require another VPN app.

The pairing file stays in the device-only Keychain. Each StikJIT operation uses
a temporary file with complete file protection, removed when the operation
returns. The DDI cache stays in the app's Library. Blocking device operations run
serially; activation asks iOS for background execution before opening the target.
The app prepares the device, starts the dedicated helper extension and completes
its XPC handshake while the activator is still foreground. Only then does it
send the target bundle identifier to that already connected helper. The helper
runs both the shared C target-launch operation and JIT under the same 25-second
deadline, so cancellation cannot leave a blocked launch on the app's serial queue. The helper's serial queue may block in a
native debugger call; it cannot block the app's queue. A 25-second deadline,
Cancel, and background expiration all send the helper's immediate `cancel()`
message. It deletes its temporary pairing directory and exits its own process,
closing its debugger sockets. The host waits for remote XPC interruption or invalidation before
allowing another attempt, and uses the established helper-only termination SPI
as a fallback. Each attempt starts a new request. If no connection was established,
no native JIT work was sent; the host terminates that startup request directly.
A target left paused by debugger disconnection may need closing and reopening.
Return to the activator to see the result of an attempt.

The packet tunnel routes only `10.7.0.1/32` to the local interface `10.7.1.1/32`.
It reflects IPv4 packets for that exact address pair by swapping their addresses.
The aligned address-word permutation preserves IPv4 and TCP/UDP checksum sums.
There is no DNS configuration, proxy or default included route.

## Build and signing

Use XcodeGen and an iOS 17.4 or newer SDK. Stage the unmodified StikJIT framework
with its bundled scripts, and its matching idevice static library, in the main
checkout's `.work`. The app also bundles Playport's existing
`app/PlayportJIT/playport-universal.js` and compiles the shared C app-service
module from `app/Sources/Relaunch`. The helper reuses
`app/Sources/PlayportJITEntry/entry.c` as its executable entry point. Before
Foundation decodes the private extension request, that canonical entry enables
decoding its anonymous `NSXPCListenerEndpoint`; without it the helper cannot
receive the app's endpoint. `ENABLE_DEBUG_DYLIB=NO` keeps this entry in the helper
executable.

From this directory, with both dependency paths pointing inside this repository:

```sh
STIKJIT_FRAMEWORK_DIR="$PLAYPORT_BUILD/jit-framework-derived/Build/Products/Release-iphoneos" \
IDEVICE_LIBRARY_DIR="$PLAYPORT_BUILD/sources/StikJIT/idevice" \
xcodegen generate
```

Build the `PlayportJITActivator` scheme from the main checkout with a repo-local
derived-data directory. Provision and sign the app and `PlayportJITTunnel`
extension separately, and sign the `PlayportJITWorker` helper with its own profile.
The app and packet-tunnel extension require the `packet-tunnel-provider` Network Extension
entitlement, and the embedded framework must be signed. Generated Xcode projects,
profiles, signing material and build outputs belong in `.work`, never in Git.
The normal Playport Linux build pipeline does not build this standalone app.
File sharing exposes the app's Documents folder in Files. A user can select a
pairing file there through the setup importer, or open a pairing plist from Files;
both paths copy its contents into the same device-only Keychain item.

## Limits and device checks

Developer Mode, a valid RemotePairing file for this iPhone and permission to add
the built-in VPN are required. The first preparation may download and mount a
Developer Disk Image. An existing VPN can conflict with the packet tunnel.

The app lists developer/debuggable apps, not arbitrary App Store apps. On iOS 26,
a target must implement the JIT allocator protocol understood by the selected
script. Known Playport bundle identifiers use the existing Playport script;
other apps use StikJIT's universal script. App selection cannot add that protocol
to an unsupported app. Launch and framework errors remain visible in the app.
JIT is process-specific: activate again after the target process ends.

Host parsing alone is not delivery proof. Verify setup, the permission prompt,
real app discovery, target launch and JIT on the intended iPhone before claiming
installation or activation works.
