import AssistArmCore
import Foundation

/// Fixed-length ring of multi-channel samples, written from any thread, read by the plots.
final class SeriesRing: @unchecked Sendable {
    struct Envelope {
        var mins: [Float]
        var maxs: [Float]
        var isEmpty: Bool { mins.isEmpty }
    }

    let channels: Int
    private(set) var capacity: Int
    private var data: [Float]
    private var writeRow = 0
    private var filled = 0
    private let lock = NSLock()

    init(channels: Int, capacity: Int) {
        self.channels = channels
        self.capacity = max(1, capacity)
        data = Array(repeating: 0, count: channels * self.capacity)
    }

    func reset(capacity: Int? = nil) {
        lock.withLock {
            if let capacity { self.capacity = max(1, capacity) }
            data = Array(repeating: 0, count: channels * self.capacity)
            writeRow = 0
            filled = 0
        }
    }

    func push(_ values: [Float]) {
        lock.withLock {
            let base = writeRow * channels
            for c in 0..<channels { data[base + c] = c < values.count ? values[c] : .nan }
            writeRow = (writeRow + 1) % capacity
            filled = min(filled + 1, capacity)
        }
    }

    func push(block: EMGBlock) {
        lock.withLock {
            for row in 0..<block.rowCount {
                let base = writeRow * channels
                for c in 0..<channels { data[base + c] = c < block.channelCount ? block.value(row: row, channel: c) : .nan }
                writeRow = (writeRow + 1) % capacity
                filled = min(filled + 1, capacity)
            }
        }
    }

    var latest: [Float]? {
        lock.withLock {
            guard filled > 0 else { return nil }
            let row = (writeRow - 1 + capacity) % capacity
            return Array(data[(row * channels)..<(row * channels + channels)])
        }
    }

    /// Min/max per bin over the whole window (oldest first) for one channel. Empty bins are NaN.
    func envelope(channel: Int, bins: Int) -> Envelope {
        lock.withLock {
            guard filled > 0, bins > 0 else { return Envelope(mins: [], maxs: []) }
            let binCount = min(bins, capacity)
            var mins = [Float](repeating: .nan, count: binCount)
            var maxs = [Float](repeating: .nan, count: binCount)
            let oldest = (writeRow - filled + capacity) % capacity
            let offset = capacity - filled
            for k in 0..<filled {
                let v = data[((oldest + k) % capacity) * channels + channel]
                guard !v.isNaN else { continue }
                let bin = (offset + k) * binCount / capacity
                if mins[bin].isNaN || v < mins[bin] { mins[bin] = v }
                if maxs[bin].isNaN || v > maxs[bin] { maxs[bin] = v }
            }
            return Envelope(mins: mins, maxs: maxs)
        }
    }
}

/// All plotted series for one EMG source: raw EMG at the source rate, activation at the
/// quasi-tension rate, joint angle and stiffness at the control rate.
final class PlotBuffers: @unchecked Sendable {
    private(set) var window: Double
    let channelCount: Int
    let emg: SeriesRing
    /// Normalised activation 0…1 (or raw quasi-tension before calibration).
    let activation: SeriesRing
    /// [target°, measured left°, measured right° (mirrored back)]
    let angle: SeriesRing
    /// [normalised stiffness 0…100, compliance byte]
    let stiffness: SeriesRing

    init(channelCount: Int, emgRate: Double, qtRate: Double, controlRate: Double, window: Double) {
        self.channelCount = channelCount
        self.window = window
        emg = SeriesRing(channels: channelCount, capacity: Int(emgRate * window))
        activation = SeriesRing(channels: channelCount, capacity: Int(qtRate * window))
        angle = SeriesRing(channels: 3, capacity: Int(controlRate * window))
        stiffness = SeriesRing(channels: 2, capacity: Int(controlRate * window))
    }

    func resize(window: Double, emgRate: Double, qtRate: Double, controlRate: Double) {
        self.window = window
        emg.reset(capacity: Int(emgRate * window))
        activation.reset(capacity: Int(qtRate * window))
        angle.reset(capacity: Int(controlRate * window))
        stiffness.reset(capacity: Int(controlRate * window))
    }

    func clearControl() {
        angle.reset()
        stiffness.reset()
    }

    func push(_ sample: ControlSample, configuration c: ControlConfiguration) {
        let left = sample.statusLeft.map { Float(Double($0.position - c.zeroLeft) / c.unitsPerDegree) } ?? .nan
        let rightRaw = sample.statusRight.map { Double($0.position - c.zeroRight) / c.unitsPerDegree }
        let right = rightRaw.map { Float(c.mirrorRight ? -$0 : $0) } ?? .nan
        angle.push([Float(sample.targetDegrees), left, right])
        stiffness.push([Float(sample.estimate.normalizedStiffness), Float(sample.compliance)])
    }
}
