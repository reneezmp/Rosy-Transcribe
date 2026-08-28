import Foundation

#if canImport(Sparkle)
import Sparkle

/// Checking GitHub for a newer build, via Sparkle.
///
/// Sparkle is the one third-party dependency in this project. It was taken on
/// deliberately: replacing a running application is genuinely hard to get
/// right, and the alternative was hand-rolling the download, signature check,
/// atomic swap and relaunch — the part where a bug eats the app. Sparkle is
/// the tool every other Mac app uses for exactly this.
///
/// The whole file is behind `canImport`, so the app still builds and runs
/// without the package. Updating is simply absent until Sparkle is added to
/// the project; nothing else breaks. That matters because this file was
/// written in a session with no compiler.
@MainActor
final class UpdaterService: NSObject, ObservableObject, SPUUpdaterDelegate {

    /// Served straight from the repository over raw.githubusercontent.com.
    /// GitHub Pages would work too, but this is one fewer thing to set up and
    /// one fewer place to forget to update.
    static let feedURL = "https://raw.githubusercontent.com/reneezmp/RosyTranscriber/main/appcast.xml"

    @Published private(set) var availableVersion: String?
    @Published private(set) var lastCheckFailed: String?

    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: self,
        userDriverDelegate: nil)

    /// Checks in the background on launch, and reports only if something is
    /// found. A dialog on every launch of a personal tool is a nuisance.
    var checksAutomatically: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        lastCheckFailed = nil
        controller.updater.checkForUpdates()
    }

    func checkInBackground() {
        controller.updater.checkForUpdatesInBackground()
    }

    // MARK: - SPUUpdaterDelegate

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        Self.feedURL
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor [weak self] in
            self?.availableVersion = version
            self?.lastCheckFailed = nil
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor [weak self] in
            self?.availableVersion = nil
            self?.lastCheckFailed = nil
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        // A missing or unreachable feed is not worth interrupting anyone over;
        // it is recorded so the settings row can say so quietly.
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            self?.lastCheckFailed = message
        }
    }
}

#else

/// Stand-in for builds without the Sparkle package, so the rest of the app
/// compiles and runs unchanged.
@MainActor
final class UpdaterService: NSObject, ObservableObject {
    @Published private(set) var availableVersion: String?
    @Published private(set) var lastCheckFailed: String?

    var isAvailable: Bool { false }
    var checksAutomatically: Bool {
        get { false }
        set { _ = newValue }
    }

    func checkForUpdates() {
        lastCheckFailed = "This build was made without the Sparkle package, so it cannot check for updates."
    }

    func checkInBackground() {}
}

#endif

extension UpdaterService {
    /// What the running app calls itself, for the About line and for comparing
    /// against what the appcast offers.
    static var currentVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
