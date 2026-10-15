import SwiftUI

/// Loads a browse page and its continuations (more shelves, more playlist tracks).
@MainActor
@Observable
final class PageModel {
    enum Source { case home(chip: String?), target(BrowseTarget) }

    let source: Source
    private(set) var page: BrowsePage? {
        didSet { derive() }
    }
    /// Worked out once per change of `page`, not on every render: rebuilding a 500-song list
    /// a dozen times per render made each new batch of songs stall scrolling.
    private(set) var mainTracks: [Track] = []
    private(set) var mainShelfID: UUID?
    /// Each list shelf's songs, by shelf.
    private(set) var shelfTracks: [UUID: [Track]] = [:]

    private func derive() {
        mainShelfID = page?.mainShelf?.id
        var byShelf: [UUID: [Track]] = [:]
        for shelf in page?.shelves ?? [] where shelf.style == .list { byShelf[shelf.id] = shelf.tracks }
        shelfTracks = byShelf
        mainTracks = mainShelfID.flatMap { byShelf[$0] } ?? []
    }
    private(set) var error: (any Error)?
    private var loadingMore = false

    /// Recently opened pages, so going back or reopening one shows it at once instead of a skeleton.
    private static var cache: [String: (page: BrowsePage, loaded: Date)] = [:]
    private static var cacheOrder: [String] = []
    /// Younger than this, a cached page is shown without asking YouTube again.
    private static let fresh: TimeInterval = 120

    /// Per account: signing in or out must never show the other session's pages.
    private var cacheKey: String {
        let id = switch source {
        case .home(let chip): "home|\(chip ?? "")"
        case .target(let target): "\(target.browseId)|\(target.params ?? "")"
        }
        return "\(AuthManager.shared.cacheIdentity)|\(id)"
    }

    /// Pages worth reopening instantly after a restart: Home and your collections. Search-like
    /// pages (moods, charts, "show all") go stale too fast to be worth the disk.
    private var persists: Bool {
        switch source {
        case .home(let chip): chip == nil
        case .target(let target):
            [.album, .playlist, .artist, .podcast].contains(target.kind)
                || [Router.history.browseId, Router.librarySongs.browseId, Router.uploads.browseId].contains(target.browseId)
        }
    }

    init(_ source: Source) {
        self.source = source
        page = Self.cache[cacheKey]?.page
        if page != nil { loadedKey = cacheKey }
        derive()
    }

    /// First load of a view: the cached copy if it's fresh, otherwise fetch (keeping any older
    /// copy on screen meanwhile).
    func loadCached() async {
        // The account changed under this view: never keep showing the other session's page.
        if loadedKey != nil, loadedKey != cacheKey, Self.cache[cacheKey] == nil { page = nil }
        if let cached = Self.cache[cacheKey] {
            page = cached.page
            if Date().timeIntervalSince(cached.loaded) < Self.fresh { return }
        } else if page == nil, persists, let saved = await DiskCache.load(BrowsePage.self, key: cacheKey), page == nil {
            // Last time's copy, shown at once while a fresh one loads.
            page = saved.value
            if case .home = source { perfLog.notice("home shown from disk") }
            loadedKey = cacheKey
            Self.cache[cacheKey] = (saved.value, saved.saved)
            Self.cacheOrder.append(cacheKey)
        }
        // Before the saved session is read, YouTube would answer as signed out.
        guard AuthManager.shared.restored else { return }
        await load()
    }

    /// The cache key the shown page was loaded under.
    private var loadedKey: String?

    /// Drops a page from the cache (a deleted playlist must not come back on Back).
    static func forget(browseId: String) {
        for key in cache.keys where key.contains("|\(browseId)|") {
            cache[key] = nil
            DiskCache.remove(key: key)
        }
        cacheOrder.removeAll { $0.contains("|\(browseId)|") }
    }

    private func remember() {
        guard let page else { return }
        let key = cacheKey
        loadedKey = key
        Self.cache[key] = (page, Date())
        Self.cacheOrder.removeAll { $0 == key }
        Self.cacheOrder.append(key)
        if Self.cacheOrder.count > 30 { Self.cache[Self.cacheOrder.removeFirst()] = nil }
        if persists { DiskCache.store(page, key: key) }
    }

    func load() async {
        error = nil
        // Refreshing what's on screen (a skeleton already says "loading" otherwise).
        let refreshing = page != nil
        if refreshing { Activity.shared.begin(.page) }
        defer { if refreshing { Activity.shared.end(.page) } }
        do {
            switch source {
            case .home(let chip):
                page = try await MusicAPI.home(params: chip)
                perfLog.notice("home loaded from network")
            case .target(let target):
                var result = try await MusicAPI.browse(target)
                // A just-created playlist can take a moment to become visible; retry briefly.
                var attempt = 0
                while target.kind == .playlist, result.header == nil, attempt < 4 {
                    attempt += 1
                    try await Task.sleep(for: .milliseconds(600 * attempt))
                    result = try await MusicAPI.browse(target)
                }
                page = result
            }
            remember()
            if case .target(let target) = source, target.kind == .artist { await fillArtistDurations() }
        } catch is CancellationError {
        } catch let urlError as URLError where urlError.code == .cancelled {
            // Superseded (e.g. the view reloaded when the session was restored), not a failure.
        } catch {
            // Keep showing what we have; a downloaded album or playlist still opens offline;
            // only an empty page shows the error.
            if page == nil, case .target(let target) = source, let offline = DownloadManager.shared.page(for: target) {
                page = offline
            } else if page == nil {
                self.error = error
            }
        }
    }

    /// An artist's song lists come without lengths. Their full song list (the Popular shelf's
    /// own page) has them: one request, after the page is already on screen. Songs this Mac
    /// knows fill in too.
    private func fillArtistDurations() async {
        guard let shelves = page?.shelves,
              let popular = shelves.first(where: { $0.style == .list && $0.items.contains { $0.track != nil } }),
              popular.items.contains(where: { $0.track?.duration == nil }) else { return }
        var lengths: [String: TimeInterval] = [:]
        if let more = popular.moreTarget, let songs = try? await MusicAPI.browse(more) {
            for track in songs.shelves.flatMap(\.items).compactMap(\.track) {
                if let duration = track.duration { lengths[track.videoId] = duration }
            }
        }
        guard var updated = page else { return }
        let known = AudioCache.durations()
        var changed = false
        for shelf in updated.shelves.indices {
            for item in updated.shelves[shelf].items.indices {
                guard case .track(var track) = updated.shelves[shelf].items[item], track.duration == nil,
                      let length = lengths[track.videoId] ?? known[track.videoId] else { continue }
                track.duration = length
                updated.shelves[shelf].items[item] = .track(track)
                changed = true
            }
        }
        guard changed else { return }
        page = updated
        remember()
    }

    // MARK: Editing your playlist (applied here at once, then sent to YouTube)

    /// Takes songs out of every list on the page (history rows, by their history token).
    func removeEverywhere(_ tracks: [Track]) {
        let tokens = Set(tracks.compactMap(\.historyToken))
        guard let shelves = page?.shelves else { return }
        for index in shelves.indices {
            page?.shelves[index].items.removeAll { item in
                guard let token = item.track?.historyToken else { return false }
                return tokens.contains(token)
            }
        }
        page?.shelves.removeAll { $0.items.isEmpty }
        remember()
    }

    /// Takes songs out of the main list without waiting for a reload.
    func removeLocally(_ tracks: [Track]) {
        guard let id = mainShelfID, let index = page?.shelves.firstIndex(where: { $0.id == id }) else { return }
        let slots = Set(tracks.map { $0.setVideoId ?? $0.videoId })
        page?.shelves[index].items.removeAll { item in
            guard let track = item.track else { return false }
            return slots.contains(track.setVideoId ?? track.videoId)
        }
        remember()
    }

    /// Moves a song within the main list to just before `destination`. Returns the song now after it
    /// (`successor` nil: it's last), or nil when nothing moved.
    func moveLocally(_ track: Track, to destination: Int) -> (successor: Track?, Void)? {
        guard let id = mainShelfID, let index = page?.shelves.firstIndex(where: { $0.id == id }),
              var items = page?.shelves[index].items,
              let from = items.firstIndex(where: { $0.track?.setVideoId == track.setVideoId && $0.track?.videoId == track.videoId }),
              destination != from, destination != from + 1
        else { return nil }
        let moved = items.remove(at: from)
        let to = min(max(0, destination > from ? destination - 1 : destination), items.count)
        items.insert(moved, at: to)
        page?.shelves[index].items = items
        remember()
        return (to + 1 < items.count ? items[to + 1].track : nil, ())
    }

    /// Appends the next batch of shelves (home feed) when the bottom is reached.
    func loadMoreShelves() async {
        // A page restored from disk waits for the session (its tokens would be fetched signed out).
        guard !loadingMore, AuthManager.shared.restored, let token = page?.continuation else { return }
        loadingMore = true
        defer { loadingMore = false }
        guard let more = try? await MusicAPI.continuation(token), !more.shelves.isEmpty || more.continuation != nil else {
            // Failed or nothing left: drop the token so the loading placeholder doesn't linger forever.
            page?.continuation = nil
            return
        }
        page?.shelves += more.shelves
        page?.continuation = more.continuation == token ? nil : more.continuation
        remember()
    }

    /// Loads the next few batches of shelves up front (Home has two or three), so scrolling to the
    /// bottom finds them ready instead of loading them as they come into view.
    func loadMoreShelvesAhead(batches: Int = 3) async {
        for _ in 0..<batches {
            guard !Task.isCancelled, page?.continuation != nil else { return }
            await loadMoreShelves()
        }
    }

    /// Fetches the rest of a long playlist in the background, a batch at a time, so a fast scroll
    /// never outruns the download (a batch landing on screen built its rows all in one frame),
    /// and play, search and sort cover every song.
    func loadRemainingTracks() async {
        while !Task.isCancelled, let id = mainShelfID, mainTracks.count < 5000,
              page?.shelves.first(where: { $0.id == id })?.continuation != nil {
            if loadingMore {
                try? await Task.sleep(for: .milliseconds(200))
                continue
            }
            let before = mainTracks.count
            await loadMore(into: id)
            guard mainTracks.count > before else { break }
            // Just a frame's breather: finishing sooner matters more (a batch that lands on screen
            // builds its rows all at once).
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Appends more tracks to a long list shelf (big playlists, liked songs).
    func loadMore(into shelfId: UUID) async {
        guard !loadingMore, AuthManager.shared.restored, let index = page?.shelves.firstIndex(where: { $0.id == shelfId }),
              let token = page?.shelves[index].continuation else { return }
        loadingMore = true
        defer { loadingMore = false }
        guard var more = try? await MusicAPI.continuation(token) else { return }
        if case .target(let target) = source { more.fillTrackContext(target: target) }
        let extra = more.shelves.filter { $0.style == .list }
        Bench.event("append \(extra.flatMap(\.items).count) rows")
        page?.shelves[index].items += extra.flatMap(\.items)
        page?.shelves[index].continuation = extra.last?.continuation
        if shelfId == mainShelfID, case .target(let target) = source {
            PlayerController.shared.extendContext(target, with: extra.flatMap(\.tracks))
        }
        page?.shelves += more.shelves.filter { $0.style != .list }
        remember()
    }
}

struct BrowseView: View {
    let target: BrowseTarget
    @State private var model: PageModel
    /// What's pinned at the top: nothing, the sticky bar, or the bar plus the list's column header.
    /// Only this coarse state is stored: keeping the raw scroll offset re-rendered the whole page,
    /// every row included, on every frame of scrolling.
    @State private var pinned = Pinned.none
    /// Where the song list starts on the page; only changes when the layout does.
    @State private var listTop: CGFloat = 0
    @State private var scrollToFinder = false

    private enum Pinned { case none, bar, barAndColumns }
    @State private var tint = Color(white: 0.3)
    @State private var trackQuery = ""
    @State private var trackSort = TrackSort.custom
    @State private var popularExpanded = false
    @State private var showFinder = false
    @State private var editingDetails = false
    @State private var confirmDelete = false
    @Environment(AuthManager.self) private var auth
    @Environment(Router.self) private var router

    /// Your own playlist (you can add songs, rename and delete it).
    private func isOwned(_ page: BrowsePage) -> Bool {
        // Liked Music and Episodes for Later are YouTube's auto playlists: not editable like yours.
        guard target.kind == .playlist, !["VLLM", "VLSE"].contains(target.browseId), let owner = page.header?.owner?.name,
              let account = auth.accountName else { return false }
        return owner == account
    }

    init(target: BrowseTarget) {
        self.target = target
        _model = State(initialValue: PageModel(.target(target)))
    }

    private var isCollection: Bool { [.album, .playlist, .podcast].contains(target.kind) }

    var body: some View {
        if let variant = Bench.variant, let page = model.page {
            // Experiment only: the same rows in a plain lazy stack vs a native List.
            BenchListExperiment(variant: variant, tracks: model.mainTracks) { Task { await model.loadMore(into: page.mainShelf!.id) } }
                .scrollBench("page", ready: true)
        } else {
            mainBody
        }
    }

    private var mainBody: some View {
        ScrollViewReader { proxy in
            scrollingPage
                .onChange(of: scrollToFinder) { _, requested in
                    guard requested else { return }
                    scrollToFinder = false
                    Task {
                        // Let the finder appear before scrolling to it.
                        try? await Task.sleep(for: .milliseconds(50))
                        withAnimation(.snappy) { proxy.scrollTo("finder", anchor: .top) }
                    }
                }
        }
    }

    private var scrollingPage: some View {
        ScrollView {
            // One container for every state, so the scroll restorer outlives the skeleton.
            VStack(spacing: 0) {
            if let page = model.page {
                PausesHoverWhileScrolling {
                VStack(alignment: .leading, spacing: 0) {
                    // How far the page has scrolled, read from one invisible marker: cheaper than
                    // `onScrollGeometryChange`, which combines geometry from the whole page each frame.
                    Color.clear
                        .frame(height: 0)
                        .onGeometryChange(for: Pinned.self) { proxy in
                            let offset = -proxy.frame(in: .scrollView).minY
                            // The columns pin once the list's own header reaches the bottom of the 64pt bar.
                            if isCollection, listTop > 0, offset > listTop - 64 { return .barAndColumns }
                            return offset > stickyThreshold ? .bar : .none
                        } action: { state in
                            Bench.event("pinned \(state)")
                            pinned = state
                        }
                    header(page)
                    content(page)
                }
                .coordinateSpace(.named("page"))
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.playContext, target)
                .environment(\.playlistEditing, editing(page))
                }
                .appearTransition()
            } else if let error = model.error {
                ErrorView(error: error) { Task { await model.load() } }
                    .padding(.top, 80)
            } else if isCollection {
                SkeletonCollection()
            } else {
                SkeletonRows(count: 12).padding(28)
            }
            }
            .restoresScrollPosition()
        }
        .scrollIndicators(.automatic)
        .reportsScrolling()
        .scrollBench("page", ready: !model.mainTracks.isEmpty)
        .overlay(alignment: .top) {
            if let page = model.page, pinned != .none {
                VStack(spacing: 0) {
                    StickyHeader(target: target, title: page.header?.title ?? target.title, tint: tint, tracks: playableTracks(page))
                    if pinned == .barAndColumns {
                        TrackListHeader(showAlbum: target.kind == .playlist,
                                        numberWidth: TrackList.numberWidth(for: model.mainTracks.count))
                            .padding(.top, 8)
                            .padding(.horizontal, Theme.pagePadding - 12)
                            .background(Theme.panel)
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: pinned)
        .artworkTint(model.page?.header?.thumbnail, into: $tint)
        .sheet(isPresented: $editingDetails) {
            PlaylistDetailsSheet(playlistId: target.browseId, title: model.page?.header?.title ?? "",
                                 details: model.page?.header?.description ?? "",
                                 privacy: PlaylistDetailsSheet.privacy(from: model.page?.header),
                                 onSaved: { Task { await model.load() } },
                                 onDelete: { confirmDelete = true })
        }
        .confirmationDialog("Delete \(model.page?.header?.title ?? "playlist")?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                Task {
                    do {
                        try await MusicAPI.deletePlaylist(target.browseId)
                        PageModel.forget(browseId: target.browseId)
                        PlayerController.shared.forgetContext(target)
                        DownloadManager.shared.remove(target)
                        LocalLibrary.shared.removeRecent(MediaItem(target: target, subtitle: ""))
                        RemoteLibraryCache.needsReload += 1
                        router.showToast(String(localized: "Removed from Your Library"))
                        router.navigate(.home)
                    } catch {
                        router.showToast(String(localized: "Couldn't delete playlist"), icon: "exclamationmark.triangle.fill")
                    }
                }
            }
        } message: {
            Text("This will delete the playlist from your YouTube Music account.")
        }
        .task(id: auth.sessionVersion) {
            await model.loadCached()
            if let header = model.page?.header, target.kind != .other, !["VLLM", "LM"].contains(target.browseId) {
                LocalLibrary.shared.recordVisit(MediaItem(
                    target: BrowseTarget(browseId: target.browseId, kind: target.kind, title: header.title, params: target.params),
                    subtitle: [header.subtitle, header.artists.map(\.name).joined(separator: ", ")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " • "),
                    thumbnail: header.thumbnail
                ))
            }
            // Part of the view's task, so it stops when the page closes.
            await model.loadRemainingTracks()
        }
    }

    private var stickyThreshold: CGFloat { target.kind == .other ? 80 : 300 }

    // MARK: Editing your playlist

    private func editing(_ page: BrowsePage) -> PlaylistEditing? {
        if target.browseId == Router.history.browseId {
            return PlaylistEditing(remove: removeFromHistory, move: nil, removeTitle: String(localized: "Remove from Listening History"),
                                   canRemove: { $0.historyToken != nil })
        }
        guard isOwned(page) else { return nil }
        let reorderable = trackSort == .custom && trackQuery.trimmingCharacters(in: .whitespaces).isEmpty
        let title = page.header?.title ?? target.title
        return PlaylistEditing(remove: remove, move: reorderable ? move : nil, add: { [model, router, target] ids in
            router.add(videoIds: ids, toPlaylist: target.browseId, title: title) { Task { await model.load() } }
        }, insert: reorderable ? { ids, index in insert(ids, at: index, title: title) } : nil)
    }

    private func remove(_ tracks: [Track]) {
        let removable = tracks.filter { $0.setVideoId != nil }
        guard !removable.isEmpty else { return }
        // For Undo: where a single removed song was, so it can go back in the same place.
        let all = model.mainTracks
        let position = removable.count == 1 ? all.firstIndex { $0.setVideoId == removable[0].setVideoId } : nil
        let successor = position.flatMap { all.indices.contains($0 + 1) ? all[$0 + 1] : nil }
        model.removeLocally(removable)
        let playlistId = target.browseId
        router.showToast(removable.count == 1 ? String(localized: "Removed from playlist") : String(localized: "Removed \(removable.count) songs from playlist"),
                         icon: "trash", undoName: String(localized: "Remove from Playlist")) { [model, router] in
            Task {
                do {
                    for track in removable {
                        let slot = try await MusicAPI.addReturningSlots(videoId: track.videoId, toPlaylist: playlistId)
                        if removable.count == 1, let slot, let successor {
                            var restored = track
                            restored.setVideoId = slot
                            try? await MusicAPI.move(restored, before: successor, inPlaylist: playlistId)
                        }
                    }
                } catch {
                    router.showToast(String(localized: "Couldn't undo"), icon: "exclamationmark.triangle.fill")
                }
                await model.load()
            }
        }
        Task {
            do {
                try await MusicAPI.remove(removable, fromPlaylist: playlistId)
            } catch {
                router.showToast(String(localized: "Couldn't remove from playlist"), icon: "exclamationmark.triangle.fill")
                await model.load()
            }
        }
    }

    private func removeFromHistory(_ tracks: [Track]) {
        let tokens = tracks.compactMap(\.historyToken)
        guard !tokens.isEmpty else { return }
        model.removeEverywhere(tracks)
        router.showToast(tokens.count == 1 ? String(localized: "Removed from your listening history") : String(localized: "Removed \(tokens.count) songs from your history"))
        Task {
            do {
                try await MusicAPI.removeFromHistory(tokens: tokens)
            } catch {
                router.showToast(String(localized: "Couldn't remove from history"), icon: "exclamationmark.triangle.fill")
                await model.load()
            }
        }
    }

    /// Songs dropped in from elsewhere: added, then moved to where they were dropped.
    private func insert(_ ids: [String], at index: Int, title: String) {
        let tracks = model.mainTracks
        let successor = tracks.indices.contains(index) ? tracks[index] : nil
        let playlistId = target.browseId
        Task { [model, router] in
            do {
                for id in ids {
                    let slot = try await MusicAPI.addReturningSlots(videoId: id, toPlaylist: playlistId)
                    if let slot, let successor {
                        var added = Track(videoId: id, title: "")
                        added.setVideoId = slot
                        try? await MusicAPI.move(added, before: successor, inPlaylist: playlistId)
                    }
                }
                router.showToast(ids.count == 1 ? String(localized: "Added to \(title)") : String(localized: "Added \(ids.count) songs to \(title)"))
            } catch {
                router.showToast(String(localized: "Couldn't add to \(title)"), icon: "exclamationmark.triangle.fill")
            }
            await model.load()
        }
    }

    private func move(_ track: Track, to index: Int) {
        guard let result = model.moveLocally(track, to: index) else { return }
        Task {
            do {
                try await MusicAPI.move(track, before: result.successor, inPlaylist: target.browseId)
            } catch {
                router.showToast(String(localized: "Couldn't reorder playlist"), icon: "exclamationmark.triangle.fill")
                await model.load()
            }
        }
    }

    /// Under your playlist's songs: "Find more", which opens the song finder in place.
    @ViewBuilder
    private var finderSection: some View {
        if showFinder {
            PlaylistFinder(playlistId: target.browseId, onAdded: { Task { await model.load() } },
                           onClose: { withAnimation(.snappy) { showFinder = false } })
                .padding(.top, 20)
                // Scrolled to with room above it: the sticky title bar (64pt) covers the top.
                .background(alignment: .top) {
                    Color.clear.frame(height: 1).alignmentGuide(.top) { $0[.top] + 84 }.id("finder")
                }
        } else {
            HStack {
                Spacer()
                Button {
                    withAnimation(.snappy) { showFinder = true }
                    scrollToFinder = true
                } label: {
                    Text("Find more")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(HoverScaleButtonStyle(hovering: false))
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }

    /// In-playlist search and sort (🔍 and "Custom order").
    private func arrange(_ tracks: [Track]) -> [Track] {
        var result = tracks
        let query = trackQuery.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            result = result.filter {
                $0.title.localizedCaseInsensitiveContains(query)
                    || $0.artistLine.localizedCaseInsensitiveContains(query)
                    || ($0.album?.name.localizedCaseInsensitiveContains(query) ?? false)
            }
        }
        switch trackSort {
        case .custom: break
        case .title: result.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist: result.sort { $0.artistLine.localizedCaseInsensitiveCompare($1.artistLine) == .orderedAscending }
        case .album: result.sort { ($0.album?.name ?? "").localizedCaseInsensitiveCompare($1.album?.name ?? "") == .orderedAscending }
        case .duration: result.sort { ($0.duration ?? 0) < ($1.duration ?? 0) }
        }
        return result
    }

    private func playableTracks(_ page: BrowsePage) -> [Track] {
        target.kind == .artist ? (page.shelves.first { $0.style == .list }?.tracks ?? []) : model.mainTracks
    }

    // MARK: Header

    @ViewBuilder
    private func header(_ page: BrowsePage) -> some View {
        if target.kind == .artist, let header = page.header {
            ArtistHeader(header: header)
            ActionBar(target: target, header: header, tracks: playableTracks(page), tint: tint, style: .artist)
        } else if isCollection, let header = page.header {
            CollectionHeader(header: header, kind: target.kind, tracks: model.mainTracks, tint: tint)
            ActionBar(target: target, header: header, tracks: model.mainTracks, tint: tint, style: .collection,
                      query: $trackQuery, sort: $trackSort, owned: isOwned(page),
                      onEdit: { editingDetails = true }, onDelete: { confirmDelete = true })
            if isOwned(page) {
                HStack(spacing: 8) {
                    OwnerPill(title: String(localized: "Add"), icon: "plus") {
                        withAnimation(.snappy) { showFinder = true }
                        scrollToFinder = true
                    }
                    OwnerPill(title: String(localized: "Name & details"), icon: "pencil") { editingDetails = true }
                }
                .padding(.horizontal, Theme.pagePadding)
                .padding(.bottom, 16)
            }
        } else if target.kind == .episode, let header = page.header {
            EpisodeHeader(header: header, videoId: String(target.browseId.dropFirst(4)), tint: tint)
        } else {
            Text(page.header?.title ?? target.title)
                .font(.pageTitle)
                .padding(.horizontal, Theme.pagePadding)
                .padding(.top, 28)
                .padding(.bottom, 20)
        }
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ page: BrowsePage) -> some View {
        VStack(alignment: .leading, spacing: 32) {
            if isOwned(page), model.mainTracks.isEmpty {
                // An empty playlist of yours: the finder is the page.
                PlaylistFinder(playlistId: target.browseId, onAdded: { Task { await model.load() } }, onClose: nil)
            }
            if page.shelves.isEmpty && !isOwned(page) {
                ContentUnavailableView("Nothing here yet", systemImage: "music.note.list",
                                       description: Text("YouTube Music didn't return anything for this page."))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            }
            ForEach(Array(page.shelves.enumerated()), id: \.element.id) { index, shelf in
                let isMain = shelf.id == model.mainShelfID
                // The page's own list keeps hidden songs (dimmed); other lists drop them.
                let tracks = isMain ? (model.shelfTracks[shelf.id] ?? []) : ContentFilter.shared.filter(model.shelfTracks[shelf.id] ?? [])
                if shelf.style == .list, !isMain, isOwned(page), !tracks.isEmpty {
                    // YouTube's suggestions for your playlist ("Recommended").
                    RecommendedSongs(playlistId: target.browseId, tracks: tracks) { Task { await model.load() } }
                } else if shelf.style == .list, !tracks.isEmpty, shelf.items.allSatisfy({ $0.track != nil }) {
                    VStack(alignment: .leading, spacing: 12) {
                        if target.kind == .artist {
                            Text(index == 0 ? String(localized: "Popular") : (shelf.title ?? String(localized: "Songs")))
                                .font(.sectionTitle)
                                .padding(.horizontal, 12)
                        } else if let title = shelf.title, !isCollection {
                            Text(title).font(.sectionTitle).padding(.horizontal, 12)
                        }
                        let shown = isMain && isCollection && (trackSort != .custom || !trackQuery.isEmpty) ? arrange(tracks) : tracks
                        // An artist's Popular: five songs, ten with "See more".
                        let popular = target.kind == .artist && index == 0
                        TrackList(tracks: shown,
                                  showArtwork: target.kind != .album,
                                  showAlbum: target.kind == .playlist || target.kind == .other,
                                  showHeader: isCollection && isMain,
                                  // Artists and albums: when YouTube counts them.
                                  showPlays: target.kind == .artist || (target.kind == .album && shown.contains { $0.plays != nil }),
                                  showArtists: !popular,
                                  visibleCount: popular ? (popularExpanded ? 10 : 5) : nil,
                                  // An artist's lengths arrive a moment after the page: keep their
                                  // column from the start so nothing shifts.
                                  durationColumn: target.kind == .artist ? true : nil) {
                            Task { await model.loadMore(into: shelf.id) }
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("page")).minY } action: { top in
                            if isMain { listTop = top }
                        }
                        if popular, shown.count > 5 {
                            Button(popularExpanded ? String(localized: "Show less") : String(localized: "See more")) {
                                popularExpanded.toggle()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Theme.secondary)
                            .hoverUnderline()
                            .padding(.horizontal, 28)
                            .padding(.top, 4)
                        }
                        if shown.isEmpty {
                            ContentUnavailableView.search(text: trackQuery.trimmingCharacters(in: .whitespaces))
                                // Only loaded songs are searched: fetch the rest of a long list.
                                .task(id: tracks.count) { await model.loadMore(into: shelf.id) }
                        }
                        if isMain, isOwned(page) {
                            finderSection
                        }
                    }
                } else {
                    ShelfView(shelf: shelf) { Task { await model.loadMore(into: shelf.id) } }
                }
            }
            if let token = page.continuation {
                // e.g. "Related playlists" under a playlist.
                SkeletonCarousel()
                    .task(id: token) { await model.loadMoreShelves() }
            }
            if target.kind == .album || target.kind == .podcast, let description = page.header?.description {
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 16)
            }
        }
        .padding(.horizontal, Theme.pagePadding - 12)
        .padding(.top, isCollection || target.kind == .artist ? 0 : 0)
        .padding(.bottom, 32)
    }
}

// MARK: - Collection header

struct CollectionHeader: View {
    var header: PageHeader
    var kind: PageKind
    var tracks: [Track]
    var tint: Color
    @Environment(Router.self) private var router

    private var meta: String {
        var parts: [String] = []
        if let subtitle = header.subtitle {
            // "Album • 2013" → keep the year; playlist subtitles already read well.
            parts += subtitle.components(separatedBy: " • ").filter { !["Album", "Playlist", "Single", "EP"].contains($0) }
        }
        // YouTube's own count covers the whole playlist; loaded tracks may only be the first page.
        if let second = header.secondSubtitle, !second.isEmpty {
            parts += second.components(separatedBy: " • ").filter {
                !$0.contains("views") && !$0.hasPrefix("0 ")
            }
        } else if !tracks.isEmpty {
            parts.append(Format.count(tracks.count, .song))
            let total = tracks.compactMap(\.duration).reduce(0, +)
            if total > 0 { parts.append(Format.longDuration(total)) }
        }
        return parts.joined(separator: " • ")
    }

    private var label: String {
        header.subtitle?.components(separatedBy: " • ").first ?? (kind == .album ? String(localized: "Album") : String(localized: "Playlist"))
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 24) {
            ArtworkView(url: header.thumbnail, size: 232, cornerRadius: 6)
                .shadow(color: .black.opacity(0.5), radius: 24, y: 8)

            VStack(alignment: .leading, spacing: 8) {
                Text(label).font(.system(size: 14, weight: .medium))
                Text(header.title)
                    .font(.system(size: 76, weight: .black))
                    .tracking(-1.5)
                    .lineLimit(2)
                    .minimumScaleFactor(0.35)
                    .padding(.bottom, 6)
                HStack(spacing: 6) {
                    if let owner = header.owner {
                        if let avatar = header.ownerAvatar {
                            ArtworkView(url: avatar, size: 24, circle: true)
                        }
                        ArtistLinks(artists: [owner], font: .system(size: 14, weight: .bold), color: Theme.text)
                    } else if !header.artists.isEmpty {
                        ArtistLinks(artists: header.artists, font: .system(size: 14, weight: .bold), color: Theme.text)
                    }
                    if !meta.isEmpty {
                        Text((header.artists.isEmpty && header.owner == nil ? "" : "• ") + meta)
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.text.opacity(0.75))
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.text)
        .padding(.horizontal, Theme.pagePadding)
        .padding(.top, 64)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [tint.headerTint(), tint.headerTint().mix(with: Theme.shade, by: 0.45)], startPoint: .top, endPoint: .bottom)
        )
    }
}

// MARK: - Podcast episode

/// A podcast episode's page: artwork, title, the show, a Play button and the show notes.
struct EpisodeHeader: View {
    var header: PageHeader
    var videoId: String
    var tint: Color
    private var player: PlayerController { .shared }

    private var episode: Track {
        Track(videoId: videoId, title: header.title, artists: header.artists, thumbnail: header.thumbnail, isVideo: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .bottom, spacing: 24) {
                ArtworkView(url: header.thumbnail, size: 200, cornerRadius: 8)
                    .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Podcast episode").font(.system(size: 14, weight: .medium))
                    Text(header.title)
                        .font(.system(size: 40, weight: .black))
                        .lineLimit(3)
                        .minimumScaleFactor(0.5)
                    if !header.artists.isEmpty {
                        ArtistLinks(artists: header.artists, font: .system(size: 15, weight: .bold), color: Theme.text)
                    }
                    if let subtitle = header.subtitle { Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.text.opacity(0.75)) }
                }
            }
            HStack(spacing: 16) {
                let current = player.current?.videoId == videoId
                PlayCircleButton(size: 56, isPlaying: current && player.isPlaying) {
                    if current { player.togglePlayPause() } else { player.play([episode]) }
                }
                if let resume = player.resumePosition(for: episode) {
                    Text("Resumes at \(Format.time(resume))").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                IconButton(systemImage: "text.badge.plus", size: 20, label: String(localized: "Add to playlist")) { Router.shared.addToPlaylist([episode]) }
                IconButton(systemImage: "text.append", size: 20, label: String(localized: "Add to queue")) {
                    player.addToQueue([episode])
                    Router.shared.showToast(String(localized: "Added to queue"))
                }
            }
            if let description = header.description {
                Text(description)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: 760, alignment: .leading)
            }
        }
        .padding(.horizontal, Theme.pagePadding)
        .padding(.top, 48)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [tint.headerTint(), Theme.panel], startPoint: .top, endPoint: .bottom))
    }
}

// MARK: - Artist header

struct ArtistHeader: View {
    var header: PageHeader

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            GeometryReader { geo in
                ArtworkBanner(url: header.thumbnail, width: geo.size.width, height: 360)
            }
            .frame(height: 360)
            LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 8) {
                Text(header.title)
                    .font(.system(size: 84, weight: .black))
                    .tracking(-2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                if let subtitle = header.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 15, weight: .medium))
                }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.4), radius: 12)
            .padding(.horizontal, Theme.pagePadding)
            .padding(.bottom, 24)
        }
        .frame(height: 360)
        .clipped()
    }
}

struct ArtworkBanner: View {
    var url: URL?
    var width: CGFloat
    var height: CGFloat = 340
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Theme.elevated)
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: width, height: height)
                    .clipped()
            }
        }
        .frame(width: width, height: height)
        .task(id: url) {
            // Artist banners are wide crops; keep the original URL rather than forcing a square size.
            guard let url else { return }
            let loaded = await ImageLoader.shared.image(for: url)
            withAnimation { image = loaded }
        }
    }
}

// MARK: - Action bar (big play button row)

struct ActionBar: View {
    enum Style { case collection, artist }

    var target: BrowseTarget
    var header: PageHeader
    var tracks: [Track]
    var tint: Color
    var style: Style
    var query: Binding<String>? = nil
    var sort: Binding<TrackSort>? = nil
    var owned = false
    var onEdit: () -> Void = {}
    var onDelete: () -> Void = {}
    @State private var searching = false
    @FocusState private var searchFocused: Bool
    private var player: PlayerController { .shared }
    private var account: AccountLibrary { .shared }
    private var downloads: DownloadManager { .shared }

    private var item: MediaItem {
        MediaItem(target: BrowseTarget(browseId: target.browseId, kind: target.kind, title: header.title, params: target.params),
                  subtitle: header.subtitle ?? "", thumbnail: header.thumbnail, playlistId: header.playlistId)
    }

    private var playingHere: Bool { player.isPlaying && player.isPlaying(from: target) }
    private var isLikedSongs: Bool { ["VLLM", "LM"].contains(target.browseId) }

    var body: some View {
        HStack(spacing: 20) {
            if !tracks.isEmpty {
                PlayCircleButton(size: 56, isPlaying: playingHere) { player.playOrToggle(tracks, from: target) }
                IconButton(systemImage: "shuffle", size: 26, label: String(localized: "Shuffle play")) {
                    player.play(tracks, shuffled: true, from: target)
                }
            }
            if style == .artist {
                let following = account.isSubscribed(item, header: header)
                Button { account.toggleSubscribed(item, header: header) } label: {
                    Text(following ? String(localized: "Subscribed") : String(localized: "Subscribe"))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .overlay(Capsule().strokeBorder(following ? Theme.text : Theme.secondary, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .tooltip(following ? String(localized: "Unsubscribe") : String(localized: "Subscribe"))
                if header.radioPlaylistId != nil {
                    IconButton(systemImage: "dot.radiowaves.left.and.right", size: 22, label: String(localized: "Start artist mix")) {
                        player.startRadio(for: item, header: header)
                    }
                }
            } else {
                if !owned, !isLikedSongs {
                    let saved = account.isSaved(item, header: header)
                    IconButton(systemImage: saved ? "checkmark.circle.fill" : "plus.circle", size: 28, active: saved,
                               label: saved ? String(localized: "Remove from Your Library") : String(localized: "Save to Your Library")) {
                        account.toggleSaved(item, header: header)
                    }
                }
                downloadButton
            }
            MenuButton.more(size: 22) {
                var entries = MediaMenuEntries.make(item, header: header, tracks: tracks, owned: owned)
                if owned {
                    entries += [
                        .divider,
                        .action(String(localized: "Edit Details"), systemImage: "pencil", onEdit),
                        .item(String(localized: "Delete"), systemImage: "minus.circle", destructive: true, action: onDelete),
                    ]
                }
                return entries
            }
            .fixedSize()
            Spacer()
            if let query, let sort {
                HStack(spacing: 6) {
                    if searching {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                            TextField("Search in playlist", text: query)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .focused($searchFocused)
                                .frame(width: 170)
                                .onExitCommand { query.wrappedValue = ""; searching = false }
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.text.opacity(0.1)))
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                        // Clicking elsewhere leaves the field; an empty search folds back into its icon.
                        .endEditingOnOutsideClick(isActive: searchFocused) {
                            searchFocused = false
                            if query.wrappedValue.isEmpty { withAnimation(.snappy) { searching = false } }
                        }
                    } else {
                        IconButton(systemImage: "magnifyingglass", size: 15, label: String(localized: "Search in playlist")) {
                            withAnimation(.snappy) { searching = true }
                            searchFocused = true
                        }
                    }
                    MenuButton(alignment: .trailing) {
                        [.header(String(localized: "Sort by"))]
                            + TrackSort.allCases.map { option in .choice(option.name, selected: sort.wrappedValue == option) { sort.wrappedValue = option } }
                    } label: { open in
                        HStack(spacing: 6) {
                            Text(sort.wrappedValue.name).font(.system(size: 13))
                            Image(systemName: "list.bullet").font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(open ? Theme.text : Theme.secondary)
                    }
                    .fixedSize()
                }
            }
        }
        .padding(.horizontal, Theme.pagePadding)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [tint.headerTint().mix(with: Theme.shade, by: 0.55), Theme.panel], startPoint: .top, endPoint: .bottom)
        )
    }

    /// ⬇︎: download for offline, a progress ring while it runs, filled once done.
    @ViewBuilder
    private var downloadButton: some View {
        switch downloads.state(for: target) {
        case .none:
            IconButton(systemImage: "arrow.down.circle", size: 28, label: String(localized: "Download")) {
                guard !tracks.isEmpty else { return }
                downloads.download(item, header: header, tracks: tracks)
            }
            .disabled(tracks.isEmpty)
        case .downloading(let progress):
            Button { downloads.remove(target) } label: {
                ZStack {
                    Circle().stroke(Theme.tertiary, lineWidth: 2.5)
                    Circle().trim(from: 0, to: max(0.03, progress))
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.3), value: progress)
                    Image(systemName: "stop.fill").font(.system(size: 8)).foregroundStyle(Theme.text)
                }
                .frame(width: 26, height: 26)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tooltip(String(localized: "Downloading \(Int(progress * 100))% — click to cancel"))
            .accessibilityLabel("Downloading, \(Int(progress * 100)) percent. Cancel download")
        case .downloaded:
            IconButton(systemImage: "arrow.down.circle.fill", size: 28, active: true, label: String(localized: "Remove download")) {
                downloads.remove(target)
            }
        }
    }
}

/// Compact bar that pins the title and Play button once the header scrolls away.
struct StickyHeader: View {
    var target: BrowseTarget
    var title: String
    var tint: Color
    var tracks: [Track]
    private var player: PlayerController { .shared }

    var body: some View {
        HStack(spacing: 12) {
            PlayCircleButton(size: 40, isPlaying: player.isPlaying && player.isPlaying(from: target)) {
                player.playOrToggle(tracks, from: target)
            }
                .disabled(tracks.isEmpty)
            Text(title).font(.sectionTitle).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, Theme.pagePadding)
        .frame(height: 64)
        // Close to the header's own colour.
        .background(tint.headerTint().mix(with: Theme.shade, by: 0.2))
    }
}

enum TrackSort: String, CaseIterable, Identifiable {
    case custom = "Custom order", title = "Title", artist = "Artist", album = "Album", duration = "Duration"
    var id: String { rawValue }
    /// Shown in the UI (the raw value is what's saved).
        var name: String {
            switch self {
            case .custom: String(localized: "Custom order")
            case .title: String(localized: "Title")
            case .artist: String(localized: "Artist")
            case .album: String(localized: "Album")
            case .duration: String(localized: "Duration")
            }
        }
}

struct OwnerPill: View {
    var title: String
    var icon: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(Theme.text.opacity(hovering ? 0.16 : 0.1)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
