import Foundation

/// EMG-to-quasi-tension FIR filter (Koike & Kawato).
///
/// Impulse response h(t) = 6.44 (e^(-10.8 t) - e^(-16.52 t)), sampled every
/// `1/sampleRate` seconds over 0.5 s and normalised to unit gain, exactly as the
/// legacy `CKoikeFilter` (100 taps at 200 Hz).
public struct KoikeFilter: Sendable {
    public let coefficients: [Double]
    private var history: [Double]
    private var head = 0

    public init(sampleRate: Double = 200, duration: Double = 0.5) {
        let taps = max(1, Int((sampleRate * duration).rounded()))
        var c = (0..<taps).map { i -> Double in
            let t = Double(i) / sampleRate
            return 6.44 * (exp(-10.8 * t) - exp(-16.52 * t))
        }
        let sum = c.reduce(0, +)
        c = c.map { $0 / sum }
        coefficients = c
        history = Array(repeating: 0, count: taps)
    }

    public var tapCount: Int { coefficients.count }

    public mutating func reset() {
        history = Array(repeating: 0, count: coefficients.count)
        head = 0
    }

    /// Push one input sample and return the filtered output.
    public mutating func push(_ x: Double) -> Double {
        let n = coefficients.count
        history[head] = x
        var acc = 0.0
        var idx = head
        for k in 0..<n {
            acc += coefficients[k] * history[idx]
            idx = idx == 0 ? n - 1 : idx - 1
        }
        head = (head + 1) % n
        return acc
    }
}
