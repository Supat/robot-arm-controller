import AssistArmCore
import Foundation

/// Futaba RS-series (RS30x/RS40x) command servo protocol: short packets, return packets,
/// and the memory-map addresses the controller uses. Bytes follow the legacy `ControlServo.cpp`.
public enum Futaba {
    /// Header of packets the host sends.
    public static let header: [UInt8] = [0xFA, 0xAF]
    /// Header of return packets the servo sends.
    public static let returnHeader: [UInt8] = [0xFD, 0xDF]
    public static let baudRate = 115200

    /// Memory map (RAM) addresses.
    public enum Address {
        public static let cwComplianceMargin: UInt8 = 0x18
        public static let ccwComplianceMargin: UInt8 = 0x19
        public static let cwComplianceSlope: UInt8 = 0x1A
        public static let ccwComplianceSlope: UInt8 = 0x1B
        public static let punch: UInt8 = 0x1C
        public static let goalPosition: UInt8 = 0x1E
        public static let goalTime: UInt8 = 0x20
        public static let maxTorque: UInt8 = 0x23
        public static let torqueEnable: UInt8 = 0x24
        public static let presentPosition: UInt8 = 0x2A  // 42
    }

    /// Flag byte of a command packet.
    public enum Flag {
        /// Write to RAM, no return packet.
        public static let write: UInt8 = 0x00
        /// Return packet with memory map 42–59 (position, time, speed, current, then temperature
        /// and voltage, or voltage alone, depending on the model; see `Packet.status()`).
        public static let returnStatus: UInt8 = 0x09
        /// Return an ACK packet.
        public static let returnAck: UInt8 = 0x01
    }

    /// Broadcast ID; servos do not answer it.
    public static let broadcastID: UInt8 = 0xFF

    public static func checksum<C: Collection>(_ bytes: C) -> UInt8 where C.Element == UInt8 {
        bytes.reduce(0, ^)
    }

    /// Short packet: `FA AF ID Flag Addr Len Cnt Data… Sum` (Sum = XOR from ID to last data byte).
    public static func shortPacket(id: UInt8, flag: UInt8, address: UInt8, data: [UInt8]) -> [UInt8] {
        var body: [UInt8] = [id, flag, address, UInt8(data.count), data.isEmpty ? 1 : 1]
        body += data
        return header + body + [checksum(body)]
    }

    public static func writeRAM(id: UInt8, address: UInt8, data: [UInt8]) -> [UInt8] {
        shortPacket(id: id, flag: Flag.write, address: address, data: data)
    }

    public static func torque(id: UInt8, on: Bool) -> [UInt8] {
        writeRAM(id: id, address: Address.torqueEnable, data: [on ? 1 : 0])
    }

    public static func maxTorque(id: UInt8, percent: UInt8) -> [UInt8] {
        writeRAM(id: id, address: Address.maxTorque, data: [min(100, percent)])
    }

    /// Compliance slope for CW and CCW (addresses 0x1A, 0x1B) in one write.
    public static func complianceSlope(id: UInt8, slope: UInt8) -> [UInt8] {
        writeRAM(id: id, address: Address.cwComplianceSlope, data: [slope, slope])
    }

    /// Goal position (0.1°) and goal time (10 ms) in one write (addresses 0x1E–0x21).
    public static func move(id: UInt8, position: Int16, time: UInt16) -> [UInt8] {
        let p = UInt16(bitPattern: position)
        return writeRAM(id: id, address: Address.goalPosition,
                        data: [UInt8(p & 0xFF), UInt8(p >> 8), UInt8(time & 0xFF), UInt8(time >> 8)])
    }

    /// Ask for memory map 42–59. The answer is a 26-byte return packet.
    public static func statusRequest(id: UInt8) -> [UInt8] {
        shortPacket(id: id, flag: Flag.returnStatus, address: 0, data: [])
    }

    public static let statusReturnLength = 7 + 18 + 1

    /// A parsed packet (command echo or servo return).
    public struct Packet: Equatable, Sendable {
        public var id: UInt8
        public var flag: UInt8
        public var address: UInt8
        public var length: UInt8
        public var count: UInt8
        public var data: [UInt8]

        /// Above any real servo temperature (°C) and below any real supply voltage (10 mV units).
        static let maxPlausibleTemperature: Int16 = 200

        /// Total byte count of a packet whose first 7 bytes are `head`.
        public static func totalLength(head: ArraySlice<UInt8>) -> Int {
            7 + Int(head[head.startIndex + 5]) * Int(head[head.startIndex + 6]) + 1
        }

        /// Decode the status block (memory map 42–59).
        ///
        /// Models differ after the current field. Some report temperature at 50–51 and voltage
        /// at 52–53. Others (the bench servos answer `… B4 03 00 00 …`, 9.48 V) have no
        /// temperature and report voltage at 50–51 with 52–53 left zero. A powered servo never
        /// reads 0 V, and no servo runs at hundreds of °C, so the two are told apart by value.
        public func status() throws -> ServoStatus {
            guard address == Address.presentPosition, data.count >= 12 else {
                throw ServoError.badPacket("expected 18 bytes from address 42, got \(data.count) from \(address)")
            }
            func i16(_ offset: Int) -> Int16 { Int16(bitPattern: UInt16(data[offset]) | UInt16(data[offset + 1]) << 8) }
            let word50 = i16(8), word52 = i16(10)
            let voltageOnly = word52 == 0 && word50 > Self.maxPlausibleTemperature
            return ServoStatus(position: i16(0), elapsedTime: i16(2), speed: i16(4), current: i16(6),
                               temperature: voltageOnly ? nil : word50,
                               voltage: voltageOnly ? word50 : word52, raw: data)
        }
    }

    /// Scan `bytes` for the first complete, checksum-valid packet. Returns the packet and the
    /// number of bytes consumed up to and including it, or nil if more bytes are needed.
    /// Bytes before a valid header are discarded (RS-485 adapters often echo what we sent,
    /// and the echo is itself a valid packet, so callers filter on `flag`/`length`).
    public static func parse(_ bytes: [UInt8]) -> (packet: Packet, consumed: Int)? {
        var start = 0
        while start + 7 <= bytes.count {
            let isCommand = bytes[start] == 0xFA && bytes[start + 1] == 0xAF
            let isReturn = bytes[start] == 0xFD && bytes[start + 1] == 0xDF
            guard isCommand || isReturn else { start += 1; continue }
            let head = bytes[start..<(start + 7)]
            let total = Packet.totalLength(head: head)
            guard start + total <= bytes.count else { return nil }
            let body = bytes[(start + 2)..<(start + total - 1)]
            if checksum(body) == bytes[start + total - 1] {
                let packet = Packet(id: bytes[start + 2], flag: bytes[start + 3], address: bytes[start + 4],
                                    length: bytes[start + 5], count: bytes[start + 6],
                                    data: Array(bytes[(start + 7)..<(start + total - 1)]))
                return (packet, start + total)
            }
            start += 1
        }
        return nil
    }
}
