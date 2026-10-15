import AppKit
import Observation
import Sparkle

/// In-app updates (Sparkle): checks the latest GitHub release daily, downloads and installs the
/// update, and relaunches. Updates are verified with the app's EdDSA key, and macOS doesn't ask
/// to "Open Anyway" again for an update installed this way.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    private(set) var canCheck = false
    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observation: NSKeyValueObservation?

    private var updater: SPUUpdater { controller.updater }

    var automaticallyChecks: Bool {
        get { access(keyPath: \.automaticallyChecks); return updater.automaticallyChecksForUpdates }
        set { withMutation(keyPath: \.automaticallyChecks) { updater.automaticallyChecksForUpdates = newValue } }
    }

    var automaticallyDownloads: Bool {
        get { access(keyPath: \.automaticallyDownloads); return updater.automaticallyDownloadsUpdates }
        set { withMutation(keyPath: \.automaticallyDownloads) { updater.automaticallyDownloadsUpdates = newValue } }
    }

    private init() {
        // A benchmark copy must not check for or install updates.
        controller = SPUStandardUpdaterController(startingUpdater: !Bench.enabled, updaterDelegate: nil, userDriverDelegate: nil)
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheck = value }
        }
    }

    func checkForUpdates() {
        Task {
            // No release published yet (or the repository is still private): GitHub answers 404 and
            // Sparkle would show a scary "Update Error!". Nothing newer exists, so say so.
            if await feedIsMissing() {
                showUpToDate()
            } else {
                controller.checkForUpdates(nil)
            }
        }
    }

    private func feedIsMissing() async -> Bool {
        guard let url = updater.feedURL else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 8
        // Offline or other failures: let Sparkle report them as usual.
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 404
    }

    private func showUpToDate() {
        let alert = NSAlert()
        alert.messageText = String(localized: "You're up to date")
        alert.informativeText = String(localized: "YT Musicfast \(UpdateChecker.shared.currentVersion) is the newest version available.")
        alert.addButton(withTitle: String(localized: "OK"))
        NSApp.activate()
        alert.runModal()
    }
}
