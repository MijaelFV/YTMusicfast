import SwiftUI

/// Recent searches, remembered locally.
@MainActor
enum RecentSearches {
    private static let key = "recentSearches.v2"

    static var all: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }

    static func add(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        // A private session leaves no trace.
        guard trimmed.count > 1, !PlayerController.shared.privateSession else { return }
        let updated = [trimmed] + all.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        UserDefaults.standard.set(Array(updated.prefix(10)), forKey: key)
    }

    static func remove(_ query: String) {
        UserDefaults.standard.set(all.filter { $0 != query }, forKey: key)
    }

    // What you opened or played from Search, shown with artwork.
    private static let itemsKey = "recentSearchItems"

    static var items: [ShelfItem] {
        (UserDefaults.standard.data(forKey: itemsKey)).flatMap { try? JSONDecoder().decode([ShelfItem].self, from: $0) } ?? []
    }

    static func add(_ item: ShelfItem) {
        guard !PlayerController.shared.privateSession else { return }
        let updated = [item] + items.filter { $0.id != item.id }
        if let data = try? JSONEncoder().encode(Array(updated.prefix(12))) { UserDefaults.standard.set(data, forKey: itemsKey) }
    }

    static func remove(_ item: ShelfItem) {
        if let data = try? JSONEncoder().encode(items.filter { $0.id != item.id }) { UserDefaults.standard.set(data, forKey: itemsKey) }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: itemsKey)
    }
}

/// Results already seen this session, so Back from an artist, or switching between All and
/// Songs, shows them at once instead of searching again. Small and in memory only.
@MainActor
enum SearchCache {
    private static var entries: [String: (results: SearchResults, filters: [SearchFilter], date: Date)] = [:]
    private static var order: [String] = []
    /// Shown at once when older, but searched again behind them.
    static let fresh: TimeInterval = 10 * 60

    /// Per account: signing in or out changes what YouTube returns.
    private static func scoped(_ key: String) -> String { AuthManager.shared.cacheIdentity + "|" + key }

    static func get(_ key: String) -> (results: SearchResults, filters: [SearchFilter], date: Date)? { entries[scoped(key)] }

    static func put(_ key: String, _ results: SearchResults, filters: [SearchFilter]) {
        let key = scoped(key)
        entries[key] = (results, filters, Date())
        order.removeAll { $0 == key }
        order.append(key)
        if order.count > 20 { entries[order.removeFirst()] = nil }
    }
}

/// Searching what plays without the internet: downloads, songs in the replay cache you've
/// played lately, and your own files (offline, search looks through your downloads).
@MainActor
enum OfflineSearch {
    static func tracks(matching query: String) -> [Track] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        var seen = Set<String>()
        var found: [Track] = []
        let candidates = DownloadManager.shared.collections.flatMap(\.tracks)
            + LocalFiles.shared.tracks
            + LocalLibrary.shared.recentTracks.filter { PlayerController.availableOffline($0) }
        for track in candidates where PlayerController.availableOffline(track) && !seen.contains(track.videoId) {
            let text = ([track.title, track.album?.name ?? ""] + track.artists.map(\.name)).joined(separator: " ").lowercased()
            guard words.allSatisfy(text.contains) else { continue }
            seen.insert(track.videoId)
            found.append(track)
            if found.count >= 100 { break }
        }
        return found
    }
}

struct SearchView: View {
    @Environment(Router.self) private var router
    @State private var filter: SearchFilter?
    @State private var results: SearchResults?
    @State private var filters: [SearchFilter] = []
    @State private var error: (any Error)?
    @State private var loadingMore = false
    /// The query+filter the visible results belong to; when it differs, results are stale.
    @State private var resultsKey = ""
    @State private var recents = RecentSearches.all
    @State private var recentItems = RecentSearches.items
    /// The results are this Mac's own music (offline), not YouTube's.
    @State private var offlineResults = false
    @Environment(\.openSettings) private var openSettings

    private var query: String { router.submittedQuery }
    private var currentKey: String { "\(query)|\(filter?.params ?? "")" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if query.isEmpty {
                    browse
                } else {
                    if !filters.isEmpty {
                        HStack(spacing: 8) {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(Array(filters.enumerated()), id: \.element.id) { index, chip in
                                        Chip(title: chip.title, selected: selectedIndex == index) {
                                            select(index)
                                        }
                                    }
                                }
                                .padding(.leading, Theme.pagePadding)
                                .padding(.trailing, 24)
                            }
                            // Chips that don't fit fade out instead of being cut mid-word.
                            .mask {
                                HStack(spacing: 0) {
                                    Rectangle()
                                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 28)
                                }
                            }
                            filtersButton
                                .padding(.trailing, Theme.pagePadding - 6)
                        }
                        .background { shortcuts }
                    }
                    if let error, results == nil || resultsKey != currentKey {
                        ErrorView(error: error) { Task { await run() } }
                    } else if let results {
                        let stale = resultsKey != currentKey
                        resultsView(results)
                            .opacity(stale ? 0.35 : 1)
                            .overlay(alignment: .top) { if stale { ProgressView().padding(.top, 40) } }
                            .allowsHitTesting(!stale)
                            .animation(.easeOut(duration: 0.15), value: stale)
                    } else {
                        SkeletonRows().padding(.horizontal, Theme.pagePadding)
                    }
                }
            }
            .padding(.vertical, 20)
            .restoresScrollPosition()
        }
        .task(id: currentKey) {
            guard !query.isEmpty else { results = nil; return }
            let key = currentKey
            let offline = PlayerController.shared.offlineMode || !Connectivity.shared.isOnline
            if !offline, let cached = SearchCache.get(key) {
                // Seen moments ago (Back, or another chip and back): at once, no skeleton.
                results = cached.results
                resultsKey = key
                offlineResults = false
                if !cached.filters.isEmpty { filters = cached.filters }
                error = nil
            }
            if offline || SearchCache.get(key).map({ Date().timeIntervalSince($0.date) < SearchCache.fresh }) != true {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                await run()
            }
            // Remember queries the user lingered on.
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled, results != nil {
                RecentSearches.add(query)
                recents = RecentSearches.all
            }
        }
        .onChange(of: router.submittedQuery) { filter = nil }
        .environment(\.searchOrigin, true)
        .onAppear { recentItems = RecentSearches.items }
    }

    // MARK: Empty state: recent searches + Browse all

    @ViewBuilder
    private var browse: some View {
        if !recentItems.isEmpty {
            // Opened from Search before: one click back (Recent searches).
            ShelfView(shelf: Shelf(title: String(localized: "Recently opened"), style: .carousel,
                                   items: ContentFilter.shared.filter(recentItems)))
                .padding(.horizontal, Theme.pagePadding - 12)
                .environment(\.searchOrigin, false)
        }
        if !recents.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Recent searches").font(.sectionTitle).padding(.horizontal, Theme.pagePadding)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(recents, id: \.self) { recent in
                            HStack(spacing: 8) {
                                Text(recent).font(.system(size: 14, weight: .medium))
                                Button {
                                    RecentSearches.remove(recent)
                                    recents = RecentSearches.all
                                } label: {
                                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.secondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove \(recent)")
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Theme.chip))
                            .contentShape(Capsule())
                            .onTapGesture { router.search(recent) }
                        }
                    }
                    .padding(.horizontal, Theme.pagePadding)
                }
            }
        }
        if !recents.isEmpty || !recentItems.isEmpty {
            Button("Clear recent searches") {
                RecentSearches.clear()
                recents = []
                recentItems = []
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.secondary)
            .hoverUnderline()
            .padding(.horizontal, Theme.pagePadding)
        }
        BrowseAllView()
    }

    // MARK: Results

    @ViewBuilder
    private func resultsView(_ results: SearchResults) -> some View {
        let visible = ContentFilter.shared.filter(results.items)
        let songs = visible.compactMap(\.track).filter { !$0.isVideo }
        let videos = visible.compactMap(\.track).filter(\.isVideo)
        let media = visible.compactMap { item -> MediaItem? in
            if case .media(let m) = item { return m }
            return nil
        }

        if offlineResults {
            VStack(alignment: .leading, spacing: 12) {
                Label(PlayerController.shared.offlineMode ? String(localized: "Offline Mode — searching music on this Mac")
                                                          : String(localized: "You're offline — searching music on this Mac"),
                      systemImage: "icloud.slash")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, Theme.pagePadding)
                if songs.isEmpty {
                    ContentUnavailableView.search(text: query).padding(.top, 20)
                } else {
                    TrackList(tracks: songs + videos, showHeader: true)
                        .padding(.horizontal, Theme.pagePadding - 12)
                }
            }
        } else if results.items.isEmpty && results.top == nil {
            ContentUnavailableView.search(text: query).padding(.top, 40)
        } else if filter != nil {
            filtered(songs: songs + videos, media: media)
        } else {
            // YouTube Music's layout: the top result as a wide banner, then
            // everything else in one list, in YouTube's order, each row saying what it is.
            let top = results.top.flatMap { ContentFilter.shared.filter([$0]).first }
            VStack(alignment: .leading, spacing: 20) {
                if let top {
                    TopResultBanner(item: top, subtitle: results.topSubtitle)
                        .padding(.horizontal, Theme.pagePadding)
                }
                LazyVStack(spacing: 0) {
                    ForEach(visible.filter { $0.id != top?.id }) { item in
                        SearchResultRow(item: item)
                    }
                }
                .padding(.horizontal, Theme.pagePadding - 12)
            }
        }
    }

    @ViewBuilder
    private func filtered(songs: [Track], media: [MediaItem]) -> some View {
        if media.isEmpty {
            TrackList(tracks: songs, showHeader: true, showPlays: songs.contains { $0.plays != nil }) { Task { await loadMore() } }
                .padding(.horizontal, Theme.pagePadding - 12)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 0, alignment: .top)], spacing: 8) {
                ForEach(Array(media.enumerated()), id: \.offset) { index, item in
                    MediaCard(item: .media(item), size: 156)
                        .onAppear { if index == media.count - 1 { Task { await loadMore() } } }
                }
            }
            .padding(.horizontal, Theme.pagePadding - 12)
        }
    }

    // MARK: Filters

    /// YouTube Music's chip at `index` (All, Songs, Albums…).
    private func select(_ index: Int) {
        guard filters.indices.contains(index) else { return }
        filter = filters[index].params == nil ? nil : filters[index]
    }

    private var selectedIndex: Int {
        filters.firstIndex { $0.title == (filter?.title ?? String(localized: "All")) } ?? 0
    }

    /// The content filters from Settings, at hand while searching. They apply everywhere, at once.
    private var filtersButton: some View {
        let content = ContentFilter.shared
        let hiding = content.hideAI || content.hideExplicit || content.hideUnavailable
        return MenuButton(alignment: .trailing, entries: { filterMenu }) { open in
            Image(systemName: hiding ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 20))
                .foregroundStyle(open ? Theme.text : Theme.secondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .tooltip(String(localized: "Content filter"), edge: .bottom)
        .accessibilityLabel("Content filter")
    }

    private var filterMenu: [MenuEntry] {
        let content = ContentFilter.shared
        return [
            .header(String(localized: "Hide")),
            .choice(String(localized: "AI-generated music"), systemImage: "sparkles", selected: content.hideAI) { content.hideAI.toggle() },
            .choice(String(localized: "Explicit songs"), systemImage: "e.square", selected: content.hideExplicit) { content.hideExplicit.toggle() },
            .choice(String(localized: "Songs that can't be played"), systemImage: "nosign", selected: content.hideUnavailable) { content.hideUnavailable.toggle() },
            .divider,
            .item(String(localized: "Content filter settings…"), systemImage: "gearshape") {
                UserDefaults.standard.set("filter", forKey: "settingsTab")
                openSettings()
            },
            .footer(AnyView(
                Text("Applies everywhere, like in Settings. Artists and songs you hid stay hidden.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 220, alignment: .leading)
            )),
        ]
    }

    /// ⌘1–⌘9 pick a filter, ⌃Tab / ⌃⇧Tab move to the next or previous one.
    private var shortcuts: some View {
        ZStack {
            ForEach(0..<min(9, filters.count), id: \.self) { index in
                Button("") { select(index) }.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            Button("") { select((selectedIndex + 1) % filters.count) }.keyboardShortcut(.tab, modifiers: .control)
            Button("") { select((selectedIndex + filters.count - 1) % filters.count) }.keyboardShortcut(.tab, modifiers: [.control, .shift])
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// YouTube Music's "Songs" search filter.
    private static let songsFilter = "EgWKAQIIAWoMEA4QChADEAQQCRAF"

    private func run() async {
        error = nil
        let key = currentKey
        // Offline (or Offline Mode): this Mac's own music, without asking YouTube.
        if PlayerController.shared.offlineMode || !Connectivity.shared.isOnline {
            showOffline(key)
            return
        }
        do {
            // "All" lists its songs without lengths; the songs-only search has them. Asked at the
            // same time, so it adds no waiting, and only used to fill those in.
            async let songsOnly = filter == nil ? try? MusicAPI.search(query, params: Self.songsFilter) : nil
            let fresh = try await MusicAPI.search(query, params: filter?.params)
            guard !Task.isCancelled else { return }
            // Results show at once; the lengths follow when (if) they arrive.
            results = fresh
            resultsKey = key
            offlineResults = false
            if !fresh.filters.isEmpty { filters = fresh.filters }
            SearchCache.put(key, fresh, filters: filters)
            guard let songs = await songsOnly, !Task.isCancelled, resultsKey == key else { return }
            let lengths = Dictionary(songs.items.compactMap { item in item.track.flatMap { track in track.duration.map { (track.videoId, $0) } } },
                                     uniquingKeysWith: { first, _ in first })
            guard var shown = results,
                  shown.items.contains(where: { $0.track.map { $0.duration == nil && lengths[$0.videoId] != nil } ?? false }) else { return }
            shown.items = shown.items.map { item in
                guard case .track(var track) = item, track.duration == nil, let length = lengths[track.videoId] else { return item }
                track.duration = length
                return .track(track)
            }
            results = shown
            SearchCache.put(key, shown, filters: filters)
        } catch {
            guard !Task.isCancelled else { return }
            if PlayerController.isNetworkError(error) {
                // The connection dropped: what's on this Mac now, YouTube's results once it's back.
                showOffline(key)
            } else {
                self.error = error
            }
        }
    }

    private func showOffline(_ key: String) {
        results = SearchResults(items: OfflineSearch.tracks(matching: query).map(ShelfItem.track))
        resultsKey = key
        offlineResults = true
        guard !PlayerController.shared.offlineMode else { return }
        Connectivity.shared.whenOnline(retryAfter: 5) {
            Task { @MainActor in
                guard offlineResults, resultsKey == key, currentKey == key else { return }
                await run()
            }
        }
    }

    private func loadMore() async {
        guard !loadingMore, let token = results?.continuation, resultsKey == currentKey else { return }
        let key = resultsKey
        loadingMore = true
        defer { loadingMore = false }
        // Dropped if the query changed meanwhile: this page belongs to the old results.
        guard let more = try? await MusicAPI.searchContinuation(token), key == resultsKey else { return }
        results?.items += more.items
        results?.continuation = more.continuation
        if let results { SearchCache.put(key, results, filters: filters) }
    }
}

/// "Browse all": YouTube Music's moods & genres as coloured tiles.
struct BrowseAllView: View {
    @State private var model = PageModel(.target(Router.moods))

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Browse all").font(.sectionTitle).padding(.horizontal, Theme.pagePadding)
            if let page = model.page {
                VStack(alignment: .leading, spacing: 28) {
                    ForEach(page.shelves) { ShelfView(shelf: $0) }
                }
                .padding(.horizontal, Theme.pagePadding - 12)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 16)], spacing: 16) {
                    ForEach(0..<12, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.elevated).frame(height: 100)
                    }
                }
                .shimmer()
                .padding(.horizontal, Theme.pagePadding)
            }
        }
        .task { await model.load() }
    }
}

/// What a search result is, as a short label ("Song", "Album", "Single"…): YouTube's own word
/// when its subtitle starts with one.
enum ResultKind {
    static func label(_ item: ShelfItem, subtitle: String? = nil) -> String {
        switch item {
        case .track(let t): return t.isVideo ? String(localized: "Video") : String(localized: "Song")
        case .media(let m):
            let first = (subtitle ?? m.subtitle).components(separatedBy: " • ").first ?? ""
            if ["Album", "Single", "EP", "Playlist", "Podcast", "Episode", "Profile", "Artist"].contains(first) {
                return String(localized: String.LocalizationValue(first))
            }
            switch m.target.kind {
            case .artist: return String(localized: "Artist")
            case .album: return String(localized: "Album")
            case .playlist: return String(localized: "Playlist")
            case .podcast: return String(localized: "Podcast")
            case .episode: return String(localized: "Episode")
            case .other: return ""
            }
        }
    }

    /// The subtitle without its leading kind word (shown as the label instead).
    static func detail(_ subtitle: String) -> String {
        let parts = subtitle.components(separatedBy: " • ")
        guard let first = parts.first, ["Album", "Single", "EP", "Playlist", "Podcast", "Episode", "Profile", "Artist", "Song", "Video"].contains(first)
        else { return subtitle }
        return parts.dropFirst().joined(separator: " • ")
    }
}

/// The top result across the page (as in YouTube Music): big artwork, its name and kind, and
/// Play. A click opens it (or plays a song).
struct TopResultBanner: View {
    var item: ShelfItem
    var subtitle: String?
    @State private var hovering = false
    @Environment(Router.self) private var router

    var body: some View {
        HStack(spacing: 24) {
            switch item {
            case .track(let track):
                ArtworkView(url: track.thumbnail, size: 112, cornerRadius: 6)
                    .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
                VStack(alignment: .leading, spacing: 6) {
                    Text(track.title).font(.system(size: 30, weight: .bold)).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(ResultKind.label(item)).foregroundStyle(Theme.secondary)
                        Text("•").foregroundStyle(Theme.secondary)
                        ArtistLinks(artists: track.artists, font: .system(size: 15), color: Theme.secondary, interactive: hovering)
                        let extra = [track.duration.map(Format.time), track.plays].compactMap { $0 }
                        if !extra.isEmpty {
                            Text("• " + extra.joined(separator: " • ")).foregroundStyle(Theme.secondary)
                        }
                    }
                    .font(.system(size: 15))
                }
            case .media(let media):
                ArtworkView(url: media.thumbnail, size: 112, cornerRadius: 6, circle: media.target.kind == .artist)
                    .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
                VStack(alignment: .leading, spacing: 6) {
                    Text(media.title).font(.system(size: 30, weight: .bold)).lineLimit(1)
                    let detail = ResultKind.detail(subtitle ?? media.subtitle)
                    LinkedSubtitle(text: [ResultKind.label(item, subtitle: subtitle), detail].filter { !$0.isEmpty }.joined(separator: " • "),
                                   artists: media.artists ?? [], interactive: hovering, lines: 1, font: .system(size: 15))
                }
            }
            Spacer(minLength: 16)
            if canPlay {
                PlayCircleButton(size: 56, action: play)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.text.opacity(hovering ? 0.1 : 0.06)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .menuOnRightClick(hovering: hovering) {
            switch item {
            case .track(let track): TrackMenuEntries.make(for: track)
            case .media(let media): MediaMenuEntries.make(media)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
        .accessibilityAction(named: "Play") { play() }
    }

    private var canPlay: Bool {
        if case .media(let m) = item { return m.target.kind != .other }
        return true
    }

    private func open() {
        RecentSearches.add(item)
        switch item {
        case .track: play()
        case .media(let media): router.open(media.target)
        }
    }

    private func play() {
        RecentSearches.add(item)
        switch item {
        case .track(let track): PlayerController.shared.playRadio(from: track)
        case .media(let media): PlayerController.shared.playCollection(media.target, playlistId: media.playlistId)
        }
    }
}

/// One search result of any kind: artwork, title, who it's by (clickable), what it is, and for
/// songs their length, like and menu.
struct SearchResultRow: View {
    var item: ShelfItem
    @State private var hovering = false
    @Environment(Router.self) private var router
    private var player: PlayerController { .shared }

    var body: some View {
        HStack(spacing: 16) {
            switch item {
            case .track(let track):
                let current = player.current?.videoId == track.videoId
                ArtworkView(url: track.thumbnail, size: 48, cornerRadius: 4)
                    .overlay {
                        if hovering || (current && player.isPlaying) {
                            RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.5))
                            if hovering {
                                Image(systemName: current && player.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 16)).foregroundStyle(.white)
                            } else {
                                EqualizerBars(animating: true)
                            }
                        }
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title).font(.system(size: 15)).foregroundStyle(current ? Theme.accent : Theme.text).lineLimit(1).help(track.title)
                    HStack(spacing: 4) {
                        if track.isExplicit == true { ExplicitBadge() }
                        ArtistLinks(artists: track.artists, color: hovering ? Theme.text : Theme.secondary, interactive: hovering)
                            .layoutPriority(1)
                        // What else YouTube says about it (YouTube Music shows the same).
                        let extra = [track.duration.map(Format.time), track.plays].compactMap { $0 }
                        if !extra.isEmpty {
                            Text("• " + extra.joined(separator: " • "))
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case .media(let media):
                ArtworkView(url: media.thumbnail, size: 48, cornerRadius: 4, circle: media.target.kind == .artist)
                VStack(alignment: .leading, spacing: 3) {
                    Text(media.title).font(.system(size: 15)).foregroundStyle(Theme.text).lineLimit(1).help(media.title)
                    let detail = ResultKind.detail(media.subtitle)
                    if !detail.isEmpty {
                        LinkedSubtitle(text: detail, artists: media.artists ?? [], interactive: hovering, lines: 1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(ResultKind.label(item))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.text.opacity(0.08)))
                .frame(width: 110, alignment: .leading)
            // Like and ⋯ side by side: no slot kept for anything that isn't there.
            HStack(spacing: 16) {
                if case .track(let track) = item, hovering || player.isLiked(track) {
                    LikeToggle(track: track, hovering: hovering)
                } else {
                    Color.clear.frame(width: 16, height: 16)
                }
                if hovering {
                    Button { MenuPresenter.shared.showContextMenu(menu) } label: {
                        Image(systemName: "ellipsis").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.text)
                            .frame(width: 20, height: 20).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("More options")
                } else {
                    Color.clear.frame(width: 20, height: 20)
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 64)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(hovering ? Theme.text.opacity(0.1) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .menuOnRightClick(hovering: hovering) { menu }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
    }

    private var menu: [MenuEntry] {
        switch item {
        case .track(let track): TrackMenuEntries.make(for: track)
        case .media(let media): MediaMenuEntries.make(media)
        }
    }

    private func open() {
        RecentSearches.add(item)
        switch item {
        case .track(let track):
            if player.current?.videoId == track.videoId { player.togglePlayPause() } else { player.playRadio(from: track) }
        case .media(let media): router.open(media.target)
        }
    }
}
