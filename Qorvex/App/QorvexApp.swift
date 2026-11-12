import SwiftUI
import AVFoundation

@main
struct QorvexApp: App {
    init() {
        // Let inline muted videos play without interrupting the user's music.
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .moviePlayback, options: [.mixWithOthers])
        Task.detached(priority: .background) { await RedditClient.shared.prune() }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
