import SwiftUI
import AVFoundation

@main
struct QorvexApp: App {
    init() {
        // Let inline muted videos play without interrupting the user's music.
        AudioSession.ambient()
        Task.detached(priority: .background) { await RedditClient.shared.prune() }
        CrashReporter.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
