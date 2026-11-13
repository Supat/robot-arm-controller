import AssistArmCore
import Foundation

/// `ServoDriver` for Futaba RS-series servos on a `ServoTransport`.
///
/// Writes use short packets with no return packet. Status reads send a flag-0x09 request
/// and wait for the 26-byte return packet, skipping any echo of the request produced by
/// half-duplex RS-485 adapters.
public actor FutabaRSServoDriver: ServoDriver {
    public let transport: ServoTransport
    public nonisolated var name: String { "Futaba RS @ \(transport.name)" }
    /// How long to wait for a return packet. The legacy code slept 50 ms; servos answer in a few ms.
    public var replyTimeout: Duration = .milliseconds(60)
    /// Minimum gap between consecutive packets, so a slow adapter is not overrun.
    public var interPacketGap: Duration = .milliseconds(1)

    private var isOpen = false
    private var lastSend = ContinuousClock.now

    public init(transport: ServoTransport) {
        self.transport = transport
    }

    public func open() async throws {
        guard !isOpen else { return }
        try await transport.open()
        isOpen = true
    }

    public func close() async {
        guard isOpen else { return }
        await transport.close()
        isOpen = false
    }

    private func send(_ packet: [UInt8]) async throws {
        guard isOpen else { throw ServoError.notOpen }
        let since = ContinuousClock.now - lastSend
        if since < interPacketGap { try? await Task.sleep(for: interPacketGap - since) }
        try await transport.write(packet)
        lastSend = ContinuousClock.now
    }

    public func setTorque(id: UInt8, enabled: Bool) async throws {
        try await send(Futaba.torque(id: id, on: enabled))
    }

    public func setMaxTorque(id: UInt8, percent: UInt8) async throws {
        try await send(Futaba.maxTorque(id: id, percent: percent))
    }

    public func setCompliance(id: UInt8, slope: UInt8) async throws {
        try await send(Futaba.complianceSlope(id: id, slope: slope))
    }

    public func move(id: UInt8, position: Int16, time: UInt16) async throws {
        try await send(Futaba.move(id: id, position: position, time: time))
    }

    public func readStatus(id: UInt8) async throws -> ServoStatus {
        try await transport.discardInput()
        try await send(Futaba.statusRequest(id: id))
        var buffer: [UInt8] = []
        let deadline = ContinuousClock.now + replyTimeout
        while true {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { throw ServoError.timeout(id: id) }
            let want = max(1, Futaba.statusReturnLength - buffer.count)
            let chunk = try await transport.read(count: want, timeout: remaining)
            if chunk.isEmpty { continue }
            buffer += chunk
            while let (packet, consumed) = Futaba.parse(buffer) {
                buffer.removeFirst(consumed)
                // Skip the echo of our own request (length 0) or packets from other servos.
                guard packet.id == id, packet.length > 0 else { continue }
                return try packet.status()
            }
            if buffer.count > 256 { buffer.removeFirst(buffer.count - 64) }
        }
    }
}
