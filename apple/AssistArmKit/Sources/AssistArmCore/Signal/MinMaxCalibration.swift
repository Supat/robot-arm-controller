import Foundation

/// Per-channel quasi-tension range used to normalise activation to 0…1.
public struct ActivationRange: Codable, Sendable, Equatable {
    public var minimum: [Double]
    public var maximum: [Double]

    public init(minimum: [Double], maximum: [Double]) {
        precondition(minimum.count == maximum.count)
        self.minimum = minimum
        self.maximum = maximum
    }

    /// Range that passes values through unchanged (0 → 0, 1 → 1), as the legacy code used when
    /// too few samples were collected.
    public static func identity(channelCount: Int) -> ActivationRange {
        ActivationRange(minimum: Array(repeating: 0, count: channelCount), maximum: Array(repeating: 1, count: channelCount))
    }

    public var channelCount: Int { minimum.count }

    /// Legacy `CDaqControl::GetNormalizedQt`: clamp to the calibrated range and scale to 0…1.
    public func normalize(_ value: Double, channel: Int) -> Double {
        let lo = minimum[channel], hi = maximum[channel]
        guard hi > lo else { return 0 }
        if value >= hi { return 1 }
        if value <= lo { return 0 }
        return (value - lo) / (hi - lo)
    }

    public func normalize(_ values: [Double]) -> [Double] {
        values.enumerated().map { normalize($1, channel: $0) }
    }
}

/// Collects quasi-tension while the user relaxes and contracts maximally, then yields the
/// min/max range. The first `discardSeconds` are skipped (legacy skipped 200 samples = 1 s)
/// so the filter's start-up transient is not counted.
public struct MinMaxCalibration: Sendable {
    public let channelCount: Int
    public let discardSeconds: Double
    private let sampleRate: Double
    private var minimum: [Double]
    private var maximum: [Double]
    private(set) public var sampleCount = 0
    private(set) public var usedCount = 0

    public init(channelCount: Int, sampleRate: Double = 200, discardSeconds: Double = 1.0) {
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        self.discardSeconds = discardSeconds
        minimum = Array(repeating: .infinity, count: channelCount)
        maximum = Array(repeating: -.infinity, count: channelCount)
    }

    public mutating func add(_ sample: QuasiTensionSample) {
        sampleCount += 1
        guard Double(sampleCount) > discardSeconds * sampleRate else { return }
        usedCount += 1
        for ch in 0..<channelCount {
            minimum[ch] = min(minimum[ch], sample.values[ch])
            maximum[ch] = max(maximum[ch], sample.values[ch])
        }
    }

    public var elapsedSeconds: Double { Double(sampleCount) / sampleRate }

    /// Current running range, or nil until at least one sample has been used.
    public var range: ActivationRange? {
        guard usedCount > 0 else { return nil }
        return ActivationRange(minimum: minimum, maximum: maximum)
    }

    /// Final range; falls back to the identity range when nothing usable was collected,
    /// as the legacy program did.
    public func finish() -> ActivationRange {
        range ?? .identity(channelCount: channelCount)
    }
}
