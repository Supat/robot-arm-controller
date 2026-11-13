import Foundation

/// Anything that delivers raw EMG blocks: the Trigno SDK, an LSL inlet, a file, a synthesiser.
public protocol EMGSource: AnyObject, Sendable {
    var name: String { get }
    var channelCount: Int { get }
    var sampleRate: Double { get }
    /// Begin delivering blocks to `sink` (called from an arbitrary thread).
    func start(_ sink: @escaping @Sendable (EMGBlock) -> Void) async throws
    func stop() async
}

/// Two synthetic muscles for development without sensors: band-limited noise under a slowly
/// alternating envelope, with a co-contraction burst every cycle. Amplitudes are in volts,
/// about what a Trigno sensor reports.
public final class SyntheticEMGSource: EMGSource, @unchecked Sendable {
    public let name = "Synthetic EMG"
    public let channelCount: Int
    public let sampleRate: Double
    public var amplitude: Float = 2e-4
    public var periodSeconds: Double = 8

    private let blockSeconds = 0.01
    private var task: Task<Void, Never>?
    private let lock = NSLock()

    public init(channelCount: Int = 2, sampleRate: Double = 2000) {
        self.channelCount = channelCount
        self.sampleRate = sampleRate
    }

    public func start(_ sink: @escaping @Sendable (EMGBlock) -> Void) async throws {
        await stop()
        let rows = max(1, Int(sampleRate * blockSeconds))
        let rate = sampleRate, channels = channelCount, amp = amplitude, period = periodSeconds
        let t = Task.detached(priority: .userInitiated) {
            var index = 0
            var rng = SystemRandomNumberGenerator()
            var lowpass = [Float](repeating: 0, count: channels)
            let start = ContinuousClock.now
            while !Task.isCancelled {
                var samples = [Float](repeating: 0, count: rows * channels)
                for r in 0..<rows {
                    let time = Double(index + r) / rate
                    let phase = (time / period).truncatingRemainder(dividingBy: 1)
                    // 0…0.4: muscle 0, 0.5…0.9: muscle 1, 0.92…1: both.
                    var envelope = [Double](repeating: 0.05, count: channels)
                    if phase < 0.4 { envelope[0] += sin(.pi * phase / 0.4) }
                    if phase >= 0.5 && phase < 0.9, channels > 1 { envelope[1] += sin(.pi * (phase - 0.5) / 0.4) }
                    if phase >= 0.92 { for c in 0..<channels { envelope[c] += 0.8 } }
                    for c in 0..<channels {
                        // White noise lightly smoothed so it looks like 20–450 Hz EMG.
                        let white = Float.random(in: -1...1, using: &rng)
                        lowpass[c] += 0.6 * (white - lowpass[c])
                        samples[r * channels + c] = lowpass[c] * amp * Float(envelope[c])
                    }
                }
                sink(EMGBlock(sampleRate: rate, channelCount: channels, samples: samples, startIndex: index))
                index += rows
                let due = start + .seconds(Double(index) / rate)
                try? await Task.sleep(until: due, clock: .continuous)
            }
        }
        lock.withLock { task = t }
    }

    public func stop() async {
        let t = lock.withLock { let t = task; task = nil; return t }
        t?.cancel()
    }
}
