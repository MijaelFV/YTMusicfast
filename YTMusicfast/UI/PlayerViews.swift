import Translation
import SwiftUI

// MARK: - Shared artwork animation

private struct ArtNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    /// Namespace used to fly the now-playing artwork between the player bar and the full player.
    var artNamespace: Namespace.ID? {
        get { self[ArtNamespaceKey.self] }
        set { self[ArtNamespaceKey.self] = newValue }
    }
}

private struct NowPlayingArtGeometry: ViewModifier {
    @Environment(\.artNamespace) private var namespace

    func body(content: Content) -> some View {
        if let namespace {
            content.matchedGeometryEffect(id: "now-playing-art", in: namespace)
        } else {
            content
        }
    }
}

extension View {
    func nowPlayingArtGeometry() -> some View { modifier(NowPlayingArtGeometry()) }
}

// MARK: - Player bar

struct PlayerBar: View {
    @Environment(Router.self) private var router
    /// The bar's width, for its 30% · 40% · 30% split. Changes only when the window resizes.
    @State private var width: CGFloat = 1200
    private var player: PlayerController { .shared }

    var body: some View {
        // The song and the buttons each get 30% of the bar; the controls the 40% between.
        let side = max(180, (width - 32) * 0.3)
        HStack(spacing: 0) {
            NowPlayingInfo()
                .padding(.trailing, 16)
                .frame(width: side, alignment: .leading)

            VStack(spacing: 6) {
                TransportControls(size: .regular)
                ProgressScrubber()
            }
            .frame(maxWidth: 722)
            .frame(maxWidth: .infinity)

            // Narrower windows drop the least-used buttons (all of them are also in the menus)
            // rather than letting the cluster spill over the scrubber.
            ViewThatFits(in: .horizontal) {
                sideControls(.full)
                sideControls(.medium)
                sideControls(.small)
                sideControls(.tiny)
            }
            .padding(.leading, 16)
            .frame(width: side, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .frame(height: 84)
        .background {
            // Like YouTube Music, clicking an empty part of the bar opens or closes the player page;
            // ⌥-click switches the visualizer. Buttons, links and the scrubber keep their clicks.
            Theme.window
                .overlay(alignment: .bottom) { PlayerBarVisualizer().frame(height: 72) }
                .contentShape(Rectangle())
                .onTapGesture {
                    if NSEvent.modifierFlags.contains(.option) {
                        let current = VisualizerMode(rawValue: UserDefaults.standard.string(forKey: VisualizerMode.key) ?? "") ?? .off
                        UserDefaults.standard.set(current.next.rawValue, forKey: VisualizerMode.key)
                    } else if player.current != nil {
                        router.toggleNowPlayingPage()
                    }
                }
        }
    }

    private enum Density: Int, Comparable {
        case tiny, small, medium, full
        static func < (a: Density, b: Density) -> Bool { a.rawValue < b.rawValue }
    }

    private func sideControls(_ density: Density) -> some View {
        HStack(spacing: 2) {
            if density >= .small {
                IconButton(systemImage: "rectangle.portrait.on.rectangle.portrait", size: 15,
                           active: router.rightPanel == .nowPlaying, label: String(localized: "Now playing view")) {
                    withAnimation(.spring(duration: 0.3)) { router.togglePanel(.nowPlaying) }
                }
            }
            let cast = CastController.shared
            IconButton(systemImage: "music.mic", size: 15,
                       active: cast.lyricsButtonsControlTV ? cast.lyricsOnTV : router.route == .lyrics,
                       label: String(localized: "Lyrics (⌥⌘L)")) {
                if cast.lyricsButtonsControlTV { cast.toggleLyricsOnTV() } else { router.toggleLyrics() }
            }
            IconButton(systemImage: "list.bullet", size: 15, active: router.rightPanel == .queue, label: String(localized: "Queue (⌥⌘U)")) {
                withAnimation(.spring(duration: 0.3)) { router.togglePanel(.queue) }
            }
            if density >= .small { PlaybackOptionsMenu() }
            if density >= .medium { DevicePicker() }
            VolumeSlider()
                .frame(width: density == .full ? 130 : density == .medium ? 104 : 84)
                .padding(.leading, 4)
        }
        .fixedSize()
    }
}

/// Sleep timer and playback speed (YouTube Music's player options). Lit while either is in use.
struct PlaybackOptionsMenu: View {
    /// See `MenuButton.openSignal`.
    var openSignal = 0
    @State private var hovering = false
    private var player: PlayerController { .shared }

    static let speeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    private var active: Bool { player.sleepTimer != .off || player.playbackRate != 1 }

    private var entries: [MenuEntry] {
        var entries: [MenuEntry] = [.header(String(localized: "Sleep timer"))] + SleepTimerEntries.make()
        entries += [.divider, .header(String(localized: "Speed"))]
        entries += Self.speeds.map { speed in
            .choice(speed == 1 ? String(localized: "Normal") : "\(speed.formatted())×", selected: player.playbackRate == speed) {
                player.playbackRate = speed
            }
        }
        return entries
    }

    var body: some View {
        MenuButton(alignment: .trailing, entries: { entries }) { open in
            ZStack(alignment: .topTrailing) {
                Image(systemName: player.sleepTimer != .off ? "moon.fill" : "moon")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(active ? Theme.accent : hovering || open ? Theme.text : Theme.secondary)
                    .frame(width: 31, height: 31)
                if player.playbackRate != 1 {
                    Text("\(player.playbackRate.formatted())×")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 2)
                        .background(Capsule().fill(Theme.accent))
                }
            }
        }
        .opening(on: openSignal)
        .fixedSize()
        .onHover { hovering = $0 }
        .tooltip(sleepLabel)
        .accessibilityLabel("Sleep timer and speed")
    }

    private var sleepLabel: String {
        switch player.sleepTimer {
        case .off: String(localized: "Sleep timer & speed")
        case .endOfTrack: String(localized: "Stopping after this song")
        case .at(let date): String(localized: "Stopping at \(date.formatted(date: .omitted, time: .shortened))")
        }
    }
}

/// The ⊕ / ✓ "save to Liked Music" button.
struct LikeButton: View {
    var size: CGFloat = 18
    private var player: PlayerController { .shared }

    var body: some View {
        let liked = player.likeStatus == .like
        Button { player.toggleLike() } label: {
            Image(systemName: liked ? "checkmark.circle.fill" : "plus.circle")
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(liked ? Theme.accent : Theme.secondary)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: liked)
                .frame(width: size + 12, height: size + 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(liked ? String(localized: "Remove like (⌘L)") : String(localized: "Like (⌘L)"))
        .accessibilityLabel(liked ? String(localized: "Remove like") : String(localized: "Like"))
        .disabled(player.current == nil)
    }
}

struct NowPlayingInfo: View {
    @Environment(Router.self) private var router
    private var player: PlayerController { .shared }

    var body: some View {
        if let track = player.current {
            HStack(spacing: 12) {
                ArtworkView(url: track.thumbnail, size: 56, cornerRadius: 4)
                .frame(width: 56, height: 56)
                .contentShape(Rectangle())
                // YouTube Music: the cover opens the player page in the middle column.
                .onTapGesture { router.toggleNowPlayingPage() }
                // Drag the playing song onto a playlist (or into another app as its link).
                .trackDraggable(track)
                .accessibilityLabel(router.route == .nowPlaying ? "Close player page" : "Open player page")
                .accessibilityAddTraits(.isButton)

                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .onTapGesture { if let album = track.album { router.open(album: album) } }
                        .hoverUnderline()
                    if let error = player.errorMessage {
                        HStack(spacing: 8) {
                            Text(error).font(.system(size: 11)).foregroundStyle(Theme.accent).lineLimit(1)
                                .help(error)
                            // Stopped on it (not a failed start of something else while this plays).
                            if !player.isPlaying {
                                errorAction(String(localized: "Try Again")) {
                                    if let index = player.currentIndex, player.queue.indices.contains(index) { player.jump(to: player.queue[index]) }
                                }
                                errorAction(String(localized: "Skip")) { player.next() }
                            }
                        }
                    } else {
                        ArtistLinks(artists: track.artists, font: .system(size: 12))
                    }
                }
                LikeButton()
            }
            .menuOnRightClick { TrackMenuEntries.make(for: track) }
        } else {
            Color.clear.frame(height: 56)
        }
    }

    private func errorAction(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Theme.text)
            .hoverUnderline()
            .fixedSize()
    }
}

struct TransportControls: View {
    enum Size { case regular, large }
    var size: Size
    @Environment(\.colorScheme) private var colorScheme
    private var player: PlayerController { .shared }

    var body: some View {
        let large = size == .large
        let main: CGFloat = large ? 60 : 34
        HStack(spacing: large ? 30 : 18) {
            // Off → Shuffle → Smart Shuffle (recommendations mixed in).
            IconButton(systemImage: player.smartShuffle ? "shuffle.circle.fill" : "shuffle", size: large ? 20 : 15, active: player.shuffle,
                       label: player.smartShuffle ? String(localized: "Smart Shuffle (click to turn off)") : player.shuffle ? String(localized: "Shuffle — click for Smart Shuffle") : String(localized: "Shuffle (⌘S)")) {
                player.cycleShuffle()
            }
            .accessibilityValue(player.smartShuffle ? String(localized: "Smart Shuffle") : player.shuffle ? String(localized: "On") : String(localized: "Off"))
            IconButton(systemImage: "backward.end.fill", size: large ? 24 : 16, label: String(localized: "Previous (⌘←)")) { player.previous() }

            Button { player.togglePlayPause() } label: {
                ZStack {
                    Circle().fill(Theme.contrast).frame(width: main, height: main)
                    if player.isBuffering && player.current != nil {
                        // The spinner contrasts with the button, which is the opposite of the theme.
                        ProgressView().controlSize(large ? .regular : .small).colorScheme(colorScheme == .dark ? .light : .dark)
                    } else {
                        PlayPauseGlyph(isPlaying: player.isPlaying, diameter: main)
                            .foregroundStyle(Theme.onContrast)
                    }
                }
            }
            .buttonStyle(PressScaleStyle())
            .help("Play/Pause (Space)")
            .accessibilityLabel(player.isPlaying ? String(localized: "Pause") : String(localized: "Play"))

            IconButton(systemImage: "forward.end.fill", size: large ? 24 : 16, label: String(localized: "Next (⌘→)")) { player.next() }
            IconButton(systemImage: player.repeatMode == .one ? "repeat.1" : "repeat", size: large ? 20 : 15,
                       active: player.repeatMode != .off, label: String(localized: "Repeat (⌘R)")) { player.cycleRepeat() }
                .accessibilityValue(player.repeatMode == .off ? String(localized: "Off") : player.repeatMode == .all ? String(localized: "All") : String(localized: "One"))
        }
        .disabled(player.current == nil)
        .opacity(player.current == nil ? 0.5 : 1)
    }
}

/// Slight press-down scale for primary buttons.
struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(duration: 0.15), value: configuration.isPressed)
    }
}

struct ProgressScrubber: View {
    var showTimesBelow = false
    @State private var dragValue: Double?
    @State private var hovering = false
    /// Where the pointer is over the bar (0…1), for the time preview bubble.
    @State private var hoverFraction: CGFloat?
    @State private var hoverLocation: CGPoint?
    /// The total, or (clicked) the time left.
    @AppStorage("showsRemainingTime") private var remaining = false
    private var player: PlayerController { .shared }

    var body: some View {
        let known = player.duration > 0
        let duration = max(player.duration, 1)
        // With an unknown length (restored song not loaded yet) show the real elapsed time, empty bar.
        let value = dragValue ?? (known ? min(player.currentTime, duration) : player.currentTime)
        let active = (hovering || dragValue != nil) && known
        let elapsed = Text(Format.time(value))
        let total = Text(remaining && known ? "-" + Format.time(max(0, player.duration - value)) : Format.time(known ? player.duration : nil))
            .contentShape(Rectangle())
            .onTapGesture { remaining.toggle() }
            .help(remaining ? String(localized: "Show the length") : String(localized: "Show the time left"))

        VStack(spacing: 4) {
            HStack(spacing: 8) {
                if !showTimesBelow { elapsed.lineLimit(1).fixedSize().frame(minWidth: 40, alignment: .trailing) }
                GeometryReader { geo in
                    let fraction = known ? CGFloat(value / duration) : 0
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.text.opacity(0.3))
                        Capsule().fill(active ? Theme.accent : Theme.text)
                            .frame(width: max(0, geo.size.width * fraction))
                        if active {
                            Circle().fill(Theme.contrast).frame(width: 12, height: 12)
                                .shadow(color: .black.opacity(0.4), radius: 2)
                                .offset(x: max(0, geo.size.width * fraction - 6))
                        }
                    }
                    .frame(height: 4)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { g in dragValue = Double(min(max(0, g.location.x / geo.size.width), 1)) * duration }
                        .onEnded { _ in
                            if let dragValue { player.seek(to: dragValue) }
                            dragValue = nil
                        })
                }
                .frame(height: 14)
                .onHover { hovering = $0 }
                .overlay(alignment: .topLeading) {
                    // A time bubble follows the pointer along the bar.
                    GeometryReader { geo in
                        if let fraction = dragValue.map({ CGFloat($0 / duration) }) ?? hoverFraction, player.duration > 0 {
                            Text(Format.time(Double(fraction) * player.duration))
                                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                .foregroundStyle(Theme.text)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.raised))
                                .shadow(color: .black.opacity(0.5), radius: 6, y: 2)
                                .fixedSize()
                                .position(x: min(max(fraction * geo.size.width, 20), geo.size.width - 20), y: -16)
                                .allowsHitTesting(false)
                        }
                    }
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location): hoverFraction = nil; hoverLocation = location
                    case .ended: hoverFraction = nil; hoverLocation = nil
                    }
                }
                .background(GeometryReader { geo in
                    Color.clear.onChange(of: hoverLocation) { _, location in
                        hoverFraction = location.map { min(max(0, $0.x / geo.size.width), 1) }
                    }
                })
                if !showTimesBelow { total.lineLimit(1).fixedSize().frame(minWidth: 40, alignment: .leading) }
            }
            if showTimesBelow {
                HStack { elapsed; Spacer(); total }
            }
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(Theme.secondary)
        .disabled(player.current == nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Format.time(player.currentTime)) of \(Format.time(player.duration))")
        .accessibilityAdjustableAction { direction in
            player.skip(by: direction == .increment ? 10 : -10)
        }
    }
}

struct VolumeSlider: View {
    @State private var hovering = false
    /// Scroll wheel / two-finger scroll over the slider changes the volume; watched only while
    /// the pointer is on it.
    @State private var scrollMonitor: Any?

    var body: some View {
        @Bindable var player = PlayerController.shared
        HStack(spacing: 6) {
            let level = player.isMuted ? 0 : player.volume
            Button { player.toggleMute() } label: {
                Image(systemName: level == 0 ? "speaker.slash" : level < 0.5 ? "speaker.wave.1" : "speaker.wave.2")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(hovering ? Theme.text : Theme.secondary)
                    .frame(width: 22)
            }
            .buttonStyle(.plain)
            .help(level == 0 ? String(localized: "Unmute (M)") : String(localized: "Mute (M)"))
            .accessibilityLabel(level == 0 ? String(localized: "Unmute") : String(localized: "Mute"))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.text.opacity(0.3))
                    Capsule().fill(hovering ? Theme.accent : Theme.text).frame(width: geo.size.width * level)
                    if hovering {
                        Circle().fill(Theme.contrast).frame(width: 12, height: 12)
                            .offset(x: max(0, geo.size.width * level - 6))
                    }
                }
                .frame(height: 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    player.isMuted = false
                    player.volume = Double(min(max(0, g.location.x / geo.size.width), 1))
                })
            }
            .frame(height: 14)
            .accessibilityElement()
            .accessibilityLabel("Volume")
            .accessibilityValue("\(Int(level * 100)) percent")
            .accessibilityAdjustableAction { direction in
                player.volume = min(1, max(0, player.volume + (direction == .increment ? 0.1 : -0.1)))
            }
        }
        .onHover { inside in
            hovering = inside
            if inside { watchScrolling() } else { stopWatchingScrolling() }
        }
        .onDisappear { stopWatchingScrolling() }
    }

    private func watchScrolling() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            MainActor.assumeIsolated {
                // Up or right is louder, whichever way the system scrolls content.
                let inverted = event.isDirectionInvertedFromDevice
                let vertical = inverted ? -event.scrollingDeltaY : event.scrollingDeltaY
                let horizontal = inverted ? event.scrollingDeltaX : -event.scrollingDeltaX
                let delta = abs(vertical) >= abs(horizontal) ? vertical : horizontal
                guard delta != 0 else { return nil }
                // A trackpad reports points, a wheel lines: about 5% a notch.
                let step = event.hasPreciseScrollingDeltas ? delta * 0.004 : delta * 0.05
                let player = PlayerController.shared
                if player.isMuted {
                    // Muted: up turns it on from silence (not straight back to the old level).
                    guard step > 0 else { return nil }
                    player.volume = 0
                    player.isMuted = false
                }
                player.volume = min(1, max(0, player.volume + step))
                return nil
            }
        }
    }

    private func stopWatchingScrolling() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
    }
}

// MARK: - Right panel: Now Playing view / Queue

struct RightPanel: View {
    var mode: Router.RightPanel

    var body: some View {
        Group {
            switch mode {
            case .nowPlaying: NowPlayingPanel()
            case .queue: QueuePanel()
            case .devices: ConnectPanel()
            }
        }
        .panel()
    }
}

struct NowPlayingPanel: View {
    @Environment(Router.self) private var router
    /// The panel shows the song's comments in place of its cards.
    @State private var showingComments = false
    private var player: PlayerController { .shared }

    var body: some View {
        if showingComments, player.current?.isLocal == false {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    IconButton(systemImage: "chevron.left", size: 14, label: String(localized: "Back")) {
                        withAnimation(.snappy(duration: 0.25)) { showingComments = false }
                    }
                    Text("Comments").font(.system(size: 16, weight: .bold))
                    Spacer()
                    IconButton(systemImage: "xmark", size: 13, label: String(localized: "Close")) {
                        withAnimation(.spring(duration: 0.3)) { router.rightPanel = nil }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 14)
                CommentsList()
            }
            .transition(.move(edge: .trailing).combined(with: .opacity))
        } else if let track = player.currentSong {
            ScrollView {
                // Lazy: the cards further down load only when scrolled to.
                LazyVStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 8) {
                        Text(player.playingContext?.title ?? track.album?.name ?? String(localized: "Now playing"))
                            .font(.system(size: 16, weight: .bold))
                            .lineLimit(1)
                            .onTapGesture {
                                if let context = player.playingContext { router.open(context) }
                                else if let album = track.album { router.open(album: album) }
                            }
                            .hoverUnderline()
                        Spacer()
                        MenuButton.more(size: 14, alignment: .trailing) { TrackMenuEntries.make(for: track) }
                        IconButton(systemImage: "xmark", size: 13, label: String(localized: "Close")) {
                            withAnimation(.spring(duration: 0.3)) { router.rightPanel = nil }
                        }
                    }

                    // The Song/Video switch lives on the player page (click the player bar).
                    // Always the song's cover, never the video (that's the player page's); no
                    // video loads or decodes for this panel.
                    ArtworkView(url: track.thumbnail, size: 300, cornerRadius: 8, resizable: true)
                        .shadow(color: .black.opacity(0.4), radius: 16, y: 8)

                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(track.title)
                                .font(.system(size: 22, weight: .bold))
                                .lineLimit(2)
                            ArtistLinks(artists: track.artists, font: .system(size: 15))
                        }
                        Spacer()
                        LikeButton(size: 22)
                    }

                    CommentsCard(track: track) {
                        withAnimation(.snappy(duration: 0.25)) { showingComments = true }
                    }
                    if let artist = track.artists.first(where: { $0.browseId != nil }) {
                        AboutArtistCard(artist: artist)
                    }
                    CreditsCard(track: track)
                    ChaptersCard(track: track)
                    NextInQueueCard()
                }
                .padding(16)
            }
            .scrollIndicators(.never)
            .transition(.opacity)
        } else {
            ContentUnavailableView("Nothing playing", systemImage: "music.note",
                                   description: Text("Play something and it shows up here."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Loads an artist page header once per artist for the Now Playing view.
@MainActor
private enum ArtistInfoCache {
    static var headers: [String: PageHeader] = [:]
}

struct AboutArtistCard: View {
    var artist: ArtistRef
    @State private var header: PageHeader?
    @Environment(Router.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                ArtworkBanner(url: header?.thumbnail, width: 298, height: 200)
                LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .center)
                Text("About the artist")
                    .font(.cardTitle)
                    .padding(14)
            }
            .frame(height: 200)
            .clipped()
            VStack(alignment: .leading, spacing: 6) {
                Text(artist.name).font(.system(size: 17, weight: .bold))
                if header == nil {
                    // Holds the card's height while the artist loads, so nothing below jumps.
                    SkeletonText(widths: [110, 260, 230, 170]).padding(.top, 2)
                }
                if let subtitle = header?.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                if let description = header?.description {
                    Text(description)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(3)
                }
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.elevated)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { router.open(artist: artist) }
        .task(id: artist.browseId) {
            guard let id = artist.browseId else { return }
            if let cached = ArtistInfoCache.headers[id] { header = cached; return }
            header = nil // don't show the previous artist while this one loads
            let page = try? await MusicAPI.browse(BrowseTarget(browseId: id, kind: .artist, title: artist.name))
            header = page?.header
            ArtistInfoCache.headers[id] = page?.header
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { router.open(artist: artist) }
    }
}

/// "Credits": who's on the track, with Follow, plus YouTube Music's writer/producer credits.
struct CreditsCard: View {
    var track: Track
    @Environment(Router.self) private var router
    @State private var roles: [CreditRole] = []
    private var library: LocalLibrary { .shared }

    var body: some View {
        if !track.artists.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Credits").font(.cardTitle)
                    Spacer()
                    if !track.isLocal {
                        Button("Show all") { router.creditsTrack = track }
                            .buttonStyle(.plain)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Theme.secondary)
                            .hoverUnderline()
                    }
                }
                ForEach(roles.filter { !$0.role.localizedCaseInsensitiveContains("performed") && !$0.role.localizedCaseInsensitiveContains("provided") }
                    .prefix(3), id: \.role) { role in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(role.names.joined(separator: ", ")).font(.system(size: 14, weight: .medium)).lineLimit(2)
                        Text(role.role.replacingOccurrences(of: " by", with: "")).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    }
                }
                ForEach(Array(track.artists.enumerated()), id: \.offset) { index, artist in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(artist.name)
                                .font(.system(size: 14, weight: .medium))
                                .onTapGesture { router.open(artist: artist) }
                                .hoverUnderline()
                            Text(index == 0 ? String(localized: "Main Artist") : String(localized: "Artist")).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        }
                        Spacer()
                        if let id = artist.browseId {
                            let item = MediaItem(target: BrowseTarget(browseId: id, kind: .artist, title: artist.name), subtitle: String(localized: "Artist"))
                            let following = library.isPinned(item)
                            Button { library.togglePin(item) } label: {
                                Text(following ? String(localized: "Subscribed") : String(localized: "Subscribe"))
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(Theme.text)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 5)
                                    .overlay(Capsule().strokeBorder(Theme.secondary, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(14)
            .background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .task(id: track.videoId) {
                roles = []
                guard !track.isLocal else { return }
                roles = (try? await MusicAPI.credits(videoId: track.videoId)) ?? []
            }
        }
    }
}

/// The song's comment count and top comment; click for all of them (in the same panel).
struct CommentsCard: View {
    var track: Track
    var open: () -> Void
    @State private var preview: Comment?
    @State private var total: String?
    @State private var off = false
    @State private var hovering = false

    var body: some View {
        if !track.isLocal, !off {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(total ?? String(localized: "Comments")).font(.cardTitle)
                        Spacer()
                        Text("Show all")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Theme.secondary)
                            .underline(hovering)
                    }
                    if let preview {
                        HStack(alignment: .top, spacing: 10) {
                            ArtworkView(url: preview.authorAvatar, size: 24, circle: true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preview.author).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
                                Text(preview.text).font(.system(size: 13)).lineLimit(3).multilineTextAlignment(.leading)
                            }
                        }
                    } else {
                        SkeletonComment()
                    }
                }
                .foregroundStyle(Theme.text)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hovering ? Theme.raised : Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityLabel(String(localized: "Comments"))
            .task(id: track.videoId) { await load() }
        }
    }

    /// Only the first comment and the count are kept; the full list loads when opened.
    private func load() async {
        preview = nil
        total = nil
        off = false
        let videoId = track.videoId
        await WatchExtrasStore.shared.load(videoId)
        guard !Task.isCancelled else { return }
        // No token (comments are off for this video) or no answer (offline): no card.
        guard let token = WatchExtrasStore.shared.extras[videoId]?.commentsToken else {
            off = true
            return
        }
        guard let page = try? await MusicAPI.comments(token: token) else {
            if !Task.isCancelled { off = true }
            return
        }
        guard !Task.isCancelled else { return }
        if page.comments.isEmpty { off = true; return }
        preview = page.comments.first
        total = page.total
    }
}

struct NextInQueueCard: View {
    @Environment(Router.self) private var router
    private var player: PlayerController { .shared }

    var body: some View {
        if let next = player.upNext.first {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Next in queue").font(.cardTitle)
                    Spacer()
                    Button("Open queue") { withAnimation(.spring(duration: 0.3)) { router.rightPanel = .queue } }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.secondary)
                        .hoverUnderline()
                }
                QueueRow(entry: next)
            }
            .padding(14)
            .background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        }
    }
}

struct QueuePanel: View {
    private static let currentRowID = "queue-now-playing"
    var showsHeader = true
    @Environment(Router.self) private var router
    @State private var tab = 0
    /// Songs are being dragged over the queue.
    @State private var dropTargeted = false
    /// Selected songs (click, ⌘-click, ⇧-click, or ↑ / ↓ with ⇧): removed, moved or dragged together.
    @State private var selection: Set<QueueEntry.ID> = []
    /// Where a ⇧ range starts, and the end the arrow keys move.
    @State private var anchor: QueueEntry.ID?
    @State private var cursor: QueueEntry.ID?
    /// Identifies the queue as the list the arrow keys, Return and Delete act on.
    @State private var keysOwner = UUID()
    private var player: PlayerController { .shared }

    /// The selection in queue order.
    private func selectedEntries() -> [QueueEntry] { player.queue.filter { selection.contains($0.id) } }

    private func removeSelected() -> Bool {
        let playing = player.currentIndex.map { player.queue[$0].id }
        let removable = selectedEntries().filter { $0.id != playing }
        guard !removable.isEmpty else { return false }
        selection = []
        player.remove(removable)
        return true
    }

    /// ↑ / ↓ move the selection (⇧ extends it), Return plays the first selected song, and the
    /// menu key opens its menu: the same keys as a page's song list.
    private func handleKey(_ key: SelectionKeys.Key, extend: Bool, proxy: ScrollViewProxy) -> Bool {
        let queue = player.queue
        let positions = queue.indices.filter { selection.contains(queue[$0].id) }
        guard let first = positions.first, let last = positions.last else { return false }
        let position = { (id: QueueEntry.ID?) in id.flatMap { id in queue.firstIndex { $0.id == id } } }
        switch key {
        case .play:
            if first == player.currentIndex { player.togglePlayPause() } else { player.jump(to: queue[first]) }
        case .up, .down:
            let from = position(cursor) ?? (key == .up ? first : last)
            let target = min(max(0, from + (key == .up ? -1 : 1)), queue.count - 1)
            if extend, let start = position(anchor) {
                selection = Set(queue[min(start, target)...max(start, target)].map(\.id))
            } else {
                selection = [queue[target].id]
                anchor = queue[target].id
            }
            cursor = queue[target].id
            if target == player.currentIndex { proxy.scrollTo(Self.currentRowID) } else { proxy.scrollTo(queue[target].id) }
        case .menu:
            let index = position(cursor).flatMap { positions.contains($0) ? $0 : nil } ?? first
            let entry = queue[index]
            let entries = QueueRow.menuEntries(for: entry, isCurrent: index == player.currentIndex, group: selectedEntries())
            DispatchQueue.main.async {
                MenuPresenter.shared.showContextMenu(entries, at: MenuAnchorView.menuPoint(for: "\(keysOwner)-\(entry.id)"))
            }
        }
        return true
    }

    /// Songs dropped on the queue go to its end (or play, when nothing is).
    private func addDropped(_ payloads: [String]) -> Bool {
        let tracks = TrackDrag.tracks(in: payloads)
        guard !tracks.isEmpty else { return false }
        PlayerController.shared.addToQueue(tracks)
        router.showToast(tracks.count == 1 ? String(localized: "Added to queue") : String(localized: "Added \(tracks.count) songs to queue"))
        return true
    }

    var body: some View {
        @Bindable var player = PlayerController.shared
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader {
                HStack(spacing: 6) {
                    // The panel is narrow: tighten the tabs, then let them scroll, before clipping.
                    ViewThatFits(in: .horizontal) {
                        tabs(fontSize: 13, spacing: 10)
                        tabs(fontSize: 12, spacing: 8)
                        ScrollView(.horizontal, showsIndicators: false) { tabs(fontSize: 12, spacing: 8) }
                    }
                    Spacer(minLength: 0)
                    IconButton(systemImage: "infinity", size: 14, active: player.autoplay, label: String(localized: "Autoplay similar songs")) {
                        player.autoplay.toggle()
                    }
                    IconButton(systemImage: "xmark", size: 13, label: String(localized: "Close")) {
                        withAnimation(.spring(duration: 0.3)) { router.rightPanel = nil }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 14)
                .padding(.bottom, 4)
            }

            if tab == 1 {
                RecentlyPlayedList()
            } else if tab == 2 {
                RelatedList()
            } else {
            ScrollViewReader { proxy in
            List(selection: $selection) {
                // In a listening session: who's listening, and a way out, at the top of the queue.
                if ListenTogether.shared.role != .off {
                    SessionCard()
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                // Already played: they stay in the queue (YouTube Music), a click plays one again
                // and the rest of the queue stays as it is.
                if !player.played.isEmpty {
                    Section {
                        ForEach(Array(player.played)) { entry in
                            queueRow(entry)
                        }
                    } header: {
                        Text("Played").font(.cardTitle).foregroundStyle(Theme.secondary)
                    }
                }
                if let index = player.currentIndex, player.queue.indices.contains(index) {
                    Section {
                        queueRow(player.queue[index], isCurrent: true)
                            .id(Self.currentRowID)
                    } header: {
                        Text("Now playing").font(.cardTitle).foregroundStyle(Theme.text)
                    }
                }
                Section {
                    ForEach(Array(player.upNext)) { entry in
                        queueRow(entry)
                    }
                    .onMove { player.moveUpcoming(from: $0, to: $1) }
                } header: {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(player.playingContext.map { String(localized: "Next from: \($0.title)") } ?? String(localized: "Next up"))
                                .font(.cardTitle)
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                            Spacer()
                            if player.tuning { ProgressView().controlSize(.mini) }
                            if !player.upNext.isEmpty {
                                Button("Clear queue") { player.clearUpcomingWithUndo() }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(Theme.secondary)
                            }
                        }
                        if !player.radioTuners.isEmpty {
                            RadioTunerChips()
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 56)
            .overlay {
                if player.current == nil {
                    ContentUnavailableView("Your queue is empty", systemImage: "list.bullet",
                                           description: Text("Play something and what's next shows up here."))
                }
            }
            // Opens on the song that's playing (played ones are above), and follows it.
            .onAppear { proxy.scrollTo(Self.currentRowID, anchor: .top) }
            .onChange(of: player.currentIndex) { proxy.scrollTo(Self.currentRowID, anchor: .top) }
            .onChange(of: selection) { _, selected in
                if selected.count == 1 { anchor = selected.first; cursor = selected.first }
                guard !selected.isEmpty else {
                    SelectionKeys.unregister(keysOwner)
                    return
                }
                // Like a page's song list: the keys act on the list you last selected in.
                SelectionKeys.register(keysOwner) { key, extend in handleKey(key, extend: extend, proxy: proxy) }
                SelectionDelete.handler = { removeSelected() }
            }
            .onDisappear {
                SelectionKeys.unregister(keysOwner)
                if !selection.isEmpty { SelectionDelete.handler = nil }
            }
            }
            // Drag songs here from any list to queue them. (The list's own reordering is a
            // different kind of drag, so it still works.)
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                        .strokeBorder(Theme.accent, lineWidth: 2)
                        .padding(4)
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: String.self) { items, _ in addDropped(items) } isTargeted: { dropTargeted = $0 }
            }
        }
    }

    private func queueRow(_ entry: QueueEntry, isCurrent: Bool = false) -> some View {
        QueueRow(entry: entry, isCurrent: isCurrent, selected: selection.contains(entry.id), selectedEntries: selectedEntries,
                 menuAnchor: "\(keysOwner)-\(entry.id)")
            .tag(entry.id)
    }

    private func tabs(fontSize: CGFloat, spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            tabButton(String(localized: "Queue"), 0, fontSize: fontSize)
            tabButton(String(localized: "Recent"), 1, fontSize: fontSize)
            tabButton(String(localized: "Related"), 2, fontSize: fontSize)
        }
    }

    private func tabButton(_ title: String, _ index: Int, fontSize: CGFloat) -> some View {
        Button { tab = index } label: {
            Text(title)
                .font(.system(size: fontSize, weight: .bold))
                .foregroundStyle(tab == index ? Theme.text : Theme.secondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.vertical, 6)
                .overlay(alignment: .bottom) {
                    if tab == index { Rectangle().fill(Theme.accent).frame(height: 2).offset(y: 4) }
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(tab == index ? .isSelected : [])
    }
}

/// YouTube Music's radio tuning chips: the same radio, but more popular, more discovery,
/// deep cuts, a mood or a decade.
struct RadioTunerChips: View {
    private var player: PlayerController { .shared }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(player.radioTuners) { tuner in
                    Chip(title: tuner.title, selected: tuner.title == player.selectedTuner) { player.tuneRadio(tuner) }
                }
            }
        }
        .disabled(player.tuning)
        .accessibilityLabel("Tune the radio")
    }
}

/// YouTube Music's "Related" for the playing song: similar songs, artists and playlists.
struct RelatedList: View {
    @State private var page: BrowsePage?
    @State private var loadedFor: String?
    @State private var failed = false
    @Environment(Router.self) private var router
    private var player: PlayerController { .shared }

    var body: some View {
        Group {
            if player.current == nil {
                ContentUnavailableView("Nothing playing", systemImage: "sparkles",
                                       description: Text("Play something to see music like it."))
            } else if let page, loadedFor == player.current?.videoId {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(page.shelves) { shelf in
                            VStack(alignment: .leading, spacing: 4) {
                                if let title = shelf.title {
                                    Text(title).font(.cardTitle).padding(.horizontal, 16)
                                }
                                ForEach(ContentFilter.shared.filter(shelf.items).prefix(8)) { item in
                                    switch item {
                                    case .track(let track): RelatedTrackRow(track: track)
                                    case .media(let media): MediaRow(item: media)
                                    }
                                }
                            }
                        }
                        if let about = page.header?.description {
                            Text(about).font(.system(size: 13)).foregroundStyle(Theme.secondary).padding(.horizontal, 16)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .scrollIndicators(.never)
            } else if failed {
                ContentUnavailableView("Couldn't load related music", systemImage: "wifi.exclamationmark")
            } else {
                // Laid out like the list (a shelf title, then rows), so it doesn't jump when that arrives.
                SkeletonRows(count: 8, artworkSize: 44, rowPadding: 4, title: true).padding(.horizontal, 6).padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: player.current?.videoId) {
            guard let videoId = player.current?.videoId, loadedFor != videoId else { return }
            failed = false
            do {
                let related = try await MusicAPI.related(videoId: videoId)
                guard !Task.isCancelled else { return }
                page = related
                loadedFor = videoId
            } catch {
                if !Task.isCancelled { failed = true }
            }
        }
    }
}

private struct RelatedTrackRow: View {
    var track: Track
    @State private var hovering = false
    private var player: PlayerController { .shared }

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: track.thumbnail, size: 44, cornerRadius: 4)
                .overlay { CoverPlayOverlay(visible: hovering) { player.playRadio(from: track) } }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Text(track.artistLine).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if hovering {
                IconButton(systemImage: "text.line.first.and.arrowtriangle.forward", size: 13, label: String(localized: "Play next")) {
                    player.playNext(track)
                    Router.shared.showToast(String(localized: "Playing next"))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Theme.hover : .clear).padding(.horizontal, 6))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { player.playRadio(from: track) }
        .menuOnRightClick(hovering: hovering) { TrackMenuEntries.make(for: track) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(track.title), \(track.artistLine)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { player.playRadio(from: track) }
    }
}

/// Songs played on this Mac, newest first.
struct RecentlyPlayedList: View {
    private var library: LocalLibrary { .shared }

    var body: some View {
        if library.recentTracks.isEmpty {
            ContentUnavailableView("Nothing yet", systemImage: "clock",
                                   description: Text("Songs you play show up here."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(library.recentTracks) { track in
                QueueRow(entry: QueueEntry(track: track), isHistory: true)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }
}

struct QueueRow: View {
    var entry: QueueEntry
    var isCurrent = false
    var isHistory = false
    /// Selected in the queue, and the whole selection (asked for only when a menu needs it).
    var selected = false
    var selectedEntries: () -> [QueueEntry] = { [] }
    /// Names this row (while selected) for a menu opened from the keyboard.
    var menuAnchor: String?
    @State private var hovering = false
    @State private var engaged = false
    @State private var token = UUID()
    private var player: PlayerController { .shared }

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: entry.track.thumbnail, size: 44, cornerRadius: 4)
                .overlay {
                    // Static on purpose: an animated symbol inside a List redraws the whole list
                    // every frame (~20% CPU while playing).
                    if isCurrent, !engaged {
                        RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.45))
                        Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.accent)
                    }
                }
                // Hovered: ▶ plays it (⏸ / ▶ on the song that's playing).
                .overlay {
                    CoverPlayOverlay(visible: engaged, playing: isCurrent && player.isPlaying) {
                        if isCurrent { player.togglePlayPause() } else if isHistory { player.playRadio(from: entry.track) } else { player.jump(to: entry) }
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.track.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isCurrent ? Theme.accent : Theme.text)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if entry.isRecommendation {
                        Image(systemName: "sparkles").font(.system(size: 10)).foregroundStyle(Theme.accent)
                            .help("Recommended by Smart Shuffle")
                            .accessibilityLabel("Recommended")
                    }
                    if entry.track.isExplicit == true { ExplicitBadge() }
                    if entry.track.isVideo {
                        Image(systemName: "play.rectangle")
                            .font(.system(size: 10))
                            .accessibilityLabel("Music video")
                    }
                    Text(entry.track.artistLine).lineLimit(1)
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 0)
            if engaged, !isCurrent, !isHistory {
                if entry.isRecommendation {
                    Button { player.keepRecommendation(entry) } label: {
                        Image(systemName: "plus.circle").foregroundStyle(Theme.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Keep in queue")
                    .accessibilityLabel("Keep this recommendation")
                }
                Button { player.remove(entry) } label: {
                    Image(systemName: "minus.circle").foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove from queue")
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            // Remove button and menu only once the pointer rests (see `onHover(_:engaged:)`).
            if inside {
                Task {
                    try? await Task.sleep(for: .milliseconds(90))
                    if hovering { engaged = true }
                }
            } else {
                engaged = false
            }
            RowDoubleClick.hover(token, inside) {
                if isHistory { player.playRadio(from: entry.track) } else if !isCurrent { player.jump(to: entry) }
            }
        }
        .onDisappear { RowDoubleClick.hover(token, false) {} }
        .background { if selected, let menuAnchor { MenuAnchorView(id: menuAnchor) } }
        .listRowBackground(RoundedRectangle(cornerRadius: 6)
            .fill(selected ? Theme.text.opacity(0.18) : hovering ? Theme.hover : .clear).padding(.horizontal, 6))
        .listRowSeparator(.hidden)
        .menuOnRightClick(hovering: hovering) {
            if isHistory {
                return [.action(String(localized: "Play Now"), systemImage: "play.fill") { player.playRadio(from: entry.track) }, .divider]
                    + TrackMenuEntries.make(for: entry.track)
            }
            return Self.menuEntries(for: entry, isCurrent: isCurrent, group: selected ? selectedEntries() : [])
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.track.title), \(entry.track.artistLine)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if isHistory { player.playRadio(from: entry.track) } else { player.jump(to: entry) } }
        .accessibilityAction(named: "Remove from Queue") { if !isHistory { player.remove(entry) } }
    }
}

extension QueueRow {
    /// A queue song's menu; with several selected (`group`), it acts on all of them.
    @MainActor static func menuEntries(for entry: QueueEntry, isCurrent: Bool, group: [QueueEntry]) -> [MenuEntry] {
        let player = PlayerController.shared
        if group.count > 1, group.contains(where: { $0.id == entry.id }) {
            let playing = player.currentIndex.map { player.queue[$0].id }
            let others = group.filter { $0.id != playing }
            var entries: [MenuEntry] = []
            if !others.isEmpty {
                entries += [
                    // Moves these (Play Next would queue them again).
                    .action(String(localized: "Move to Top of Queue"), systemImage: "arrow.up.to.line") { player.moveToTop(others) },
                    .action(others.count == 1 ? String(localized: "Remove from Queue") : String(localized: "Remove \(others.count) Songs from Queue"),
                            systemImage: "minus.circle") { player.remove(others) },
                    .divider,
                ]
            }
            return entries + TrackMenuEntries.make(for: entry.track, selection: group.map(\.track))
        }
        var entries: [MenuEntry] = []
        if !isCurrent {
            entries += [
                .action(String(localized: "Play Now"), systemImage: "play.fill") { player.jump(to: entry) },
                .action(String(localized: "Remove from Queue"), systemImage: "minus.circle") { player.remove(entry) },
                .divider,
            ]
        }
        return entries + TrackMenuEntries.make(for: entry.track)
    }
}

/// Double-click on the hovered queue row. A tap gesture would be simpler, but any gesture on a
/// row stops a macOS List's drag-to-reorder, so this watches the app's clicks instead.
@MainActor
enum RowDoubleClick {
    private static var hovered: (token: UUID, action: () -> Void)?
    private static var monitor: Any?

    static func hover(_ token: UUID, _ inside: Bool, action: @escaping () -> Void) {
        if inside {
            hovered = (token, action)
            installMonitor()
        } else if hovered?.token == token {
            hovered = nil
        }
    }

    private static func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            if event.clickCount == 2 {
                MainActor.assumeIsolated { hovered?.action() }
            }
            return event
        }
    }
}

// MARK: - Lyrics (takes over the main view, on the artwork's colour)

struct LyricsPage: View {
    @State private var lyrics: Lyrics?
    @State private var loading = false
    /// On-device translation (Apple's Translation framework): line text → translation.
    @State private var translating = false
    @State private var translationConfig: TranslationSession.Configuration?
    @State private var translations: [String: String] = [:]
    @State private var tint = Color(white: 0.25)
    @State private var userScrolledAt: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var player: PlayerController { .shared }

    var body: some View {
        ZStack {
            tint.mix(with: Color(white: 0.24), by: 0.55)
            Group {
                if player.current == nil {
                    message(String(localized: "Play a song to see its lyrics."))
                } else if loading && lyrics == nil {
                    ProgressView().controlSize(.large)
                } else if let lyrics, lyrics.isSynced {
                    synced(lyrics)
                } else if let plain = lyrics?.plain {
                    ScrollView {
                        if translations.isEmpty {
                            Text(plain)
                                .font(.system(size: 26, weight: .bold))
                                .lineSpacing(10)
                                .foregroundStyle(.white)
                                .frame(maxWidth: 760, alignment: .leading)
                                .padding(40)
                        } else {
                            VStack(alignment: .leading, spacing: 14) {
                                ForEach(Array(plain.components(separatedBy: .newlines).enumerated()), id: \.offset) { _, line in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(line).font(.system(size: 26, weight: .bold)).foregroundStyle(.white)
                                        if let translated = translations[line.trimmingCharacters(in: .whitespaces)] {
                                            Text(translated).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                                        }
                                    }
                                }
                            }
                            .frame(maxWidth: 760, alignment: .leading)
                            .padding(40)
                        }
                        footer
                    }
                } else {
                    message(String(localized: "Looks like we don't have the lyrics for this song."))
                }
            }
        }
        .artworkTint(player.current?.thumbnail, into: $tint)
        .task(id: player.current?.videoId) { await load() }
        .overlay(alignment: .topTrailing) {
            if lyrics != nil {
                Button {
                    translating.toggle()
                    if translating {
                        translationConfig = TranslationSession.Configuration(source: nil, target: Locale.current.language)
                    } else {
                        translations = [:]
                    }
                } label: {
                    Label(translating ? String(localized: "Original") : String(localized: "Translate"), systemImage: "character.bubble")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(.black.opacity(0.3)))
                }
                .buttonStyle(.plain)
                .padding(16)
                .help("Translate the lyrics on this Mac")
            }
        }
        .translationTask(translationConfig) { session in
            let lines = lyricLines
            guard translating, !lines.isEmpty else { return }
            let requests = lines.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
            do {
                let responses = try await session.translations(from: requests)
                var result: [String: String] = [:]
                for response in responses {
                    if let index = response.clientIdentifier.flatMap(Int.init), lines.indices.contains(index),
                       response.targetText.caseInsensitiveCompare(lines[index]) != .orderedSame {
                        result[lines[index]] = response.targetText
                    }
                }
                translations = result
            } catch {
                Router.shared.showToast(String(localized: "Couldn't translate these lyrics"), icon: "character.bubble")
                translating = false
            }
        }
        .onChange(of: player.current?.videoId) {
            translations = [:]
            if translating { translationConfig?.invalidate() }
        }
    }

    /// The lines to translate, without blanks and duplicates.
    private var lyricLines: [String] {
        let raw = lyrics?.isSynced == true ? lyrics!.lines.map(\.text) : (lyrics?.plain ?? "").components(separatedBy: .newlines)
        var seen = Set<String>()
        return raw.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 26, weight: .bold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(40)
    }

    private func synced(_ lyrics: Lyrics) -> some View {
        let active = lyrics.lineIndex(at: player.currentTime + 0.25)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Color.clear.frame(height: 48)
                    ForEach(lyrics.lines) { line in
                        let isActive = line.id == active
                        let isPast = line.id < (active ?? -1)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(line.text.isEmpty ? "♪" : line.text)
                                .font(.system(size: 44, weight: .heavy))
                                .tracking(-1)
                            if let translated = translations[line.text.trimmingCharacters(in: .whitespaces)] {
                                Text(translated).font(.system(size: 24, weight: .bold))
                                    .opacity(0.7)
                            }
                        }
                            // The sung line is white, everything else greyed out.
                            .foregroundStyle(isActive ? Color.white : Theme.text.opacity(isPast ? 0.55 : 0.45))
                            .frame(maxWidth: 820, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { player.seek(to: line.time) }
                            .hoverUnderline()
                            .id(line.id)
                            .animation(.easeOut(duration: 0.25), value: isActive)
                            .accessibilityAddTraits(isActive ? .isSelected : [])
                            .accessibilityAction(named: "Play from here") { player.seek(to: line.time) }
                    }
                    footer
                    Color.clear.frame(height: 200)
                }
                .padding(.horizontal, 64)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { userScrolledAt = Date() }
            }
            .onChange(of: active) { _, line in
                guard let line, Date().timeIntervalSince(userScrolledAt ?? .distantPast) > 4 else { return }
                withAnimation(reduceMotion ? nil : .spring(duration: 0.6)) { proxy.scrollTo(line, anchor: UnitPoint(x: 0, y: 0.35)) }
            }
            .onAppear {
                if let active { proxy.scrollTo(active, anchor: UnitPoint(x: 0, y: 0.35)) }
            }
        }
    }

    private var footer: some View {
        Text("Lyrics provided by \(lyrics?.source ?? "")")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(0.7))
            .padding(.top, 24)
    }

    private func load() async {
        guard let track = player.current else { lyrics = nil; return }
        lyrics = nil
        loading = true
        try? await Task.sleep(for: .milliseconds(150))
        let result = await LyricsService.shared.lyrics(for: track, duration: player.duration)
        guard !Task.isCancelled, player.current?.videoId == track.videoId else { return }
        lyrics = result
        loading = false
    }
}

// MARK: - Player page

/// YouTube Music's player page: the cover — or the music video in Video mode — big, with the
/// Song/Video switch, on the cover's colour. Shown in the middle column (clicking the cover in the
/// player bar); ⇧⌘F opens the full screen player (`FullPlayerView`).
struct PlayerStage: View {
    @Environment(Router.self) private var router
    @Environment(\.openWindow) private var openWindow
    @State private var tint = Color(white: 0.25)
    private var player: PlayerController { .shared }

    var body: some View {
        GeometryReader { geo in
            // Room for the title row and the Song/Video switch above, and a margin below.
            let side = max(200, min(geo.size.width - 120, geo.size.height - 160))
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    Text(player.playingContext?.title ?? player.current?.album?.name ?? String(localized: "Now playing"))
                        .font(.cardTitle)
                        .lineLimit(1)
                    Spacer()
                    if let track = player.current {
                        MenuButton.more(size: 16, color: .white, alignment: .trailing) { TrackMenuEntries.make(for: track) }
                    }
                    VideoQualityButton()
                    IconButton(systemImage: "pip.enter", size: 15, label: String(localized: "Open Miniplayer"), tooltipEdge: .bottom) {
                        openWindow(id: "miniplayer")
                    }
                    IconButton(systemImage: "arrow.up.left.and.arrow.down.right", size: 14, label: String(localized: "Full screen (⇧⌘F)"),
                               tooltipEdge: .bottom) {
                        withAnimation(.easeInOut(duration: 0.3)) { router.showFullPlayer = true }
                    }
                    IconButton(systemImage: "chevron.down", size: 15, label: String(localized: "Close"), tooltipEdge: .bottom) {
                        router.toggleNowPlayingPage()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                // Above the cover or video, like YouTube Music.
                if player.current?.isLocal == false {
                    SongVideoToggle().padding(.top, 4)
                }
                Spacer(minLength: 0)
                if player.current == nil {
                    Text("Play something to see it here.")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.7))
                }
                if let track = player.current {
                    let videoShowing = VideoController.shared.videoMode && track.isVideo
                    // Keyed by the queue entry, which stays the same when switching song ↔ video:
                    // only a new song rebuilds (and animates) the cover; a switch reshapes it.
                    let entryId = player.currentIndex.flatMap { player.queue.indices.contains($0) ? player.queue[$0].id : nil }
                    NowPlayingVisual(track: track, size: videoShowing ? max(side, min(geo.size.width - 80, (geo.size.height - 160) * 16 / 9)) : side,
                                     cornerRadius: 10)
                        .frame(width: videoShowing ? nil : side, height: videoShowing ? nil : side)
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                        .id(entryId)
                        .animation(.spring(duration: 0.45, bounce: 0.1), value: videoShowing)
                        .shadow(color: .black.opacity(0.45), radius: 40, y: 20)
                        .onTapGesture(count: 2) { player.togglePlayPause() }
                        .accessibilityLabel("\(track.title) artwork")
                }
                Spacer(minLength: 0)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .foregroundStyle(.white)
        .background(tint.headerTint().mix(with: .black, by: 0.1))
        .animation(.easeInOut(duration: 0.6), value: tint)
        .artworkTint(player.current?.thumbnail, into: $tint)
    }
}

// MARK: - Menu bar mini player

struct MiniPlayerView: View {
    private var player: PlayerController { .shared }

    var body: some View {
        VStack(spacing: 14) {
            if let track = player.current {
                HStack(spacing: 12) {
                    ArtworkView(url: track.thumbnail, size: 64, cornerRadius: 6)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title).font(.headline).lineLimit(1)
                        Text(track.artistLine).font(.subheadline).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    LikeButton()
                }
                ProgressScrubber(showTimesBelow: true)
                TransportControls(size: .regular)
            } else {
                Text("Nothing playing").foregroundStyle(Theme.secondary).padding()
            }
            Button("Open YT Musicfast") { StatusBarController.showMainWindow() }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(16)
        .frame(width: 320)
        .background(Theme.panel)
        .environment(Router.shared)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Miniplayer window (always on top)

struct MiniplayerWindow: View {
    @State private var hovering = false
    @State private var tint = Color(white: 0.25)
    private var player: PlayerController { .shared }

    var body: some View {
        VStack(spacing: 0) {
            // Drag handle (the window has no title bar, just the close button).
            // Same row as the close button: the window has no title bar, so this strip *is* it.
            Image(systemName: "circle.grid.3x3.fill")
                .font(.system(size: 7))
                .foregroundStyle(Theme.tertiary)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background(WindowDragArea(doubleClickZooms: false))

            GeometryReader { geo in
                let side = max(80, min(geo.size.width - 120, geo.size.height - 36))
                ZStack {
                    if let track = player.current {
                        ArtworkView(url: track.thumbnail, size: side, cornerRadius: 6, resizable: true)
                            .frame(width: side, height: side)
                            .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
                            .opacity(hovering ? 0.35 : 1)
                    } else {
                        Image(systemName: "music.note").font(.system(size: 40)).foregroundStyle(.white.opacity(0.5))
                    }
                    if hovering, player.current != nil {
                        VStack(spacing: 0) {
                            Spacer()
                            // A narrow miniplayer keeps just the transport buttons.
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 4) {
                                    MiniVolumeButton()
                                    TransportControls(size: .regular)
                                    ShareCurrentButton()
                                }
                                TransportControls(size: .regular)
                            }
                            .padding(.horizontal, 8)
                            Spacer()
                            ProgressScrubber(showTimesBelow: true)
                                .padding(.horizontal, 12)
                                .padding(.bottom, 10)
                        }
                        .transition(.opacity)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .background(tint.headerTint(), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
            .onTapGesture(count: 2) { player.togglePlayPause() }

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.current?.title ?? String(localized: "Nothing playing"))
                        .font(.system(size: 20, weight: .bold))
                        .lineLimit(1)
                    Text(player.current?.artistLine ?? " ")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
                Spacer()
                LikeButton(size: 22)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 14)
        }
        .frame(minWidth: 280, idealWidth: 330, minHeight: 280, idealHeight: 320)
        .ignoresSafeArea(.container, edges: .top)
        .foregroundStyle(.white)
        .background(Color.black)
        .animation(.easeInOut(duration: 0.5), value: tint)
        .artworkTint(player.current?.thumbnail, into: $tint)
        .background(WindowConfigurator { window in
            // Float above other apps and keep only the close button.
            window.level = .floating
            window.isMovableByWindowBackground = true
            window.collectionBehavior.insert(.canJoinAllSpaces)
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.contentMaxSize = NSSize(width: 560, height: 640)
            // macOS restores the last frame; an earlier build saved a stretched one.
            if window.frame.width > 560 || window.frame.height > 640 {
                window.setContentSize(NSSize(width: 330, height: 320))
            }
        })
        .environment(Router.shared)
    }
}

private struct MiniVolumeButton: View {
    var body: some View {
        @Bindable var player = PlayerController.shared
        let silent = player.isMuted || player.volume == 0
        IconButton(systemImage: silent ? "speaker.slash" : "speaker.wave.1", size: 14, label: silent ? String(localized: "Unmute") : String(localized: "Mute")) {
            player.toggleMute()
        }
    }
}

private struct ShareCurrentButton: View {
    private var player: PlayerController { .shared }

    var body: some View {
        if let track = player.current {
            ShareLink(item: URL(string: "https://music.youtube.com/watch?v=\(track.videoId)")!) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .tooltip(String(localized: "Share"))
            .accessibilityLabel("Share")
        }
    }
}

/// YouTube's Quality menu for the music video: Auto (and what it's showing now), or a fixed
/// size. Only while a video is what's shown.
struct VideoQualityButton: View {
    /// See `MenuButton.openSignal`.
    var openSignal = 0
    private var video: VideoController { .shared }

    var body: some View {
        if video.videoMode, PlayerController.shared.current?.isVideo == true, !video.availableHeights.isEmpty {
            MenuButton(alignment: .trailing, entries: { entries }) { open in
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(open ? Theme.text : Theme.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .opening(on: openSignal)
            .tooltip(String(localized: "Video quality"), edge: .bottom)
            .accessibilityLabel("Video quality")
        }
    }

    private var entries: [MenuEntry] {
        let playing = video.playingHeight
        let auto = playing > 0 ? String(localized: "Auto (\(Self.name(playing)))") : String(localized: "Auto")
        var entries: [MenuEntry] = [.header(String(localized: "Video quality")), .choice(auto, selected: video.quality == 0) { video.quality = 0 }]
            + video.availableHeights.map { height in
                .choice(Self.name(height), selected: video.quality == height) { video.quality = height }
            }
        // In full screen: trim the thin bars a 16:9 video leaves on a Mac screen.
        if Router.shared.showFullPlayer {
            entries += [.divider, .choice(String(localized: "Fill screen"), selected: video.fillsScreen) { video.fillsScreen.toggle() }]
        }
        return entries
    }

    /// "1080p HD", "2160p 4K"…, as YouTube labels them.
    static func name(_ height: Int) -> String {
        switch height {
        case 2160...: "\(height)p 4K"
        case 1440..<2160: "\(height)p QHD"
        case 720..<1440: "\(height)p HD"
        default: "\(height)p"
        }
    }
}

