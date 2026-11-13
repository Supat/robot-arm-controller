import AssistArmCore
import CLSL
import Foundation

/// An LSL stream found on the network.
public struct LSLStreamDescription: Identifiable, Hashable, Sendable {
    public var name: String
    public var type: String
    public var sourceID: String
    public var hostname: String
    public var channelCount: Int
    public var nominalRate: Double
    public var channelLabels: [String]
    public var id: String { "\(sourceID)@\(hostname)/\(name)" }
}

public enum LSLError: LocalizedError, Sendable {
    case streamNotFound(String)
    case openFailed(Int32)
    case badColumns

    public var errorDescription: String? {
        switch self {
        case .streamNotFound(let name): "No LSL stream named \"\(name)\" was found."
        case .openFailed(let code): "Could not open the LSL stream (error \(code))."
        case .badColumns: "Requested channel columns are outside the stream."
        }
    }
}

/// EMG pulled from a Lab Streaming Layer inlet, e.g. the Trigno app's "Delsys" outlet
/// (16 columns, column n = sensor slot n+1) when that app is already streaming.
public final class LSLEMGSource: EMGSource, @unchecked Sendable {
    public let streamName: String
    public let columns: [Int]
    public private(set) var sampleRate: Double
    public var channelCount: Int { columns.count }
    public var name: String { "LSL \"\(streamName)\"" }
    public var resolveTimeout: Double = 5

    private var inlet: InletBox?
    private var thread: Thread?
    private let stopFlag = NSLock()
    private var stopping = false

    public init(streamName: String = "Delsys", columns: [Int], nominalRate: Double = 2000) {
        self.streamName = streamName
        self.columns = columns
        self.sampleRate = nominalRate
    }

    /// Streams visible on the network right now.
    public static func resolveAll(timeout: Double = 2) -> [LSLStreamDescription] {
        var infos = [lsl_streaminfo?](repeating: nil, count: 32)
        let n = infos.withUnsafeMutableBufferPointer { lsl_resolve_all($0.baseAddress, 32, timeout) }
        var out: [LSLStreamDescription] = []
        for i in 0..<Int(max(0, n)) {
            guard let info = infos[i] else { continue }
            out.append(describe(info))
            lsl_destroy_streaminfo(info)
        }
        return out
    }

    private static func describe(_ info: lsl_streaminfo) -> LSLStreamDescription {
        func s(_ p: UnsafePointer<CChar>?) -> String { p.map { String(cString: $0) } ?? "" }
        var labels: [String] = []
        let channels = lsl_child(lsl_get_desc(info), "channels")
        var ch = lsl_first_child(channels)
        while lsl_empty(ch) == 0 {
            labels.append(s(lsl_child_value_n(ch, "label")))
            ch = lsl_next_sibling(ch)
        }
        return LSLStreamDescription(name: s(lsl_get_name(info)), type: s(lsl_get_type(info)), sourceID: s(lsl_get_source_id(info)),
                                    hostname: s(lsl_get_hostname(info)), channelCount: Int(lsl_get_channel_count(info)),
                                    nominalRate: lsl_get_nominal_srate(info), channelLabels: labels)
    }

    public func start(_ sink: @escaping @Sendable (EMGBlock) -> Void) async throws {
        await stop()
        var found = [lsl_streaminfo?](repeating: nil, count: 1)
        let n = found.withUnsafeMutableBufferPointer { lsl_resolve_byprop($0.baseAddress, 1, "name", streamName, 1, resolveTimeout) }
        guard n > 0, let info = found[0] else { throw LSLError.streamNotFound(streamName) }
        defer { lsl_destroy_streaminfo(info) }
        let streamChannels = Int(lsl_get_channel_count(info))
        guard columns.allSatisfy({ $0 >= 0 && $0 < streamChannels }) else { throw LSLError.badColumns }
        let rate = lsl_get_nominal_srate(info)
        if rate > 0 { sampleRate = rate }

        guard let raw = lsl_create_inlet(info, 360, LSL_NO_PREFERENCE, 1) else { throw LSLError.openFailed(-1) }
        var code: Int32 = 0
        lsl_open_stream(raw, resolveTimeout, &code)
        guard code == 0 else { lsl_destroy_inlet(raw); throw LSLError.openFailed(code) }
        let inlet = InletBox(raw)
        self.inlet = inlet
        stopFlag.withLock { stopping = false }

        let columns = self.columns, sampleRate = self.sampleRate
        let thread = Thread { [weak self] in
            let maxRows = 512
            var data = [Float](repeating: 0, count: maxRows * streamChannels)
            var stamps = [Double](repeating: 0, count: maxRows)
            var index = 0
            while let self, !self.stopFlag.withLock({ self.stopping }) {
                var ec: Int32 = 0
                let elements = data.withUnsafeMutableBufferPointer { d in
                    stamps.withUnsafeMutableBufferPointer { t in
                        lsl_pull_chunk_f(inlet.raw, d.baseAddress, t.baseAddress, UInt(d.count), UInt(t.count), 0.1, &ec)
                    }
                }
                guard ec == 0 else { break }
                let rows = Int(elements) / streamChannels
                guard rows > 0 else { continue }
                var samples = [Float](repeating: 0, count: rows * columns.count)
                for row in 0..<rows {
                    for (i, column) in columns.enumerated() {
                        samples[row * columns.count + i] = data[row * streamChannels + column]
                    }
                }
                sink(EMGBlock(sampleRate: sampleRate, channelCount: columns.count, samples: samples, startIndex: index))
                index += rows
            }
        }
        thread.name = "assistarm.lsl"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    public func stop() async {
        stopFlag.withLock { stopping = true }
        while let t = thread, !t.isFinished { try? await Task.sleep(for: .milliseconds(10)) }
        thread = nil
        if let inlet { lsl_destroy_inlet(inlet.raw); self.inlet = nil }
    }
}

/// liblsl handles are plain pointers owned by this source; the box lets the reader thread hold one.
private final class InletBox: @unchecked Sendable {
    let raw: lsl_inlet
    init(_ raw: lsl_inlet) { self.raw = raw }
}
