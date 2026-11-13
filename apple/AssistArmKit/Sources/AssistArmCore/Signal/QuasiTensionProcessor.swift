import Foundation

/// A block of raw EMG samples from any source, row-major `samples[row * channelCount + channel]`.
public struct EMGBlock: Sendable {
    public let sampleRate: Double
    public let channelCount: Int
    public let samples: [Float]
    /// Index of the first row since the source started.
    public let startIndex: Int
    public let hostTime: Date

    public init(sampleRate: Double, channelCount: Int, samples: [Float], startIndex: Int, hostTime: Date = Date()) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.samples = samples
        self.startIndex = startIndex
        self.hostTime = hostTime
    }

    public var rowCount: Int { channelCount == 0 ? 0 : samples.count / channelCount }

    @inlinable
    public func value(row: Int, channel: Int) -> Float { samples[row * channelCount + channel] }
}

/// One quasi-tension sample for all channels, at `QuasiTensionProcessor.outputRate`.
public struct QuasiTensionSample: Sendable {
    /// Rectified, averaged, Koike-filtered EMG per channel (same units as the input).
    public let values: [Double]
    /// Index of this sample since the processor was reset.
    public let index: Int
}

/// Turns raw EMG into quasi-tension the way the legacy `SimpleNiControl::GetData` did:
/// rectify, average every `decimation` samples (2 kHz → 200 Hz), then the Koike FIR.
public struct QuasiTensionProcessor: Sendable {
    public let inputRate: Double
    public let outputRate: Double
    public let channelCount: Int
    public let decimation: Int

    private var filters: [KoikeFilter]
    private var accumulators: [Double]
    private var accumulated = 0
    private var outputIndex = 0

    public init(inputRate: Double, channelCount: Int, outputRate: Double = 200) {
        precondition(channelCount > 0)
        self.inputRate = inputRate
        self.channelCount = channelCount
        self.decimation = max(1, Int((inputRate / outputRate).rounded()))
        self.outputRate = inputRate / Double(decimation)
        filters = Array(repeating: KoikeFilter(sampleRate: self.outputRate), count: channelCount)
        accumulators = Array(repeating: 0, count: channelCount)
    }

    public mutating func reset() {
        for i in filters.indices { filters[i].reset() }
        accumulators = Array(repeating: 0, count: channelCount)
        accumulated = 0
        outputIndex = 0
    }

    /// Process a block and return the quasi-tension samples it completed (0 or more).
    public mutating func process(_ block: EMGBlock) -> [QuasiTensionSample] {
        precondition(block.channelCount == channelCount, "channel count mismatch")
        var out: [QuasiTensionSample] = []
        out.reserveCapacity(block.rowCount / decimation + 1)
        for row in 0..<block.rowCount {
            for ch in 0..<channelCount {
                accumulators[ch] += abs(Double(block.value(row: row, channel: ch)))
            }
            accumulated += 1
            if accumulated == decimation {
                var values = [Double](repeating: 0, count: channelCount)
                for ch in 0..<channelCount {
                    values[ch] = filters[ch].push(accumulators[ch] / Double(decimation))
                    accumulators[ch] = 0
                }
                accumulated = 0
                out.append(QuasiTensionSample(values: values, index: outputIndex))
                outputIndex += 1
            }
        }
        return out
    }
}
