import Foundation

public extension Duration {
    /// The duration in seconds as a floating-point number.
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
