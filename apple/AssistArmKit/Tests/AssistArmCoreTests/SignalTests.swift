import XCTest
@testable import AssistArmCore

final class SignalTests: XCTestCase {
    func testKoikeCoefficientsMatchLegacy() {
        let f = KoikeFilter()
        XCTAssertEqual(f.tapCount, 100)
        XCTAssertEqual(f.coefficients.reduce(0, +), 1, accuracy: 1e-12)
        // Legacy: coef[i] = 6.44*(exp(-10.8 t) - exp(-16.52 t)), t = 0.005 i, then normalised.
        var raw = (0..<100).map { i -> Double in let t = 0.005 * Double(i); return 6.44 * (exp(-10.8 * t) - exp(-16.52 * t)) }
        let sum = raw.reduce(0, +)
        raw = raw.map { $0 / sum }
        for i in 0..<100 { XCTAssertEqual(f.coefficients[i], raw[i], accuracy: 1e-15) }
        XCTAssertEqual(f.coefficients[0], 0, accuracy: 1e-15)  // h(0) = 0
        XCTAssertGreaterThan(f.coefficients[20], f.coefficients[90])
    }

    func testKoikeStepResponseReachesUnity() {
        var f = KoikeFilter()
        var y = 0.0
        for _ in 0..<100 { y = f.push(1) }
        XCTAssertEqual(y, 1, accuracy: 1e-9)
        for _ in 0..<100 { y = f.push(0) }
        XCTAssertEqual(y, 0, accuracy: 1e-9)
    }

    func testQuasiTensionDecimatesAndRectifies() {
        var p = QuasiTensionProcessor(inputRate: 2000, channelCount: 2)
        XCTAssertEqual(p.decimation, 10)
        XCTAssertEqual(p.outputRate, 200)
        // Constant ±1 square wave on ch0, zeros on ch1: mean |x| = 1 on ch0.
        var samples: [Float] = []
        for row in 0..<2000 { samples += [row % 2 == 0 ? 1 : -1, 0] }
        let out = p.process(EMGBlock(sampleRate: 2000, channelCount: 2, samples: samples, startIndex: 0))
        XCTAssertEqual(out.count, 200)
        XCTAssertEqual(out.last!.index, 199)
        XCTAssertEqual(out.last!.values[0], 1, accuracy: 1e-9)   // 1 s in, filter has settled
        XCTAssertEqual(out.last!.values[1], 0, accuracy: 1e-12)
        XCTAssertLessThan(out[5].values[0], 0.5)                   // still rising early on

        // Partial blocks carry over.
        var q = QuasiTensionProcessor(inputRate: 2000, channelCount: 1)
        let a = q.process(EMGBlock(sampleRate: 2000, channelCount: 1, samples: Array(repeating: 1, count: 7), startIndex: 0))
        let b = q.process(EMGBlock(sampleRate: 2000, channelCount: 1, samples: Array(repeating: 1, count: 3), startIndex: 7))
        XCTAssertEqual(a.count, 0)
        XCTAssertEqual(b.count, 1)
    }

    func testMinMaxCalibrationSkipsFirstSecond() {
        var c = MinMaxCalibration(channelCount: 2, sampleRate: 200, discardSeconds: 1)
        for i in 0..<400 {
            // Huge transient in the first second must be ignored.
            let v = i < 200 ? 100.0 : Double(i % 10) / 10
            c.add(QuasiTensionSample(values: [v, v * 2], index: i))
        }
        let r = c.finish()
        XCTAssertEqual(r.minimum, [0, 0])
        XCTAssertEqual(r.maximum, [0.9, 1.8])
        XCTAssertEqual(c.elapsedSeconds, 2, accuracy: 1e-9)
        XCTAssertEqual(r.normalize(0.45, channel: 0), 0.5, accuracy: 1e-12)
        XCTAssertEqual(r.normalize(-1, channel: 0), 0)
        XCTAssertEqual(r.normalize(5, channel: 1), 1)

        let empty = MinMaxCalibration(channelCount: 2).finish()
        XCTAssertEqual(empty, .identity(channelCount: 2))
    }
}
