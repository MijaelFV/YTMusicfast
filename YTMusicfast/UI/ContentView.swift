import SwiftUI

/// The window: a top bar, three rounded panels on black (library · main · now playing) and the player bar.
struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(Router.self) private var router
    @Environment(AuthManager.self) private var auth
    @Namespace private var artNamespace
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false

    var body: some View {
        @Bindable var router = router
        VStack(spacing: 0) {
            TopBar()
                .environment(\.inTitleBar, true)
                // Above the panels: their scroll views reach up under the title bar (where macOS
                // lets content scroll beneath a toolbar) and would otherwise take the top bar's clicks.
                .zIndex(1)
            GeometryReader { geo in
                // The right panel steps aside on narrow windows, then the library shrinks to covers.
                let showRight = router.rightPanel != nil && geo.size.width >= 1000
                let compactLibrary = router.libraryCollapsed || geo.size.width < 780
                HStack(spacing: Theme.gap) {
                    LibraryPanel(compact: compactLibrary)
                        .frame(width: compactLibrary ? 72 : 300)
                    MainPanel()
                        .frame(maxWidth: .infinity)
                    if showRight, let panel = router.rightPanel {
                        RightPanel(mode: panel)
                            .frame(width: 330)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .overlay(alignment: .trailing) {
                    // Too narrow to sit beside the page: float it over the page instead of ignoring the button.
                    if !showRight, let panel = router.rightPanel {
                        RightPanel(mode: panel)
                            .frame(width: 330)
                            .shadow(color: .black.opacity(0.6), radius: 24, x: -6)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(.spring(duration: 0.3), value: showRight)
                .animation(.spring(duration: 0.3), value: compactLibrary)
            }
            .padding(.horizontal, Theme.gap)
            PlayerBar()
        }
        .coordinateSpace(.named("window"))
        .overlay { TooltipLayer() }
        .environment(\.hasTooltipLayer, true)
        // The top bar *is* the title bar: start at the very top so search sits on the
        // same row as the window buttons (which AppDelegate centres in this bar).
        .ignoresSafeArea(.container, edges: .top)
        .background(Theme.window)
        .overlay(alignment: .bottom) {
            if let toast = router.toast {
                HStack(spacing: 14) {
                    Label(toast.message, systemImage: toast.icon)
                    if toast.undo != nil {
                        Button("Undo") { router.undoToast() }
                            .buttonStyle(.plain)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Theme.accent.mix(with: .black, by: 0.15))
                            // ⌘Z is Edit → Undo, which has this change too.
                            .help("Undo (⌘Z)")
                    }
                }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.onContrast)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Theme.contrast))
                    .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
                    .padding(.bottom, 100)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
            }
        }
        .animation(.spring(duration: 0.35), value: router.toast?.id)
        .environment(\.artNamespace, artNamespace)
        .sheet(isPresented: $router.showSignIn) {
            SignInView()
        }
        .sheet(item: $router.addToPlaylist) { batch in
            AddToPlaylistSheet(tracks: batch.tracks)
        }
        .sheet(item: $router.creditsTrack) { track in
            CreditsSheet(track: track)
        }
        .sheet(isPresented: $router.showShortcuts) {
            ShortcutsSheet()
        }
        .alert("Already added", isPresented: Binding(get: { router.pendingDuplicate != nil }, set: { if !$0 { router.pendingDuplicate = nil } }),
               presenting: router.pendingDuplicate) { pending in
            Button("Add Anyway") { router.addDuplicatesAnyway(pending) }
            Button("Don't Add", role: .cancel) {}
        } message: { pending in
            Text(pending.videoIds.count == 1 ? String(localized: "This song is already in \(pending.playlistTitle).")
                                             : String(localized: "Some of these songs are already in \(pending.playlistTitle)."))
        }
        .alert("Rename folder", isPresented: Binding(get: { router.renamingFolder != nil }, set: { if !$0 { router.renamingFolder = nil } }),
               presenting: router.renamingFolder) { folder in
            FolderNameField(folder: folder)
        }
        .sheet(isPresented: Binding(get: { !hasSeenWelcome }, set: { if !$0 { hasSeenWelcome = true } })) {
            WelcomeView { hasSeenWelcome = true }
        }
        .task { await UpdateChecker.shared.check() }
        // The menu-bar item can bring the window back after it was closed.
        .onAppear { StatusBarController.openMainWindow = { openWindow(id: "main") } }
        .task { _ = await ContentFilter.shared.refreshCommunityList() }
        .onChange(of: auth.sessionVersion) { PlayerController.shared.accountChanged() }
        .tint(Theme.accent)
    }
}

struct MainPanel: View {
    @Environment(Router.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let playerPage = router.route == .nowPlaying
        ZStack {
            page
                .id(router.route)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                // The player page slides up out of the player bar over the page you were on, which
                // recedes a little (YouTube Music); closing reverses it. Other navigation is instant:
                // these transitions only run when the player page opens or closes.
                .transition(playerPage
                    ? (reduceMotion ? .opacity : .move(edge: .bottom))
                    : (reduceMotion ? .opacity : .scale(scale: 0.97).combined(with: .opacity)))
                .zIndex(playerPage ? 1 : 0)
        }
        // Opening and closing move the same way, gliding like YouTube Music's player page
        // (Material's standard easing: a soft start and a long, gentle landing).
        .animation(.timingCurve(0.2, 0, 0, 1, duration: 0.55), value: playerPage)
        .panel()
    }

    @ViewBuilder
    private var page: some View {
        switch router.route {
        case .home: HomeView()
        case .search: SearchView()
        case .lyrics: LyricsPage().environment(\.colorScheme, .dark)
        case .page(let target): BrowseView(target: target)
        case .shelf(let shelf): ShelfPage(shelf: shelf)
        case .localFiles: LocalFilesView()
        case .stats: StatsView()
        case .radio(let seed): RadioPage(seed: seed)
        // Tinted by the cover with white text, like the full-screen player: dark in either theme.
        case .nowPlaying: PlayerStage().environment(\.colorScheme, .dark)
        }
    }
}

// MARK: - Top bar

struct TopBar: View {
    @Environment(Router.self) private var router
    @FocusState private var searchFocused: Bool
    @State private var launched = false
    @State private var hoveringHome = false
    @State private var hoveringSearch = false
    @State private var hoveringBrowse = false
    /// YouTube Music's autocomplete under the search field.
    @State private var suggestions: [String] = []
    /// The artist, songs and albums YouTube Music shows under the completions.
    @State private var instant: [ShelfItem] = []
    /// Index into completions, then instant results.
    @State private var highlighted: Int?
    /// The query a suggestion was just picked for (don't reopen the list for it).
    @State private var acceptedQuery: String?
    /// The search field shrinks in narrow windows; its suggestions match it.
    @State private var searchWidth: CGFloat = 480
    /// Where the search field and its dropdown are (window coordinates), so a click elsewhere closes them.
    @State private var searchFrame: CGRect = .zero
    @State private var dropdownSize: CGSize = .zero

    /// Hidden only right after a search is made; clicking back into the field shows them again
    /// An empty field shows recent searches.
    private var showSuggestions: Bool {
        searchFocused && !(suggestions.isEmpty && instant.isEmpty) && acceptedQuery != router.searchQuery
    }

    /// The dropdown is showing recent searches (the field is empty), not completions.
    private var showingRecents: Bool { router.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty }

    private func loadRecents() {
        suggestions = Array(RecentSearches.all.prefix(6))
        instant = Array(ContentFilter.shared.filter(RecentSearches.items).prefix(4))
    }

    private var suggestionCount: Int { suggestions.count + instant.count }

    /// Suggestions already fetched this session (the last 60 inputs).
    private static var suggestionCache: [String: SearchSuggestions] = [:]
    private static var suggestionOrder: [String] = []

    private static func rememberSuggestions(_ found: SearchSuggestions, for input: String) {
        suggestionCache[input] = found
        suggestionOrder.append(input)
        if suggestionOrder.count > 60 { suggestionCache[suggestionOrder.removeFirst()] = nil }
    }

    /// An instant result: songs play (with their radio, like YouTube Music), the rest open.
    private func open(_ item: ShelfItem) {
        acceptedQuery = router.searchQuery
        highlighted = nil
        RecentSearches.add(router.searchQuery)
        RecentSearches.add(item)
        searchFocused = false
        NSApp.keyWindow?.makeFirstResponder(nil)
        switch item {
        case .track(let track): PlayerController.shared.playRadio(from: track)
        case .media(let media): router.open(media.target)
        }
    }

    private func accept(_ suggestion: String) {
        acceptedQuery = suggestion
        highlighted = nil
        RecentSearches.add(suggestion)
        router.search(suggestion)
    }

    var body: some View {
        @Bindable var router = router
        ZStack {
            // Back / forward after the traffic lights; account on the right.
            HStack(spacing: 2) {
                NavButton(icon: "chevron.left", label: String(localized: "Back"), enabled: router.canGoBack, action: router.goBack)
                NavButton(icon: "chevron.right", label: String(localized: "Forward"), enabled: router.canGoForward, action: router.goForward)
                Spacer()
                ActivityIndicator()
                UpdateBadge()
                AccountMenu()
            }
            // Room for the window buttons, which full screen hides.
            .padding(.leading, WindowState.shared.isFullScreen ? 16 : 84)
            .padding(.trailing, 12)

            // Home + search in the centre.
            HStack(spacing: 8) {
                Button { router.navigate(.home) } label: {
                    Image(systemName: router.route == .home ? "house.fill" : "house")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(router.route == .home || hoveringHome ? Theme.text : Theme.secondary)
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(hoveringHome ? Theme.raised : Theme.elevated))
                }
                .buttonStyle(HoverScaleButtonStyle(hovering: hoveringHome))
                .onTrackingHover { hoveringHome = $0 }
                .tooltip(String(localized: "Home"), edge: .bottom)
                .accessibilityLabel("Home")

                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(searchFocused ? Theme.text : Theme.secondary)
                    TextField("What do you want to play?", text: $router.searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.text)
                        .focused($searchFocused)
                        .onKeyPress(.downArrow) {
                            guard showSuggestions else { return .ignored }
                            highlighted = min((highlighted ?? -1) + 1, suggestionCount - 1)
                            return .handled
                        }
                        .onKeyPress(.upArrow) {
                            guard showSuggestions, let current = highlighted else { return .ignored }
                            highlighted = current > 0 ? current - 1 : nil
                            return .handled
                        }
                        .onSubmit {
                            if showSuggestions, let index = highlighted, suggestions.indices.contains(index) {
                                accept(suggestions[index])
                            } else if showSuggestions, let index = highlighted, instant.indices.contains(index - suggestions.count) {
                                open(instant[index - suggestions.count])
                            } else if !router.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                                acceptedQuery = router.searchQuery
                                RecentSearches.add(router.searchQuery)
                                router.search(router.searchQuery)
                            }
                        }
                        .onExitCommand { acceptedQuery = router.searchQuery }
                        // Clicking into the field again brings its suggestions back.
                        .simultaneousGesture(TapGesture().onEnded { acceptedQuery = nil })
                    if !router.searchQuery.isEmpty {
                        Button {
                            router.searchQuery = ""
                            // On the results page, clearing goes back to Browse.
                            if router.route == .search { router.search("") }
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                    Rectangle().fill(Theme.tertiary).frame(width: 1, height: 22)
                    let browsing = router.route == .search && router.submittedQuery.isEmpty
                    Button { router.search("") } label: {
                        Image(systemName: browsing ? "square.grid.2x2.fill" : "square.grid.2x2")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(browsing || hoveringBrowse ? Theme.text : Theme.secondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(HoverScaleButtonStyle(hovering: hoveringBrowse))
                    .onTrackingHover { hoveringBrowse = $0 }
                    .tooltip(String(localized: "Browse"), edge: .bottom)
                    .accessibilityLabel("Browse")
                }
                .padding(.leading, 14)
                .padding(.trailing, 16)
                .frame(height: 48)
                .frame(maxWidth: 480)
                .background(Capsule().fill(hoveringSearch || searchFocused ? Theme.raised : Theme.elevated))
                .overlay(
                    Capsule().strokeBorder(searchFocused ? Theme.text.opacity(0.85) : hoveringSearch ? Theme.text.opacity(0.12) : .clear,
                                           lineWidth: searchFocused ? 2 : 1)
                )
                .contentShape(Capsule())
                .onTrackingHover { hoveringSearch = $0 }
                .onTapGesture {
                    searchFocused = true
                    acceptedQuery = nil
                }
                .animation(.easeOut(duration: 0.12), value: hoveringSearch)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { searchWidth = $0 }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { searchFrame = $0 }
                .overlay(alignment: .topLeading) {
                    if showSuggestions {
                        SuggestionList(suggestions: suggestions, items: instant, query: router.searchQuery, recent: showingRecents, highlighted: highlighted,
                                       width: max(searchWidth, 320), accept: accept, open: open)
                            .onGeometryChange(for: CGSize.self) { $0.size } action: { dropdownSize = $0 }
                            .offset(y: 54)
                            .transition(.opacity)
                    }
                }
                // A click anywhere else closes the dropdown and leaves the field.
                .endEditingOnOutsideClick(
                    isActive: searchFocused,
                    inside: showSuggestions ? [CGRect(origin: CGPoint(x: searchFrame.minX, y: searchFrame.minY + 54), size: dropdownSize)] : []
                ) {
                    searchFocused = false
                    highlighted = nil
                }
            }
            .padding(.horizontal, 200)
        }
        .frame(height: AppDelegate.topBarHeight)
        .background(WindowDragArea())
        .background(WindowConfigurator { TitleBarSizer.configure($0) })
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).midY } action: { midY in
            // Window buttons follow our bar's centre line.
            TrafficLights.update(centerFromTop: midY)
        }
        .onChange(of: router.searchFocusRequest) { searchFocused = true }
        .onChange(of: searchFocused) { _, focused in
            guard focused else { return }
            acceptedQuery = nil
            highlighted = nil
            if showingRecents { loadRecents() }
        }
        // Leaving Search gives the keyboard back (Space plays again instead of typing into the field).
        .onChange(of: router.route) { _, route in
            if route != .search, searchFocused {
                searchFocused = false
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
        .task(id: router.searchQuery) {
            let query = router.searchQuery.trimmingCharacters(in: .whitespaces)
            highlighted = nil
            // Keep only the old suggestions that still fit what's typed, until fresh ones arrive.
            suggestions = suggestions.filter { $0.lowercased().hasPrefix(query.lowercased()) }
            guard !query.isEmpty else { loadRecents(); return }
            let found: SearchSuggestions
            if let known = Self.suggestionCache[query.lowercased()] {
                // Typed before (e.g. backspacing): no waiting, no request.
                found = known
            } else {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let fetched = try? await MusicAPI.searchSuggestions(query), !Task.isCancelled else { return }
                found = fetched
                Self.rememberSuggestions(fetched, for: query.lowercased())
            }
            suggestions = Array(found.queries.prefix(instant.isEmpty && found.items.isEmpty ? 8 : 5))
            instant = Array(ContentFilter.shared.filter(found.items).prefix(5))
        }
        .task {
            // macOS focuses the first text field when the window opens; don't start on Search.
            try? await Task.sleep(for: .milliseconds(100))
            searchFocused = false
            NSApp.keyWindow?.makeFirstResponder(nil)
            launched = true
        }
    }

}

/// The autocomplete dropdown: the typed part plain, the completion bold (YouTube Music).
private struct SuggestionList: View {
    var suggestions: [String]
    var items: [ShelfItem]
    var query: String
    /// Recent searches (empty field) rather than completions.
    var recent = false
    var highlighted: Int?
    var width: CGFloat
    var accept: (String) -> Void
    var open: (ShelfItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if recent {
                Text("Recent searches")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                SuggestionRow(text: suggestion, query: query, icon: recent ? "clock.arrow.circlepath" : "magnifyingglass",
                              highlighted: highlighted == index) { accept(suggestion) }
            }
            if !items.isEmpty {
                if !suggestions.isEmpty {
                    Rectangle().fill(Theme.text.opacity(0.08)).frame(height: 1).padding(.vertical, 4).padding(.horizontal, 8)
                }
                ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                    InstantResultRow(item: item, highlighted: highlighted == suggestions.count + offset) { open(item) }
                }
            }
        }
        .padding(6)
        .frame(width: width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.raised))
        .shadow(color: .black.opacity(0.55), radius: 18, y: 8)
    }
}

private struct SuggestionRow: View {
    var text: String
    var query: String
    var icon = "magnifyingglass"
    var highlighted: Bool
    var action: () -> Void
    @State private var hovering = false

    private var label: Text {
        let typed = query.trimmingCharacters(in: .whitespaces)
        if text.lowercased().hasPrefix(typed.lowercased()), !typed.isEmpty {
            return Text(String(text.prefix(typed.count))).foregroundStyle(Theme.secondary)
                + Text(String(text.dropFirst(typed.count))).fontWeight(.bold)
        }
        return Text(text)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                label.font(.system(size: 14)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 6).fill(highlighted || hovering ? Theme.text.opacity(0.1) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// An artist, song or album right in the autocomplete (YouTube Music's instant results).
private struct InstantResultRow: View {
    var item: ShelfItem
    var highlighted: Bool
    var action: () -> Void
    @State private var hovering = false

    private var title: String {
        switch item {
        case .track(let track): track.title
        case .media(let media): media.title
        }
    }

    private var subtitle: String {
        switch item {
        case .track(let track): "\(track.isVideo ? "Video" : "Song") • \(track.artistLine)"
        case .media(let media):
            media.subtitle.isEmpty ? media.target.kind.rawValue.capitalized
                : media.target.kind == .artist ? String(localized: "Artist • \(media.subtitle)") : media.subtitle
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                switch item {
                case .track(let track): ArtworkView(url: track.thumbnail, size: 36, cornerRadius: 4)
                case .media(let media): ArtworkView(url: media.thumbnail, size: 36, cornerRadius: 4, circle: media.target.kind == .artist)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if case .track = item {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                        .opacity(highlighted || hovering ? 1 : 0)
                }
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 12)
            .frame(height: 48)
            .background(RoundedRectangle(cornerRadius: 6).fill(highlighted || hovering ? Theme.text.opacity(0.1) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(title), \(subtitle)")
    }
}

/// Back / forward: dimmed when there's nowhere to go, a dark circle behind them on hover.
private struct NavButton: View {
    var icon: String
    var label: String
    var enabled: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(enabled ? Theme.text : Theme.tertiary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(enabled && hovering ? Theme.elevated : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverScaleButtonStyle(hovering: enabled && hovering))
        .disabled(!enabled)
        .onTrackingHover { hovering = $0 }
        .tooltip(label, edge: .bottom)
        .accessibilityLabel(label)
    }
}

/// Hands us the hosting NSWindow as soon as the view is attached to it.
struct WindowConfigurator: NSViewRepresentable {
    var configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { WindowHookView(configure: configure) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class WindowHookView: NSView {
        let configure: (NSWindow) -> Void
        init(configure: @escaping (NSWindow) -> Void) {
            self.configure = configure
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { configure(window) }
        }
    }
}

/// Lets the empty parts of the top bar act like a real title bar (ours is hidden): drag to move
/// the window, double-click for whatever System Settings → Desktop & Dock says (fill/zoom,
/// minimize or nothing).
struct WindowDragArea: NSViewRepresentable {
    /// Off for windows that shouldn't change size on a double-click (the miniplayer).
    var doubleClickZooms = true

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.doubleClickZooms = doubleClickZooms
        return view
    }

    func updateNSView(_ view: DragView, context: Context) { view.doubleClickZooms = doubleClickZooms }

    final class DragView: NSView {
        var doubleClickZooms = true

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                if doubleClickZooms { TitleBarDoubleClick.perform(on: window) }
            } else {
                window.performDrag(with: event)
            }
        }
    }
}

/// The system's title-bar double-click setting, applied to a window without a visible title bar.
@MainActor
enum TitleBarDoubleClick {
    static func perform(on window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        let defaults = UserDefaults.standard
        switch defaults.string(forKey: "AppleActionOnDoubleClick") {
        case "None":
            return
        case "Minimize":
            window.miniaturize(nil)
        case nil where defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick"):
            window.miniaturize(nil)
        default:
            // "Fill" / "Maximize" (and the default): toggle between filling the screen and the
            // previous size, like double-clicking any title bar.
            window.zoom(nil)
        }
    }
}

struct UpdateBadge: View {
    private var updates: UpdateChecker { .shared }

    var body: some View {
        if updates.updateAvailable, let version = updates.latestVersion {
            Button(action: updates.openRelease) {
                Label("Update to \(version)", systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.onContrast)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.contrast))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
        }
    }
}

struct AccountMenu: View {
    @Environment(Router.self) private var router
    @Environment(AuthManager.self) private var auth
    @Environment(\.openSettings) private var openSettings
    @State private var hovering = false

    var body: some View {
        if auth.isSignedIn {
            MenuButton(alignment: .trailing) {
                AccountMenuEntries.entries { openSettings() }
            } label: { open in
                Text(String((auth.accountName ?? "?").prefix(1)).uppercased())
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Theme.accent))
                    .padding(8)
                    .background(Circle().fill(hovering || open ? Theme.raised : Theme.elevated))
                    .scaleEffect(hovering || open ? 1.04 : 1)
                    .animation(.easeOut(duration: 0.12), value: hovering || open)
            }
            .onTrackingHover { hovering = $0 }
            .tooltip(auth.accountName ?? String(localized: "Account"), edge: .bottom)
            .accessibilityLabel("Account")
        } else {
            Button { router.showSignIn = true } label: {
                Text("Sign in")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.onContrast)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Theme.contrast))
            }
            .buttonStyle(HoverScaleButtonStyle(hovering: hovering))
            .onTrackingHover { hovering = $0 }
        }
    }
}

// MARK: - Your Library (left panel)

struct LibraryPanel: View {
    var compact: Bool

    enum Filter: String, CaseIterable, Identifiable {
        case playlists = "Playlists", byYou = "By you", albums = "Albums", artists = "Artists", podcasts = "Podcasts", downloaded = "Downloaded"
        var id: String { rawValue }
        /// Shown in the UI (the raw value is what's saved).
        var title: String {
            switch self {
            case .playlists: String(localized: "Playlists")
            case .byYou: String(localized: "By you")
            case .albums: String(localized: "Albums")
            case .artists: String(localized: "Artists")
            case .podcasts: String(localized: "Podcasts")
            case .downloaded: String(localized: "Downloaded")
            }
        }
        var kind: PageKind? {
            switch self {
            case .playlists, .byYou: .playlist
            case .albums: .album
            case .artists: .artist
            case .podcasts: .podcast
            case .downloaded: nil
            }
        }
    }

    enum Sort: String, CaseIterable {
        case recents = "Recents", recentlyAdded = "Recently added", alphabetical = "Alphabetical", creator = "Creator"
        /// Shown in the UI (the raw value is what's saved).
        var title: String {
            switch self {
            case .recents: String(localized: "Recents")
            case .recentlyAdded: String(localized: "Recently added")
            case .alphabetical: String(localized: "Alphabetical")
            case .creator: String(localized: "Creator")
            }
        }
    }

    /// "View as": list, compact (no covers) or a grid of covers.
    enum ViewMode: String, CaseIterable {
        case list = "List", compact = "Compact", grid = "Grid"
        /// Shown in the UI (the raw value is what's saved).
        var title: String {
            switch self {
            case .list: String(localized: "List")
            case .compact: String(localized: "Compact")
            case .grid: String(localized: "Grid")
            }
        }
        var symbol: String {
            switch self {
            case .list: "list.bullet"
            case .compact: "list.dash"
            case .grid: "square.grid.2x2"
            }
        }
    }

    @Environment(Router.self) private var router
    @Environment(AuthManager.self) private var auth
    @State private var remote = RemoteLibrary()
    /// Remembered on this Mac.
    @AppStorage("libraryFilter") private var filterRaw = ""
    private var filter: Filter? {
        get { Filter(rawValue: filterRaw) }
        nonmutating set { filterRaw = newValue?.rawValue ?? "" }
    }
    @AppStorage("librarySort") private var sort = Sort.recents
    @AppStorage("libraryView") private var viewMode = ViewMode.list
    @State private var searching = false
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    private var local: LocalLibrary { .shared }

    /// Pinned first, then recently opened, then the account library — de-duplicated, filtered, sorted.
    private var items: [(item: MediaItem, pinned: Bool)] {
        var seen = Set<String>()
        var result: [(MediaItem, Bool)] = []
        let sources: [([MediaItem], Bool)] = filter == .downloaded
            ? [(DownloadManager.shared.collections.map(\.item), false)]
            : sort == .recentlyAdded
                ? [(local.pinned, true), (remote.items, false), (local.recentCollections, false)]
                : [(local.pinned, true), (local.recentCollections, false), (remote.items, false)]
        for (items, pinned) in sources {
            for item in items where !seen.contains(item.collectionId)
                && !["VLLM", "LM"].contains(item.target.browseId)
                && (filter?.kind == nil || item.target.kind == filter?.kind)
                && (filter != .byYou || isYours(item))
                && (searchText.isEmpty || item.title.localizedCaseInsensitiveContains(searchText)) {
                seen.insert(item.collectionId)
                result.append((item, pinned))
            }
        }
        switch sort {
        case .alphabetical:
            result.sort { a, b in
                a.1 != b.1 ? a.1 : a.0.title.localizedCaseInsensitiveCompare(b.0.title) == .orderedAscending
            }
        case .creator:
            result.sort { a, b in
                a.1 != b.1 ? a.1 : Self.creator(of: a.0).localizedCaseInsensitiveCompare(Self.creator(of: b.0)) == .orderedAscending
            }
        case .recents, .recentlyAdded:
            break
        }
        return result
    }

    /// A playlist you made (its creator is your account).
    private func isYours(_ item: MediaItem) -> Bool {
        guard item.target.kind == .playlist, let account = auth.accountName else { return false }
        return item.subtitle.components(separatedBy: " • ").contains(account)
    }

    /// Who made it: the artist of an album, the owner of a playlist, the artist themselves.
    private static func creator(of item: MediaItem) -> String {
        if item.target.kind == .artist { return item.title }
        return item.subtitle.components(separatedBy: " • ")
            .first { !["Album", "Playlist", "Single", "EP", "Podcast", ""].contains($0) && !$0.contains("song") && Int($0) == nil }
            ?? item.title
    }

    /// Items not inside a folder (those show under their folder instead).
    private func topLevel(_ entries: [(item: MediaItem, pinned: Bool)]) -> [(item: MediaItem, pinned: Bool)] {
        guard filter == nil, searchText.isEmpty, !local.folders.isEmpty else { return entries }
        return entries.filter { entry in !local.folders.contains { $0.contains(entry.item) } }
    }

    private func row(_ entry: (item: MediaItem, pinned: Bool), indent: Bool = false) -> some View {
        LibraryRow(item: entry.item, pinned: entry.pinned, compact: compact, dense: viewMode == .compact,
                   selected: { if case .page(let open) = router.route { open.browseId == entry.item.target.browseId } else { false } }(),
                   onRemoveFromRecents: local.recentCollections.contains { $0.collectionId == entry.item.collectionId } ? {
                       let index = local.removeRecent(entry.item)
                       router.showToast(String(localized: "Removed from Recents"), icon: "minus.circle",
                                        undoName: String(localized: "Remove from Recents")) { local.restoreRecent(entry.item, at: index) }
                   } : nil) {
            router.open(entry.item.target)
        }
        .padding(.leading, indent && !compact ? 16 : 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !compact {
                filters
                searchAndSort
            }

            ScrollView {
                PausesHoverWhileScrolling {
                LazyVStack(spacing: 0) {
                    let all = items
                    if searchText.isEmpty {
                        specialRows
                    }
                    if viewMode == .grid, !compact {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                            ForEach(all, id: \.item.id) { entry in
                                LibraryGridTile(item: entry.item, selected: router.route == .page(entry.item.target)) {
                                    router.open(entry.item.target)
                                }
                            }
                        }
                        .padding(.top, 6)
                    } else {
                        if filter == nil, searchText.isEmpty {
                            ForEach(local.folders) { folder in
                                LibraryFolderRow(folder: folder, compact: compact, count: all.filter { folder.contains($0.item) }.count)
                                if folder.expanded {
                                    ForEach(all.filter { folder.contains($0.item) }, id: \.item.id) { row($0, indent: true) }
                                }
                            }
                        }
                        ForEach(topLevel(all), id: \.item.id) { row($0) }
                    }
                    if !compact, !auth.isSignedIn {
                        signInCard
                    } else if !compact, items.isEmpty, filter != nil || !searchText.isEmpty {
                        Text(!searchText.isEmpty ? String(localized: "Nothing matches “\(searchText)”.")
                             : filter == .downloaded ? String(localized: "Download albums and playlists to listen offline.")
                             : filter == .byYou ? String(localized: "Playlists you make show up here.")
                             : String(localized: "No \(filter!.title.lowercased()) yet."))
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondary)
                            .padding(16)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                }
            }
            .scrollIndicators(.never)
            .reportsScrolling()
        }
        .panel()
        .task(id: "\(auth.sessionVersion)-\(RemoteLibraryCache.shared.version)") {
            await remote.load(signedIn: auth.isSignedIn)
            RemoteLibraryCache.playlistTitles = remote.items.filter { $0.target.kind == .playlist }.map(\.title)
        }
    }

    /// Liked Music, history, library songs, uploads, episodes and local files: always near the top.
    @ViewBuilder
    private var specialRows: some View {
        let dense = viewMode == .compact
        let downloadsOnly = filter == .downloaded
        if auth.isSignedIn, filter == nil || filter == .playlists || filter == .byYou
            || (downloadsOnly && DownloadManager.shared.collection(for: Router.likedSongs) != nil) {
            LibraryRow(title: String(localized: "Liked Music"), subtitle: String(localized: "Playlist"), style: .liked, compact: compact, dense: dense,
                       selected: router.route == .page(Router.likedSongs), target: Router.likedSongs) { router.open(Router.likedSongs) }
        }
        if auth.isSignedIn, filter == nil {
            LibraryRow(title: String(localized: "Songs"), subtitle: String(localized: "All songs in your library"), style: .symbol("music.note", .blue), compact: compact, dense: dense,
                       selected: router.route == .page(Router.librarySongs)) { router.open(Router.librarySongs) }
            LibraryRow(title: String(localized: "Recently played"), subtitle: String(localized: "History"), style: .history, compact: compact, dense: dense,
                       selected: router.route == .page(Router.history)) { router.open(Router.history) }
            LibraryRow(title: String(localized: "Uploads"), subtitle: String(localized: "Music you uploaded"), style: .symbol("icloud.and.arrow.up", .purple), compact: compact, dense: dense,
                       selected: router.route == .page(Router.uploads)) { router.open(Router.uploads) }
        }
        if auth.isSignedIn, filter == nil || filter == .podcasts {
            LibraryRow(title: String(localized: "Episodes for Later"), subtitle: String(localized: "Podcast episodes"), style: .symbol("bookmark.fill", .green),
                       compact: compact, dense: dense, selected: router.route == .page(Router.episodesForLater),
                       target: Router.episodesForLater) { router.open(Router.episodesForLater) }
        }
        if filter == nil, !ListeningStats.shared.plays.isEmpty {
            LibraryRow(title: String(localized: "Your Stats"), subtitle: String(localized: "Top songs and artists"), style: .symbol("chart.bar.fill", .pink),
                       compact: compact, dense: dense, selected: router.route == .stats) { router.navigate(.stats) }
        }
        if filter == nil, !LocalFiles.shared.folders.isEmpty {
            LibraryRow(title: String(localized: "Local Files"), subtitle: "\(Format.count(LocalFiles.shared.tracks.count, .song)) on this Mac", style: .symbol("folder.fill", .teal),
                       compact: compact, dense: dense, selected: router.route == .localFiles) { router.navigate(.localFiles) }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { withAnimation(.spring(duration: 0.3)) { router.libraryCollapsed.toggle() } } label: {
                if compact {
                    Image(systemName: "books.vertical.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                } else {
                    Text("Your Library")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Theme.text)
                }
            }
            .buttonStyle(.plain)
            .help(compact ? String(localized: "Expand Your Library") : String(localized: "Collapse Your Library"))
            .accessibilityLabel(compact ? String(localized: "Expand Your Library") : String(localized: "Collapse Your Library"))
            if !compact {
                Spacer()
                MenuButton(entries: CreateMenu.entries) { open, hovering in
                    Label("Create", systemImage: open ? "xmark" : "plus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .contentTransition(.symbolEffect(.replace))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(open || hovering ? Theme.raised : Theme.elevated))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
        .padding(.leading, compact ? 0 : 20)
        .padding(.trailing, compact ? 0 : 12)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
            if filter != nil {
                Button { withAnimation(.snappy) { filter = nil } } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Theme.chip))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear filter")
            }
            ForEach(Filter.allCases) { option in
                if filter == nil || filter == option {
                    Chip(title: option.title, selected: filter == option) {
                        withAnimation(.snappy) { filter = filter == option ? nil : option }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        }
        .padding(.bottom, 10)
    }

    private var searchAndSort: some View {
        HStack(spacing: 8) {
            if searching {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    TextField("Search in Your Library", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($searchFocused)
                        .onExitCommand { searching = false; searchText = "" }
                }
                .padding(.horizontal, 8)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.elevated))
                .transition(.opacity.combined(with: .move(edge: .leading)))
                // Clicking elsewhere leaves the field; an empty search folds back into its icon.
                .endEditingOnOutsideClick(isActive: searchFocused) {
                    searchFocused = false
                    if searchText.isEmpty { withAnimation(.snappy) { searching = false } }
                }
            } else {
                IconButton(systemImage: "magnifyingglass", size: 14, label: String(localized: "Search in Your Library")) {
                    withAnimation(.snappy) { searching = true }
                    searchFocused = true
                }
            }
            Spacer(minLength: 4)
            MenuButton(alignment: .trailing) {
                [.header(String(localized: "Sort by"))]
                    + Sort.allCases.map { option in .choice(option.title, selected: sort == option) { sort = option } }
                    + [.divider, .header(String(localized: "View as"))]
                    + ViewMode.allCases.map { mode in .choice(mode.title, systemImage: mode.symbol, selected: viewMode == mode) { viewMode = mode } }
            } label: { open in
                HStack(spacing: 6) {
                    Text(sort.title).font(.system(size: 13))
                    Image(systemName: viewMode.symbol).font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(open ? Theme.text : Theme.secondary)
            }
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private var signInCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your music, in one place").font(.cardTitle)
            Text("Sign in to see your playlists, liked songs and mixes.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
            Button { router.showSignIn = true } label: {
                Text("Sign in")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.onContrast)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Theme.contrast))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.elevated))
        .padding(.top, 8)
    }
}

/// The text field and buttons of the "Rename folder" alert.
private struct FolderNameField: View {
    let folder: LocalLibrary.Folder
    @State private var name: String

    init(folder: LocalLibrary.Folder) {
        self.folder = folder
        _name = State(initialValue: folder.name)
    }

    var body: some View {
        TextField("Name", text: $name)
        Button("Rename") { LocalLibrary.shared.rename(folder, to: name) }
        Button("Cancel", role: .cancel) {}
    }
}

/// A playlist folder in Your Library: click to open or close it; right-click to rename or delete.
struct LibraryFolderRow: View {
    var folder: LocalLibrary.Folder
    var compact: Bool
    var count: Int
    @State private var hovering = false
    @Environment(Router.self) private var router

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Theme.elevated)
                .frame(width: compact ? 48 : 48, height: 48)
                .overlay(Image(systemName: folder.expanded ? "folder.fill" : "folder").font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.secondary))
            if !compact {
                VStack(alignment: .leading, spacing: 3) {
                    Text(folder.name).font(.system(size: 15)).foregroundStyle(Theme.text).lineLimit(1)
                    Text("Folder • \(Format.count(count, .item))").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.secondary)
                    .rotationEffect(.degrees(folder.expanded ? 90 : 0))
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
        .rowBackground(hovering: hovering)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { withAnimation(.snappy) { LocalLibrary.shared.toggleExpanded(folder) } }
        .menuOnRightClick(hovering: hovering) {
            [
                .action(String(localized: "Rename"), systemImage: "pencil") { router.renamingFolder = folder },
                .action(String(localized: "Delete Folder"), systemImage: "trash") {
                    // The folder as it is now (its playlists), so Undo puts back exactly this.
                    let current = LocalLibrary.shared.folders.first { $0.id == folder.id } ?? folder
                    let index = LocalLibrary.shared.delete(current)
                    router.showToast(String(localized: "Deleted folder “\(current.name)”"), icon: "trash",
                                     undoName: String(localized: "Delete Folder")) {
                        LocalLibrary.shared.restore(current, at: index)
                    }
                },
            ]
        }
        .help(compact ? folder.name : "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Folder \(folder.name), \(Format.count(count, .item))")
        .accessibilityAddTraits(.isButton)
    }
}

/// "View as Grid": covers in a grid.
struct LibraryGridTile: View {
    var item: MediaItem
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        let player = PlayerController.shared
        let playingThis = player.isPlaying(from: item.target)
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(url: item.thumbnail, size: 116, cornerRadius: 6, circle: item.target.kind == .artist, resizable: true)
                .aspectRatio(1, contentMode: .fit)
                // The round play button on the hovered card.
                .overlay(alignment: .bottomTrailing) {
                    let state = player.playState(of: item.target)
                    if hovering || state == .loading || state == .playing, item.target.kind != .other {
                        PlayCircleButton(size: 36, isPlaying: state == .playing, loading: state == .loading) {
                            if playingThis { player.togglePlayPause() } else { player.playCollection(item.target, playlistId: item.playlistId) }
                        }
                        .padding(6)
                        .transition(.opacity.combined(with: .offset(y: 6)))
                    }
                }
                .animation(.easeOut(duration: 0.15), value: hovering)
            Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Text(item.target.kind == .artist ? String(localized: "Artist") : item.subtitle.components(separatedBy: " • ").first ?? "")
                .font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.selected : hovering ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .menuOnRightClick(hovering: hovering) { MediaMenuEntries.make(item) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(.isButton)
    }
}

private struct SongDropTarget: ViewModifier {
    var enabled: Bool
    @Binding var targeted: Bool
    var onDrop: ([String]) -> Bool

    func body(content: Content) -> some View {
        if enabled {
            content.dropDestination(for: String.self) { items, _ in onDrop(items) } isTargeted: { targeted = $0 }
        } else {
            content
        }
    }
}

struct LibraryRow: View {
    enum Style: Equatable { case item, liked, history, symbol(String, Color) }

    var title: String
    var subtitle: String
    var style: Style = .item
    var thumbnail: URL?
    var circle = false
    var pinned = false
    var compact: Bool
    /// "Compact" view: one line, no cover.
    var dense = false
    var selected: Bool
    var target: BrowseTarget?
    var playlistId: String?
    /// For the right-click menu (albums, playlists and artists).
    var item: MediaItem?
    var onRemoveFromRecents: (() -> Void)?
    var action: () -> Void
    @State private var hovering = false
    @State private var engaged = false
    @State private var dropTargeted = false
    private var player: PlayerController { .shared }

    private var isDownloaded: Bool {
        guard let target else { return false }
        return DownloadManager.shared.state(for: target) != .none
    }

    /// Songs dragged onto a playlist are added to it; onto Liked Music, liked.
    private var acceptsSongs: Bool { style == .liked || target?.kind == .playlist }

    private func addDropped(_ payloads: [String]) -> Bool {
        let ids = TrackDrag.videoIds(in: payloads)
        guard !ids.isEmpty, let target else { return false }
        let router = Router.shared
        guard AuthManager.shared.isSignedIn else { router.showSignIn = true; return false }
        if style == .liked {
            Task {
                for id in ids { try? await MusicAPI.setLike(.like, videoId: id) }
                router.showToast(ids.count == 1 ? String(localized: "Added to Liked Music") : String(localized: "Added \(ids.count) songs to Liked Music"))
            }
        } else {
            router.add(videoIds: ids, toPlaylist: target.browseId, title: title)
        }
        return true
    }

    /// This row is what's playing right now (accent title + speaker icon).
    private var isPlayingFrom: Bool {
        guard let target else { return false }
        return player.isPlaying(from: target)
    }

    init(title: String, subtitle: String, style: Style, compact: Bool, dense: Bool = false, selected: Bool,
         target: BrowseTarget? = nil, action: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.style = style
        self.target = target
        self.compact = compact
        self.dense = dense
        self.selected = selected
        self.action = action
    }

    init(item: MediaItem, pinned: Bool, compact: Bool, dense: Bool = false, selected: Bool,
         onRemoveFromRecents: (() -> Void)? = nil, action: @escaping () -> Void) {
        self.dense = dense
        self.item = item
        self.onRemoveFromRecents = onRemoveFromRecents
        title = item.title
        let kind = switch item.target.kind {
        case .album: String(localized: "Album")
        case .artist: String(localized: "Artist")
        case .playlist: String(localized: "Playlist")
        case .podcast: String(localized: "Podcast")
        case .episode: String(localized: "Episode")
        case .other: ""
        }
        let detail = item.subtitle.components(separatedBy: " • ")
            .first { !["Album", "Playlist", "Artist", "Single", "EP", ""].contains($0) && !$0.contains("song") }
        subtitle = [kind, detail ?? ""].filter { !$0.isEmpty }.joined(separator: " • ")
        thumbnail = item.thumbnail
        circle = item.target.kind == .artist
        target = item.target
        playlistId = item.playlistId
        self.pinned = pinned
        self.compact = compact
        self.selected = selected
        self.action = action
    }

    var body: some View {
        HStack(spacing: 12) {
            if !dense || compact { art }
            if !compact, dense {
                // Compact view: name and kind on one line.
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 14)).foregroundStyle(isPlayingFrom ? Theme.accent : Theme.text).lineLimit(1)
                    Text("• " + (subtitle.components(separatedBy: " • ").first ?? "")).font(.system(size: 13))
                        .foregroundStyle(Theme.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    if isDownloaded { DownloadedBadge() }
                    if isPlayingFrom {
                        Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                            .font(.system(size: 12)).foregroundStyle(Theme.accent)
                    }
                }
            } else if !compact {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15))
                        .foregroundStyle(isPlayingFrom ? Theme.accent : Theme.text)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        if pinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.accent)
                                .rotationEffect(.degrees(45))
                        }
                        if isDownloaded { DownloadedBadge() }
                        Text(subtitle).lineLimit(1)
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 0)
                if isPlayingFrom {
                    Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.accent)
                        .padding(.trailing, 4)
                        .accessibilityLabel("Playing")
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, dense && !compact ? 6 : 8)
        .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
        .rowBackground(hovering: hovering, selected: selected)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.accent, lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
        .modifier(SongDropTarget(enabled: acceptsSongs, targeted: $dropTargeted, onDrop: addDropped))
        .onHover($hovering, engaged: $engaged)
        .onTapGesture(perform: action)
        // Registered only for the hovered row, the one you can right-click: cheaper while scrolling.
        .menuOnRightClick(hovering: hovering && item != nil) {
            guard let item else { return [] }
            var entries = MediaMenuEntries.make(item)
            if let onRemoveFromRecents {
                entries += [.divider, .action(String(localized: "Remove from Recents"), systemImage: "minus.circle", onRemoveFromRecents)]
            }
            return entries
        }
        .help(compact ? title : "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(subtitle)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { action() }
    }

    @ViewBuilder
    private var art: some View {
        switch style {
        case .liked:
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.27, green: 0.13, blue: 0.85), Color(red: 0.55, green: 0.85, blue: 0.85)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 48, height: 48)
                .overlay(Image(systemName: "heart.fill").font(.system(size: 18, weight: .bold)).foregroundStyle(.white))
        case .history:
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Theme.elevated)
                .frame(width: 48, height: 48)
                .overlay(Image(systemName: "clock.arrow.circlepath").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.secondary))
        case .symbol(let name, let color):
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(LinearGradient(colors: [color.mix(with: .white, by: 0.15), color.mix(with: .black, by: 0.45)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 48, height: 48)
                .overlay(Image(systemName: name).font(.system(size: 18, weight: .bold)).foregroundStyle(.white))
        case .item:
            ArtworkView(url: thumbnail, size: 48, cornerRadius: 4, circle: circle)
                .overlay {
                    // Hovering the artwork offers to play without opening the page.
                    if let target {
                        CoverPlayOverlay(visible: hovering, state: player.playState(of: target), circle: circle, glyphSize: 18) {
                            if isPlayingFrom { player.togglePlayPause() } else { player.playCollection(target, playlistId: playlistId) }
                        }
                    }
                }
        }
    }
}
