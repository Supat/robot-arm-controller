import AssistArmCore
import Foundation
import FutabaRS
import LSLEMG
import Observation
import TrignoEMG
import TrignoKit

struct LogEntry: Identifiable {
    let id = UUID()
    let time = Date()
    let text: String
    let isError: Bool
}

enum EMGSourceKind: String, CaseIterable, Identifiable, Codable {
    case trigno, lsl, synthetic
    var id: String { rawValue }
    var title: String {
        switch self {
        case .trigno: "Trigno SDK"
        case .lsl: "LSL inlet"
        case .synthetic: "Synthetic"
        }
    }
}

enum ServoKind: String, CaseIterable, Identifiable, Codable {
    case serial, tcp, mock
    var id: String { rawValue }
    var title: String {
        switch self {
        case .serial: "Serial (USB)"
        case .tcp: "TCP bridge"
        case .mock: "Simulated"
        }
    }
}

/// Everything the UI binds to. Hardware and the control loop live in actors owned here.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable { case disconnected, connecting, connected }

    // MARK: Persisted settings
    private let defaults = UserDefaults.standard

    var emgKind: EMGSourceKind = .trigno { didSet { defaults.set(emgKind.rawValue, forKey: "emgKind") } }
    var trignoHost = "192.168.1.50" { didSet { defaults.set(trignoHost, forKey: "trignoHost") } }
    var slotFlexor = 1 { didSet { defaults.set(slotFlexor, forKey: "slotFlexor") } }
    var slotExtensor = 2 { didSet { defaults.set(slotExtensor, forKey: "slotExtensor") } }
    var lslStream = "Delsys" { didSet { defaults.set(lslStream, forKey: "lslStream") } }
    var lslColumnFlexor = 0 { didSet { defaults.set(lslColumnFlexor, forKey: "lslColumnFlexor") } }
    var lslColumnExtensor = 1 { didSet { defaults.set(lslColumnExtensor, forKey: "lslColumnExtensor") } }

    var servoKind: ServoKind = .serial { didSet { defaults.set(servoKind.rawValue, forKey: "servoKind") } }
    var serialPath = "" { didSet { defaults.set(serialPath, forKey: "serialPath") } }
    var bridgeHost = "192.168.1.60" { didSet { defaults.set(bridgeHost, forKey: "bridgeHost") } }
    var bridgePort = 5000 { didSet { defaults.set(bridgePort, forKey: "bridgePort") } }

    var configuration = ControlConfiguration() {
        didSet {
            defaults.set(try? JSONEncoder().encode(configuration), forKey: "configuration")
            Task { await controller?.update(configuration: configuration) }
        }
    }
    var range: ActivationRange? {
        didSet {
            defaults.set(try? JSONEncoder().encode(range), forKey: "range")
            if let range { Task { await controller?.update(range: range) } }
        }
    }
    var recordTelemetry = true { didSet { defaults.set(recordTelemetry, forKey: "recordTelemetry") } }
    var plotWindow: Double = 5 {
        didSet { defaults.set(plotWindow, forKey: "plotWindow"); resizeBuffers() }
    }

    // MARK: Live state
    private(set) var emgPhase: Phase = .disconnected
    private(set) var servoPhase: Phase = .disconnected
    private(set) var trignoSystem: SystemInfo?
    private(set) var lslStreams: [LSLStreamDescription] = []
    private(set) var serialPorts: [SerialPortInfo] = SerialPortInfo.available()
    private(set) var zero: ServoSetup.ZeroResult?
    private(set) var isCalibrating = false
    private(set) var calibrationElapsed: Double = 0
    private(set) var liveRange: ActivationRange?
    private(set) var isControlling = false
    /// A start or stop is in flight. Starting the stream takes a while on a slow link, and a
    /// second start during it would send the Trigno base a second START, which it rejects.
    private(set) var isSwitching = false
    private(set) var latest: ControlSample?
    private(set) var currentRecording: URL?
    private(set) var log: [LogEntry] = []
    var alert: String?

    private(set) var buffers: PlotBuffers?
    private(set) var sourceName = ""
    private(set) var servoName = ""

    private var session: TrignoSession?
    private var source: EMGSource?
    private var pipeline: QuasiTensionPipeline?
    private var calibrator: ActivationCalibrator?
    private var servo: ServoDriver?
    private var controller: AssistController?
    private var telemetry: TelemetryLog?
    private var calibrationMonitor: Task<Void, Never>?
    private(set) var estimator: JointEstimator
    /// Paths of the subject's parameter files; empty means the built-in legacy set.
    var paramEqPath = "" { didSet { defaults.set(paramEqPath, forKey: "paramEqPath") } }
    var paramTrqPath = "" { didSet { defaults.set(paramTrqPath, forKey: "paramTrqPath") } }
    var usesBundledParameters: Bool { paramEqPath.isEmpty && paramTrqPath.isEmpty }

    var emgConnected: Bool { emgPhase == .connected }
    var servoConnected: Bool { servoPhase == .connected }
    var isBusy: Bool { isCalibrating || isControlling }
    /// Data is flowing into the plot buffers, so the plots should redraw.
    var isStreaming: Bool { isCalibrating || isControlling }
    var canCalibrate: Bool { emgConnected && !isControlling && !isSwitching }
    var canControl: Bool { emgConnected && servoConnected && range != nil && !isCalibrating && !isSwitching }

    static var recordingsDirectory: URL {
        URL.documentsDirectory.appending(path: "AssistArm/Recordings", directoryHint: .isDirectory)
    }

    init() {
        estimator = (try? JointEstimator.legacyDefault()) ?? JointEstimator(
            equilibriumModel: try! SingleJointModel(channelCount: 2, parameters: [0, 0, 0, 0, 0, -1, 0, 0, 0]),
            stiffnessModel: try! SingleJointModel(channelCount: 2, parameters: [0, 0, 0, 0, 0, -1, -1, -1, 0]))
        paramEqPath = defaults.string(forKey: "paramEqPath") ?? ""
        paramTrqPath = defaults.string(forKey: "paramTrqPath") ?? ""
        if !usesBundledParameters {
            do {
                estimator = try JointEstimator(equilibriumURL: URL(filePath: paramEqPath), torqueURL: URL(filePath: paramTrqPath))
            } catch {
                paramEqPath = ""; paramTrqPath = ""
                log.append(LogEntry(text: "Could not reload model parameters, using built-in set: \(error.localizedDescription)", isError: true))
            }
        }
        if let s = defaults.string(forKey: "emgKind"), let k = EMGSourceKind(rawValue: s) { emgKind = k }
        if let s = defaults.string(forKey: "servoKind"), let k = ServoKind(rawValue: s) { servoKind = k }
        trignoHost = defaults.string(forKey: "trignoHost") ?? trignoHost
        if defaults.object(forKey: "slotFlexor") != nil { slotFlexor = defaults.integer(forKey: "slotFlexor") }
        if defaults.object(forKey: "slotExtensor") != nil { slotExtensor = defaults.integer(forKey: "slotExtensor") }
        lslStream = defaults.string(forKey: "lslStream") ?? lslStream
        if defaults.object(forKey: "lslColumnFlexor") != nil { lslColumnFlexor = defaults.integer(forKey: "lslColumnFlexor") }
        if defaults.object(forKey: "lslColumnExtensor") != nil { lslColumnExtensor = defaults.integer(forKey: "lslColumnExtensor") }
        serialPath = defaults.string(forKey: "serialPath") ?? serialPorts.first?.path ?? ""
        bridgeHost = defaults.string(forKey: "bridgeHost") ?? bridgeHost
        if defaults.object(forKey: "bridgePort") != nil { bridgePort = defaults.integer(forKey: "bridgePort") }
        if let d = defaults.data(forKey: "configuration"), let c = try? JSONDecoder().decode(ControlConfiguration.self, from: d) { configuration = c }
        if let d = defaults.data(forKey: "range"), let r = try? JSONDecoder().decode(ActivationRange.self, from: d) { range = r }
        if defaults.object(forKey: "recordTelemetry") != nil { recordTelemetry = defaults.bool(forKey: "recordTelemetry") }
        if defaults.object(forKey: "plotWindow") != nil { plotWindow = defaults.double(forKey: "plotWindow") }
        // Zero offsets are per power-up, not per launch.
        configuration.zeroLeft = 0
        configuration.zeroRight = 0
    }

    // MARK: EMG source

    func connectEMG() async {
        guard emgPhase == .disconnected else { return }
        emgPhase = .connecting
        do {
            let source: EMGSource
            switch emgKind {
            case .synthetic:
                source = SyntheticEMGSource()
            case .trigno:
                let session = TrignoSession(host: trignoHost.trimmingCharacters(in: .whitespaces))
                let system = try await session.open()
                self.session = session
                trignoSystem = system
                guard let columns = TrignoEMGSource.columns(forSlots: [slotFlexor, slotExtensor], in: system) else {
                    await session.close()
                    self.session = nil
                    let active = system.sensors.map { String($0.slot) }.joined(separator: ", ")
                    throw ControllerError.channelMismatch(source: system.sensors.count, model: 2).withHint(
                        "Sensors \(slotFlexor) and \(slotExtensor) must be paired and on. Active slots: \(active.isEmpty ? "none" : active).")
                }
                source = TrignoEMGSource(session: session, system: system, columns: columns)
                info("Trigno \(system.baseSerial): sensors \(slotFlexor) (flexor) and \(slotExtensor) (extensor), \(Int(system.emgRate)) Hz")
            case .lsl:
                source = LSLEMGSource(streamName: lslStream, columns: [lslColumnFlexor, lslColumnExtensor])
                info("LSL inlet \"\(lslStream)\" columns \(lslColumnFlexor), \(lslColumnExtensor) (opens when streaming starts)")
            }
            self.source = source
            sourceName = source.name
            let pipeline = QuasiTensionPipeline(source: source)
            self.pipeline = pipeline
            let buffers = PlotBuffers(channelCount: source.channelCount, emgRate: source.sampleRate, qtRate: pipeline.outputRate,
                                      controlRate: configuration.updateRate, window: plotWindow)
            self.buffers = buffers
            await pipeline.addRawSink { block in buffers.emg.push(block: block) }
            await pipeline.addQuasiTensionSink { [weak self] sample in
                // Plot normalised activation once a range exists, raw quasi-tension before.
                Task { @MainActor in
                    guard let self else { return }
                    let values = self.range.map { $0.normalize(sample.values) } ?? sample.values
                    buffers.activation.push(values.map { Float($0) })
                }
            }
            calibrator = await ActivationCalibrator(pipeline: pipeline)
            controller = nil
            emgPhase = .connected
            info("EMG source ready: \(source.name)")
        } catch {
            emgPhase = .disconnected
            fail(error)
        }
    }

    func disconnectEMG() async {
        if isControlling { await stopControl() }
        if isCalibrating { _ = await stopCalibration() }
        await pipeline?.stop()
        await session?.close()
        session = nil
        pipeline = nil
        calibrator = nil
        controller = nil
        source = nil
        trignoSystem = nil
        emgPhase = .disconnected
        info("EMG source disconnected")
    }

    func refreshLSLStreams() async {
        let streams = await Task.detached { LSLEMGSource.resolveAll(timeout: 1.5) }.value
        lslStreams = streams
        info(streams.isEmpty ? "No LSL streams found" : "LSL streams: \(streams.map(\.name).joined(separator: ", "))")
    }

    // MARK: Servo

    func refreshSerialPorts() {
        serialPorts = SerialPortInfo.available()
        if serialPath.isEmpty || !serialPorts.contains(where: { $0.path == serialPath }) {
            serialPath = serialPorts.first?.path ?? serialPath
        }
    }

    func connectServo() async {
        guard servoPhase == .disconnected else { return }
        servoPhase = .connecting
        let driver: ServoDriver
        do {
            switch servoKind {
            case .mock: driver = MockServoDriver()
            case .serial: driver = FutabaRSServoDriver(transport: try ServoTransports.make(serialPath))
            case .tcp: driver = FutabaRSServoDriver(transport: TCPServoTransport(host: bridgeHost, port: UInt16(clamping: bridgePort)))
            }
        } catch {
            servoPhase = .disconnected
            fail(error)
            return
        }
        do {
            try await driver.open()
            info("Servo link open: \(driver.name). Zeroing…")
            let result = try await ServoSetup.zero(driver, configuration: configuration)
            zero = result
            configuration.zeroLeft = result.left.position
            configuration.zeroRight = result.right.position
            servo = driver
            servoName = driver.name
            controller = nil
            servoPhase = .connected
            info(String(format: "Servos zeroed: left %.1f°, right %.1f° (%.1f V)", result.left.positionDegrees, result.right.positionDegrees, result.left.volts))
        } catch {
            await driver.close()
            servoPhase = .disconnected
            fail(error)
        }
    }

    func disconnectServo() async {
        if isControlling { await stopControl() }
        await servo?.close()
        servo = nil
        controller = nil
        zero = nil
        servoPhase = .disconnected
        info("Servo link closed")
    }

    // MARK: Calibration

    func startCalibration() async {
        guard let calibrator, canCalibrate, !isCalibrating else { return }
        isSwitching = true
        defer { isSwitching = false }
        do {
            try await calibrator.start()
            isCalibrating = true
            calibrationElapsed = 0
            liveRange = nil
            info("Calibrating: relax, then contract each muscle fully")
            calibrationMonitor = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard let self, let calibrator = self.calibrator else { return }
                    let progress = await calibrator.progress
                    self.calibrationElapsed = progress.elapsed
                    self.liveRange = progress.range
                }
            }
        } catch {
            fail(error)
        }
    }

    @discardableResult
    func stopCalibration() async -> ActivationRange? {
        guard let calibrator, isCalibrating else { return nil }
        calibrationMonitor?.cancel()
        isCalibrating = false
        isSwitching = true
        defer { isSwitching = false }
        let result = await calibrator.stop()
        range = result
        liveRange = nil
        info("Calibrated: " + (0..<result.channelCount).map { String(format: "ch%d %.3g…%.3g", $0 + 1, result.minimum[$0], result.maximum[$0]) }.joined(separator: ", "))
        return result
    }

    func clearCalibration() {
        range = nil
    }

    // MARK: Control

    func startControl() async {
        guard let pipeline, let servo, let range, canControl, !isControlling else { return }
        isSwitching = true
        defer { isSwitching = false }
        do {
            if controller == nil {
                controller = try await AssistController(pipeline: pipeline, servo: servo, estimator: estimator,
                                                        range: range, configuration: configuration)
                await controller?.addSampleSink { [weak self] sample in
                    Task { @MainActor in self?.receive(sample) }
                }
                await controller?.addErrorSink { [weak self] error in
                    Task { @MainActor in
                        guard let self else { return }
                        self.fail(error)
                        await self.stopControl()
                    }
                }
            }
            guard let controller else { return }
            await controller.update(range: range)
            await controller.update(configuration: configuration)
            buffers?.clearControl()
            if recordTelemetry {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyyMMdd-HHmmss"
                let url = Self.recordingsDirectory.appending(path: "assist-\(formatter.string(from: .now)).csv")
                telemetry = try TelemetryLog(url: url, channelCount: pipeline.channelCount)
                currentRecording = url
            }
            try await controller.start()
            isControlling = true
            info("Controlling (\(configuration.stiffness.mode.title), threshold \(Int(configuration.stiffness.threshold)))")
        } catch {
            fail(error)
        }
    }

    func stopControl() async {
        guard let controller, isControlling else { return }
        isControlling = false
        isSwitching = true
        defer { isSwitching = false }
        await controller.stop()
        if let telemetry {
            do { try telemetry.finish(); info("Saved \(telemetry.url.lastPathComponent)") } catch { fail(error) }
        }
        telemetry = nil
        currentRecording = nil
        info("Stopped")
    }

    private func receive(_ sample: ControlSample) {
        latest = sample
        buffers?.push(sample, configuration: configuration)
        telemetry?.write(sample)
    }

    private func resizeBuffers() {
        guard let source, let pipeline, let buffers else { return }
        buffers.resize(window: plotWindow, emgRate: source.sampleRate, qtRate: pipeline.outputRate, controlRate: configuration.updateRate)
    }

    func revealRecordings() {
        try? FileManager.default.createDirectory(at: Self.recordingsDirectory, withIntermediateDirectories: true)
        #if os(macOS)
        NSWorkspace.shared.open(Self.recordingsDirectory)
        #endif
    }

    // MARK: Model parameters

    /// Lets the user pick the legacy `parameter/` folder or the two files `param_eq.txt` and `param_trq.txt`.
    func chooseParameterFiles() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "Choose model parameters"
        panel.message = "Select the folder containing param_eq.txt and param_trq.txt, or both files."
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        var eq: URL?, trq: URL?
        if urls.count == 1, (try? urls[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            eq = urls[0].appending(path: JointEstimator.equilibriumFileName)
            trq = urls[0].appending(path: JointEstimator.torqueFileName)
        } else {
            for u in urls {
                let name = u.lastPathComponent.lowercased()
                if name.contains("eq") { eq = u } else if name.contains("trq") || name.contains("torque") || name.contains("stiff") { trq = u }
            }
        }
        guard let eq, let trq else {
            fail(ModelError.badParameterFile("pick the parameter folder, or both files (names containing \"eq\" and \"trq\")"))
            return
        }
        loadParameters(equilibrium: eq, torque: trq)
        #endif
    }

    func loadParameters(equilibrium: URL, torque: URL) {
        do {
            estimator = try JointEstimator(equilibriumURL: equilibrium, torqueURL: torque)
            paramEqPath = equilibrium.path
            paramTrqPath = torque.path
            controller = nil   // the next start uses the new model
            let s = estimator.summary
            info(String(format: "Model parameters loaded from %@: rest %.1f°, flexor %.1f°, extensor %.1f°",
                        equilibrium.deletingLastPathComponent().path, s.rest, s.perMuscle[0], s.perMuscle[1]))
        } catch {
            fail(error)
        }
    }

    func useBundledParameters() {
        guard let e = try? JointEstimator.legacyDefault() else { return }
        estimator = e
        paramEqPath = ""
        paramTrqPath = ""
        controller = nil
        info("Using the built-in legacy model parameters")
    }

    // MARK: Log

    func info(_ text: String) {
        log.append(LogEntry(text: text, isError: false))
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }

    func fail(_ error: Error) {
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        log.append(LogEntry(text: text, isError: true))
        alert = text
    }
}

#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

/// Wraps an error with a hint for the user.
struct HintedError: LocalizedError {
    let base: Error
    let hint: String
    var errorDescription: String? {
        ((base as? LocalizedError)?.errorDescription ?? base.localizedDescription) + " " + hint
    }
}

extension Error {
    func withHint(_ hint: String) -> HintedError { HintedError(base: self, hint: hint) }
}
