import SwiftUI

@main
struct ScribeDropletApp: App {
    var body: some Scene {
        WindowGroup("Scribe Droplet") {
            ContentView()
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1040, height: 680)
    }
}
