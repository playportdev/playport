// SPDX-License-Identifier: GPL-3.0-or-later
import NetworkExtension
import Darwin

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let packetQueue = DispatchQueue(label: "playport.jit-tunnel.packets")
    private var running = false
    private let local: [UInt8] = [10, 7, 1, 1]
    private let peer: [UInt8] = [10, 7, 0, 1]

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.7.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.7.1.1"], subnetMasks: ["255.255.255.255"])
        ipv4.includedRoutes = [NEIPv4Route(destinationAddress: "10.7.0.1", subnetMask: "255.255.255.255")]
        ipv4.excludedRoutes = [.default()]
        settings.ipv4Settings = ipv4
        settings.mtu = 1500
        setTunnelNetworkSettings(settings) { error in
            self.packetQueue.async {
                if let error { completionHandler(error); return }
                self.running = true
                completionHandler(nil)
                self.readPackets()
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        packetQueue.async {
            self.running = false
            completionHandler()
        }
    }

    private func readPackets() {
        guard running else { return }
        packetFlow.readPackets { packets, protocols in
            self.packetQueue.async {
                guard self.running else { return }
                var reflected: [Data] = []
                for (packet, family) in zip(packets, protocols) {
                    guard family.int32Value == AF_INET, packet.count >= 20 else { continue }
                    var bytes = [UInt8](packet)
                    let headerLength = Int(bytes[0] & 0x0f) * 4
                    let totalLength = Int(bytes[2]) << 8 | Int(bytes[3])
                    guard bytes[0] >> 4 == 4, headerLength >= 20, headerLength <= bytes.count,
                          totalLength >= headerLength, totalLength <= bytes.count,
                          Array(bytes[12..<16]) == self.local, Array(bytes[16..<20]) == self.peer else { continue }
                    // Swapping aligned address words preserves both the IPv4 and transport checksum sums.
                    for offset in 0..<4 { bytes.swapAt(12 + offset, 16 + offset) }
                    reflected.append(Data(bytes))
                }
                if !reflected.isEmpty {
                    _ = self.packetFlow.writePackets(reflected, withProtocols: reflected.map { _ in NSNumber(value: AF_INET) })
                }
                self.readPackets()
            }
        }
    }
}
