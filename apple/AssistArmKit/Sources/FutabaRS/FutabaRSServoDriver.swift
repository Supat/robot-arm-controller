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
    /// Minimum idle time on the wire between consecutive packets. A write returns once the bytes
    /// are in the adapter's buffer, not once they have left the UART, so the gap is measured from
    /// the estimated end of transmission. Servos drop a packet that arrives on the heels of the
    /// previous one; 1 ms measured this way is enough on the bench (0 ms also worked).
    public var interPacketGap: Duration = .milliseconds(1)
    /// Bit rate used to estimate when a written packet has finished leaving the UART.
    public var baudRate: Int = Futaba.baudRate

    /// Purge the adapter's receive buffer before each status request (drops stale bytes).
    public var purgeBeforeRead = true

    public func configure(interPacketGap: Duration? = nil, replyTimeout: Duration? = nil, purgeBeforeRead: Bool? = nil) {
        if let interPacketGap { self.interPacketGap = interPacketGap }
        if let replyTimeout { self.replyTimeout = replyTimeout }
        if let purgeBeforeRead { self.purgeBeforeRead = purgeBeforeRead }
    }

    private var isOpen = false
    /// When the bus is expected to be idle again after our last transmission or the last reply.
    private var busIdleAt = ContinuousClock.now

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
        let wait = busIdleAt + interPacketGap - ContinuousClock.now
        if wait > .zero { try? await Task.sleep(for: wait) }
        try await transport.write(packet)
        busIdleAt = ContinuousClock.now + .seconds(Double(packet.count * 10) / Double(max(1, baudRate)))
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
        try await readReturn(id: id, flag: Futaba.Flag.returnStatus).status()
    }

    /// Memory map 30–41 (goal position, goal time, max torque, torque enable) for bench checks.
    public func readGoalBlock(id: UInt8) async throws -> [UInt8] {
        try await readReturn(id: id, flag: 0x0B).data
    }

    /// Send a flag-only request and wait for the servo's return packet.
    public func readReturn(id: UInt8, flag: UInt8) async throws -> Futaba.Packet {
        if purgeBeforeRead { try await transport.discardInput() }
        try await send(Futaba.shortPacket(id: id, flag: flag, address: 0, data: []))
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
                busIdleAt = ContinuousClock.now
                return packet
            }
            if buffer.count > 256 { buffer.removeFirst(buffer.count - 64) }
        }
    }
}
