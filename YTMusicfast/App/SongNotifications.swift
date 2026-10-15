import AppKit
import Observation
import UserNotifications

/// A banner with the song's title and artwork when the song changes while you're in another app.
@MainActor
@Observable
final class SongNotifications {
    static let shared = SongNotifications()

    var enabled = UserDefaults.standard.bool(forKey: "songNotifications") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "songNotifications")
            if enabled { requestPermission() }
        }
    }
    /// macOS turned notifications off for the app (System Settings → Notifications).
    private(set) var denied = false

    @ObservationIgnored private var lastVideoId: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    private static let identifier = "now-playing"

    private init() {
        if enabled { refreshPermission() }
    }

    private func requestPermission() {
        Task {
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])) ?? false
            denied = !granted
        }
    }

    private func refreshPermission() {
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            denied = settings.authorizationStatus == .denied
        }
    }

    func trackChanged(_ track: Track) {
        guard enabled, track.videoId != lastVideoId else { return }
        lastVideoId = track.videoId
        // You can see what's playing when the app is in front.
        guard !NSApp.isActive else { return }
        task?.cancel()
        task = Task {
            // Skipping through songs shouldn't fire a banner for each one.
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, PlayerController.shared.current?.videoId == track.videoId, !NSApp.isActive else { return }
            let content = UNMutableNotificationContent()
            content.title = track.title
            content.body = [track.artistLine, track.album?.name].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
            if let attachment = await Self.artworkAttachment(for: track) { content.attachments = [attachment] }
            guard !Task.isCancelled else { return }
            let center = UNUserNotificationCenter.current()
            center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
            try? await center.add(UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil))
        }
    }

    /// Notifications want artwork as a file.
    private static func artworkAttachment(for track: Track) async -> UNNotificationAttachment? {
        guard let url = track.thumbnail else { return nil }
        let data: Data?
        if url.isFileURL {
            data = try? Data(contentsOf: url)
        } else {
            data = try? await URLSession.shared.data(from: url).0
        }
        guard let data else { return nil }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ytmusicfast-artwork-\(UUID().uuidString).jpg")
        guard (try? data.write(to: file)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: "artwork", url: file)
    }
}
