import Foundation

/// CSV log of every control tick, replacing the legacy `./LinearData/*.txt` dumps.
public final class TelemetryLog: @unchecked Sendable {
    public let url: URL
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "assistarm.telemetry")
    private let channelCount: Int
    private var buffer = ""

    public init(url: URL, channelCount: Int) throws {
        self.url = url
        self.channelCount = channelCount
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var header = ["time_s"]
        header += (0..<channelCount).map { "qt\($0 + 1)" }
        header += (0..<channelCount).map { "activation\($0 + 1)" }
        header += ["eq_deg", "stiffness", "nstiffness", "compliance", "target_deg", "goal_left", "goal_right",
                   "pos_left_deg", "pos_right_deg", "current_left_mA", "current_right_mA"]
        try Data((header.joined(separator: ",") + "\n").utf8).write(to: url)
        handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
    }

    public func write(_ s: ControlSample) {
        var fields: [String] = [f(s.time)]
        fields += s.quasiTension.map { f($0, digits: 8) }
        fields += s.activation.map { f($0) }
        fields += [f(s.estimate.equilibriumDegrees), f(s.estimate.stiffness), f(s.estimate.normalizedStiffness),
                   String(s.compliance), f(s.targetDegrees), String(s.targetLeft), String(s.targetRight),
                   s.statusLeft.map { f($0.positionDegrees) } ?? "", s.statusRight.map { f($0.positionDegrees) } ?? "",
                   s.statusLeft.map { String($0.current) } ?? "", s.statusRight.map { String($0.current) } ?? ""]
        let line = fields.joined(separator: ",") + "\n"
        queue.async { [self] in
            buffer += line
            if buffer.utf8.count > 16 * 1024 { flush() }
        }
    }

    private func flush() {
        guard !buffer.isEmpty else { return }
        handle.write(Data(buffer.utf8))
        buffer = ""
    }

    public func finish() throws {
        try queue.sync {
            flush()
            try handle.close()
        }
    }

    private func f(_ v: Double, digits: Int = 4) -> String {
        String(format: "%.\(digits)f", v)
    }
}
