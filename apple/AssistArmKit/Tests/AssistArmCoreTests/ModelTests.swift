import XCTest
@testable import AssistArmCore

final class ModelTests: XCTestCase {
    // param_eq.txt from the legacy demo.
    let eqParams: [Double] = [4.76194, 21224.7, -5982.69, 192.182, -1244.74, -14.4463, -13990, -6807.12, 0.0]
    // param_trq.txt from the legacy demo.
    let trqParams: [Double] = [22.5173, 27360.5, -11043, 0.00236232, -3.45335e-005, -52.8076, -6824.3, -20.7912, 0.430399]

    func testBundledParametersLoad() throws {
        let eq = try SingleJointModel.bundled(.equilibrium)
        let trq = try SingleJointModel.bundled(.torque)
        XCTAssertEqual(eq.coefficients, Array(eqParams.dropLast()))
        XCTAssertEqual(eq.centerAngle, 0)
        XCTAssertEqual(trq.coefficients, Array(trqParams.dropLast()))
        XCTAssertEqual(trq.centerAngle, 0.430399)
    }

    func testFileFormatParsing() throws {
        let m = try SingleJointModel(channelCount: 2, fileText: "9\n1\n2\n3\n4\n5\n6\n7\n8\n0.5\n")
        XCTAssertEqual(m.coefficients, [1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(m.centerAngle, 0.5)
        XCTAssertThrowsError(try SingleJointModel(channelCount: 2, fileText: "3\n1\n2\n3\n"))
        XCTAssertThrowsError(try SingleJointModel(channelCount: 2, parameters: [1, 2, 3]))
    }

    func testEquilibriumMatchesLegacyFormula() throws {
        let m = try SingleJointModel(channelCount: 2, parameters: eqParams)
        let u = [0.3, 0.1]
        // Legacy calcEqPoint: num = p0 + p1 u1 + p2 u2 + p3 u1² + p4 u2²; den = p5 + p6 u1 + p7 u2; eq = -num/den.
        let num = 4.76194 + 21224.7 * 0.3 + -5982.69 * 0.1 + 192.182 * 0.09 + -1244.74 * 0.01
        let den = -14.4463 + -13990 * 0.3 + -6807.12 * 0.1
        XCTAssertEqual(m.equilibrium(u), -num / den, accuracy: 1e-12)
        XCTAssertEqual(m.stiffness(u), -den, accuracy: 1e-12)
        // Relaxed arm: 4.76194 / 14.4463 rad ≈ 18.9°.
        XCTAssertEqual(m.equilibrium([0, 0]) * 180 / .pi, 18.886, accuracy: 0.01)
    }

    func testEstimatorNormalisesStiffnessOverUnitCube() throws {
        let est = try JointEstimator.legacyDefault()
        // stiffness = 52.8076 + 6824.3 u1 + 20.7912 u2 → min at (0,0), max at (1,1).
        XCTAssertEqual(est.stiffnessRange.lowerBound, 52.8076, accuracy: 1e-9)
        XCTAssertEqual(est.stiffnessRange.upperBound, 52.8076 + 6824.3 + 20.7912, accuracy: 1e-9)
        XCTAssertEqual(est.estimate([0, 0]).normalizedStiffness, 0, accuracy: 1e-9)
        XCTAssertEqual(est.estimate([1, 1]).normalizedStiffness, 100, accuracy: 1e-9)
        XCTAssertEqual(est.estimate([0.5, 0]).normalizedStiffness, 6824.3 * 0.5 / (6824.3 + 20.7912) * 100, accuracy: 1e-9)
        XCTAssertEqual(est.estimate([2, 2]).normalizedStiffness, 100)  // clamped
    }

    func testStiffnessPolicy() {
        var p = StiffnessPolicy(mode: .highOrLow, threshold: 40)
        XCTAssertEqual(p.compliance(normalizedStiffness: 39.9), 0xFF)
        XCTAssertEqual(p.compliance(normalizedStiffness: 40), 0x32)
        XCTAssertEqual(p.initialCompliance, 0xFF)
        p.mode = .low
        XCTAssertEqual(p.compliance(normalizedStiffness: 100), 0xFF)
        p.mode = .high
        XCTAssertEqual(p.compliance(normalizedStiffness: 0), 0x32)
        XCTAssertEqual(p.initialCompliance, 0x32)
        p.mode = .linear
        XCTAssertEqual(p.compliance(normalizedStiffness: 0), 0xFF)
        XCTAssertEqual(p.compliance(normalizedStiffness: 40), 0xFF)
        XCTAssertEqual(p.compliance(normalizedStiffness: 100), 0x32)
        XCTAssertEqual(p.compliance(normalizedStiffness: 70), UInt8((255.0 + (50.0 - 255.0) * 0.5).rounded()))
    }

    func testLegacyStiffnessScalingIsStiffForEitherMuscle() throws {
        let est = try JointEstimator.legacyDefault()
        // Trigno-scale quasi-tension in volts.
        let raw = ActivationRange(minimum: [2.5e-5, 2.9e-6], maximum: [6.6e-5, 3.4e-6])
        let legacy = est.withLegacyStiffnessRange(raw)
        XCTAssertEqual(legacy.estimate([0, 0]).normalizedStiffness, 0, accuracy: 1e-6)
        XCTAssertEqual(legacy.estimate([0, 0.2]).normalizedStiffness, 100, accuracy: 1e-6)   // extensor alone → stiff
        XCTAssertEqual(legacy.estimate([0.2, 0]).normalizedStiffness, 100, accuracy: 1e-6)
        // Cube scaling: extensor alone stays nearly 0 with these parameters.
        XCTAssertLessThan(est.estimate([0, 1]).normalizedStiffness, 1)
        XCTAssertGreaterThan(est.estimate([1, 0]).normalizedStiffness, 99)
    }
}
