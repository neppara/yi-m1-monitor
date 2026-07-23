// Entry point. Swap CameraSession for MockCameraSession here (or in a preview) - RootView and
// every other view are generic over CameraSessionProtocol, so this is the only place that picks
// which implementation backs the app (T3.2).
import SwiftUI
import YiM1Core

@main
struct YiM1MonitorApp: App {
    @StateObject private var session = CameraSession()

    var body: some Scene {
        WindowGroup {
            RootView(session: session)
                .preferredColorScheme(.dark)
        }
    }
}
