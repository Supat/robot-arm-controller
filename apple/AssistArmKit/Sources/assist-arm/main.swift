import AssistArmCore
import Foundation
import FutabaRS
import LSLEMG
import TrignoEMG
import TrignoKit

// Headless controller for bench work and development.
//
//   assist-arm ports                              list serial ports and direct-USB adapters
//   assist-arm status --port usb://1115:0008      read status of servos 1 and 2 (no motion)
//   assist-arm inspect --port usb://1115:0008 --id 1   show RAM 30–41 around small test moves (±20°)
//   assist-arm bench --port usb://1115:0008 --driver-gaps 0,3 --purge 1,0 --gaps 0,2   move-then-read timing test (no motion)
//   assist-arm servo --port /dev/cu.usbserial-X   read status of servos 1 and 2, then zero them
//   assist-arm run [options]                      calibrate, then control
//     --source synthetic|trigno|lsl   (default synthetic)
//     --host 192.168.1.50             Trigno SDK server
//     --slots 1,2                     Trigno sensor slots for muscle 1 and 2 (default 1,2)
//     --stream Delsys --columns 0,1   LSL stream and columns
//     --servo mock|/dev/cu.usbserial-X|usb://vid:pid[@loc]|tcp://host:port   (default mock)
//     --mode linear|low|high|highOrLow --threshold 40
//     --stiffness-scaling legacy|cube  (default legacy: stiffness 0…100 spans the raw calibration range)
//     --calibrate 8                   seconds of calibration (default 8)
//     --duration 20                   seconds of control (default 20)
//     --log out.csv                   telemetry CSV
//     --params DIR                    folder with the subject's param_eq.txt and param_trq.txt
//     --param-eq FILE --param-trq FILE   or the two files individually (default: built-in legacy set)

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

func makeServo(_ spec: String) throws -> ServoDriver {
    if spec == "mock" { return MockServoDriver() }
    return FutabaRSServoDriver(transport: try ServoTransports.make(spec))
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

func printStatus(_ servo: ServoDriver, _ config: ControlConfiguration) async throws {
    for id in [config.leftServoID, config.rightServoID] {
        let s = try await servo.readStatus(id: id)
        log(String(format: "servo %d: %.1f°  %d mA  %d °C  %.1f V", id, s.positionDegrees, s.current, s.temperature, s.volts))
        if !s.raw.isEmpty { log("  raw 42–59: " + s.raw.map { String(format: "%02X", $0) }.joined(separator: " ")) }
    }
}

func cmdStatus(_ o: Options) async throws {
    let servo = try makeServo(o["port", default: o["servo", default: "mock"]])
    try await servo.open()
    defer { Task { await servo.close() } }
    log("Link open: \(servo.name)")
    try await printStatus(servo, ControlConfiguration())
}

/// Bus timing experiment: move both servos to where they already are, wait `gap`, then read
/// status. Reports how often the read succeeds for each gap. No motion.
func cmdBench(_ o: Options) async throws {
    let servo = try makeServo(o["port", default: o["servo", default: "mock"]])
    // Open, close and reopen first: the link must release the adapter on close.
    try await servo.open()
    await servo.close()
    try await servo.open()
    log("Link open, close and reopen OK: \(servo.name)")
    defer { Task { await servo.close() } }
    let c = ControlConfiguration()
    let ids = [c.leftServoID, c.rightServoID]
    var hold: [UInt8: Int16] = [:]
    for id in ids { hold[id] = try await servo.readStatus(id: id).position }
    for id in ids { try await servo.setTorque(id: id, enabled: true) }
    defer { Task { for id in ids { try? await servo.setTorque(id: id, enabled: false) } } }
    let driver = servo as? FutabaRSServoDriver
    let purges = o["purge"].isEmpty ? [true] : o.ints("purge", default: [1]).map { $0 != 0 }
    for driverGapMs in o.ints("driver-gaps", default: [3]) {
        for purge in purges {
            await driver?.configure(interPacketGap: .milliseconds(driverGapMs), purgeBeforeRead: purge)
            for gapMs in o.ints("gaps", default: [0, 1, 2, 5, 10, 20, 50]) {
                var ok = 0, fail = 0
                var worst: Error?
                for _ in 0..<10 {
                    for id in ids { try await servo.move(id: id, position: hold[id]!, time: 0) }
                    if gapMs > 0 { try await Task.sleep(for: .milliseconds(gapMs)) }
                    do {
                        for id in ids { _ = try await servo.readStatus(id: id) }
                        ok += 1
                    } catch { fail += 1; worst = error }
                    try await Task.sleep(for: .milliseconds(20))
                }
                log("driver gap \(driverGapMs) ms, purge \(purge ? "on " : "off"), extra gap \(gapMs) ms: \(ok) ok, \(fail) failed"
                    + (worst.map { " (\($0.localizedDescription))" } ?? ""))
            }
        }
    }
}

/// Bench check of goal writes: shows RAM 30–41 before and after small moves (±20°).
func cmdInspect(_ o: Options) async throws {
    guard let servo = try makeServo(o["port", default: o["servo", default: "mock"]]) as? FutabaRSServoDriver else {
        throw ServoError.io("inspect needs a real Futaba link")
    }
    try await servo.open()
    defer { Task { await servo.close() } }
    let id = UInt8(o["id", default: "1"]) ?? 1
    func show(_ label: String) async throws {
        let g = try await servo.readGoalBlock(id: id)
        let s = try await servo.readStatus(id: id)
        func i16(_ i: Int) -> Int16 { Int16(bitPattern: UInt16(g[i]) | UInt16(g[i + 1]) << 8) }
        log(String(format: "%@: goal %.1f°  goalTime %d  maxTorque %d%%  torqueEnable %d  | pos %.1f°  %d mA  raw30–41 %@",
                   label, Double(i16(0)) / 10, i16(2), g[5], g[6], s.positionDegrees, s.current,
                   g.map { String(format: "%02X", $0) }.joined(separator: " ")))
    }
    let rom = try await servo.readReturn(id: id, flag: 0x03).data
    func r16(_ i: Int) -> Int16 { Int16(bitPattern: UInt16(rom[i]) | UInt16(rom[i + 1]) << 8) }
    log(String(format: "ROM 0–29: model %02X%02X fw %d id %d  CW limit %.1f°  CCW limit %.1f°  margin CW %d CCW %d  slope CW %d CCW %d  punch %d  raw %@",
               rom[1], rom[0], rom[2], rom[4], Double(r16(8)) / 10, Double(r16(10)) / 10, rom[24], rom[25], rom[26], rom[27], r16(28),
               rom.map { String(format: "%02X", $0) }.joined(separator: " ")))
    if let slope = UInt8(o["slope"].replacingOccurrences(of: "0x", with: ""), radix: 16) {
        try await servo.setCompliance(id: id, slope: slope)
        log("compliance slope set to 0x\(String(slope, radix: 16))")
    }
    try await show("start")
    try await servo.setTorque(id: id, enabled: true)
    try await Task.sleep(for: .milliseconds(100))
    try await show("torque on")
    let step = Int16(o["step", default: "200"]) ?? 200
    for target: Int16 in [step, -step, 0] {
        try await servo.move(id: id, position: target, time: 0)
        try await Task.sleep(for: .milliseconds(300))
        try await show("after move \(target)")
        try await Task.sleep(for: .milliseconds(700))
        try await show("settled")
    }
    try await servo.setTorque(id: id, enabled: false)
    try await show("torque off")
}

/// Bench check of continuous goal updates: re-send the same goal at 50 Hz for 1 s and watch
/// the position, to see whether repeated goal writes stall the servo's motion.
func cmdTrack(_ o: Options) async throws {
    guard let servo = try makeServo(o["port", default: o["servo", default: "mock"]]) as? FutabaRSServoDriver else {
        throw ServoError.io("track needs a real Futaba link")
    }
    try await servo.open()
    defer { Task { await servo.close() } }
    let ids = o.ints("ids", default: [Int(o["id", default: "2"]) ?? 2]).map { UInt8($0) }
    let mirror = o["mirror", default: "1"] != "0"      // second servo gets the negated goal
    let step = Int16(o["step", default: "300"]) ?? 300
    let time = UInt16(o["time", default: "0"]) ?? 0
    let repeatMs = Int(o["repeat", default: "20"]) ?? 20
    let slope = UInt8(o["slope", default: "32"].replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0x32
    let slopeAfterTorque = o["slope-after-torque"] == "1"   // write the slope with torque already on, as the control loop does
    for id in ids {
        try await servo.setCompliance(id: id, slope: slopeAfterTorque ? 0xFF : slope)   // soft first when testing the live write
        try await servo.setTorque(id: id, enabled: true)
        if slopeAfterTorque { try await servo.setCompliance(id: id, slope: slope) }
    }
    let sine = o["sine"] == "1"      // goal sweeps 0…step and back over 2 s instead of a constant goal
    for target in [step, 0] {
        let t0 = ContinuousClock.now
        var lastPrint = -1.0
        var sends = 0
        while (ContinuousClock.now - t0).seconds < (sine ? 2.0 : 1.0) {
            let tt = (ContinuousClock.now - t0).seconds
            let goal = sine ? Int16((Double(step) * (1 - cos(2 * Double.pi * tt / 2)) / 2).rounded()) : target
            for (i, id) in ids.enumerated() {
                try await servo.move(id: id, position: (i == 1 && mirror) ? -goal : goal, time: time)
            }
            sends += 1
            let t = (ContinuousClock.now - t0).seconds
            if t - lastPrint >= 0.2 {
                lastPrint = t
                var line = String(format: "goal %.1f°  time %d  repeat %d ms  mirror %d  t=%.2f ", Double(goal) / 10, time, repeatMs, mirror ? 1 : 0, t)
                for id in ids {
                    let st = try await servo.readStatus(id: id)
                    line += String(format: " | servo %d: %.1f°  %d mA", id, st.positionDegrees, st.current)
                }
                log(line + "  (\(sends) sends)")
            }
            if repeatMs > 0 { try await Task.sleep(for: .milliseconds(repeatMs)) } else { try await Task.sleep(for: .seconds(1)) }
        }
    }
    for id in ids { try await servo.setTorque(id: id, enabled: false) }
}

func cmdServo(_ o: Options) async throws {
    let servo = try makeServo(o["port", default: o["servo", default: "mock"]])
    try await servo.open()
    defer { Task { await servo.close() } }
    var config = ControlConfiguration()
    try await printStatus(servo, config)
    let zero = try await ServoSetup.zero(servo, configuration: config)
    config.zeroLeft = zero.left.position
    config.zeroRight = zero.right.position
    log("zero: left \(zero.left.positionDegrees)°, right \(zero.right.positionDegrees)°")
}

func cmdRun(_ o: Options) async throws {
    let source = try await makeSource(o)
    let servo = try makeServo(o["servo", default: "mock"])
    try await servo.open()
    var config = ControlConfiguration()
    config.stiffness = StiffnessPolicy(mode: StiffnessMode(rawValue: o["mode", default: "highOrLow"]) ?? .highOrLow,
                                       threshold: o.double("threshold", default: 40),
                                       legacyScaling: o["stiffness-scaling", default: "legacy"] != "cube")

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

    let estimator: JointEstimator
    if !o["params"].isEmpty {
        estimator = try JointEstimator(folder: URL(filePath: o["params"]))
        log("Model parameters from \(o["params"])")
    } else if !o["param-eq"].isEmpty || !o["param-trq"].isEmpty {
        estimator = try JointEstimator(equilibriumURL: URL(filePath: o["param-eq"]), torqueURL: URL(filePath: o["param-trq"]))
    } else {
        estimator = try JointEstimator.legacyDefault()
    }
    let summary = estimator.summary
    log(String(format: "Model: rest %.1f°, flexor only %.1f°, extensor only %.1f°", summary.rest, summary.perMuscle[0], summary.perMuscle[1]))
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
    case "status": try await cmdStatus(options)
    case "bench": try await cmdBench(options)
    case "inspect": try await cmdInspect(options)
    case "track": try await cmdTrack(options)
    case "servo": try await cmdServo(options)
    case "run": try await cmdRun(options)
    default:
        log("Unknown command \(options.command). Commands: ports, status, bench, inspect, track, servo, run.")
        exit(2)
    }
} catch {
    log("Error: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
    exit(1)
}
