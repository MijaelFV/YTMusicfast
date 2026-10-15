import AppKit
import Observation

/// Checks GitHub Releases for a newer version. Important for an unofficial client: when YouTube
/// changes something and playback breaks, users need to hear about the fixed build quickly.
@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    /// "owner/repo" on GitHub (nil disables checks). While the repository is private the API answers
    /// 404, so no update is ever offered.
    static let repository: String? = "MijaelFV/YTMusicfast"

    private(set) var latestVersion: String?
    private(set) var releaseURL: URL?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var updateAvailable: Bool {
        guard let latestVersion else { return false }
        return Self.isNewer(latestVersion, than: currentVersion)
    }

    func check() async {
        guard let repository = Self.repository,
              let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else { return }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        Activity.shared.begin(.updates)
        defer { Activity.shared.end(.updates) }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSON(data: data),
              let tag = json["tag_name"].string else { return }
        latestVersion = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        releaseURL = json["html_url"].string.flatMap(URL.init(string:))
    }

    /// The "Update" badge: Sparkle shows what's new, then downloads and installs it.
    func openRelease() {
        Updater.shared.checkForUpdates()
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
