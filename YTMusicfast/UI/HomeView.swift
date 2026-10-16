import SwiftUI

struct HomeView: View {
    enum Feed: String, CaseIterable, Identifiable {
        case forYou = "All", explore = "Explore", charts = "Charts"
        var id: String { rawValue }
        /// Shown in the UI (the raw value is what's saved).
        var title: String {
            switch self {
            case .forYou: String(localized: "All")
            case .explore: String(localized: "Explore")
            case .charts: String(localized: "Charts")
            }
        }
    }

    @State private var feed: Feed = .forYou
    @State private var model = PageModel(.home(chip: nil))
    /// YouTube Music's mood chips (Energize, Relax, Workout…), from the unfiltered Home.
    @State private var moods: [SearchFilter] = []
    @State private var mood: SearchFilter?
    @State private var tint = Color(red: 0.33, green: 0.12, blue: 0.18)
    @Environment(AuthManager.self) private var auth
    private var library: LocalLibrary { .shared }

    /// The quick-access grid (YouTube Music's Speed dial): what you pinned first, then
    /// recently opened, then picks from the feed.
    private var tiles: [MediaItem] {
        var seen = Set<String>()
        let fromHome = (model.page?.shelves ?? []).filter { $0.style == .carousel }.flatMap(\.items).compactMap { item -> MediaItem? in
            if case .media(let m) = item { return m }
            return nil
        }
        // De-duplicate by page, not link: the same playlist can arrive with different params.
        return (library.pinned + library.recentCollections + fromHome).filter { seen.insert($0.target.browseId).inserted }.prefix(8).map { $0 }
    }

    /// "On repeat": songs you've played more than once in the last four weeks.
    private var onRepeat: [Track] {
        let top = ListeningStats.shared.summary(for: .month).topTracks.filter { $0.count >= 2 }
        guard top.count >= 4 else { return [] }
        // History saved from some pages has no length; the song's own (known once played) fills in.
        let tracks = top.prefix(12).map(\.track)
        guard tracks.contains(where: { $0.duration == nil }) else { return tracks }
        let known = AudioCache.durations()
        return tracks.map { track in
            var track = track
            if track.duration == nil { track.duration = known[track.videoId] }
            return track
        }
    }

    var body: some View {
        ScrollView {
            PausesHoverWhileScrolling {
            VStack(alignment: .leading, spacing: 28) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Feed.allCases) { option in
                            Chip(title: option.title, selected: feed == option && (option != .forYou || mood == nil)) {
                                feed = option
                                if option == .forYou { select(mood: nil) }
                            }
                        }
                        if feed == .forYou, !moods.isEmpty {
                            Rectangle().fill(Theme.tertiary).frame(width: 1, height: 20).padding(.horizontal, 4)
                            ForEach(moods) { chip in
                                Chip(title: chip.title, selected: mood == chip) { select(mood: mood == chip ? nil : chip) }
                            }
                        }
                    }
                    .padding(.horizontal, Theme.pagePadding)
                }

                switch feed {
                case .forYou: forYou
                case .explore: FeedView(target: Router.explore)
                case .charts: ChartsFeed()
                }
            }
            .padding(.top, 20)
            .padding(.bottom, 32)
            .background(alignment: .top) {
                // Scrolls with the content; picks up the colour of the hovered tile.
                LinearGradient(colors: [tint.headerTint().opacity(0.9), Theme.panel], startPoint: .top, endPoint: .bottom)
                    .frame(height: 340)
                    .padding(.top, -20)
                    .animation(.easeInOut(duration: 0.6), value: tint)
            }
            .restoresScrollPosition()
            }
        }
        .reportsScrolling()
        .scrollBench("home", ready: model.page != nil)
        .task(id: "\(auth.sessionVersion)|\(mood?.params ?? "")") {
            await model.loadCached()
            if mood == nil, let chips = model.page?.chips, !chips.isEmpty { moods = chips }
            await model.loadMoreShelvesAhead()
        }
    }

    private func select(mood chip: SearchFilter?) {
        guard chip != mood else { return }
        mood = chip
        model = PageModel(.home(chip: chip?.params))
    }

    @ViewBuilder
    private var forYou: some View {
        if PlayerController.shared.offlineMode {
            OfflineHome()
        } else if let page = model.page {
            VStack(alignment: .leading, spacing: 28) {
                if !tiles.isEmpty, mood == nil {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 8)], spacing: 8) {
                        ForEach(tiles) { QuickTile(item: $0, tint: $tint) }
                    }
                    .padding(.horizontal, Theme.pagePadding)
                }
                // Lazy: built as shelves scroll near. Building all of them up front was worse: every
                // card's hover region then exists, and each scroll frame re-checks all of them.
                LazyVStack(alignment: .leading, spacing: 28) {
                    if library.recentTracks.count >= 4, mood == nil {
                        ShelfView(shelf: Shelf(title: String(localized: "Recently played"), style: .carousel,
                                               items: library.recentTracks.prefix(20).map(ShelfItem.track)))
                    }
                    if mood == nil, !onRepeat.isEmpty {
                        ShelfView(shelf: Shelf(title: String(localized: "On repeat"), label: String(localized: "Your most played lately"), style: .rows,
                                               items: onRepeat.map(ShelfItem.track), moreTarget: StatsView.target))
                    }
                    ForEach(page.shelves) { shelf in
                        ShelfView(shelf: shelf)
                    }
                    if let token = page.continuation {
                        SkeletonCarousel()
                            .task(id: token) { await model.loadMoreShelves() }
                    }
                }
                .padding(.horizontal, Theme.pagePadding - 12)
            }
            .appearTransition()
        } else if let error = model.error {
            ErrorView(error: error) { Task { await model.load() } }
        } else {
            SkeletonHome().padding(.horizontal, Theme.pagePadding)
        }
    }
}

/// Explore / Charts shown inside Home under their chip.
struct FeedView: View {
    let target: BrowseTarget
    @State private var model: PageModel

    init(target: BrowseTarget) {
        self.target = target
        _model = State(initialValue: PageModel(.target(target)))
    }

    var body: some View {
        Group {
            if let page = model.page {
                LazyVStack(alignment: .leading, spacing: 28) {
                    ForEach(page.shelves) { ShelfView(shelf: $0) }
                }
                .padding(.horizontal, Theme.pagePadding - 12)
                .appearTransition()
            } else if let error = model.error {
                ErrorView(error: error) { Task { await model.load() } }
            } else {
                SkeletonHome().padding(.horizontal, Theme.pagePadding)
            }
        }
        .task { await model.loadCached() }
    }
}

/// Home in Offline Mode: what plays without the internet.
struct OfflineHome: View {
    private var downloads: DownloadManager { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 12) {
                Image(systemName: "icloud.slash.fill").font(.system(size: 22))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Offline Mode").font(.system(size: 17, weight: .bold))
                    Text("Only downloaded and previously played music plays.").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                Button("Go Online") { PlayerController.shared.offlineMode = false }.buttonStyle(.borderedProminent)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.elevated))
            .padding(.horizontal, Theme.pagePadding)
            LazyVStack(alignment: .leading, spacing: 28) {
                if !downloads.collections.isEmpty {
                    ShelfView(shelf: Shelf(title: String(localized: "Downloads"), style: .carousel, items: downloads.collections.map { .media($0.item) }))
                }
                let cached = LocalLibrary.shared.recentTracks.filter(PlayerController.availableOffline)
                if !cached.isEmpty {
                    ShelfView(shelf: Shelf(title: String(localized: "Played on this Mac"), style: .rows, items: cached.map(ShelfItem.track)))
                }
                if !LocalFiles.shared.tracks.isEmpty {
                    ShelfView(shelf: Shelf(title: String(localized: "Local Files"), style: .rows, items: LocalFiles.shared.tracks.prefix(40).map(ShelfItem.track)))
                }
            }
            .padding(.horizontal, Theme.pagePadding - 12)
        }
    }
}

/// Charts with YouTube Music's country picker (remembered).
struct ChartsFeed: View {
    @AppStorage("chartsCountry") private var country = ""
    @State private var page: BrowsePage?
    @State private var error: (any Error)?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let page, !page.countries.isEmpty {
                MenuButton {
                    page.countries.map { option in
                        .choice(option.name, selected: option.code == (page.selectedCountry ?? country)) { country = option.code }
                    }
                } label: { _ in
                    HStack(spacing: 6) {
                        Image(systemName: "globe")
                        Text(page.countries.first { $0.code == (page.selectedCountry ?? country) }?.name ?? String(localized: "Country"))
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.chip))
                }
                .fixedSize()
                .padding(.horizontal, Theme.pagePadding)
            }
            if let page {
                LazyVStack(alignment: .leading, spacing: 28) {
                    ForEach(page.shelves) { ShelfView(shelf: $0) }
                }
                .padding(.horizontal, Theme.pagePadding - 12)
                .appearTransition()
            } else if let error {
                ErrorView(error: error) { Task { await load() } }
            } else {
                SkeletonHome().padding(.horizontal, Theme.pagePadding)
            }
        }
        .task(id: country) { await load() }
    }

    private func load() async {
        error = nil
        do {
            page = try await MusicAPI.charts(country: country.isEmpty ? nil : country)
        } catch {
            if page == nil { self.error = error }
        }
    }
}

/// Compact quick-access tile; hovering tints the page with the tile's artwork colour.
struct QuickTile: View {
    var item: MediaItem
    @Binding var tint: Color
    @State private var hovering = false
    @Environment(Router.self) private var router

    var body: some View {
        HStack(spacing: 10) {
            ArtworkView(url: item.thumbnail, size: 52, cornerRadius: 0, circle: false)
                .shadow(color: .black.opacity(0.3), radius: 6, x: 2)
            Text(item.title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.text)
                .lineLimit(2)
            Spacer(minLength: 4)
            let state = PlayerController.shared.playState(of: item.target)
            if hovering || state == .loading || state == .playing {
                PlayCircleButton(size: 32, isPlaying: state == .playing, loading: state == .loading) {
                    if state == .playing || state == .paused { PlayerController.shared.togglePlayPause() } else { play() }
                }
                    .padding(.trailing, 8)
                    .transition(.opacity)
            }
        }
        .frame(height: 52)
        .background(Theme.text.opacity(hovering ? 0.2 : 0.1))
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .contentShape(Rectangle())
        .onHover { h in
            withAnimation(.easeOut(duration: 0.15)) { hovering = h }
            guard h, let url = Artwork.url(item.thumbnail, size: 60) else { return }
            Task {
                if let color = await ImageLoader.shared.averageColor(for: url) { tint = Color(nsColor: color) }
            }
        }
        .onTapGesture { router.open(item.target) }
        .menuOnRightClick(hovering: hovering) { MediaMenuEntries.make(item) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { router.open(item.target) }
        .accessibilityAction(named: "Play") { play() }
    }

    private func play() {
        PlayerController.shared.playCollection(item.target, playlistId: item.playlistId)
    }
}
