import SwiftUI

@main
struct ScribeDropletApp: App {

    @StateObject private var updater = UpdaterService()

    var body: some Scene {
        WindowGroup("Scribe Droplet") {
            ContentView()
                .task {
                    // Quietly, on launch. A dialog every time you open a
                    // personal tool is a nuisance; Sparkle only speaks up if
                    // there is actually something newer.
                    updater.checkInBackground()
                }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1040, height: 680)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
                Divider()
                Text("Version \(UpdaterService.currentVersion)")
            }
        }
    }
}
