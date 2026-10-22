import AVFoundation
import SwiftUI

@main
struct AzaharApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Play game audio even with the silent switch on, mix politely with other apps.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        EmulatorCore.shared.initialize()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .onOpenURL { url in
                    // "Open in…" from Files/AirDrop: import the game file. Files inside our own
                    // folder (opened in place from the Files app) are picked up by the folder scan.
                    if url.isFileURL { GameLibrary.shared.importFiles([url]) }
                }
        }
        .onChange(of: scenePhase) { phase in
            // Pick up files added through the Files app / Finder / iTunes while we were away.
            if phase == .active, EmulatorCore.shared.state == .idle { GameLibrary.shared.refresh() }
            if phase == .background, EmulatorCore.shared.state == .running {
                EmulatorCore.shared.setPaused(true)
            }
        }
    }
}
