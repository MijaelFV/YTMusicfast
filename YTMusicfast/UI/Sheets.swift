import SwiftUI
import WebKit

/// Albums, playlists and artists from the signed-in account's library.
@MainActor
@Observable
final class RemoteLibrary {
    private(set) var items: [MediaItem] = []

    private static var diskKey: String { "\(AuthManager.shared.cacheIdentity)|library" }

    func load(signedIn: Bool) async {
        // Last time's library at once (before the session is even read), then a fresh copy.
        if items.isEmpty, AuthManager.shared.cacheIdentity != "signed-out",
           let saved = await DiskCache.load([MediaItem].self, key: Self.diskKey), items.isEmpty {
            items = saved.value
        }
        guard AuthManager.shared.restored else { return }
        guard signedIn else { items = []; return }
        Activity.shared.begin(.library)
        defer { Activity.shared.end(.library) }
        let ids = ["FEmusic_liked_playlists", "FEmusic_liked_albums", "FEmusic_library_corpus_artists", "FEmusic_library_corpus_track_artists",
                   "FEmusic_library_non_music_audio_list"]
        var collected: [MediaItem] = []
        var failed = false
        await withTaskGroup(of: [MediaItem]?.self) { group in
            for id in ids {
                group.addTask {
                    guard let page = try? await MusicAPI.browse(BrowseTarget(browseId: id, kind: .other, title: "")) else { return nil }
                    return page.shelves.flatMap(\.items).compactMap {
                        if case .media(let m) = $0, m.target.kind != .other, !["VLLM", "LM"].contains(m.target.browseId),
                           !(m.target.kind == .playlist && m.title == "Liked Music") { return m }
                        return nil
                    }
                }
            }
            for await batch in group {
                if let batch { collected += batch } else { failed = true }
            }
        }
        // A failed refresh (offline) keeps what's shown instead of emptying Your Library.
        guard !failed || items.isEmpty else { return }
        items = collected
        DiskCache.store(collected, key: Self.diskKey)
        // Your playlists for "Add to playlist ▸" in song menus.
        await PlaylistTargets.refresh()
    }
}

// MARK: - Add to playlist

struct AddToPlaylistSheet: View {
    let tracks: [Track]
    @Environment(\.dismiss) private var dismiss
    @Environment(Router.self) private var router
    @State private var playlists: [PlaylistOption]?
    @State private var error: String?
    @State private var newTitle = ""
    @State private var filter = ""

    private var subtitle: String {
        tracks.count == 1 ? "\(tracks[0].title) · \(tracks[0].artistLine)" : "\(tracks.count) songs"
    }

    private var shown: [PlaylistOption] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        return (playlists ?? []).filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ArtworkView(url: tracks.first?.thumbnail, size: 44, cornerRadius: 6)
                VStack(alignment: .leading) {
                    Text("Add to playlist").font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            HStack {
                TextField("New playlist name", text: $newTitle)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(create)
                Button("Create", action: create).disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Divider()
            if let playlists, playlists.count > 8 {
                TextField("Find a playlist", text: $filter)
                    .textFieldStyle(.roundedBorder)
            }
            if let playlists, shown.isEmpty {
                ContentUnavailableView(playlists.isEmpty ? String(localized: "No playlists yet") : String(localized: "No playlists match “\(filter)”"),
                                       systemImage: "music.note.list",
                                       description: Text(playlists.isEmpty ? String(localized: "Name one above and press Create.") : String(localized: "Try another name.")))
                    .frame(maxHeight: .infinity)
            } else if playlists != nil {
                List(shown) { playlist in
                    Button {
                        add(to: playlist)
                    } label: {
                        HStack(spacing: 10) {
                            ArtworkView(url: playlist.thumbnail, size: 32, cornerRadius: 4)
                            Text(playlist.title)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            } else if let error {
                Text(error).foregroundStyle(.secondary)
            } else {
                SkeletonRows(count: 6)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 400, height: 480)
        .task {
            guard let first = tracks.first else { return }
            do { playlists = try await MusicAPI.editablePlaylists(for: first.videoId) }
            catch { self.error = error.localizedDescription }
        }
    }

    private func add(to playlist: PlaylistOption) {
        router.add(videoIds: tracks.map(\.videoId), toPlaylist: playlist.playlistId, title: playlist.title)
        dismiss()
    }

    private func create() {
        let title = newTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        let ids = tracks.map(\.videoId)
        Task {
            do {
                try await MusicAPI.createPlaylist(title: title, videoIds: ids)
                router.showToast(String(localized: "Created \(title)"), icon: "checkmark.circle.fill")
                try? await Task.sleep(for: .seconds(1.5))
                RemoteLibraryCache.needsReload += 1
            } catch {
                router.showToast(String(localized: "Couldn't create playlist"), icon: "exclamationmark.triangle.fill")
            }
        }
        dismiss()
    }
}

// MARK: - Sign in

struct SignInView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthManager.self) private var auth
    @State private var finishing = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "lock.fill").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Sign in with Google").font(.headline)
                    Text("You're signing in on Google's own page. YT Musicfast never sees your password.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()
            ZStack {
                GoogleSignInWebView {
                    finishing = true
                    Task {
                        await auth.completeSignIn()
                        dismiss()
                    }
                }
                if finishing {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Signing you in…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.regularMaterial)
                }
            }
        }
        .frame(width: 520, height: 700)
    }
}

/// Shows Google's login form and finishes as soon as YouTube's session cookie appears.
/// The YouTube Music website itself is never shown: navigation there is intercepted.
struct GoogleSignInWebView: NSViewRepresentable {
    var onSignedIn: () -> Void

    /// Google's login form, continuing to YouTube's sign-in handshake (which sets the youtube.com cookies).
    static let loginURL = URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&uilel=3&hl=en&continue=https%3A%2F%2Fwww.youtube.com%2Fsignin%3Faction_handle_signin%3Dtrue%26app%3Ddesktop%26next%3Dhttps%253A%252F%252Fmusic.youtube.com%252F")!

    func makeCoordinator() -> Coordinator { Coordinator(onSignedIn: onSignedIn) }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.customUserAgent = InnerTube.safariUserAgent
        webView.navigationDelegate = context.coordinator
        context.coordinator.attach(to: webView)
        webView.load(URLRequest(url: Self.loginURL))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
        let onSignedIn: () -> Void
        private var done = false
        private weak var webView: WKWebView?

        init(onSignedIn: @escaping () -> Void) { self.onSignedIn = onSignedIn }

        func attach(to webView: WKWebView) {
            self.webView = webView
            webView.configuration.websiteDataStore.httpCookieStore.add(self)
        }

        func detach() {
            webView?.configuration.websiteDataStore.httpCookieStore.remove(self)
        }

        /// Fires whenever any cookie changes; we finish once the *complete* session is present
        /// (Google sets the cookies over several redirects).
        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            checkSession { _ in }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let host = navigationAction.request.url?.host, host == "music.youtube.com" else {
                decisionHandler(.allow)
                return
            }
            // Never render the YouTube Music site here: either we're signed in (finish),
            // or Google skipped the form, so send the user back to it.
            checkSession { signedIn in
                decisionHandler(.cancel)
                if !signedIn { webView.load(URLRequest(url: GoogleSignInWebView.loginURL)) }
            }
        }

        private func checkSession(_ completion: @escaping (Bool) -> Void) {
            guard let store = webView?.configuration.websiteDataStore.httpCookieStore else { completion(false); return }
            store.getAllCookies { [weak self] cookies in
                guard let self else { return }
                let signedIn = AuthManager.isComplete(cookies)
                if signedIn, !self.done {
                    self.done = true
                    self.onSignedIn()
                }
                completion(signedIn)
            }
        }
    }
}
