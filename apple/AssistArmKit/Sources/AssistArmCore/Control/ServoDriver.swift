import Foundation

/// Live readings of one servo (Futaba memory map 42–59).
public struct ServoStatus: Sendable, Equatable {
    /// Present position, 0.1° units.
    public var position: Int16
    /// Elapsed time of the current move, 10 ms units.
    public var elapsedTime: Int16
    /// Present speed, °/s.
    public var speed: Int16
    /// Present load (current), mA.
    public var current: Int16
    /// °C, or nil when the servo model does not report a temperature.
    public var temperature: Int16?
    /// 10 mV units.
    public var voltage: Int16
    /// The 18 raw bytes of memory map 42–59 as received, for bench diagnostics (empty for mocks).
    public var raw: [UInt8]

    public init(position: Int16, elapsedTime: Int16 = 0, speed: Int16 = 0, current: Int16 = 0, temperature: Int16? = nil, voltage: Int16 = 0,
                raw: [UInt8] = []) {
        self.position = position
        self.elapsedTime = elapsedTime
        self.speed = speed
        self.current = current
        self.temperature = temperature
        self.voltage = voltage
        self.raw = raw
    }

    public var positionDegrees: Double { Double(position) / 10 }
    public var volts: Double { Double(voltage) / 100 }
}

public enum ServoError: LocalizedError, Sendable {
    case notOpen
    case io(String)
    case timeout(id: UInt8)
    case badPacket(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .notOpen: "Servo link is not open."
        case .io(let detail): "Servo link I/O error: \(detail)"
        case .timeout(let id): "Servo \(id) did not answer."
        case .badPacket(let detail): "Malformed servo packet: \(detail)"
        case .unsupported(let detail): detail
        }
    }
}

/// The operations the controller needs from a position-controlled servo bus.
/// Positions are in 0.1° (Futaba convention); compliance follows the Futaba slope byte.
public protocol ServoDriver: AnyObject, Sendable {
    var name: String { get }
    func open() async throws
    func close() async
    func setTorque(id: UInt8, enabled: Bool) async throws
    /// 0…100 % of rated torque.
    func setMaxTorque(id: UInt8, percent: UInt8) async throws
    /// Compliance slope for both directions. Larger = softer.
    func setCompliance(id: UInt8, slope: UInt8) async throws
    /// Goal position in 0.1°, travel time in 10 ms units (0 = as fast as possible).
    func move(id: UInt8, position: Int16, time: UInt16) async throws
    func readStatus(id: UInt8) async throws -> ServoStatus
}

/// A servo bus that only exists in memory: each servo approaches its goal with a first-order
/// lag whose time constant grows with the compliance slope. Good enough to drive the UI.
public actor MockServoDriver: ServoDriver {
    public nonisolated let name = "Simulated servos"

    private struct Servo {
        var torque = false
        var goal: Int16 = 0
        var position: Double = 0
        var compliance: UInt8 = 0xFF
        var maxTorque: UInt8 = 100
        var lastUpdate = ContinuousClock.now
    }

    private var servos: [UInt8: Servo] = [:]
    private var isOpen = false
    /// Offset reported as "mechanical zero", to exercise zeroing code.
    public var restingPosition: Int16 = 0

    public init() {}

    private func servo(_ id: UInt8) -> Servo {
        var s = servos[id] ?? Servo(position: Double(restingPosition))
        let now = ContinuousClock.now
        let dt = max(0, (now - s.lastUpdate).seconds)
        if s.torque {
            // 0x32 ≈ 60 ms, 0xFF ≈ 250 ms time constant.
            let tau = 0.04 + 0.21 * Double(s.compliance) / 255
            let alpha = 1 - exp(-dt / tau)
            s.position += (Double(s.goal) - s.position) * alpha
        }
        s.lastUpdate = now
        servos[id] = s
        return s
    }

    public func open() async throws { isOpen = true }
    public func close() async { isOpen = false }

    public func setTorque(id: UInt8, enabled: Bool) async throws {
        guard isOpen else { throw ServoError.notOpen }
        var s = servo(id); s.torque = enabled; servos[id] = s
    }

    public func setMaxTorque(id: UInt8, percent: UInt8) async throws {
        guard isOpen else { throw ServoError.notOpen }
        var s = servo(id); s.maxTorque = percent; servos[id] = s
    }

    public func setCompliance(id: UInt8, slope: UInt8) async throws {
        guard isOpen else { throw ServoError.notOpen }
        var s = servo(id); s.compliance = slope; servos[id] = s
    }

    public func move(id: UInt8, position: Int16, time: UInt16) async throws {
        guard isOpen else { throw ServoError.notOpen }
        var s = servo(id); s.goal = position; servos[id] = s
    }

    public func readStatus(id: UInt8) async throws -> ServoStatus {
        guard isOpen else { throw ServoError.notOpen }
        let s = servo(id)
        let load = s.torque ? Int16(min(2000, abs(Double(s.goal) - s.position) * 2)) : 0
        return ServoStatus(position: Int16(s.position.rounded()), speed: 0, current: load, temperature: 32, voltage: 740)
    }
}
