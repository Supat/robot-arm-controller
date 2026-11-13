import Foundation

/// How estimated joint stiffness is turned into servo compliance, mirroring the legacy
/// radio buttons "linear / low / high / high or low".
public enum StiffnessMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Servo stiffness follows normalised joint stiffness between `threshold` and 100.
    case linear
    /// Always soft.
    case low
    /// Always stiff.
    case high
    /// Soft below `threshold`, stiff at or above it.
    case highOrLow

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .linear: "Linear"
        case .low: "Low"
        case .high: "High"
        case .highOrLow: "High or low"
        }
    }
}

/// Maps normalised stiffness (0…100) to a Futaba compliance-slope byte.
///
/// Larger slope = softer servo. The legacy values were 0xFF (soft, "LOW") and 0x32 (stiff,
/// "HIGH"). In the legacy linear mode the byte grew *with* stiffness, i.e. a stiffer arm made
/// the servo softer, which contradicted the other modes (and the value sent was a stray
/// pointer cast); here linear interpolates from `soft` at `threshold` to `stiff` at 100.
public struct StiffnessPolicy: Codable, Sendable, Equatable {
    public var mode: StiffnessMode
    /// 0…100, the legacy GUI defaulted to 40.
    public var threshold: Double
    public var softCompliance: UInt8
    public var stiffCompliance: UInt8

    public init(mode: StiffnessMode = .highOrLow, threshold: Double = 40, softCompliance: UInt8 = 0xFF, stiffCompliance: UInt8 = 0x32) {
        self.mode = mode
        self.threshold = min(100, max(0, threshold))
        self.softCompliance = softCompliance
        self.stiffCompliance = stiffCompliance
    }

    /// Compliance the servo should have before any estimate exists.
    public var initialCompliance: UInt8 {
        mode == .high ? stiffCompliance : softCompliance
    }

    public func compliance(normalizedStiffness s: Double) -> UInt8 {
        switch mode {
        case .low: return softCompliance
        case .high: return stiffCompliance
        case .highOrLow: return s < threshold ? softCompliance : stiffCompliance
        case .linear:
            let span = max(1e-9, 100 - threshold)
            let t = min(1, max(0, (s - threshold) / span))
            let value = Double(softCompliance) + (Double(stiffCompliance) - Double(softCompliance)) * t
            return UInt8(clamping: Int(value.rounded()))
        }
    }
}
