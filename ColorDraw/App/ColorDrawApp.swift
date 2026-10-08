import SwiftUI

@main
struct ColorDrawApp: App {
    @State private var store = ArtworkStore.forLaunch()
    @State private var samples = SampleCatalog()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(store)
                .environment(samples)
                .tint(Theme.pink)
                .task { await samples.loadPreviews() }
        }
    }
}

/// Switches set by launch arguments.
enum LaunchOptions {
    /// UI tests pass `-uiTesting`: endless decorative animations are paused so the test runner
    /// can tell when the app is idle.
    static let isUITesting = CommandLine.arguments.contains("-uiTesting")
}
