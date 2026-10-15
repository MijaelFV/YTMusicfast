import AppKit
import SwiftUI

// MARK: - Create (+) and account menus

/// Your Library's "Create" menu: what you can make, each with a line saying what it is.
@MainActor
enum CreateMenu {
    static func entries() -> [MenuEntry] {
        let router = Router.shared
        let signedIn = AuthManager.shared.isSignedIn
        let player = PlayerController.shared
        return [
            .item(String(localized: "Playlist"), subtitle: String(localized: "Create a playlist with songs"), systemImage: "music.note.list", largeIcon: true) {
                guard signedIn else { router.showSignIn = true; return }
                Task { await LibraryActions.createPlaylist(router: router) }
            },
            .item(String(localized: "Playlist from queue"), subtitle: String(localized: "Save what's playing and up next"),
                  systemImage: "text.badge.plus", largeIcon: true, enabled: !player.queue.isEmpty) {
                guard signedIn else { router.showSignIn = true; return }
                Task { await LibraryActions.saveQueue(router: router) }
            },
            .divider,
            .item(String(localized: "Folder"), subtitle: String(localized: "Organize your playlists"), systemImage: "folder", largeIcon: true) {
                router.renamingFolder = LocalLibrary.shared.createFolder()
            },
            .item(String(localized: "Upload music"), subtitle: String(localized: "Add your own songs to YouTube Music"),
                  systemImage: "icloud.and.arrow.up", largeIcon: true) {
                guard signedIn else { router.showSignIn = true; return }
                LibraryActions.uploadMusic(router: router)
            },
            .item(String(localized: "Local files"), subtitle: String(localized: "Play music folders from this Mac"), systemImage: "externaldrive", largeIcon: true) {
                LocalFilesView.chooseFolder()
                if !LocalFiles.shared.folders.isEmpty { router.navigate(.localFiles) }
            },
        ]
    }
}

/// The account menu under your initial (top right).
@MainActor
enum AccountMenuEntries {
    static func entries(openSettings: @escaping () -> Void) -> [MenuEntry] {
        let router = Router.shared
        let auth = AuthManager.shared
        let player = PlayerController.shared
        let updates = UpdateChecker.shared
        var entries: [MenuEntry] = []
        if let name = auth.accountName { entries.append(.header(name)) }
        entries += [
            .item(String(localized: "Account"), trailingImage: "arrow.up.forward.square") {
                NSWorkspace.shared.open(URL(string: "https://myaccount.google.com")!)
            },
            .item(String(localized: "YouTube Music on the web"), trailingImage: "arrow.up.forward.square") {
                NSWorkspace.shared.open(URL(string: "https://music.youtube.com")!)
            },
            .item(String(localized: "Recents")) { router.open(Router.history) },
            .item(String(localized: "Your stats")) { router.navigate(.stats) },
            .item(String(localized: "Private session"), checked: player.privateSession) {
                player.privateSession.toggle()
                router.showToast(player.privateSession ? String(localized: "Private session on — nothing you play is remembered") : String(localized: "Private session off"),
                                 icon: "eye.slash.fill")
            },
            .item(String(localized: "Settings"), action: openSettings),
        ]
        if updates.updateAvailable, let version = updates.latestVersion {
            entries.append(.item(String(localized: "Update YT Musicfast to \(version)"), dot: true) { updates.openRelease() })
        }
        entries.append(.item(String(localized: "Log out")) { Task { await auth.signOut() } })
        return entries
    }
}

// MARK: - Library actions shared by panels and menus

@MainActor
enum LibraryActions {
    static func createPlaylist(router: Router) async {
        let existing = RemoteLibraryCache.playlistTitles.filter { $0.hasPrefix("My Playlist #") }.count
        let title = String(localized: "My Playlist #\(existing + 1)")
        do {
            let id = try await MusicAPI.createPlaylist(title: title, videoIds: [])
            router.showToast(String(localized: "Created \(title)"))
            if let id { router.open(BrowseTarget(browseId: "VL\(id)", kind: .playlist, title: title)) }
            // The library listing lags a little behind creation too.
            try? await Task.sleep(for: .seconds(1.5))
            RemoteLibraryCache.needsReload += 1
        } catch {
            router.showToast(String(localized: "Couldn't create playlist"), icon: "exclamationmark.triangle.fill")
        }
    }

    /// Picks song files and uploads them to YouTube Music (they appear under Uploads).
    static func uploadMusic(router: Router) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.mp3, .mpeg4Audio, .audio].compactMap { $0 }
        panel.message = String(localized: "Choose songs to upload to YouTube Music (MP3, M4A, FLAC, OGG, WMA)")
        panel.prompt = String(localized: "Upload")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let files = panel.urls
        router.showToast(files.count == 1 ? String(localized: "Uploading \(files[0].lastPathComponent)…") : String(localized: "Uploading \(files.count) songs…"),
                         icon: "icloud.and.arrow.up")
        Task {
            var failed = 0
            for file in files {
                do { try await MusicAPI.upload(file) } catch { failed += 1 }
            }
            if failed == 0 {
                router.showToast(files.count == 1 ? String(localized: "Uploaded — it'll appear in Uploads shortly") : String(localized: "Uploaded \(files.count) songs"),
                                 icon: "checkmark.icloud.fill")
            } else {
                router.showToast(String(localized: "\(failed) uploads failed"), icon: "exclamationmark.icloud.fill")
            }
            PageModel.forget(browseId: Router.uploads.browseId)
        }
    }

    static func saveQueue(router: Router) async {
        let player = PlayerController.shared
        let ids = Array(player.queue.dropFirst(player.currentIndex ?? 0).prefix(200).map(\.track.videoId))
        guard !ids.isEmpty else { return }
        let title = "\(player.context?.title ?? "Queue") mix"
        do {
            let id = try await MusicAPI.createPlaylist(title: title, videoIds: ids)
            router.showToast(String(localized: "Saved \(Format.count(ids.count, .song)) to “\(title)”"))
            RemoteLibraryCache.needsReload += 1
            if let id { router.open(BrowseTarget(browseId: "VL\(id)", kind: .playlist, title: title)) }
        } catch {
            router.showToast(String(localized: "Couldn't create playlist"), icon: "exclamationmark.triangle.fill")
        }
    }
}

/// Lets actions outside the library panel ask it to refresh, and know existing titles.
@MainActor
@Observable
final class RemoteLibraryCache {
    static var playlistTitles: [String] = []
    static var needsReload = 0 {
        didSet { shared.version = needsReload }
    }
    static let shared = RemoteLibraryCache()
    var version = 0
}
