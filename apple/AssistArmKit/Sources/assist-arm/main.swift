import AssistArmCore
import Foundation
import FutabaRS
import LSLEMG
import TrignoEMG
import TrignoKit

// Headless controller for bench work and development.
//
//   assist-arm ports                              list serial ports
//   assist-arm servo --port /dev/cu.usbserial-X   read status of servos 1 and 2, then zero them
//   assist-arm run [options]                      calibrate, then control
//     --source synthetic|trigno|lsl   (default synthetic)
//     --host 192.168.1.50             Trigno SDK server
//     --slots 1,2                     Trigno sensor slots for muscle 1 and 2 (default 1,2)
//     --stream Delsys --columns 0,1   LSL stream and columns
//     --servo mock|/dev/cu.usbserial-X|tcp://host:port   (default mock)
//     --mode linear|low|high|highOrLow --threshold 40
//     --calibrate 8                   seconds of calibration (default 8)
//     --duration 20                   seconds of control (default 20)
//     --log out.csv                   telemetry CSV

struct Options {
    var command = "run"
    var values: [String: String] = [:]

    init(_ args: [String]) {
        var rest = args.dropFirst()
        if let first = rest.first, !first.hasPrefix("--") { command = first; rest = rest.dropFirst() }
        var it = rest.makeIterator()
        while let a = it.next() {
            guard a.hasPrefix("--") else { continue }
            values[String(a.dropFirst(2))] = it.next() ?? ""
        }
    }

    subscript(_ key: String, default def: String = "") -> String { values[key] ?? def }
    func double(_ key: String, default def: Double) -> Double { Double(self[key]) ?? def }
    func ints(_ key: String, default def: [Int]) -> [Int] {
        let parsed = self[key].split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return parsed.isEmpty ? def : parsed
    }
}

func log(_ s: String) { print(s); fflush(stdout) }

func makeServo(_ spec: String) -> ServoDriver {
    if spec == "mock" { return MockServoDriver() }
    if spec.hasPrefix("tcp://") {
        let hp = spec.dropFirst(6).split(separator: ":")
        return FutabaRSServoDriver(transport: TCPServoTransport(host: String(hp[0]), port: UInt16(hp.count > 1 ? hp[1] : "5000") ?? 5000))
    }
    return FutabaRSServoDriver(transport: SerialPort(path: spec))
}

func makeSource(_ o: Options) async throws -> EMGSource {
    switch o["source", default: "synthetic"] {
    case "trigno":
        let session = TrignoSession(host: o["host", default: "127.0.0.1"])
        let system = try await session.open()
        log("Trigno: \(system.sensors.count) active sensors, EMG \(system.emgRate) Hz")
        let slots = o.ints("slots", default: [1, 2])
        guard let columns = TrignoEMGSource.columns(forSlots: slots, in: system) else {
            throw ControllerError.channelMismatch(source: system.sensors.count, model: slots.count)
        }
        return TrignoEMGSource(session: session, system: system, columns: columns)
    case "lsl":
        return LSLEMGSource(streamName: o["stream", default: "Delsys"], columns: o.ints("columns", default: [0, 1]))
    default:
        return SyntheticEMGSource()
    }
}

func cmdPorts() {
    let ports = SerialPortInfo.available()
    if ports.isEmpty { log("No serial ports.") }
    for p in ports { log("\(p.path)\t\(p.name)") }
}

func cmdServo(_ o: Options) async throws {
    let servo = makeServo(o["port", default: o["servo", default: "mock"]])
    try await servo.open()
    defer { Task { await servo.close() } }
    var config = ControlConfiguration()
    for id in [config.leftServoID, config.rightServoID] {
        let s = try await servo.readStatus(id: id)
        log("servo \(id): \(s.positionDegrees)°  \(s.current) mA  \(s.temperature) °C  \(s.volts) V")
    }
    let zero = try await ServoSetup.zero(servo, configuration: config)
    config.zeroLeft = zero.left.position
    config.zeroRight = zero.right.position
    log("zero: left \(zero.left.positionDegrees)°, right \(zero.right.positionDegrees)°")
}

func cmdRun(_ o: Options) async throws {
    let source = try await makeSource(o)
    let servo = makeServo(o["servo", default: "mock"])
    try await servo.open()
    var config = ControlConfiguration()
    config.stiffness = StiffnessPolicy(mode: StiffnessMode(rawValue: o["mode", default: "highOrLow"]) ?? .highOrLow,
                                       threshold: o.double("threshold", default: 40))

    log("Zeroing servos (\(servo.name))…")
    let zero = try await ServoSetup.zero(servo, configuration: config)
    config.zeroLeft = zero.left.position
    config.zeroRight = zero.right.position

    let pipeline = QuasiTensionPipeline(source: source)
    let calibrator = await ActivationCalibrator(pipeline: pipeline)
    let seconds = o.double("calibrate", default: 8)
    log("Calibrating for \(seconds) s: relax, then contract each muscle fully (\(source.name))…")
    try await calibrator.start()
    try await Task.sleep(for: .seconds(seconds))
    let range = await calibrator.stop()
    log("Range: min \(range.minimum.map { String(format: "%.3g", $0) })  max \(range.maximum.map { String(format: "%.3g", $0) })")

    let estimator = try JointEstimator.legacyDefault()
    let controller = try await AssistController(pipeline: pipeline, servo: servo, estimator: estimator, range: range, configuration: config)
    let telemetry = o["log"].isEmpty ? nil : try TelemetryLog(url: URL(filePath: o["log"]), channelCount: source.channelCount)
    let printer = Printer()
    await controller.addSampleSink { s in
        telemetry?.write(s)
        printer.maybePrint(s)
    }
    await controller.addErrorSink { log("ERROR: \($0.localizedDescription)") }
    log("Controlling for \(o.double("duration", default: 20)) s (mode \(config.stiffness.mode.rawValue), threshold \(config.stiffness.threshold))…")
    try await controller.start()
    try await Task.sleep(for: .seconds(o.double("duration", default: 20)))
    await controller.stop()
    try telemetry?.finish()
    await servo.close()
    log("Done.")
}

final class Printer: @unchecked Sendable {
    private var last = -1.0
    private let lock = NSLock()
    func maybePrint(_ s: ControlSample) {
        lock.withLock {
            guard s.time - last >= 0.5 else { return }
            last = s.time
            let act = s.activation.map { String(format: "%.2f", $0) }.joined(separator: " ")
            let pos = s.statusLeft.map { String(format: "%.1f", $0.positionDegrees) } ?? "?"
            log(String(format: "t=%6.2f  u=[%@]  eq=%6.1f°  nstiff=%5.1f  comp=0x%02X  goalL=%5d  posL=%@°",
                       s.time, act, s.estimate.equilibriumDegrees, s.estimate.normalizedStiffness, s.compliance, s.targetLeft, pos))
        }
    }
}

let options = Options(CommandLine.arguments)
do {
    switch options.command {
    case "ports": cmdPorts()
    case "servo": try await cmdServo(options)
    case "run": try await cmdRun(options)
    default:
        log("Unknown command \(options.command). Commands: ports, servo, run.")
        exit(2)
    }
} catch {
    log("Error: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
    exit(1)
}
