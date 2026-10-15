import SwiftUI

/// What a radio is built from: a song, or an album, playlist or artist.
struct RadioSeed: Hashable {
    var title: String
    var thumbnail: URL?
    var videoId: String?
    var item: MediaItem?

    init(track: Track) {
        title = track.title
        thumbnail = track.thumbnail
        videoId = track.videoId
    }

    init(item: MediaItem) {
        title = item.title
        thumbnail = item.thumbnail
        self.item = item
    }
}

/// "Go to radio": the radio's songs as a page, without playing them. Play or shuffle
/// them, get a new mix, or keep it as a playlist.
struct RadioPage: View {
    let seed: RadioSeed
    @State private var tracks: [Track] = []
    @State private var continuation: String?
    @State private var error: String?
    @State private var loading = false
    @State private var saving = false
    @State private var tint = Color(white: 0.3)
    @Environment(Router.self) private var router
    @Environment(AuthManager.self) private var auth
    private var player: PlayerController { .shared }

    private var title: String { String(localized: "\(seed.title) Radio") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                actions
                if !tracks.isEmpty {
                    TrackList(tracks: tracks, showHeader: true)
                        .padding(.horizontal, Theme.pagePadding - 12)
                        .padding(.bottom, 32)
                        .appearTransition()
                } else if let error {
                    ErrorView(message: error) { Task { await load() } }.padding(.top, 40)
                } else {
                    SkeletonRows(count: 12).padding(.horizontal, 28)
                }
            }
        }
        .reportsScrolling()
        .artworkTint(seed.thumbnail, into: $tint)
        .task { await load() }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 24) {
            ArtworkView(url: seed.thumbnail, size: 192, cornerRadius: seed.item?.target.kind == .artist ? 96 : 6,
                        circle: seed.item?.target.kind == .artist)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(Circle().fill(.black.opacity(0.55)))
                        .padding(8)
                }
                .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
            VStack(alignment: .leading, spacing: 8) {
                Text("Radio").font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.system(size: 48, weight: .black))
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
                Text(tracks.isEmpty ? String(localized: "Songs like \(seed.title)") : "\(String(localized: "Songs like \(seed.title)")) • \(Format.count(tracks.count, .song))")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondary)
            }
            .foregroundStyle(Theme.text)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.pagePadding)
        .padding(.top, 72)
        .padding(.bottom, 24)
        .background(
            LinearGradient(colors: [tint.headerTint(), tint.headerTint().mix(with: Theme.shade, by: 0.45)], startPoint: .top, endPoint: .bottom)
        )
    }

    private var actions: some View {
        HStack(spacing: 16) {
            PlayCircleButton(size: 56) { player.play(tracks, shuffled: false) }
                .disabled(tracks.isEmpty)
            IconButton(systemImage: "shuffle", size: 22, label: String(localized: "Shuffle Play")) { player.play(tracks, shuffled: true) }
                .disabled(tracks.isEmpty)
            IconButton(systemImage: "arrow.clockwise", size: 20, label: String(localized: "New mix")) { Task { await refresh() } }
                .disabled(loading)
            if auth.isSignedIn {
                Button { Task { await save() } } label: {
                    Label("Save as Playlist", systemImage: "plus.circle")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().strokeBorder(Theme.tertiary))
                }
                .buttonStyle(.plain)
                .disabled(tracks.isEmpty || saving)
            }
            Spacer()
            if loading { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, Theme.pagePadding)
        .padding(.vertical, 20)
    }

    private func fetch() async throws -> RadioResult {
        if let videoId = seed.videoId { return try await MusicAPI.radio(videoId: videoId) }
        guard let item = seed.item, let id = await PlayerController.radioPlaylistId(for: item, header: nil) else {
            throw InnerTubeError.unplayable(String(localized: "Couldn't start a radio for this"))
        }
        return try await MusicAPI.radio(playlistId: id, params: "wAEB")
    }

    private func load() async {
        guard tracks.isEmpty else { return }
        loading = true
        defer { loading = false }
        do {
            let result = try await fetch()
            tracks = ContentFilter.shared.filter(result.tracks)
            continuation = result.continuation
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The radio's next songs: a different mix of the same radio.
    private func refresh() async {
        loading = true
        defer { loading = false }
        let seen = Set(tracks.map(\.videoId))
        let next: RadioResult? = if let continuation { try? await MusicAPI.radioContinuation(continuation) } else { try? await fetch() }
        guard let next else {
            router.showToast(String(localized: "Couldn't load a new mix"), icon: "exclamationmark.triangle.fill")
            return
        }
        let fresh = ContentFilter.shared.filter(next.tracks).filter { !seen.contains($0.videoId) }
        // Keep the seed song first, the rest is new.
        let first = seed.videoId.flatMap { id in tracks.first { $0.videoId == id } }
        tracks = (first.map { [$0] } ?? []) + (fresh.isEmpty ? tracks.shuffled() : fresh)
        continuation = next.continuation
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            guard let id = try await MusicAPI.createPlaylist(title: title, videoIds: tracks.map(\.videoId)) else { throw URLError(.badServerResponse) }
            RemoteLibraryCache.needsReload += 1
            router.showToast(String(localized: "Saved to Your Library"))
            router.open(BrowseTarget(browseId: "VL" + id, kind: .playlist, title: title))
        } catch {
            router.showToast(String(localized: "Couldn't create playlist"), icon: "exclamationmark.triangle.fill")
        }
    }
}
