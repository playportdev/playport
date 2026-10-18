# The phone over WireGuard: works on home Wi-Fi, not yet from another network

2026-10-18, PLA-402. Setup:

- **Phone:** iPhone18,4 on iOS 27.0.1 (24A446), with dev IPA
  `32b9122003bd05ec6cea991e661b7e4ae0fca49c76f104f8ca21e315aca4a08e` (head `4b35f5d`).
- **Tooling:** `e5f644e`, plus `tools/net/install-workstation.sh`.
- **Network:** WireGuard to the UniFi gateway gives the phone `10.42.1.2`. AllowedIPs are
  `10.42.0.0/24, 10.42.1.0/24, 10.7.0.1/32`. A static route sends `10.7.0.1/32` to the
  workstation, whose `tools/net/jit-reflect.nft` sends each packet back to its sender
  as from `10.7.0.1`.

## Results

### Routing and reflection
From the start, every leg worked in both directions. The workstation reached
`10.42.1.2`: ping was answered, and an SSH session from the phone stayed up.

The phone's own SSH client connected to `10.7.0.1` on ports 22 and 62078, and a packet
capture on the workstation's LAN interface showed four steps for each try:

1. the SYN arrived from the phone at `10.7.0.1`;
2. it left again as `10.7.0.1 → 10.42.1.2`;
3. the phone's RST came back;
4. the RST was returned as from `10.7.0.1`.

So UniFi forwards the reflected packets, including a source of `10.7.0.1` arriving
from the LAN.

### Lockdown on cellular
The phone was on cellular with Wi-Fi switched on but not joined. It sent a RST
(TTL 63, so from the phone itself) for port 62078:

- on `10.42.1.2`, from the workstation;
- on `10.42.1.2` reflected, from `10.7.0.1`.

Nothing listened there.

### Lockdown with Wi-Fi joined
After the phone joined Wi-Fi (home Wi-Fi, with WireGuard still on), `10.42.1.2:62078`
accepted.

`pp phone status` behaved as follows:

- No phone was listed by mDNS, so it added the phone by address. No UDID was kept yet,
  so the matching pairing record was found and its UDID kept.
- It then reported `"away": "10.42.1.2"`, `ConnectionType` Network and the app's pid,
  which is a DVT call.

### Hollow Knight launch
`pp ui --play app-367520 --until first-frame+10 --shot`, run `20261018T133642`
(screenshots stay in the run directory):

- `setup: before play: … vpn=up`: WireGuard's route to `10.7.0.1` counted as the tunnel.
- The built-in helper checked the tunnel and the DDI mount, attached, blessed 32768
  pages and detached.
- JIT `acquire(512 MiB) -> 0 after 10.73 s`. The 2026-09-28 LocalDevVPN baseline was 3.19 s.
- First frame at +17.41 s; the run reached `until first-frame+10`.

### Away from home, on another Wi-Fi network
The phone joined a non-home Wi-Fi network, with WireGuard to `10.42.1.2` on. Ping round
trips were 30–95 ms.

- **Tooling.** `10.42.1.2:62078` accepts the TCP connection, then resets it on the first
  lockdown message. A bare `QueryType` from the workstation got a reset, and netmuxd logged
  `Failed to start lockdown session: … Broken pipe`. Two changes did not help:
  - WireGuard Interface › Addresses `10.42.1.2/16`, which puts the workstation in the
    tunnel's subnet;
  - MTU 1280.
- **JIT.** A Play from Playport stayed on "waiting for JIT" through the reflection.
  - The cause is not known: the workstation had no root for a capture, and the phone
    could not be read.
  - With MTU 1280, the same.

## Conclusions

- **At home, joined to home Wi-Fi with WireGuard on, everything works**, through the
  WireGuard interface and the reflection.
- **On cellular alone**, nothing listens on 62078.
- **On another Wi-Fi network**, lockdown accepts the TCP connection, then drops it before
  answering. The JIT path hangs.

The working case differs from the failing one only in the Wi-Fi network the phone is
joined to, not in the tunnel. A plausible explanation is iOS 26.4's change to network
lockdown: StikDebug and SideStore users report heartbeat `BrokenPipe` and dropped
loopback connections since iOS 26.4. This is not yet shown. iOS may accept network
lockdown only from peers it counts as on the joined Wi-Fi's local network.

**Not a working setup yet: a phone away from home cannot be driven this way.**

**Next, at the workstation:** with the phone on a non-home Wi-Fi, capture the reflected
JIT connection and the phone's resets, and read the app's `jit:` lines, for example over
a home visit or a pulled log.

## Not checked

- An install over the WAN.
- The restart after a game through the reflection: the run ended at first-frame+10.

The phone's iOS 27.0.1 is newer than the known-good table's 27.0 row. This run is the
Hollow Knight pass for it, through the reflection, not LocalDevVPN.
