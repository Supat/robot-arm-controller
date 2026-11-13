import AssistArmCore
import Foundation
import Network

/// A byte pipe to the servo bus: a local serial port, or a TCP bridge for devices that have
/// no serial access (an iPad talking to a small board on the robot, for instance).
public protocol ServoTransport: AnyObject, Sendable {
    var name: String { get }
    func open() async throws
    func close() async
    func write(_ bytes: [UInt8]) async throws
    /// Wait up to `timeout` for bytes; returns whatever arrived (possibly fewer than `count`).
    func read(count: Int, timeout: Duration) async throws -> [UInt8]
    func discardInput() async throws
}

/// TCP transport for a serial bridge that forwards raw bytes to an RS-485 adapter.
public final class TCPServoTransport: ServoTransport, @unchecked Sendable {
    public let host: String
    public let port: UInt16
    public var name: String { "tcp://\(host):\(port)" }

    private let queue = DispatchQueue(label: "assistarm.servo.tcp")
    private var connection: NWConnection?
    private let lock = NSLock()
    private var pending: [UInt8] = []

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    public func open() async throws {
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let once = ResumeOnce()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { cont.resume() }
                case .failed(let e): once.run { cont.resume(throwing: ServoError.io(e.localizedDescription)) }
                case .cancelled: once.run { cont.resume(throwing: ServoError.io("cancelled")) }
                default: break
                }
            }
            conn.start(queue: queue)
        }
        connection = conn
        receiveLoop(conn)
    }

    private func receiveLoop(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { lock.withLock { pending += data } }
            if error == nil && !isComplete { receiveLoop(conn) }
        }
    }

    public func close() async {
        connection?.cancel()
        connection = nil
    }

    public func write(_ bytes: [UInt8]) async throws {
        guard let connection else { throw ServoError.notOpen }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error { cont.resume(throwing: ServoError.io(error.localizedDescription)) } else { cont.resume() }
            })
        }
    }

    public func read(count: Int, timeout: Duration) async throws -> [UInt8] {
        guard connection != nil else { throw ServoError.notOpen }
        let deadline = ContinuousClock.now + timeout
        while true {
            let got: [UInt8] = lock.withLock {
                let n = min(count, pending.count)
                let out = Array(pending.prefix(n))
                pending.removeFirst(n)
                return out
            }
            if got.count == count || ContinuousClock.now >= deadline { return got }
            if !got.isEmpty {
                // Partial read: wait briefly for the rest, then return what we have.
                try? await Task.sleep(for: .milliseconds(2))
                let more = try await read(count: count - got.count, timeout: min(.milliseconds(20), deadline - ContinuousClock.now))
                return got + more
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    public func discardInput() async throws {
        lock.withLock { pending.removeAll() }
    }
}

/// Runs its closure the first time only; later calls are ignored.
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}
