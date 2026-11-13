import XCTest
import AssistArmCore
@testable import FutabaRS

final class FutabaPacketTests: XCTestCase {
    func testTorqueOnMatchesLegacyBytes() {
        // Legacy RSIDTorqueOnOff(ID=1, 1): FA AF 01 00 24 01 01 01 sum
        let p = Futaba.torque(id: 1, on: true)
        XCTAssertEqual(p, [0xFA, 0xAF, 0x01, 0x00, 0x24, 0x01, 0x01, 0x01, 0x01 ^ 0x00 ^ 0x24 ^ 0x01 ^ 0x01 ^ 0x01])
    }

    func testMoveMatchesLegacyRSIDMove() {
        // Legacy RSIDMove(ID=2, pos=-900 (0xFC7C), time=0): FA AF 02 00 1E 04 01 7C FC 00 00 sum
        let p = Futaba.move(id: 2, position: -900, time: 0)
        let body: [UInt8] = [0x02, 0x00, 0x1E, 0x04, 0x01, 0x7C, 0xFC, 0x00, 0x00]
        XCTAssertEqual(p, [0xFA, 0xAF] + body + [body.reduce(0, ^)])
        XCTAssertEqual(p.count, 12)
    }

    func testMaxTorqueAndCompliance() {
        XCTAssertEqual(Array(Futaba.maxTorque(id: 1, percent: 75)[2..<8]), [0x01, 0x00, 0x23, 0x01, 0x01, 75])
        // Compliance slope for CW (0x1A) and CCW (0x1B) in one 2-byte write.
        XCTAssertEqual(Array(Futaba.complianceSlope(id: 1, slope: 0x32)[2..<9]), [0x01, 0x00, 0x1A, 0x02, 0x01, 0x32, 0x32])
    }

    func testStatusRequestMatchesManualExample() {
        // Manual: FA AF 01 09 00 00 01 09
        XCTAssertEqual(Futaba.statusRequest(id: 1), [0xFA, 0xAF, 0x01, 0x09, 0x00, 0x00, 0x01, 0x09])
    }

    func testParseReturnPacketAndSkipEcho() throws {
        // 18 data bytes from address 42: pos=900 (0x0384), time=5, speed=-10, current=120, temp=33, volt=740.
        var data: [UInt8] = []
        for v in [900, 5, -10, 120, 33, 740].map { Int16($0) } { let u = UInt16(bitPattern: v); data += [UInt8(u & 0xFF), UInt8(u >> 8)] }
        data += Array(repeating: 0, count: 6)
        let body: [UInt8] = [0x01, 0x00, 0x2A, 0x12, 0x01] + data
        let ret = Futaba.returnHeader + body + [body.reduce(0, ^)]
        XCTAssertEqual(ret.count, Futaba.statusReturnLength)

        // Garbage, then the echoed request, then the return packet.
        let stream: [UInt8] = [0x00, 0x13] + Futaba.statusRequest(id: 1) + ret
        var buffer = stream
        var packets: [Futaba.Packet] = []
        while let (p, used) = Futaba.parse(buffer) { packets.append(p); buffer.removeFirst(used) }
        XCTAssertEqual(packets.count, 2)
        XCTAssertEqual(packets[0].length, 0)           // echo
        XCTAssertEqual(packets[1].address, 42)
        let s = try packets[1].status()
        XCTAssertEqual(s, ServoStatus(position: 900, elapsedTime: 5, speed: -10, current: 120, temperature: 33, voltage: 740))
        XCTAssertEqual(s.positionDegrees, 90, accuracy: 1e-12)
        XCTAssertEqual(s.volts, 7.4, accuracy: 1e-12)

        // Incomplete packet: nothing yet.
        XCTAssertNil(Futaba.parse(Array(ret.dropLast(3))))
        // Corrupt checksum is skipped.
        var bad = ret; bad[ret.count - 1] ^= 0xFF
        XCTAssertNil(Futaba.parse(bad))
    }

    func testDriverReadsStatusThroughLoopbackTransport() async throws {
        let transport = ScriptedTransport()
        let driver = FutabaRSServoDriver(transport: transport)
        try await driver.open()
        try await driver.setTorque(id: 1, enabled: true)
        try await driver.move(id: 1, position: 450, time: 20)
        let status = try await driver.readStatus(id: 1)
        XCTAssertEqual(status.position, 450)
        let written = transport.written
        XCTAssertEqual(written[0], Futaba.torque(id: 1, on: true))
        XCTAssertEqual(written[1], Futaba.move(id: 1, position: 450, time: 20))
        XCTAssertEqual(written[2], Futaba.statusRequest(id: 1))
        await driver.close()
    }
}

/// Echoes every write (like a half-duplex RS-485 adapter) and answers status requests
/// with the last commanded position.
final class ScriptedTransport: ServoTransport, @unchecked Sendable {
    let name = "scripted"
    private let lock = NSLock()
    private var inbox: [UInt8] = []
    private(set) var written: [[UInt8]] = []
    private var goal: Int16 = 0

    func open() async throws {}
    func close() async {}
    func discardInput() async throws { lock.withLock { inbox.removeAll() } }

    func write(_ bytes: [UInt8]) async throws {
        lock.withLock {
            written.append(bytes)
            inbox += bytes  // echo
            guard let (p, _) = Futaba.parse(bytes) else { return }
            if p.address == Futaba.Address.goalPosition, p.data.count >= 2 {
                goal = Int16(bitPattern: UInt16(p.data[0]) | UInt16(p.data[1]) << 8)
            }
            if p.flag == Futaba.Flag.returnStatus {
                let u = UInt16(bitPattern: goal)
                let data: [UInt8] = [UInt8(u & 0xFF), UInt8(u >> 8)] + Array(repeating: 0, count: 16)
                let body: [UInt8] = [p.id, 0x00, 0x2A, 0x12, 0x01] + data
                inbox += Futaba.returnHeader + body + [body.reduce(0, ^)]
            }
        }
    }

    func read(count: Int, timeout: Duration) async throws -> [UInt8] {
        lock.withLock {
            let n = min(count, inbox.count)
            defer { inbox.removeFirst(n) }
            return Array(inbox.prefix(n))
        }
    }
}
