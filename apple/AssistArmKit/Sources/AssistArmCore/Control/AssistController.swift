import Foundation

/// Servo-side settings of the control loop. Angles the servo understands are 0.1° units.
public struct ControlConfiguration: Codable, Sendable, Equatable {
    public var leftServoID: UInt8 = 1
    public var rightServoID: UInt8 = 2
    /// The right servo turns the opposite way (legacy: `-target + zero_R`).
    public var mirrorRight = true
    /// Positions read while the arm hung at rest after zeroing, 0.1° units.
    public var zeroLeft: Int16 = 0
    public var zeroRight: Int16 = 0
    /// Servo units per degree of joint angle. Futaba uses 10; the legacy code used 8.
    public var unitsPerDegree: Double = 10
    /// Joint angle clamp either side of zero, degrees (legacy ±90).
    public var angleLimitDegrees: Double = 90
    /// Control loop rate: EMG processing, model evaluation and compliance updates.
    public var updateRate: Double = 50
    /// How often a goal position is written to the servos. Futaba RS servos restart their motion
    /// on every goal command, so writing at the loop rate (50 Hz) makes them crawl at a fraction of
    /// full speed; on the bench 20 Hz tracked a sweeping goal with ~0.2 s lag and 10 Hz was similar.
    public var goalUpdateRate: Double = 20
    /// How often servo status (angle, current) is read back for display and logging.
    public var statusPollRate: Double = 5
    /// Legacy set 75 % at zeroing.
    public var maxTorquePercent: UInt8 = 75
    /// Travel time per goal, 10 ms units (0 = fastest). Non-zero values made tracking worse on the bench.
    public var moveTime: UInt16 = 0
    public var stiffness = StiffnessPolicy()

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case leftServoID, rightServoID, mirrorRight, zeroLeft, zeroRight, unitsPerDegree, angleLimitDegrees
        case updateRate, goalUpdateRate, statusPollRate, maxTorquePercent, moveTime, stiffness
    }

    /// Tolerates settings saved by older builds that lack newer keys.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        leftServoID = try c.decodeIfPresent(UInt8.self, forKey: .leftServoID) ?? leftServoID
        rightServoID = try c.decodeIfPresent(UInt8.self, forKey: .rightServoID) ?? rightServoID
        mirrorRight = try c.decodeIfPresent(Bool.self, forKey: .mirrorRight) ?? mirrorRight
        zeroLeft = try c.decodeIfPresent(Int16.self, forKey: .zeroLeft) ?? zeroLeft
        zeroRight = try c.decodeIfPresent(Int16.self, forKey: .zeroRight) ?? zeroRight
        unitsPerDegree = try c.decodeIfPresent(Double.self, forKey: .unitsPerDegree) ?? unitsPerDegree
        angleLimitDegrees = try c.decodeIfPresent(Double.self, forKey: .angleLimitDegrees) ?? angleLimitDegrees
        updateRate = try c.decodeIfPresent(Double.self, forKey: .updateRate) ?? updateRate
        goalUpdateRate = try c.decodeIfPresent(Double.self, forKey: .goalUpdateRate) ?? goalUpdateRate
        statusPollRate = try c.decodeIfPresent(Double.self, forKey: .statusPollRate) ?? statusPollRate
        maxTorquePercent = try c.decodeIfPresent(UInt8.self, forKey: .maxTorquePercent) ?? maxTorquePercent
        moveTime = try c.decodeIfPresent(UInt16.self, forKey: .moveTime) ?? moveTime
        stiffness = try c.decodeIfPresent(StiffnessPolicy.self, forKey: .stiffness) ?? stiffness
    }
}

/// One tick of the control loop, for plots and the CSV log.
public struct ControlSample: Sendable {
    /// Seconds since the controller started.
    public var time: Double
    public var quasiTension: [Double]
    public var activation: [Double]
    public var estimate: JointEstimate
    public var compliance: UInt8
    /// Commanded goals, 0.1° servo units, zero offsets included.
    public var targetLeft: Int16
    public var targetRight: Int16
    /// Last status read-back, if any (updated at `statusPollRate`).
    public var statusLeft: ServoStatus?
    public var statusRight: ServoStatus?

    /// Commanded joint angle, degrees, zero offset removed.
    public var targetDegrees: Double
}

public enum ControllerError: LocalizedError, Sendable {
    case channelMismatch(source: Int, model: Int)
    case notCalibrated

    public var errorDescription: String? {
        switch self {
        case .channelMismatch(let s, let m): "EMG source has \(s) channels but the model expects \(m)."
        case .notCalibrated: "Calibrate the activation range first."
        }
    }
}

/// The legacy `EstMykin` loop: quasi-tension → normalised activation → equilibrium angle and
/// stiffness → servo goals and compliance, at a fixed rate with periodic status read-back.
public actor AssistController {
    public let pipeline: QuasiTensionPipeline
    public let servo: ServoDriver
    public var estimator: JointEstimator
    public var range: ActivationRange
    public var configuration: ControlConfiguration

    public private(set) var isRunning = false
    private var loop: Task<Void, Never>?
    private var sampleSinks: [@Sendable (ControlSample) -> Void] = []
    private var errorSinks: [@Sendable (Error) -> Void] = []
    private var latest: QuasiTensionSample?
    private var compliance: UInt8?
    private var statusLeft: ServoStatus?
    private var statusRight: ServoStatus?

    public init(pipeline: QuasiTensionPipeline, servo: ServoDriver, estimator: JointEstimator,
                range: ActivationRange, configuration: ControlConfiguration = ControlConfiguration()) async throws {
        let channels = pipeline.channelCount
        guard channels == estimator.channelCount else {
            throw ControllerError.channelMismatch(source: channels, model: estimator.channelCount)
        }
        self.pipeline = pipeline
        self.servo = servo
        self.estimator = estimator
        self.range = range
        self.configuration = configuration
        await pipeline.addQuasiTensionSink { [weak self] sample in
            guard let self else { return }
            Task { await self.receive(sample) }
        }
    }

    public func addSampleSink(_ sink: @escaping @Sendable (ControlSample) -> Void) { sampleSinks.append(sink) }
    public func addErrorSink(_ sink: @escaping @Sendable (Error) -> Void) { errorSinks.append(sink) }

    public func update(configuration: ControlConfiguration) { self.configuration = configuration }
    public func update(range: ActivationRange) { self.range = range }
    public func update(estimator: JointEstimator) { self.estimator = estimator }

    private func receive(_ sample: QuasiTensionSample) {
        latest = sample
    }

    public func start() async throws {
        guard !isRunning else { return }
        latest = nil
        compliance = nil
        statusLeft = nil
        statusRight = nil
        let c = configuration
        for id in [c.leftServoID, c.rightServoID] {
            try await servo.setTorque(id: id, enabled: true)
            try await servo.setCompliance(id: id, slope: c.stiffness.initialCompliance)
        }
        compliance = c.stiffness.initialCompliance
        try await pipeline.start()
        isRunning = true
        loop = Task { [weak self] in await self?.run() }
    }

    public func stop() async {
        guard isRunning else { return }
        isRunning = false
        loop?.cancel()
        loop = nil
        await pipeline.stop()
        let c = configuration
        for id in [c.leftServoID, c.rightServoID] {
            try? await servo.setTorque(id: id, enabled: false)
        }
    }

    private func run() async {
        let started = ContinuousClock.now
        var tick = 0
        var lastStatusPoll = -Double.infinity
        var lastGoalWrite = -Double.infinity
        while !Task.isCancelled && isRunning {
            let c = configuration
            let period = 1 / max(1, c.updateRate)
            let now = (ContinuousClock.now - started).seconds
            if let sample = latest {
                do {
                    let pollStatus = now - lastStatusPoll >= 1 / max(0.1, c.statusPollRate)
                    if pollStatus { lastStatusPoll = now }
                    let writeGoal = now - lastGoalWrite >= 1 / max(0.1, c.goalUpdateRate) - period / 2
                    if writeGoal { lastGoalWrite = now }
                    let out = try await step(sample, time: now, writeGoal: writeGoal, pollStatus: pollStatus)
                    for sink in sampleSinks { sink(out) }
                } catch {
                    for sink in errorSinks { sink(error) }
                    await stop()
                    return
                }
            }
            tick += 1
            try? await Task.sleep(until: started + .seconds(Double(tick) * period), clock: .continuous)
        }
    }

    private func step(_ sample: QuasiTensionSample, time: Double, writeGoal: Bool, pollStatus: Bool) async throws -> ControlSample {
        let c = configuration
        let activation = range.normalize(sample.values)
        let estimate = (c.stiffness.legacyScaling ? estimator.withLegacyStiffnessRange(range) : estimator).estimate(activation)

        let wanted = c.stiffness.compliance(normalizedStiffness: estimate.normalizedStiffness)
        if wanted != compliance {
            try await servo.setCompliance(id: c.leftServoID, slope: wanted)
            try await servo.setCompliance(id: c.rightServoID, slope: wanted)
            compliance = wanted
        }

        let limit = c.angleLimitDegrees
        let degrees = min(limit, max(-limit, estimate.equilibriumDegrees))
        let units = Int(( degrees * c.unitsPerDegree).rounded())
        let left = Int16(clamping: units + Int(c.zeroLeft))
        let right = Int16(clamping: (c.mirrorRight ? -units : units) + Int(c.zeroRight))
        if writeGoal {
            try await servo.move(id: c.leftServoID, position: left, time: c.moveTime)
            try await servo.move(id: c.rightServoID, position: right, time: c.moveTime)
        }

        if pollStatus {
            statusLeft = try await servo.readStatus(id: c.leftServoID)
            statusRight = try await servo.readStatus(id: c.rightServoID)
        }

        return ControlSample(time: time, quasiTension: sample.values, activation: activation, estimate: estimate,
                             compliance: wanted, targetLeft: left, targetRight: right,
                             statusLeft: statusLeft, statusRight: statusRight, targetDegrees: degrees)
    }
}

/// Servo bring-up shared by the GUI and the CLI, as in the legacy "Init Servo" button:
/// torque on, soft compliance, drive both to 0, wait, read the resting positions, limit
/// torque, torque off.
public enum ServoSetup {
    public struct ZeroResult: Sendable, Equatable {
        public var left: ServoStatus
        public var right: ServoStatus
    }

    public static func zero(_ servo: ServoDriver, configuration c: ControlConfiguration,
                            settle: Duration = .seconds(1)) async throws -> ZeroResult {
        for id in [c.leftServoID, c.rightServoID] {
            try await servo.setTorque(id: id, enabled: true)
            try await servo.setCompliance(id: id, slope: 0xFF)
            try await servo.move(id: id, position: 0, time: 0)
        }
        try await Task.sleep(for: settle)
        let left = try await servo.readStatus(id: c.leftServoID)
        let right = try await servo.readStatus(id: c.rightServoID)
        for id in [c.leftServoID, c.rightServoID] {
            try await servo.setMaxTorque(id: id, percent: c.maxTorquePercent)
            try await servo.setTorque(id: id, enabled: false)
        }
        return ZeroResult(left: left, right: right)
    }
}
