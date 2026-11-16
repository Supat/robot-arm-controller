import AssistArmCore
import Foundation
import TrignoKit

/// EMG from a `TrignoSession` (Delsys Trigno SDK server), picking the EMG-port columns of the
/// sensors used as the joint's muscles. The session must already be open (`open()`).
public final class TrignoEMGSource: EMGSource, @unchecked Sendable {
    public let session: TrignoSession
    public let system: SystemInfo
    /// 0-based columns in the 16-channel EMG frame, in muscle order.
    public let columns: [Int]
    public let sampleRate: Double
    public var channelCount: Int { columns.count }
    public let name: String
    /// Let the hardware trigger start the stream instead of sending START.
    public var waitForTrigger = false

    public init(session: TrignoSession, system: SystemInfo, columns: [Int]) {
        precondition(!columns.isEmpty)
        self.session = session
        self.system = system
        self.columns = columns
        self.sampleRate = system.emgRate
        self.name = "Trigno (\(system.baseSerial))"
    }

    /// Convenience: the EMG channels of the given sensor slots, one column per sensor.
    public static func columns(forSlots slots: [Int], in system: SystemInfo) -> [Int]? {
        var cols: [Int] = []
        for slot in slots {
            guard let sensor = system.sensors.first(where: { $0.slot == slot }),
                  let channel = sensor.channels(on: .emg).first else { return nil }
            cols.append(channel.column)
        }
        return cols
    }

    public func start(_ sink: @escaping @Sendable (EMGBlock) -> Void) async throws {
        let columns = self.columns
        let rate = sampleRate
        // The server only obeys START from its master connection, and answers anything else
        // "CONNECTION NOT MASTER" without streaming. A connection left over from a dropped
        // link keeps the role, so claim it on every start.
        _ = try await session.client.send("MASTER")
        try await startSession(columns: columns, rate: rate, sink)
        guard !waitForTrigger else { return }
        // START can be refused with a reply the session does not treat as an error, so make
        // sure samples really arrive.
        let deadline = ContinuousClock.now + .seconds(3)
        while await !session.hasData() {
            if ContinuousClock.now >= deadline {
                await session.stop()
                throw TrignoEMGError.noData
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func startSession(columns: [Int], rate: Double, _ sink: @escaping @Sendable (EMGBlock) -> Void) async throws {
        try await session.start(waitForTrigger: waitForTrigger) { block in
            guard block.port == .emg else { return }
            let rows = block.rowCount
            var samples = [Float](repeating: 0, count: rows * columns.count)
            for row in 0..<rows {
                for (i, column) in columns.enumerated() {
                    samples[row * columns.count + i] = block.value(row: row, column: column)
                }
            }
            sink(EMGBlock(sampleRate: rate, channelCount: columns.count, samples: samples,
                          startIndex: block.startIndex, hostTime: block.hostTime))
        }
    }

    public func stop() async {
        await session.stop()
    }
}

public enum TrignoEMGError: LocalizedError, Sendable {
    case noData

    public var errorDescription: String? {
        switch self {
        case .noData:
            "The Trigno server accepted the connection but sent no EMG samples. Check the network link to the Trigno Control Utility, then reconnect."
        }
    }
}
