import XCTest
@testable import AssistArmCore

/// Scripted EMG: constant amplitude per channel, delivered quickly.
final class ScriptedEMGSource: EMGSource, @unchecked Sendable {
    let name = "scripted"
    let channelCount = 2
    let sampleRate = 2000.0
    var amplitudes: [Float]
    private var task: Task<Void, Never>?
    init(amplitudes: [Float]) { self.amplitudes = amplitudes }

    func start(_ sink: @escaping @Sendable (EMGBlock) -> Void) async throws {
        let amps = amplitudes
        task = Task.detached {
            var index = 0
            while !Task.isCancelled {
                var s = [Float](repeating: 0, count: 20 * 2)
                for r in 0..<20 { for c in 0..<2 { s[r * 2 + c] = (r % 2 == 0 ? 1 : -1) * amps[c] } }
                sink(EMGBlock(sampleRate: 2000, channelCount: 2, samples: s, startIndex: index))
                index += 20
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
    }
    func stop() async { task?.cancel(); task = nil }
}

final class ControllerTests: XCTestCase {
    func testCalibrationThenControlDrivesMockServos() async throws {
        let source = ScriptedEMGSource(amplitudes: [1, 0])
        let pipeline = QuasiTensionPipeline(source: source)
        let calibrator = await ActivationCalibrator(pipeline: pipeline)
        try await calibrator.start()
        try await Task.sleep(for: .milliseconds(400))
        let range = await calibrator.stop()
        // Scripted source is faster than real time, so plenty of samples arrive.
        XCTAssertGreaterThan(range.maximum[0], 0.5)
        XCTAssertEqual(range.maximum[1], 0, accuracy: 1e-9)

        // Full activation on muscle 1 and none on muscle 2.
        let fixed = ActivationRange(minimum: [0, 0], maximum: [1, 1])
        let servo = MockServoDriver()
        try await servo.open()
        var config = ControlConfiguration()
        config.updateRate = 200
        config.statusPollRate = 50
        config.stiffness = StiffnessPolicy(mode: .highOrLow, threshold: 40)
        let estimator = try JointEstimator.legacyDefault()
        let controller = try await AssistController(pipeline: pipeline, servo: servo, estimator: estimator, range: fixed, configuration: config)

        let box = SampleBox()
        await controller.addSampleSink { box.append($0) }
        try await controller.start()
        try await Task.sleep(for: .milliseconds(800))
        await controller.stop()

        let samples = box.all
        XCTAssertGreaterThan(samples.count, 20)
        let last = samples.last!
        XCTAssertEqual(last.activation[0], 1, accuracy: 1e-6)
        XCTAssertEqual(last.activation[1], 0, accuracy: 1e-6)
        let expected = estimator.estimate([1, 0])
        XCTAssertEqual(last.estimate, expected)
        XCTAssertEqual(last.targetDegrees, min(90, max(-90, expected.equilibriumDegrees)), accuracy: 1e-9)
        XCTAssertEqual(Int(last.targetLeft), Int((last.targetDegrees * 10).rounded()))
        XCTAssertEqual(Int(last.targetRight), -Int((last.targetDegrees * 10).rounded()))
        XCTAssertEqual(last.compliance, expected.normalizedStiffness >= 40 ? 0x32 : 0xFF)
        // The mock servo moved towards the goal and status was read back.
        let pos = try XCTUnwrap(last.statusLeft).position
        XCTAssertGreaterThan(abs(Int(pos)), abs(Int(last.targetLeft)) / 4)
        let status = try await servo.readStatus(id: 1)
        XCTAssertEqual(status.current, 0, "torque is off after stop")
    }

    func testChannelMismatchIsRejected() async throws {
        let pipeline = QuasiTensionPipeline(source: SyntheticEMGSource(channelCount: 3))
        do {
            _ = try await AssistController(pipeline: pipeline, servo: MockServoDriver(), estimator: try .legacyDefault(), range: .identity(channelCount: 3))
            XCTFail("expected mismatch")
        } catch ControllerError.channelMismatch(let s, let m) {
            XCTAssertEqual(s, 3); XCTAssertEqual(m, 2)
        }
    }

    func testTelemetryLogWritesCSV() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "assistarm-\(UUID().uuidString).csv")
        let log = try TelemetryLog(url: url, channelCount: 2)
        let est = JointEstimate(equilibrium: 0.5, stiffness: 100, normalizedStiffness: 42)
        log.write(ControlSample(time: 1.25, quasiTension: [1e-4, 2e-4], activation: [0.5, 1], estimate: est, compliance: 0x32,
                                targetLeft: 286, targetRight: -286, statusLeft: ServoStatus(position: 280, current: 12),
                                statusRight: nil, targetDegrees: 28.6))
        try log.finish()
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("time_s,qt1,qt2,activation1,activation2,eq_deg,"))
        XCTAssertEqual(lines[1], "1.2500,0.00010000,0.00020000,0.5000,1.0000,28.6479,100.0000,42.0000,50,28.6000,286,-286,28.0000,,12,")
    }
}

final class SampleBox: @unchecked Sendable {
    private var items: [ControlSample] = []
    private let lock = NSLock()
    func append(_ s: ControlSample) { lock.withLock { items.append(s) } }
    var all: [ControlSample] { lock.withLock { items } }
}
