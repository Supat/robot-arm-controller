// swift-tools-version: 6.0
import PackageDescription

// TrignoKit (Delsys Trigno SDK client) lives in the sibling delsys-app checkout:
//   GitHub/delsys-app/apple/TrignoKit
// Override with ASSISTARM_TRIGNOKIT_PATH if your checkout is elsewhere.
import Foundation
let trignoKitPath = ProcessInfo.processInfo.environment["ASSISTARM_TRIGNOKIT_PATH"]
    ?? "../../../delsys-app/apple/TrignoKit"

let package = Package(
    name: "AssistArmKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "AssistArmCore", targets: ["AssistArmCore"]),
        .library(name: "FutabaRS", targets: ["FutabaRS"]),
        .library(name: "TrignoEMG", targets: ["TrignoEMG"]),
        .library(name: "LSLEMG", targets: ["LSLEMG"]),
        .executable(name: "assist-arm", targets: ["assist-arm"]),
    ],
    dependencies: [
        .package(name: "TrignoKit", path: trignoKitPath),
    ],
    targets: [
        // Signal processing, musculoskeletal model, control loop. No hardware, no UI.
        .target(
            name: "AssistArmCore",
            resources: [.copy("Resources/parameters")]
        ),
        // Futaba RS-series command servos over a serial port (or a TCP serial bridge).
        .target(name: "FutabaRS", dependencies: ["AssistArmCore"]),
        // EMG from the Delsys Trigno SDK server via TrignoKit.
        .target(name: "TrignoEMG", dependencies: ["AssistArmCore", .product(name: "TrignoKit", package: "TrignoKit")]),
        // EMG from a Lab Streaming Layer inlet (e.g. the Trigno app's "Delsys" stream).
        .target(name: "LSLEMG", dependencies: ["AssistArmCore", .product(name: "CLSL", package: "TrignoKit")]),
        // Headless controller for development and bench tests.
        .executableTarget(name: "assist-arm", dependencies: ["AssistArmCore", "FutabaRS", "TrignoEMG", "LSLEMG"]),

        .testTarget(name: "AssistArmCoreTests", dependencies: ["AssistArmCore"]),
        .testTarget(name: "FutabaRSTests", dependencies: ["FutabaRS"]),
    ]
)
