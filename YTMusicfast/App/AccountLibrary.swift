import Foundation
import Observation

/// Saving albums/playlists to the YouTube Music library and subscribing to artists.
/// Signed in, these are real account actions; signed out they fall back to pinning in Your Library,
/// so the buttons always do something. Changes show at once and roll back if YouTube refuses.
@MainActor
@Observable
final class AccountLibrary {
    static let shared = AccountLibrary()

    /// Saves and subscriptions changed in this session, by account + playlist id / channel id.
    /// They beat what a page said when it loaded.
    private var saved: [String: Bool] = [:]
    private var subscriptions: [String: Bool] = [:]

    /// Per account, so signing out or switching never shows the other session's state.
    private func key(_ id: String) -> String { "\(AuthManager.shared.sessionVersion)|\(id)" }

    private static func plain(_ id: String) -> String { id.hasPrefix("VL") ? String(id.dropFirst(2)) : id }

    /// The id the library knows a collection by: an album's audio playlist, else the playlist itself.
    static func libraryId(target: BrowseTarget, header: PageHeader?) -> String? {
        switch target.kind {
        case .album: header?.playlistId
        case .playlist: plain(target.browseId)
        default: nil
        }
    }

    // MARK: Albums & playlists

    func isSaved(_ item: MediaItem, header: PageHeader?) -> Bool {
        guard AuthManager.shared.isSignedIn, let id = Self.libraryId(target: item.target, header: header) else {
            return LocalLibrary.shared.isPinned(item)
        }
        return saved[key(id)] ?? header?.inLibrary ?? false
    }

    func toggleSaved(_ item: MediaItem, header: PageHeader?) {
        guard AuthManager.shared.isSignedIn, let id = Self.libraryId(target: item.target, header: header) else {
            let pinned = LocalLibrary.shared.isPinned(item)
            LocalLibrary.shared.togglePin(item)
            Router.shared.showToast(pinned ? String(localized: "Removed from Your Library") : String(localized: "Added to Your Library"),
                                    undo: pinned ? { LocalLibrary.shared.togglePin(item) } : nil)
            return
        }
        let wasSaved = isSaved(item, header: header)
        saved[key(id)] = !wasSaved
        Router.shared.showToast(wasSaved ? String(localized: "Removed from Your Library") : String(localized: "Saved to Your Library"),
                                undo: wasSaved ? { [weak self] in self?.toggleSaved(item, header: header) } : nil)
        Task {
            do {
                try await MusicAPI.setInLibrary(!wasSaved, playlistId: id)
                RemoteLibraryCache.needsReload += 1
            } catch {
                saved[key(id)] = wasSaved
                Router.shared.showToast(String(localized: "Couldn't update Your Library"), icon: "exclamationmark.triangle.fill")
            }
        }
    }

    // MARK: Artists

    func isSubscribed(_ item: MediaItem, header: PageHeader?) -> Bool {
        guard AuthManager.shared.isSignedIn, let channel = header?.channelId else {
            return LocalLibrary.shared.isPinned(item)
        }
        return subscriptions[key(channel)] ?? header?.subscribed ?? false
    }

    func toggleSubscribed(_ item: MediaItem, header: PageHeader?) {
        guard AuthManager.shared.isSignedIn, let channel = header?.channelId else {
            LocalLibrary.shared.togglePin(item)
            return
        }
        let was = isSubscribed(item, header: header)
        subscriptions[key(channel)] = !was
        Router.shared.showToast(was ? String(localized: "Unsubscribed from \(item.title)") : String(localized: "Subscribed to \(item.title)"),
                                undo: was ? { [weak self] in self?.toggleSubscribed(item, header: header) } : nil)
        Task {
            do {
                try await MusicAPI.setSubscribed(!was, channelId: channel)
                RemoteLibraryCache.needsReload += 1
            } catch {
                subscriptions[key(channel)] = was
                Router.shared.showToast(String(localized: "Couldn't update subscription"), icon: "exclamationmark.triangle.fill")
            }
        }
    }
}
