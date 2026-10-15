import AppKit
import CoreImage
import SwiftUI

// MARK: - Full screen player (smart TV)

/// The full screen player's own window: borderless, over the whole screen the app is on, with the
/// menu bar and Dock out of the way. macOS's full screen (a Space of its own, animated from
/// snapshots of the window) got stuck when the player went in and out of it, leaving the
/// snapshot frozen on the desktop; a window like this opens and closes at once and can't.
/// Its view exists only while it's showing, so nothing of it runs otherwise.
@MainActor
final class FullPlayerWindow {
    static let shared = FullPlayerWindow()
    /// Its title, for the keyboard shortcuts that only work in the app's own windows.
    static let title = "YT Musicfast Full Screen"

    private var window: NSWindow?
    private var savedOptions: NSApplication.PresentationOptions = []

    /// Borderless windows don't take the keyboard by default.
    private final class PlayerWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    func setVisible(_ visible: Bool) {
        visible ? show() : hide()
    }

    private func show() {
        guard window == nil else { return }
        let screen = NSApp.mainWindow?.screen ?? NSApp.keyWindow?.screen ?? NSScreen.main
        guard let frame = screen?.frame else { return }
        let window = PlayerWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = Self.title
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.animationBehavior = .none
        window.contentView = NSHostingView(rootView: FullPlayerView()
            .environment(Router.shared)
            // Immersive and tinted by the cover: dark in either appearance.
            .environment(\.colorScheme, .dark))
        window.setFrame(frame, display: true)
        window.alphaValue = 0
        self.window = window

        savedOptions = NSApp.presentationOptions
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            window.animator().alphaValue = 1
        }
    }

    private func hide() {
        guard let window else { return }
        self.window = nil
        NSApp.presentationOptions = savedOptions
        // Back to the main window, which stayed where it was underneath.
        NSApp.windows.first { $0.title == "YT Musicfast" && $0.isVisible }?.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            window.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated {
                window.orderOut(nil)
                // Its view goes too: the player's clock, timers and monitors stop with it.
                window.contentView = nil
            }
        }
    }
}

/// What the arrow keys have highlighted, like a TV remote's focus.
enum TVFocus: Hashable {
    case top(TVTopItem)
    case seek
    case control(TVControl)
    case tab(TVRailTab)
    case card(Int)
}

/// The full screen player's buttons, left to right, as the arrow keys visit them.
enum TVControl: CaseIterable {
    case dislike, like, shuffle, previous, playPause, next, repeatMode, lyrics, rail, options, speaker, volume
}

/// The top bar's buttons, left to right.
enum TVTopItem: CaseIterable {
    case songVideo, quality, pin, more, exit
}

/// The menus the remote keys open.
enum TVMenu: Hashable {
    case quality, more, options, speaker
}

/// The rail's tabs (YouTube Music on a TV).
enum TVRailTab: CaseIterable {
    case upNext, related

    var title: String {
        switch self {
        case .upNext: String(localized: "Up next")
        case .related: String(localized: "Related")
        }
    }
}

/// What a key just did, flashed on screen for a moment.
enum TVFlash: Equatable {
    case seek(Int)
    case volume(Double)
    case play(Bool)
    /// A swipe to the next song (true) or the one before.
    case skip(Bool)
}

/// The full screen player's lean-back state, shared with the keyboard shortcuts.
@MainActor
@Observable
final class TVPlayerState {
    static let shared = TVPlayerState()

    /// The controls fade after a few seconds without the pointer or a key while music plays,
    /// leaving the cover and the song, as TV music apps do.
    var controlsVisible = true
    /// Pinned: the controls stay up instead of fading (remembered).
    var pinned = UserDefaults.standard.bool(forKey: "fullScreenPinned") {
        didSet { UserDefaults.standard.set(pinned, forKey: "fullScreenPinned") }
    }
    /// Synced lyrics beside the cover, or as captions over a music video.
    var showsLyrics = false
    /// The rail along the bottom: the coming songs, or songs related to this one.
    var showsRail = false
    var railTab: TVRailTab = .upNext
    /// Highlighted by the arrow keys; nil while the pointer is in use.
    var focus: TVFocus?
    var flash: TVFlash?
    /// Bumped to open a menu from the keyboard (see `MenuButton.openSignal`).
    private(set) var menuSignals: [TVMenu: Int] = [:]

    /// The playing song's lyrics, for the side lyrics and the video captions alike.
    private(set) var lyrics: Lyrics?
    private(set) var lyricsFor: String?
    /// Songs related to the playing one, for the rail.
    private(set) var related: [Track] = []
    private(set) var relatedFor: String?
    private(set) var relatedFailed = false

    @ObservationIgnored var pointerOverControls = false
    @ObservationIgnored private var lastActivity = Date()
    @ObservationIgnored private var lastPointer = NSPoint.zero
    @ObservationIgnored private var flashTask: Task<Void, Never>?
    @ObservationIgnored private var awake: NSObjectProtocol?
    @ObservationIgnored private var swipeMonitor: Any?
    /// The trackpad swipe so far: how far the fingers went, and whether it already skipped.
    @ObservationIgnored private var swipe = CGSize.zero
    @ObservationIgnored private var swiped = false

    private var player: PlayerController { .shared }

    // MARK: Showing and hiding

    func wake() {
        lastActivity = .now
        if !controlsVisible { withAnimation(.easeOut(duration: 0.25)) { controlsVisible = true } }
    }

    /// The pointer moved: the controls come back and the keyboard highlight goes, as on a TV
    /// with a pointer remote. Layout changes under a still pointer don't count.
    func pointerMoved() {
        let location = NSEvent.mouseLocation
        guard location != lastPointer else { return }
        lastPointer = location
        wake()
        if focus != nil { withAnimation(.easeOut(duration: 0.15)) { focus = nil } }
    }

    func togglePin() {
        wake()
        pinned.toggle()
    }

    func toggleLyrics() {
        wake()
        withAnimation(.spring(duration: 0.5, bounce: 0.1)) { showsLyrics.toggle() }
    }

    /// Q: the rail on its Up next tab, or away.
    func toggleUpNext() {
        if showsRail, railTab == .upNext { setRail(false) } else { railTab = .upNext; setRail(true) }
    }

    func setRail(_ on: Bool) {
        wake()
        withAnimation(.spring(duration: 0.4, bounce: 0.1)) {
            showsRail = on
            if !on, focus.map(Self.isInRail) == true { focus = .control(.rail) }
        }
    }

    /// Hides the controls once idle. Runs while the full screen player is up.
    func hideWhenIdle() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard controlsVisible, !pinned, Date.now.timeIntervalSince(lastActivity) > 4, player.isPlaying,
                  !pointerOverControls, !showsRail, !MenuPresenter.shared.isOpen else { continue }
            withAnimation(.easeInOut(duration: 0.7)) {
                controlsVisible = false
                focus = nil
            }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    func reset() {
        showsRail = false
        controlsVisible = true
        focus = nil
        flash = nil
        pointerOverControls = false
        keepAwake(false)
        watchSwipes(false)
    }

    /// The display stays on while music plays in full screen, like a TV app (a playing video
    /// already keeps it on). Let go on pause and on leaving.
    func keepAwake(_ on: Bool) {
        if on, awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: .idleDisplaySleepDisabled, reason: "Music playing in the full screen player")
        } else if !on, let activity = awake {
            ProcessInfo.processInfo.endActivity(activity)
            awake = nil
        }
    }

    /// Two fingers sideways on a trackpad skip songs: towards the left for the next one, towards
    /// the right for the one before. Not over the controls or the rail, which scroll themselves.
    func watchSwipes(_ on: Bool) {
        if on, swipeMonitor == nil {
            swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                MainActor.assumeIsolated { TVPlayerState.shared.scrolled(event) }
                return event
            }
        } else if !on, let monitor = swipeMonitor {
            NSEvent.removeMonitor(monitor)
            swipeMonitor = nil
        }
    }

    private func scrolled(_ event: NSEvent) {
        // Trackpad gestures only (a mouse wheel has no phases), and not their momentum.
        guard event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty else { return }
        if event.phase.contains(.began) {
            swipe = .zero
            swiped = false
        }
        guard !swiped, !pointerOverControls else { return }
        swipe.width += event.scrollingDeltaX
        swipe.height += event.scrollingDeltaY
        guard abs(swipe.width) > 120, abs(swipe.width) > abs(swipe.height) * 2 else { return }
        swiped = true
        wake()
        // The deltas follow the content; with natural scrolling that's where the fingers went.
        let towardsLeft = event.isDirectionInvertedFromDevice ? swipe.width < 0 : swipe.width > 0
        if towardsLeft { player.next() } else { player.previous() }
        show(.skip(towardsLeft))
    }

    // MARK: Remote keys

    /// Arrows, Return, Space and Esc, the way a TV remote works them. With the controls hidden,
    /// ← → seek and ↑ ↓ set the volume; with them showing, the arrows move the highlight and
    /// Return presses it. Returns false for keys left to the rest of the app.
    func handleKey(_ code: UInt16) -> Bool {
        switch code {
        case 49: // Space
            lastActivity = .now
            togglePlay()
            return true
        case 35: // P pins the controls
            togglePin()
            return true
        case 53: // Esc backs out of the rail first; then the caller leaves full screen.
            guard showsRail else { return false }
            setRail(false)
            return true
        case 36, 76: // Return
            if !controlsVisible || focus == nil {
                wake()
                setFocus(.control(.playPause))
            } else if let focus {
                wake()
                activate(focus)
            }
            return true
        case 123, 124, 125, 126:
            if !controlsVisible {
                lastActivity = .now
                switch code {
                case 123: seek(-10)
                case 124: seek(10)
                case 126: changeVolume(by: 0.05)
                default: changeVolume(by: -0.05)
                }
            } else {
                wake()
                move(code)
            }
            return true
        default:
            wake()
            return false
        }
    }

    private func move(_ code: UInt16) {
        guard let focus else { setFocus(.control(.playPause)); return }
        let left = code == 123, right = code == 124, up = code == 126, down = code == 125
        switch focus {
        case .top(let item):
            let items = availableTop
            let index = items.firstIndex(of: item) ?? 0
            if left, index > 0 { setFocus(.top(items[index - 1])) }
            if right, index < items.count - 1 { setFocus(.top(items[index + 1])) }
            if down { setFocus(.seek) }
        case .seek:
            if left { seek(-10) } else if right { seek(10) } else if down { setFocus(.control(.playPause)) }
            else if up, let first = availableTop.first { setFocus(.top(first)) }
        case .control(.volume) where up || down:
            // Up and down are the volume's own direction; left goes back along the row.
            changeVolume(by: up ? 0.05 : -0.05)
        case .control(let control):
            let controls = availableControls
            let index = controls.firstIndex(of: control) ?? 0
            if left, index > 0 { setFocus(.control(controls[index - 1])) }
            if right, index < controls.count - 1 { setFocus(.control(controls[index + 1])) }
            if up { setFocus(.seek) }
            if down {
                if !showsRail { setRail(true) }
                setFocus(.tab(railTab))
            }
        case .tab(let tab):
            let tabs = TVRailTab.allCases
            let index = tabs.firstIndex(of: tab) ?? 0
            if left, index > 0 { railTab = tabs[index - 1]; setFocus(.tab(railTab)) }
            if right, index < tabs.count - 1 { railTab = tabs[index + 1]; setFocus(.tab(railTab)) }
            if up { setFocus(.control(.rail)) }
            if down, cardCount > 0 { setFocus(.card(0)) }
        case .card(let index):
            if left, index > 0 { setFocus(.card(index - 1)) }
            if right, index < cardCount - 1 { setFocus(.card(index + 1)) }
            if up { setFocus(.tab(railTab)) }
        }
    }

    private func setFocus(_ new: TVFocus) {
        withAnimation(.spring(duration: 0.22, bounce: 0.2)) { focus = new }
    }

    private func activate(_ focus: TVFocus) {
        switch focus {
        case .top(let item): perform(item)
        case .seek: togglePlay()
        case .control(let control): perform(control)
        case .tab: if cardCount > 0 { setFocus(.card(0)) }
        case .card(let index): playCard(index)
        }
    }

    private static func isInRail(_ focus: TVFocus) -> Bool {
        switch focus {
        case .tab, .card: true
        default: false
        }
    }

    /// Rating a local file means nothing.
    var availableControls: [TVControl] {
        player.current?.isLocal == true ? TVControl.allCases.filter { $0 != .like && $0 != .dislike } : TVControl.allCases
    }

    /// What the top bar shows right now.
    var availableTop: [TVTopItem] {
        let track = player.current
        let video = VideoController.shared
        return TVTopItem.allCases.filter {
            switch $0 {
            case .songVideo: track?.isLocal == false
            case .quality: video.videoMode && track?.isVideo == true && !video.availableHeights.isEmpty
            case .more: track != nil
            case .pin, .exit: true
            }
        }
    }

    func openMenu(_ menu: TVMenu) {
        menuSignals[menu, default: 0] += 1
    }

    func perform(_ item: TVTopItem) {
        switch item {
        case .songVideo: SongVideoToggle.flip()
        case .quality: openMenu(.quality)
        case .pin: togglePin()
        case .more: openMenu(.more)
        case .exit: withAnimation(.easeInOut(duration: 0.3)) { Router.shared.showFullPlayer = false }
        }
    }

    func perform(_ control: TVControl) {
        switch control {
        case .options: openMenu(.options); return
        case .speaker: openMenu(.speaker); return
        case .volume: player.toggleMute(); show(.volume(player.isMuted ? 0 : player.volume)); return
        default: break
        }
        guard let track = player.current else { return }
        switch control {
        case .options, .speaker, .volume: break
        case .dislike: player.setDisliked(player.likeStatus != .dislike, track)
        case .like: player.toggleLike()
        case .shuffle: player.cycleShuffle()
        case .previous: player.previous()
        case .playPause: togglePlay()
        case .next: player.next()
        case .repeatMode: player.cycleRepeat()
        case .lyrics: toggleLyrics()
        case .rail: setRail(!showsRail)
        }
    }

    // MARK: The rail's songs

    /// The coming songs the rail shows (the queue can be long).
    var upNextCards: [QueueEntry] { Array(player.upNext.prefix(40)) }

    var cardCount: Int { railTab == .upNext ? upNextCards.count : related.count }

    func playCard(_ index: Int) {
        switch railTab {
        case .upNext:
            let cards = upNextCards
            if cards.indices.contains(index) { player.jump(to: cards[index]) }
        case .related:
            if related.indices.contains(index) { player.playRadio(from: related[index]) }
        }
        if focus.map(Self.isInRail) == true { setFocus(.tab(railTab)) }
    }

    func loadRelated() async {
        guard let videoId = player.current?.videoId, relatedFor != videoId else { return }
        relatedFailed = false
        do {
            let page = try await MusicAPI.related(videoId: videoId)
            guard player.current?.videoId == videoId else { return }
            var seen = Set<String>()
            related = page.shelves.flatMap { ContentFilter.shared.filter($0.items) }.compactMap { item -> Track? in
                guard case .track(let track) = item, seen.insert(track.videoId).inserted else { return nil }
                return track
            }
            .prefix(40).map { $0 }
            relatedFor = videoId
        } catch {
            if player.current?.videoId == videoId { relatedFailed = true }
        }
    }

    func loadLyrics() async {
        guard let track = player.current, lyricsFor != track.videoId else { return }
        let result = await LyricsService.shared.lyrics(for: track, duration: player.duration)
        guard !Task.isCancelled, player.current?.videoId == track.videoId else { return }
        lyrics = result
        lyricsFor = track.videoId
    }

    // MARK: Feedback

    private func togglePlay() {
        let willPlay = !player.isPlaying
        player.togglePlayPause()
        show(.play(willPlay))
    }

    private func seek(_ seconds: Int) {
        player.skip(by: TimeInterval(seconds))
        // Presses in a row add up: "30 seconds".
        if case .seek(let previous) = flash, previous.signum() == seconds.signum() {
            show(.seek(previous + seconds))
        } else {
            show(.seek(seconds))
        }
    }

    private func changeVolume(by delta: Double) {
        player.isMuted = false
        player.volume = min(1, max(0, player.volume + delta))
        show(.volume(player.volume))
    }

    /// What each kind of flash last showed: kept while it fades, so it fades as it was.
    private(set) var lastSeek = 0
    private(set) var lastVolume = 0.0
    private(set) var centerSymbol = "play.fill"

    /// No animation here: the flashes fade by themselves (see TVFlashView), and their contents
    /// change at once, so quick presses never leave a copy fading out behind a new one.
    private func show(_ new: TVFlash) {
        switch new {
        case .seek(let seconds): lastSeek = seconds
        case .volume(let level): lastVolume = level
        case .play(let playing): centerSymbol = playing ? "play.fill" : "pause.fill"
        case .skip(let forward): centerSymbol = forward ? "forward.end.fill" : "backward.end.fill"
        }
        flash = new
        flashTask?.cancel()
        flashTask = Task {
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            flash = nil
        }
    }
}

/// A lean-back player made for a big screen: the whole screen in the cover's colours,
/// the cover and the song big enough to read from the sofa, the controls fading away while the
/// music plays, a rail of what's next and synced lyrics a key away. Music videos fill the screen.
/// It works like a TV remote too: the arrows move a highlight and Return presses it.
struct FullPlayerView: View {
    @Environment(Router.self) private var router
    @State private var tint = Color(white: 0.2)
    /// Measured heights. The rail slides in over the bottom without re-laying anything out:
    /// the controls glide up with it and the cover zooms down to make room (YouTube on a TV).
    @State private var controlsHeight: CGFloat = 200
    @State private var railHeight: CGFloat = 290
    @State private var stageHeight: CGFloat = 500
    /// The controls' gap above the screen edge, tightened above the rail.
    private static let controlsBottom: CGFloat = 44
    private var player: PlayerController { .shared }
    private var tv: TVPlayerState { .shared }

    var body: some View {
        GeometryReader { geo in
            let margin = max(40, geo.size.width * 0.055)
            let videoShowing = player.current.map { VideoController.shared.videoMode && $0.isVideo && !$0.isLocal } ?? false
            let chrome = tv.controlsVisible ? 1.0 : 0.0
            // What floats above the bottom: over the controls while they show, near the edge when not.
            let railLift = tv.showsRail ? railHeight - Self.controlsBottom + 18 : 0
            let floatInset = tv.controlsVisible ? controlsHeight + railLift + 16 : 48
            let stageScale = tv.showsRail && stageHeight > 0 ? max(0.4, (stageHeight - railLift) / stageHeight) : 1
            ZStack {
                if videoShowing, let track = player.current {
                    Color.black
                    NowPlayingVisual(track: track, size: geo.size.width, cornerRadius: 0, fullScreen: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // A click plays or pauses, as on YouTube.
                        .onTapGesture { tv.perform(.playPause) }
                    // Scrims so the controls read over any picture.
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom).frame(height: 180)
                        Spacer()
                        LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom).frame(height: 360)
                    }
                    .opacity(chrome)
                    .allowsHitTesting(false)
                } else {
                    TVBackdrop(url: player.current?.thumbnail, tint: tint)
                }

                VStack(spacing: 0) {
                    // Hidden controls aren't drawn at all (their clock and progress bar would keep
                    // redrawing); their space stays, so nothing else moves.
                    ZStack {
                        if tv.controlsVisible { topBar(margin: margin).transition(.opacity) }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 96)
                    if videoShowing {
                        Spacer(minLength: 0)
                    } else {
                        stage(margin: margin)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { stageHeight = $0 }
                            // From the left margin, so the cover stays lined up with the controls below.
                            .scaleEffect(stageScale, anchor: UnitPoint(x: margin / max(1, geo.size.width), y: 0))
                    }
                    ZStack(alignment: .bottom) {
                        Color.clear.frame(height: controlsHeight)
                        if tv.controlsVisible {
                            controls(margin: margin, videoShowing: videoShowing)
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controlsHeight = $0 }
                                .transition(.opacity)
                        }
                    }
                    .offset(y: -railLift)
                }

                if tv.showsRail {
                    TVRail(margin: margin)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { railHeight = $0 }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if videoShowing, tv.showsLyrics {
                    TVLyricsCaption()
                        .padding(.horizontal, margin)
                        .padding(.bottom, floatInset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .allowsHitTesting(false)
                }
                if !tv.showsRail {
                    TVUpNextSoon()
                        .padding(.trailing, margin)
                        .padding(.bottom, floatInset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
                TVFlashView(flash: tv.flash)
                    .allowsHitTesting(false)
            }
            .animation(.spring(duration: 0.35), value: floatInset)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .foregroundStyle(.white)
        .background(Color.black)
        .ignoresSafeArea()
        .artworkTint(player.current?.thumbnail, into: $tint)
        // Any movement brings the controls back (and the pointer, which hides with them).
        .onContinuousHover { _ in tv.pointerMoved() }
        .task { await tv.hideWhenIdle() }
        .onAppear { tv.watchSwipes(true) }
        .onChange(of: player.isPlaying, initial: true) { _, playing in tv.keepAwake(playing) }
        .task(id: tv.showsLyrics ? player.current?.videoId : nil) {
            if tv.showsLyrics { await tv.loadLyrics() }
        }
        .onDisappear { tv.reset() }
    }

    // MARK: Top bar

    private func topBar(margin: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                if let context = player.playingContext?.title {
                    Text("PLAYING FROM")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.65))
                    Text(context)
                        .font(.system(size: 16, weight: .bold))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 20)
            if player.current?.isLocal == false { SongVideoToggle().tvFocus(.top(.songVideo), capsule: true) }
            TVClock()
                .padding(.horizontal, 6)
            VideoQualityButton(openSignal: tv.menuSignals[.quality] ?? 0).tvFocus(.top(.quality))
            IconButton(systemImage: tv.pinned ? "pin.fill" : "pin", size: 16, active: tv.pinned,
                       label: tv.pinned ? String(localized: "Let the controls hide (P)") : String(localized: "Keep the controls showing (P)"),
                       tooltipEdge: .bottom) {
                tv.togglePin()
            }
            .tvFocus(.top(.pin))
            if let track = player.current {
                MenuButton.more(size: 18, color: .white, alignment: .trailing) { TrackMenuEntries.make(for: track) }
                    .opening(on: tv.menuSignals[.more] ?? 0)
                    .tvFocus(.top(.more))
            }
            IconButton(systemImage: "arrow.down.right.and.arrow.up.left", size: 17, label: String(localized: "Exit full screen (Esc)"),
                       tooltipEdge: .bottom) {
                withAnimation(.easeInOut(duration: 0.3)) { router.showFullPlayer = false }
            }
            .tvFocus(.top(.exit))
        }
        .padding(.horizontal, margin)
        .frame(height: 96)
        .onHover { tv.pointerOverControls = $0 }
    }

    // MARK: Cover and song

    @ViewBuilder
    private func stage(margin: CGFloat) -> some View {
        GeometryReader { geo in
            let lyrics = tv.showsLyrics
            let side = max(160, lyrics ? min(geo.size.height * 0.62, geo.size.width * 0.3)
                                       : min(geo.size.height * 0.9, geo.size.width * 0.38))
            HStack(alignment: .center, spacing: max(40, geo.size.width * 0.05)) {
                if let track = player.current {
                    VStack(alignment: .leading, spacing: 22) {
                        cover(track, side: side)
                        if lyrics { songInfo(track, scale: 0.5).frame(width: side, alignment: .leading) }
                    }
                    if lyrics {
                        TVLyrics(fontSize: max(30, min(52, geo.size.height * 0.075)))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .transition(.opacity.combined(with: .offset(x: 40)))
                    } else {
                        songInfo(track, scale: max(0.75, min(1.2, geo.size.height / 560)))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .transition(.opacity.combined(with: .offset(x: -30)))
                    }
                } else {
                    Text("Play something to see it here.")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, margin)
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func cover(_ track: Track, side: CGFloat) -> some View {
        // Keyed by the queue entry: a new song swaps the cover, a Song ↔ Video switch doesn't.
        let entryId = player.currentIndex.flatMap { player.queue.indices.contains($0) ? player.queue[$0].id : nil }
        return ArtworkView(url: track.thumbnail, size: side, cornerRadius: 14, resizable: true)
            .frame(width: side, height: side)
            .shadow(color: .black.opacity(0.5), radius: 50, y: 24)
            .id(entryId)
            .transition(.scale(scale: 0.94).combined(with: .opacity))
            .onTapGesture { tv.perform(.playPause) }
            .accessibilityLabel("\(track.title) artwork")
            .accessibilityAddTraits(.isButton)
    }

    /// Title, artist and album, sized for reading across the room.
    private func songInfo(_ track: Track, scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10 * scale) {
            Text(track.title)
                .font(.system(size: 56 * scale, weight: .heavy))
                .tracking(-0.5)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
            Text(track.artistLine)
                .font(.system(size: 28 * scale, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
            if let album = track.album?.name, album != track.title {
                Text(album)
                    .font(.system(size: 20 * scale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
        }
        .id(track.videoId)
        .transition(.opacity)
    }

    // MARK: Controls

    private func controls(margin: CGFloat, videoShowing: Bool) -> some View {
        let local = player.current?.isLocal == true
        return VStack(spacing: 14) {
            if videoShowing, let track = player.current {
                // The cover stays by the song over a video: the album's, when this is a
                // song switched to its video.
                HStack(spacing: 16) {
                    ArtworkView(url: (player.currentSong ?? track).thumbnail, size: 64, cornerRadius: 6)
                        .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title).font(.system(size: 30, weight: .heavy)).lineLimit(1)
                        Text(track.artistLine).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            TVScrubber(focused: tv.focus == .seek)
            ZStack {
                HStack(spacing: 8) {
                    if !local {
                        // YouTube Music's thumbs: 👎 skips the song and plays less like it.
                        TVControlButton(control: .dislike, systemImage: player.likeStatus == .dislike ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                                        active: player.likeStatus == .dislike, label: String(localized: "Dislike"))
                            // The glyph, not its round hit area, lines up with the edge.
                            .padding(.leading, -12)
                        TVControlButton(control: .like, systemImage: player.likeStatus == .like ? "hand.thumbsup.fill" : "hand.thumbsup",
                                        active: player.likeStatus == .like, label: String(localized: "Like"))
                    }
                    Spacer()
                    TVControlButton(control: .lyrics, systemImage: "music.mic", active: tv.showsLyrics, label: String(localized: "Lyrics (L)"))
                    TVControlButton(control: .rail, systemImage: "rectangle.stack", active: tv.showsRail, label: String(localized: "Up next (Q)"))
                    PlaybackOptionsMenu(openSignal: tv.menuSignals[.options] ?? 0).tvFocus(.control(.options))
                    TVSpeakerMenu(openSignal: tv.menuSignals[.speaker] ?? 0).tvFocus(.control(.speaker))
                    VolumeSlider()
                        .padding(.horizontal, 4)
                        .tvFocus(.control(.volume), capsule: true)
                        .frame(width: 140)
                        .padding(.leading, 4)
                }
                HStack(spacing: 26) {
                    TVControlButton(control: .shuffle, systemImage: player.smartShuffle ? "shuffle.circle.fill" : "shuffle",
                                    active: player.shuffle, label: String(localized: "Shuffle"))
                    TVControlButton(control: .previous, systemImage: "backward.end.fill", size: 26, label: String(localized: "Previous"))
                    TVPlayButton(focused: tv.focus == .control(.playPause))
                    TVControlButton(control: .next, systemImage: "forward.end.fill", size: 26, label: String(localized: "Next"))
                    TVControlButton(control: .repeatMode, systemImage: player.repeatMode == .one ? "repeat.1" : "repeat",
                                    active: player.repeatMode != .off, label: String(localized: "Repeat"))
                }
                .disabled(player.current == nil)
                .opacity(player.current == nil ? 0.5 : 1)
            }
        }
        .padding(.horizontal, margin)
        .padding(.top, 10)
        .padding(.bottom, Self.controlsBottom)
        .onHover { tv.pointerOverControls = $0 }
    }
}

// MARK: - Buttons with a TV focus

/// The ring and lift a TV draws around what the remote has highlighted.
private struct TVFocusRing: ViewModifier {
    var focused: Bool
    /// For wide things (the Song/Video switch, the volume): a pill instead of a circle.
    var capsule = false

    func body(content: Content) -> some View {
        content
            .background {
                if focused {
                    if capsule { Capsule().fill(.white.opacity(0.16)).padding(-6) } else { Circle().fill(.white.opacity(0.16)) }
                }
            }
            .overlay {
                if focused {
                    if capsule { Capsule().strokeBorder(.white, lineWidth: 2.5).padding(-6) } else { Circle().strokeBorder(.white, lineWidth: 2.5) }
                }
            }
            .scaleEffect(focused ? (capsule ? 1.04 : 1.12) : 1)
    }
}

extension View {
    /// The remote's highlight on a full screen player item.
    fileprivate func tvFocus(_ focus: TVFocus, capsule: Bool = false) -> some View {
        modifier(TVFocusRing(focused: TVPlayerState.shared.focus == focus, capsule: capsule))
    }
}

private struct TVControlButton: View {
    var control: TVControl
    var systemImage: String
    var size: CGFloat = 20
    var active = false
    var label: String
    @State private var hovering = false

    var body: some View {
        let focused = TVPlayerState.shared.focus == .control(control)
        Button { TVPlayerState.shared.perform(control) } label: {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(active ? Theme.accent : hovering || focused ? .white : .white.opacity(0.75))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size + 24, height: size + 24)
                .contentShape(Circle())
                .modifier(TVFocusRing(focused: focused))
        }
        .buttonStyle(PressScaleStyle())
        .onHover { hovering = $0 }
        .tooltip(label)
        .accessibilityLabel(label)
    }
}

private struct TVPlayButton: View {
    var focused: Bool
    private var player: PlayerController { .shared }
    private static let diameter: CGFloat = 76

    var body: some View {
        Button { TVPlayerState.shared.perform(.playPause) } label: {
            ZStack {
                Circle().fill(.white)
                if player.isBuffering && player.current != nil {
                    ProgressView().controlSize(.regular).colorScheme(.light)
                } else {
                    PlayPauseGlyph(isPlaying: player.isPlaying, diameter: Self.diameter)
                        .foregroundStyle(.black)
                }
            }
            .frame(width: Self.diameter, height: Self.diameter)
            .padding(5)
            .overlay { if focused { Circle().strokeBorder(.white, lineWidth: 3) } }
            .scaleEffect(focused ? 1.08 : 1)
        }
        .buttonStyle(PressScaleStyle())
        .help("Play/Pause (Space)")
        .accessibilityLabel(player.isPlaying ? String(localized: "Pause") : String(localized: "Play"))
    }
}

/// Where the music plays: this Mac's outputs, without leaving full screen for the devices panel.
private struct TVSpeakerMenu: View {
    var openSignal = 0
    private var player: PlayerController { .shared }

    var body: some View {
        let elsewhere = player.outputDeviceUID != nil || player.isAirPlaying
        MenuButton(alignment: .trailing, entries: { ConnectMenu.entries() }) { highlighted in
            Image(systemName: elsewhere ? "hifispeaker.fill" : "hifispeaker")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(elsewhere ? Theme.accent : highlighted ? .white : .white.opacity(0.75))
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .opening(on: openSignal)
        .tooltip(String(localized: "Connect to a device"))
        .accessibilityLabel("Connect to a device")
    }
}

// MARK: - Scrubber

/// The TV apps' progress bar: elapsed and total on either side, white on a faint track. It thickens
/// and shows a knob under the pointer (or the remote's highlight); drag or click to seek.
private struct TVScrubber: View {
    var focused: Bool
    @State private var dragValue: Double?
    @State private var hoverX: CGFloat?
    /// The total, or (clicked) the time left — shared with the player bar.
    @AppStorage("showsRemainingTime") private var remaining = false
    private var player: PlayerController { .shared }

    var body: some View {
        let known = player.duration > 0
        let duration = max(player.duration, 1)
        let value = dragValue ?? (known ? min(player.currentTime, duration) : player.currentTime)
        let active = (hoverX != nil || dragValue != nil || focused) && known
        HStack(spacing: 18) {
            // Flush with the title above and the buttons below; the total flush right.
            Text(Format.time(value))
                .frame(minWidth: 56, alignment: .leading)
            GeometryReader { geo in
                let fraction = known ? CGFloat(value / duration) : 0
                let thickness: CGFloat = active ? 8 : 5
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22))
                    Capsule().fill(.white)
                        .frame(width: max(thickness, geo.size.width * fraction))
                    if active {
                        Circle().fill(.white)
                            .frame(width: focused ? 22 : 18, height: focused ? 22 : 18)
                            .overlay { if focused { Circle().strokeBorder(.white.opacity(0.4), lineWidth: 6).scaleEffect(1.6) } }
                            .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
                            .offset(x: min(max(0, geo.size.width * fraction - 9), geo.size.width - 18))
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(height: thickness)
                .frame(maxHeight: .infinity)
                .animation(.spring(duration: 0.2), value: active)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in dragValue = Double(min(max(0, g.location.x / geo.size.width), 1)) * duration }
                    .onEnded { _ in
                        if let dragValue { player.seek(to: dragValue) }
                        dragValue = nil
                    })
                .onContinuousHover { phase in
                    if case .active(let location) = phase { hoverX = location.x } else { hoverX = nil }
                }
                .overlay(alignment: .topLeading) {
                    if known, let x = dragValue.map({ CGFloat($0 / duration) * geo.size.width }) ?? hoverX {
                        let fraction = min(max(0, x / geo.size.width), 1)
                        Text(Format.time(Double(fraction) * player.duration))
                            .font(.system(size: 14, weight: .semibold).monospacedDigit())
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(.black.opacity(0.6)))
                            .fixedSize()
                            .position(x: min(max(fraction * geo.size.width, 28), geo.size.width - 28), y: -14)
                            .allowsHitTesting(false)
                    }
                }
            }
            .frame(height: 24)
            Text(remaining && known ? "-" + Format.time(max(0, player.duration - value)) : Format.time(known ? player.duration : nil))
                .frame(minWidth: 56, alignment: .trailing)
                .contentShape(Rectangle())
                .onTapGesture { remaining.toggle() }
                .help(remaining ? String(localized: "Show the length") : String(localized: "Show the time left"))
        }
        .font(.system(size: 16, weight: .semibold).monospacedDigit())
        .foregroundStyle(.white.opacity(0.85))
        .disabled(player.current == nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Format.time(player.currentTime)) of \(Format.time(player.duration))")
        .accessibilityAdjustableAction { direction in
            player.skip(by: direction == .increment ? 10 : -10)
        }
    }
}

// MARK: - Key feedback

/// YouTube's on-screen answer to a key: « 10 seconds on the side you seeked to, the volume at the
/// top, ▶ / ❚❚ in the middle. Each is always there and only fades in and out: inserted and removed
/// with every press, quick presses left copies sliding out behind new ones.
private struct TVFlashView: View {
    var flash: TVFlash?
    private var tv: TVPlayerState { .shared }

    var body: some View {
        ZStack {
            seek
            volume
            center
        }
        .accessibilityHidden(true)
    }

    private var seek: some View {
        let seconds = tv.lastSeek
        let visible = if case .seek = flash { true } else { false }
        return VStack(spacing: 8) {
            Image(systemName: seconds < 0 ? "backward.fill" : "forward.fill")
                .font(.system(size: 34, weight: .bold))
            Text("\(abs(seconds)) seconds")
                .font(.system(size: 16, weight: .bold).monospacedDigit())
        }
        .frame(width: 150, height: 150)
        .background(Circle().fill(.black.opacity(0.5)))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: seconds < 0 ? .leading : .trailing)
        .padding(.horizontal, 120)
        .fading(visible)
    }

    private var volume: some View {
        let level = tv.lastVolume
        let visible = if case .volume = flash { true } else { false }
        return HStack(spacing: 14) {
            Image(systemName: level == 0 ? "speaker.slash.fill" : level < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.3.fill")
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 28)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(.white)
                    .frame(width: max(6, 200 * level))
                    .opacity(level > 0 ? 1 : 0)
            }
            .frame(width: 200, height: 6)
            Text("\(Int((level * 100).rounded()))")
                .font(.system(size: 17, weight: .bold).monospacedDigit())
                .frame(width: 36, alignment: .trailing)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(Capsule().fill(.black.opacity(0.6)))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 110)
        .fading(visible)
    }

    private var center: some View {
        let visible = switch flash {
        case .play, .skip: true
        default: false
        }
        return Image(systemName: tv.centerSymbol)
            .font(.system(size: 44, weight: .bold))
            .frame(width: 120, height: 120)
            .background(Circle().fill(.black.opacity(0.5)))
            .fading(visible)
    }
}

extension View {
    /// Fades only the opacity: what's inside changes at once.
    fileprivate func fading(_ visible: Bool) -> some View {
        animation(.easeOut(duration: visible ? 0.12 : 0.3)) { $0.opacity(visible ? 1 : 0) }
    }
}

// MARK: - Up next, near the end of a song

/// In a song's last seconds, the next one shows in the corner with a way to go to it now
/// (YouTube on a TV).
private struct TVUpNextSoon: View {
    @State private var dismissedFor: String?
    private var player: PlayerController { .shared }

    var body: some View {
        let remaining = player.duration - player.currentTime
        if let current = player.current, let next = player.upNext.first, player.duration > 45,
           remaining > 0.5, remaining <= 15, player.repeatMode != .one, dismissedFor != current.videoId {
            HStack(spacing: 14) {
                ArtworkView(url: next.track.thumbnail, size: 64, cornerRadius: 6)
                VStack(alignment: .leading, spacing: 3) {
                    Text("UP NEXT · \(Int(remaining.rounded(.up)))s")
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                        .tracking(1)
                        .foregroundStyle(.white.opacity(0.65))
                    Text(next.track.title)
                        .font(.system(size: 16, weight: .bold))
                        .lineLimit(1)
                    Text(next.track.artistLine)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
                .frame(maxWidth: 220, alignment: .leading)
                Button { player.next() } label: {
                    Text("Play now")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(.white))
                }
                .buttonStyle(PressScaleStyle())
                Button { withAnimation(.easeOut(duration: 0.2)) { dismissedFor = current.videoId } } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black.opacity(0.6)))
            .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
            .transition(.move(edge: .trailing).combined(with: .opacity))
            .onHover { TVPlayerState.shared.pointerOverControls = $0 }
        }
    }
}

// MARK: - Rail

/// YouTube Music's rail on a TV: tabs for what's next and what's like this, as big covers.
private struct TVRail: View {
    var margin: CGFloat
    private var player: PlayerController { .shared }
    private var tv: TVPlayerState { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ForEach(TVRailTab.allCases, id: \.self) { tab in
                    tabButton(tab)
                }
                if tv.railTab == .upNext, let context = player.playingContext?.title {
                    Text("from \(context)")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .padding(.leading, 6)
                }
            }
            .padding(.horizontal, margin - 14)
            // Full width whatever it holds: a spinner or a short message would otherwise shrink the
            // rail and center it, tabs and all.
            content
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: 210, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 24)
        .onHover { tv.pointerOverControls = $0 }
        .task(id: tv.railTab == .related ? player.current?.videoId : nil) {
            if tv.railTab == .related { await tv.loadRelated() }
        }
    }

    private func tabButton(_ tab: TVRailTab) -> some View {
        let selected = tv.railTab == tab
        let focused = tv.focus == .tab(tab)
        return Button { withAnimation(.easeOut(duration: 0.2)) { tv.railTab = tab } } label: {
            Text(tab.title)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(focused ? .black : selected ? .white : .white.opacity(0.55))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background {
                    if focused { Capsule().fill(.white) } else if selected { Capsule().fill(.white.opacity(0.14)) }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var content: some View {
        switch tv.railTab {
        case .upNext:
            let cards = tv.upNextCards
            if cards.isEmpty {
                message(String(localized: "Nothing up next. Turn on autoplay in the queue to keep the music going."))
            } else {
                cardRow(cards.map(\.track)) { index in
                    let entry = cards[index]
                    return [.action(String(localized: "Play Now"), systemImage: "play.fill") { player.jump(to: entry) },
                            .action(String(localized: "Remove from Queue"), systemImage: "minus.circle") { player.remove(entry) },
                            .divider] + TrackMenuEntries.make(for: entry.track)
                }
            }
        case .related:
            if tv.relatedFor == player.current?.videoId, tv.relatedFor != nil {
                if tv.related.isEmpty {
                    message(String(localized: "Nothing related to this one yet."))
                } else {
                    cardRow(tv.related) { index in
                        [.action(String(localized: "Play Now"), systemImage: "play.fill") { player.playRadio(from: tv.related[index]) },
                         .divider] + TrackMenuEntries.make(for: tv.related[index])
                    }
                }
            } else if tv.relatedFailed {
                message(String(localized: "Couldn't load related music"))
            } else {
                ProgressView().controlSize(.large).padding(.horizontal, margin).padding(.top, 50)
            }
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15))
            .foregroundStyle(.white.opacity(0.65))
            .padding(.horizontal, margin)
            .padding(.top, 8)
    }

    private func cardRow(_ tracks: [Track], menu: @escaping (Int) -> [MenuEntry]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 20) {
                    ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                        TVCard(track: track, focused: tv.focus == .card(index), menu: { menu(index) }) { tv.playCard(index) }
                            .id(index)
                    }
                }
                .padding(.horizontal, margin)
                .padding(.vertical, 12)
            }
            .scrollClipDisabled()
            .onChange(of: tv.focus) { _, focus in
                if case .card(let index) = focus {
                    withAnimation(.spring(duration: 0.35)) { proxy.scrollTo(index, anchor: .center) }
                }
            }
        }
    }
}

/// A song in the rail. Hovered or highlighted, it lifts and gets a ring: a TV's focus.
private struct TVCard: View {
    var track: Track
    var focused: Bool
    var menu: () -> [MenuEntry]
    var action: () -> Void
    @State private var hovering = false
    private static let side: CGFloat = 140

    var body: some View {
        let lifted = hovering || focused
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ArtworkView(url: track.thumbnail, size: Self.side, cornerRadius: 8)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(.white, lineWidth: lifted ? 3 : 0)
                    }
                    .shadow(color: .black.opacity(lifted ? 0.5 : 0.25), radius: lifted ? 16 : 6, y: lifted ? 8 : 3)
                Text(track.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(track.artistLine)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }
            .frame(width: Self.side)
            .scaleEffect(lifted ? 1.06 : 1, anchor: .bottom)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(duration: 0.25, bounce: 0.2), value: lifted)
        .menuOnRightClick(hovering: hovering, menu)
        .accessibilityLabel("\(track.title), \(track.artistLine)")
    }
}

// MARK: - Backdrop and clock

/// The cover, blurred and stretched over the whole screen: blurred once per song on a small copy,
/// then just scaled, so it costs nothing while the music plays.
private struct TVBackdrop: View {
    var url: URL?
    var tint: Color
    @State private var image: NSImage?

    private nonisolated static let context = CIContext(options: [.cacheIntermediates: false])

    var body: some View {
        // Clear sets the size: the filled image would otherwise grow the backdrop past the screen
        // and push the controls off it.
        Color.clear
            .background(tint.headerTint().mix(with: .black, by: 0.5))
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .id(image)
                        .transition(.opacity)
                }
            }
            .overlay {
                // Darker toward the bottom, where the controls are.
                LinearGradient(stops: [.init(color: .black.opacity(0.35), location: 0),
                                       .init(color: .black.opacity(0.2), location: 0.4),
                                       .init(color: .black.opacity(0.8), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .clipped()
            .allowsHitTesting(false)
            .task(id: url) {
                let blurred = await Self.blurred(url)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.9)) { image = blurred }
            }
    }

    private static func blurred(_ url: URL?) async -> NSImage? {
        guard let source = Artwork.url(url, size: 120), let art = await ImageLoader.shared.image(for: source),
              let cg = art.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return await Task.detached(priority: .utility) { blur(cg) }.value
    }

    private nonisolated static func blur(_ cg: CGImage) -> NSImage? {
        let input = CIImage(cgImage: cg)
        let output = input.clampedToExtent()
            .applyingGaussianBlur(sigma: Double(cg.width) / 12)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.35, kCIInputBrightnessKey: -0.08])
            .cropped(to: input.extent)
        guard let result = context.createCGImage(output, from: input.extent) else { return nil }
        return NSImage(cgImage: result, size: NSSize(width: result.width, height: result.height))
    }
}

/// The time, top right, like a TV app.
private struct TVClock: View {
    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(context.date, format: .dateTime.hour().minute())
                .font(.system(size: 18, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}

// MARK: - Lyrics

/// Lyrics beside the cover, the sung line lit.
private struct TVLyrics: View {
    var fontSize: CGFloat
    private var player: PlayerController { .shared }
    private var tv: TVPlayerState { .shared }

    var body: some View {
        Group {
            if tv.lyricsFor == nil || tv.lyricsFor != player.current?.videoId {
                ProgressView().controlSize(.large)
            } else if let lyrics = tv.lyrics, lyrics.isSynced {
                TVSyncedLyrics(lyrics: lyrics, fontSize: fontSize)
            } else if let plain = tv.lyrics?.plain {
                ScrollView {
                    Text(plain)
                        .font(.system(size: fontSize * 0.62, weight: .bold))
                        .lineSpacing(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 60)
                }
                .scrollIndicators(.never)
                .mask(TVLyricsFade())
            } else {
                Text("Looks like we don't have the lyrics for this song.")
                    .font(.system(size: fontSize * 0.6, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// Reads the playback time and passes on only the line being sung, so the lines redraw once
/// per line rather than on every time update.
private struct TVSyncedLyrics: View {
    var lyrics: Lyrics
    var fontSize: CGFloat
    private var player: PlayerController { .shared }

    var body: some View {
        TVLyricLines(lines: lyrics.lines, active: lyrics.lineIndex(at: player.currentTime + 0.25), fontSize: fontSize)
            .equatable()
    }
}

private struct TVLyricLines: View, Equatable {
    var lines: [LyricLine]
    var active: Int?
    var fontSize: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func == (a: Self, b: Self) -> Bool {
        a.active == b.active && a.fontSize == b.fontSize && a.lines == b.lines
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: fontSize * 0.5) {
                    ForEach(lines) { line in
                        let isActive = line.id == active
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.system(size: fontSize, weight: .heavy))
                            .tracking(-0.5)
                            .foregroundStyle(.white.opacity(isActive ? 1 : line.id < (active ?? -1) ? 0.5 : 0.35))
                            .scaleEffect(isActive ? 1 : 0.96, anchor: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { PlayerController.shared.seek(to: line.time) }
                            .id(line.id)
                            .animation(.easeOut(duration: 0.3), value: isActive)
                            .accessibilityAddTraits(isActive ? .isSelected : [])
                    }
                }
                .padding(.vertical, 200)
            }
            .scrollIndicators(.never)
            .mask(TVLyricsFade())
            .onChange(of: active) { _, line in
                guard let line else { return }
                withAnimation(reduceMotion ? nil : .spring(duration: 0.7)) { proxy.scrollTo(line, anchor: UnitPoint(x: 0, y: 0.4)) }
            }
            .onAppear {
                if let active { proxy.scrollTo(active, anchor: UnitPoint(x: 0, y: 0.4)) }
            }
        }
    }
}

/// Lyrics fade out at the top and bottom edges.
private struct TVLyricsFade: View {
    var body: some View {
        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18),
                               .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                       startPoint: .top, endPoint: .bottom)
    }
}

/// Over a music video, lyrics as captions: the sung line, and the next one fainter below.
private struct TVLyricsCaption: View {
    private var player: PlayerController { .shared }
    private var tv: TVPlayerState { .shared }

    var body: some View {
        if tv.lyricsFor == player.current?.videoId, let lyrics = tv.lyrics {
            if lyrics.isSynced {
                TVCaptionLines(lines: lyrics.lines, active: lyrics.lineIndex(at: player.currentTime + 0.25))
                    .equatable()
            } else {
                Text("These lyrics aren't synced, so they can't follow the video.")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(.black.opacity(0.55)))
            }
        }
    }
}

private struct TVCaptionLines: View, Equatable {
    var lines: [LyricLine]
    var active: Int?

    var body: some View {
        let current = active.flatMap { lines.indices.contains($0) ? lines[$0].text : nil } ?? ""
        let next = (active.map { $0 + 1 } ?? 0)
        VStack(spacing: 6) {
            if !current.isEmpty {
                Text(current)
                    .font(.system(size: 38, weight: .heavy))
                    .id(active)
                    .transition(.opacity.combined(with: .offset(y: 12)))
            }
            if lines.indices.contains(next), !lines[next].text.isEmpty {
                Text(lines[next].text)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                    .id(next)
                    .transition(.opacity)
            }
        }
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .shadow(color: .black.opacity(0.8), radius: 10)
        .shadow(color: .black.opacity(0.6), radius: 2)
        .animation(.easeOut(duration: 0.3), value: active)
    }
}
