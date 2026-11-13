import AssistArmCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            ControlPanel()
                .navigationTitle("Assist Arm")
                .navigationSplitViewColumnWidth(min: 320, ideal: 360, max: 440)
        } detail: {
            LiveView()
                .navigationTitle(model.emgConnected ? model.sourceName : "Not connected")
                .toolbar { StatusToolbar() }
        }
        .alert("Assist Arm", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alert ?? "")
        }
    }
}

struct StatusToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: 22) {
                Badge(label: "EMG", on: model.emgConnected, busy: model.emgPhase == .connecting)
                Badge(label: "Servo", on: model.servoConnected, busy: model.servoPhase == .connecting)
                Badge(label: "Calibrated", on: model.range != nil, busy: model.isCalibrating)
                if model.isControlling {
                    Badge(label: model.currentRecording == nil ? "Controlling" : "Controlling · recording", on: true, busy: false, color: .red)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.5), in: Capsule())
            .fixedSize()
        }
        ToolbarItem(placement: .primaryAction) {
            if model.isControlling {
                Button { Task { await model.stopControl() } } label: { Label("Stop", systemImage: "stop.fill") }
                    .tint(.red)
            } else {
                Button { Task { await model.startControl() } } label: { Label("Start", systemImage: "play.fill") }
                    .disabled(!model.canControl)
            }
        }
    }
}

private struct Badge: View {
    let label: String
    let on: Bool
    let busy: Bool
    var color: Color = .green

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(busy ? Color.orange : (on ? color : Color.secondary.opacity(0.35)))
                .frame(width: 10, height: 10)
            Text(label)
                .font(.callout.weight(on || busy ? .medium : .regular))
                .foregroundStyle(on || busy ? .primary : .secondary)
        }
    }
}

// MARK: - Sidebar

struct ControlPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            emgSection
            servoSection
            calibrationSection
            modelSection
            modeSection
            controlSection
            logSection
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var emgSection: some View {
        @Bindable var model = model
        Section {
            Picker("Source", selection: $model.emgKind) {
                ForEach(EMGSourceKind.allCases) { Text($0.title).tag($0) }
            }
            .disabled(model.emgPhase != .disconnected)
            switch model.emgKind {
            case .trigno:
                TextField("Trigno Control Utility IP", text: $model.trignoHost)
                    .disabled(model.emgPhase != .disconnected)
                HStack {
                    Stepper("Flexor sensor \(model.slotFlexor)", value: $model.slotFlexor, in: 1...16)
                }
                Stepper("Extensor sensor \(model.slotExtensor)", value: $model.slotExtensor, in: 1...16)
            case .lsl:
                HStack {
                    TextField("Stream name", text: $model.lslStream)
                    Button { Task { await model.refreshLSLStreams() } } label: { Image(systemName: "arrow.clockwise") }
                        .help("Find LSL streams on the network")
                }
                if !model.lslStreams.isEmpty {
                    Picker("Found", selection: $model.lslStream) {
                        ForEach(model.lslStreams) { s in Text("\(s.name) · \(s.channelCount) ch @ \(s.hostname)").tag(s.name) }
                    }
                }
                Stepper("Flexor column \(model.lslColumnFlexor)", value: $model.lslColumnFlexor, in: 0...143)
                Stepper("Extensor column \(model.lslColumnExtensor)", value: $model.lslColumnExtensor, in: 0...143)
            case .synthetic:
                Text("Two simulated muscles that take turns contracting.").foregroundStyle(.secondary).font(.caption)
            }
            if model.emgConnected {
                Button("Disconnect", role: .destructive) { Task { await model.disconnectEMG() } }
                    .disabled(model.isBusy)
            } else {
                Button(model.emgPhase == .connecting ? "Connecting…" : "Connect") { Task { await model.connectEMG() } }
                    .disabled(model.emgPhase == .connecting)
            }
        } header: {
            Text("EMG")
        } footer: {
            if let system = model.trignoSystem {
                Text("\(system.baseSerial) · \(system.sensors.count) active sensors · EMG \(Int(system.emgRate)) Hz")
            }
        }
    }

    @ViewBuilder private var servoSection: some View {
        @Bindable var model = model
        Section {
            Picker("Link", selection: $model.servoKind) {
                ForEach(ServoKind.allCases) { Text($0.title).tag($0) }
            }
            .disabled(model.servoPhase != .disconnected)
            switch model.servoKind {
            case .serial:
                HStack {
                    Picker("Port", selection: $model.serialPath) {
                        ForEach(model.serialPorts) { Text($0.name).tag($0.path) }
                        if !model.serialPorts.contains(where: { $0.path == model.serialPath }) {
                            Text(model.serialPath.isEmpty ? "None" : model.serialPath).tag(model.serialPath)
                        }
                    }
                    Button { model.refreshSerialPorts() } label: { Image(systemName: "arrow.clockwise") }
                }
                .disabled(model.servoPhase != .disconnected)
            case .tcp:
                TextField("Bridge host", text: $model.bridgeHost)
                TextField("Port", value: $model.bridgePort, format: .number)
            case .mock:
                Text("No hardware; servos are simulated.").foregroundStyle(.secondary).font(.caption)
            }
            LabeledContent("Servo IDs") {
                HStack(spacing: 10) {
                    Text("Left").foregroundStyle(.secondary)
                    TextField("", value: $model.configuration.leftServoID, format: .number)
                        .labelsHidden().frame(width: 44)
                    Text("Right").foregroundStyle(.secondary)
                    TextField("", value: $model.configuration.rightServoID, format: .number)
                        .labelsHidden().frame(width: 44)
                }
                .multilineTextAlignment(.trailing)
            }
            .disabled(model.servoConnected)
            if model.servoConnected {
                Button("Disconnect", role: .destructive) { Task { await model.disconnectServo() } }
                    .disabled(model.isControlling)
            } else {
                Button(model.servoPhase == .connecting ? "Zeroing…" : "Connect & zero") { Task { await model.connectServo() } }
                    .disabled(model.servoPhase == .connecting || (model.servoKind == .serial && model.serialPath.isEmpty))
            }
        } header: {
            Text("Servos")
        } footer: {
            if let z = model.zero {
                Text(String(format: "Zero: L %.1f°, R %.1f° · %.1f V · %d °C", z.left.positionDegrees, z.right.positionDegrees, z.left.volts, z.left.temperature))
            } else {
                Text("Futaba RS servos at 115200 bps. Connect drives both to 0° and records the resting angles.")
            }
        }
    }

    @ViewBuilder private var calibrationSection: some View {
        Section {
            if model.isCalibrating {
                Button(role: .destructive) { Task { await model.stopCalibration() } } label: {
                    Label(String(format: "Stop (%.0f s)", model.calibrationElapsed), systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                if let r = model.liveRange {
                    RangeRows(range: r)
                }
            } else {
                Button { Task { await model.startCalibration() } } label: {
                    Label("Calibrate", systemImage: "waveform.badge.magnifyingglass").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!model.canCalibrate)
                if let r = model.range {
                    RangeRows(range: r)
                    Button("Clear", role: .destructive) { model.clearCalibration() }.disabled(model.isControlling)
                }
            }
        } header: {
            Text("Activation range")
        } footer: {
            Text("Relax for a few seconds, then contract each muscle as hard as you can. The first second is ignored.")
        }
    }

    @ViewBuilder private var modelSection: some View {
        Section {
            LabeledContent("Parameters") {
                Text(model.usesBundledParameters ? "Built-in (legacy demo)" : URL(filePath: model.paramEqPath).deletingLastPathComponent().lastPathComponent)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.usesBundledParameters ? "param_eq.txt and param_trq.txt shipped with the legacy demo" : model.paramEqPath + "\n" + model.paramTrqPath)
            }
            HStack {
                Button("Choose…") { model.chooseParameterFiles() }
                if !model.usesBundledParameters {
                    Button("Use built-in") { model.useBundledParameters() }
                }
            }
            .disabled(model.isControlling)
        } header: {
            Text("Model")
        } footer: {
            let s = model.estimator.summary
            Text(String(format: "Subject's param_eq.txt and param_trq.txt. Equilibrium at rest %.1f°, flexor only %.1f°, extensor only %.1f°.",
                        s.rest, s.perMuscle[0], s.perMuscle[1]))
        }
    }

    @ViewBuilder private var modeSection: some View {
        @Bindable var model = model
        Section {
            Picker("Servo stiffness", selection: $model.configuration.stiffness.mode) {
                ForEach(StiffnessMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if model.configuration.stiffness.mode == .highOrLow || model.configuration.stiffness.mode == .linear {
                LabeledContent("Threshold \(Int(model.configuration.stiffness.threshold))") {
                    Slider(value: $model.configuration.stiffness.threshold, in: 0...100, step: 1)
                }
            }
            DisclosureGroup("Advanced") {
                LabeledContent("Angle limit (°)") {
                    TextField("", value: $model.configuration.angleLimitDegrees, format: .number).labelsHidden().frame(width: 60)
                }
                LabeledContent("Units per degree") {
                    TextField("", value: $model.configuration.unitsPerDegree, format: .number).labelsHidden().frame(width: 60)
                }
                LabeledContent("Update rate (Hz)") {
                    TextField("", value: $model.configuration.updateRate, format: .number).labelsHidden().frame(width: 60)
                }
                LabeledContent("Goal write rate (Hz)") {
                    TextField("", value: $model.configuration.goalUpdateRate, format: .number).labelsHidden().frame(width: 60)
                }
                LabeledContent("Max torque (%)") {
                    TextField("", value: $model.configuration.maxTorquePercent, format: .number).labelsHidden().frame(width: 60)
                }
                Toggle("Mirror right servo", isOn: $model.configuration.mirrorRight)
                Toggle("Legacy stiffness scaling", isOn: $model.configuration.stiffness.legacyScaling)
                    .help("Scale normalised stiffness between the model's values at the raw calibration minimum and maximum, as the legacy demo did. Off: scale over the 0…1 activation cube.")
            }
            .multilineTextAlignment(.trailing)
        } header: {
            Text("Mode")
        } footer: {
            Text(modeFooter)
        }
    }

    private var modeFooter: String {
        switch model.configuration.stiffness.mode {
        case .linear: "Servo compliance follows joint stiffness from the threshold up to 100."
        case .low: "Servos stay soft (compliance 0xFF)."
        case .high: "Servos stay stiff (compliance 0x32)."
        case .highOrLow: "Soft below the threshold, stiff at or above it, like the legacy demo."
        }
    }

    @ViewBuilder private var controlSection: some View {
        @Bindable var model = model
        Section {
            Toggle("Record telemetry CSV", isOn: $model.recordTelemetry).disabled(model.isControlling)
            Picker("Plot window", selection: $model.plotWindow) {
                ForEach([2.0, 5, 10, 20], id: \.self) { Text("\(Int($0)) s").tag($0) }
            }
            if model.isControlling {
                Button(role: .destructive) { Task { await model.stopControl() } } label: {
                    Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else {
                Button { Task { await model.startControl() } } label: {
                    Label("Start control", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canControl)
            }
            Button("Show recordings") { model.revealRecordings() }
        } header: {
            Text("Control")
        } footer: {
            if !model.canControl && !model.isControlling {
                Text("Needs an EMG source, a servo link and a calibrated range.")
            } else if let url = model.currentRecording {
                Text("Recording \(url.lastPathComponent)")
            }
        }
    }

    @ViewBuilder private var logSection: some View {
        Section("Log") {
            ForEach(model.log.suffix(8).reversed()) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(entry.time, format: .dateTime.hour().minute().second()).monospacedDigit().foregroundStyle(.tertiary)
                    Text(entry.text).foregroundStyle(entry.isError ? .red : .secondary)
                }
                .font(.caption)
            }
        }
    }
}

private struct RangeRows: View {
    let range: ActivationRange
    var body: some View {
        ForEach(0..<range.channelCount, id: \.self) { ch in
            LabeledContent(ch == 0 ? "Flexor" : "Extensor") {
                Text(String(format: "%.3g … %.3g", range.minimum[ch], range.maximum[ch])).monospacedDigit()
            }
            .font(.caption)
        }
    }
}
