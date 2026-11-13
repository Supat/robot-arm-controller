import SwiftUI

@main
struct AssistArmApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                #if DEBUG
                // Development: `-autoConnect YES` (uses the saved source/servo settings),
                // `-synthetic YES` to force the synthetic source and simulated servos.
                .task {
                    let defaults = UserDefaults.standard
                    guard defaults.bool(forKey: "autoConnect") else { return }
                    if defaults.bool(forKey: "synthetic") {
                        model.emgKind = .synthetic
                        model.servoKind = .mock
                    }
                    await model.connectEMG()
                    await model.connectServo()
                }
                #endif
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
