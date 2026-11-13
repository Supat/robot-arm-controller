import Foundation

public enum ModelError: LocalizedError, Sendable {
    case badParameterFile(String)
    case parameterCount(expected: Int, found: Int)

    public var errorDescription: String? {
        switch self {
        case .badParameterFile(let why): "Cannot read model parameters: \(why)"
        case .parameterCount(let expected, let found): "Model expects \(expected) parameters, file has \(found)"
        }
    }
}

/// Single-joint musculoskeletal model from the legacy `MSJointStateShin`.
///
/// For `n` muscles the parameter vector `p` has `2 + 3n` entries (plus a trailing
/// centre angle in the file). With activations `u`:
///
///     numerator   = p[0] + Σ p[1+i]·u[i] + Σ p[1+n+i]·u[i]²
///     denominator = p[1+2n] + Σ p[2+2n+i]·u[i]
///     equilibrium = -numerator / denominator            (radians)
///     stiffness   = -denominator
///
/// The legacy program loaded two parameter sets: `param_eq.txt` for the equilibrium
/// angle and `param_trq.txt` for stiffness. Each is a `SingleJointModel`.
public struct SingleJointModel: Sendable, Equatable {
    public let channelCount: Int
    /// `2 + 3n` model coefficients.
    public let coefficients: [Double]
    /// Joint angle when "straight" (radians); last value of the parameter file.
    public let centerAngle: Double

    public static func parameterCount(channelCount: Int) -> Int { 2 + 3 * channelCount + 1 }

    public init(channelCount: Int, parameters: [Double]) throws {
        let expected = Self.parameterCount(channelCount: channelCount)
        guard parameters.count == expected else {
            throw ModelError.parameterCount(expected: expected, found: parameters.count)
        }
        self.channelCount = channelCount
        self.coefficients = Array(parameters.dropLast())
        self.centerAngle = parameters[expected - 1]
    }

    /// Legacy file format: first line is the count, then one number per line.
    public init(channelCount: Int, contentsOf url: URL) throws {
        let text: String
        do { text = try String(contentsOf: url, encoding: .utf8) } catch {
            throw ModelError.badParameterFile(error.localizedDescription)
        }
        try self.init(channelCount: channelCount, fileText: text)
    }

    public init(channelCount: Int, fileText: String) throws {
        let numbers = fileText.split(whereSeparator: { $0.isWhitespace }).compactMap { Double($0) }
        guard let count = numbers.first.map({ Int($0) }), numbers.count >= count + 1 else {
            throw ModelError.badParameterFile("expected a count followed by that many numbers")
        }
        try self.init(channelCount: channelCount, parameters: Array(numbers[1...count]))
    }

    private func checkActivation(_ u: [Double]) {
        precondition(u.count == channelCount, "activation count mismatch")
    }

    public func numerator(_ u: [Double]) -> Double {
        checkActivation(u)
        var value = coefficients[0]
        for i in 0..<channelCount { value += coefficients[1 + i] * u[i] }
        for i in 0..<channelCount { value += coefficients[1 + channelCount + i] * u[i] * u[i] }
        return value
    }

    public func denominator(_ u: [Double]) -> Double {
        checkActivation(u)
        var value = coefficients[1 + 2 * channelCount]
        for i in 0..<channelCount { value += coefficients[2 + 2 * channelCount + i] * u[i] }
        return value
    }

    /// Equilibrium joint angle in radians.
    public func equilibrium(_ u: [Double]) -> Double {
        -numerator(u) / denominator(u)
    }

    /// Joint stiffness (model units).
    public func stiffness(_ u: [Double]) -> Double {
        -denominator(u)
    }

    /// The parameter files shipped with the legacy demo (`param_eq.txt`, `param_trq.txt`).
    public enum Bundled: String, CaseIterable, Sendable {
        case equilibrium = "param_eq"
        case torque = "param_trq"

        public var url: URL? {
            Bundle.module.url(forResource: rawValue, withExtension: "txt", subdirectory: "parameters")
        }
    }

    public static func bundled(_ which: Bundled, channelCount: Int = 2) throws -> SingleJointModel {
        guard let url = which.url else { throw ModelError.badParameterFile("bundled \(which.rawValue).txt missing") }
        return try SingleJointModel(channelCount: channelCount, contentsOf: url)
    }
}

/// Output of `JointEstimator` for one activation vector.
public struct JointEstimate: Sendable, Equatable {
    /// Equilibrium angle, radians.
    public var equilibrium: Double
    /// Stiffness in model units.
    public var stiffness: Double
    /// Stiffness scaled to 0…100 within the estimator's stiffness range (clamped).
    public var normalizedStiffness: Double

    public var equilibriumDegrees: Double { equilibrium * 180 / .pi }
}

/// Combines the equilibrium model and the stiffness model, as the legacy program did with
/// `msjoint` (param_eq) and `msjoint_stiff` (param_trq).
public struct JointEstimator: Sendable {
    public var equilibriumModel: SingleJointModel
    public var stiffnessModel: SingleJointModel
    /// Stiffness mapped to 0 and 100 respectively.
    public var stiffnessRange: ClosedRange<Double>

    public init(equilibriumModel: SingleJointModel, stiffnessModel: SingleJointModel, stiffnessRange: ClosedRange<Double>? = nil) {
        precondition(equilibriumModel.channelCount == stiffnessModel.channelCount)
        self.equilibriumModel = equilibriumModel
        self.stiffnessModel = stiffnessModel
        self.stiffnessRange = stiffnessRange ?? Self.stiffnessExtremes(of: stiffnessModel)
    }

    /// The legacy demo's two bundled parameter sets for a two-muscle joint.
    public static func legacyDefault() throws -> JointEstimator {
        JointEstimator(equilibriumModel: try .bundled(.equilibrium), stiffnessModel: try .bundled(.torque))
    }

    public var channelCount: Int { equilibriumModel.channelCount }

    /// Legacy file names inside a parameter folder.
    public static let equilibriumFileName = "param_eq.txt"
    public static let torqueFileName = "param_trq.txt"

    /// Loads a subject's parameter pair from two legacy-format files.
    public init(equilibriumURL: URL, torqueURL: URL, channelCount: Int = 2) throws {
        self.init(equilibriumModel: try SingleJointModel(channelCount: channelCount, contentsOf: equilibriumURL),
                  stiffnessModel: try SingleJointModel(channelCount: channelCount, contentsOf: torqueURL))
    }

    /// Loads `param_eq.txt` and `param_trq.txt` from a folder (the legacy `parameter/` directory).
    public init(folder: URL, channelCount: Int = 2) throws {
        try self.init(equilibriumURL: folder.appending(path: Self.equilibriumFileName),
                      torqueURL: folder.appending(path: Self.torqueFileName), channelCount: channelCount)
    }

    /// Equilibrium angles (degrees) at rest and with each muscle alone at full activation,
    /// for showing what a parameter set does.
    public var summary: (rest: Double, perMuscle: [Double]) {
        let n = channelCount
        let rest = equilibriumModel.equilibrium(Array(repeating: 0, count: n)) * 180 / .pi
        let per = (0..<n).map { i -> Double in
            var u = Array(repeating: 0.0, count: n); u[i] = 1
            return equilibriumModel.equilibrium(u) * 180 / .pi
        }
        return (rest, per)
    }

    /// Stiffness is linear in the activations, so its extremes over normalised activations
    /// in [0, 1]^n lie at the corners of the cube.
    ///
    /// The legacy code evaluated the extremes at the *raw* quasi-tension min/max while feeding
    /// the model *normalised* activations, which made the 0…100 scale depend on signal gain.
    /// Using the normalised corners keeps "100" meaning "both muscles at calibrated maximum".
    public static func stiffnessExtremes(of model: SingleJointModel) -> ClosedRange<Double> {
        let n = model.channelCount
        var lo = Double.infinity, hi = -Double.infinity
        for corner in 0..<(1 << n) {
            let u = (0..<n).map { (corner >> $0) & 1 == 1 ? 1.0 : 0.0 }
            let s = model.stiffness(u)
            lo = min(lo, s)
            hi = max(hi, s)
        }
        if hi <= lo { hi = lo + 1 }
        return lo...hi
    }

    /// The legacy stiffness range: the model evaluated at the raw calibration minimum and maximum
    /// (`MSJointStateShin::calcMinStiffness/calcMaxStiffness(daq->dQtMin/dQtMax)`).
    public static func legacyStiffnessRange(of model: SingleJointModel, rawRange: ActivationRange) -> ClosedRange<Double> {
        let lo = model.stiffness(rawRange.minimum)
        var hi = model.stiffness(rawRange.maximum)
        if hi <= lo { hi = lo + 1e-9 }
        return lo...hi
    }

    /// A copy whose 0…100 stiffness scale follows the legacy raw-range convention for `rawRange`.
    public func withLegacyStiffnessRange(_ rawRange: ActivationRange) -> JointEstimator {
        var copy = self
        copy.stiffnessRange = Self.legacyStiffnessRange(of: stiffnessModel, rawRange: rawRange)
        return copy
    }

    public func estimate(_ activation: [Double]) -> JointEstimate {
        let eq = equilibriumModel.equilibrium(activation)
        let stiff = stiffnessModel.stiffness(activation)
        let span = stiffnessRange.upperBound - stiffnessRange.lowerBound
        let normalized = min(100, max(0, (stiff - stiffnessRange.lowerBound) / span * 100))
        return JointEstimate(equilibrium: eq, stiffness: stiff, normalizedStiffness: normalized)
    }
}
