import AssistArmCore
import SwiftUI

/// Live plots and numeric read-outs, redrawn at display rate from `PlotBuffers`.
struct LiveView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let buffers = model.buffers {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Readouts()
                    ForEach(0..<buffers.channelCount, id: \.self) { ch in
                        PlotStrip(title: ch == 0 ? "EMG flexor" : "EMG extensor", units: "V", ring: buffers.emg, channels: [ch],
                                  labels: [], scale: .symmetric, window: buffers.window, color: [.blue, .orange][ch % 2])
                            .frame(height: 110)
                    }
                    PlotStrip(title: model.range == nil ? "Quasi-tension (uncalibrated)" : "Activation", units: model.range == nil ? "V" : "0…1",
                              ring: buffers.activation, channels: Array(0..<buffers.channelCount), labels: ["flexor", "extensor"],
                              scale: model.range == nil ? .auto : .fixed(0, 1), window: buffers.window)
                        .frame(height: 130)
                    PlotStrip(title: "Joint angle", units: "°", ring: buffers.angle, channels: [0, 1, 2], labels: ["target", "left", "right"],
                              scale: .fixed(-Float(model.configuration.angleLimitDegrees), Float(model.configuration.angleLimitDegrees)),
                              window: buffers.window, markers: [0])
                        .frame(height: 160)
                    PlotStrip(title: "Joint stiffness", units: "0…100", ring: buffers.stiffness, channels: [0], labels: ["normalised"],
                              scale: .fixed(0, 100), window: buffers.window, markers: [Float(model.configuration.stiffness.threshold)])
                        .frame(height: 120)
                    PlotStrip(title: "Servo compliance", units: "slope", ring: buffers.stiffness, channels: [1], labels: ["0x32 stiff … 0xFF soft"],
                              scale: .fixed(0, 255), window: buffers.window)
                        .frame(height: 80)
                }
                .padding()
            }
        } else {
            ContentUnavailableView("No EMG source", systemImage: "waveform.path.ecg",
                                   description: Text("Choose a source in the sidebar and connect."))
        }
    }
}

private struct Readouts: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.latest
        HStack(spacing: 12) {
            Tile(title: "Equilibrium", value: s.map { String(format: "%.1f°", $0.estimate.equilibriumDegrees) } ?? "—")
            Tile(title: "Stiffness", value: s.map { String(format: "%.0f", $0.estimate.normalizedStiffness) } ?? "—")
            Tile(title: "Compliance", value: s.map { String(format: "0x%02X", $0.compliance) } ?? "—",
                 detail: s.map { $0.compliance == model.configuration.stiffness.stiffCompliance ? "stiff" : ($0.compliance == model.configuration.stiffness.softCompliance ? "soft" : "") } ?? "")
            Tile(title: "Left servo", value: s?.statusLeft.map { String(format: "%.1f°", $0.positionDegrees) } ?? "—",
                 detail: s?.statusLeft.map { "\($0.current) mA" } ?? "")
            Tile(title: "Right servo", value: s?.statusRight.map { String(format: "%.1f°", $0.positionDegrees) } ?? "—",
                 detail: s?.statusRight.map { "\($0.current) mA · \(String(format: "%.1f", $0.volts)) V" } ?? "")
        }
    }
}

private struct Tile: View {
    let title: String
    let value: String
    var detail = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit().weight(.medium))
            Text(detail.isEmpty ? " " : detail).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
    }
}

enum PlotScale {
    case auto
    case symmetric
    case fixed(Float, Float)
}

struct PlotStrip: View {
    @Environment(AppModel.self) private var model
    let title: String
    let units: String
    let ring: SeriesRing
    let channels: [Int]
    let labels: [String]
    let scale: PlotScale
    let window: Double
    var markers: [Float] = []
    var color: Color? = nil

    static let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal]

    var body: some View {
        // Redraw at display rate only while data is flowing; idle plots cost nothing.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !model.isStreaming)) { timeline in
            Canvas { context, size in draw(in: &context, size: size) }
                .id(timeline.date)
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 8) {
                Text(title).fontWeight(.medium)
                ForEach(Array(channels.enumerated()), id: \.offset) { i, _ in
                    if i < labels.count, channels.count > 1 || !labels.isEmpty {
                        Text(labels[i]).foregroundStyle(seriesColor(i))
                    }
                }
                Text(units).foregroundStyle(.secondary)
            }
            .font(.caption2)
            .padding(4)
        }
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    private func seriesColor(_ i: Int) -> Color {
        color ?? Self.palette[i % Self.palette.count]
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let bins = max(1, Int(size.width))
        let envelopes = channels.map { ring.envelope(channel: $0, bins: bins) }
        var lo: Float, hi: Float
        switch scale {
        case .fixed(let a, let b):
            lo = a; hi = b
        case .auto, .symmetric:
            let filled = envelopes.filter { !$0.isEmpty }
            guard !filled.isEmpty else { return }
            lo = filled.flatMap { $0.mins }.filter { !$0.isNaN }.min() ?? 0
            hi = filled.flatMap { $0.maxs }.filter { !$0.isNaN }.max() ?? 1
            if case .symmetric = scale {
                let peak = max(abs(lo), abs(hi), 1e-9)
                lo = -peak; hi = peak
            }
            if hi - lo < 1e-9 { lo -= 0.5; hi += 0.5 }
            let pad = (hi - lo) * 0.08
            lo -= pad; hi += pad
        }
        let topInset: CGFloat = 16
        let plotHeight = size.height - topInset
        func y(_ v: Float) -> CGFloat { topInset + CGFloat((hi - v) / (hi - lo)) * plotHeight }

        for m in markers + (lo < 0 && hi > 0 ? [0] : []) {
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y(m)))
            line.addLine(to: CGPoint(x: size.width, y: y(m)))
            context.stroke(line, with: .color(.secondary.opacity(0.35)), style: StrokeStyle(lineWidth: 0.5, dash: m == 0 ? [] : [4, 3]))
        }

        for (i, env) in envelopes.enumerated() where !env.isEmpty {
            let count = env.mins.count
            let dx = size.width / CGFloat(count)
            var path = Path()
            var started = false
            for b in 0..<count where !env.mins[b].isNaN {
                let x = (CGFloat(b) + 0.5) * dx
                let p1 = CGPoint(x: x, y: y(env.mins[b]))
                if started { path.addLine(to: p1) } else { path.move(to: p1); started = true }
                if env.maxs[b] != env.mins[b] { path.addLine(to: CGPoint(x: x, y: y(env.maxs[b]))) }
            }
            context.stroke(path, with: .color(seriesColor(i)), lineWidth: 1)
        }

        let text = Text("\(format(hi))  /  \(format(lo))  ·  \(Int(window)) s")
            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        context.draw(text, at: CGPoint(x: size.width - 4, y: 2), anchor: .topTrailing)
    }

    private func format(_ v: Float) -> String {
        let a = abs(v)
        if a != 0 && (a < 0.01 || a >= 10000) { return String(format: "%.2e", v) }
        return String(format: "%.3g", v)
    }
}
