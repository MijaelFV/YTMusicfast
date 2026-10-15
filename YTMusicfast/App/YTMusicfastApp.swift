import AppKit
import os
import ServiceManagement
import SwiftUI
import WebKit

private let appLog = Logger(subsystem: "dev.ytmusicfast", category: "App")

@main
struct YTMusicfastApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let router = Router.shared
    private let auth = AuthManager.shared

    var body: some Scene {
        Window("YT Musicfast", id: "main") {
            ContentView()
                .environment(router)
                .environment(auth)
                .frame(minWidth: 760, minHeight: 600)
                // Dark by default; light or the system's in Settings.
                .appAppearance()
                .task { await auth.restore() }
        }
        .defaultSize(width: 1400, height: 880)
        .windowStyle(.hiddenTitleBar)
        .commands { PlaybackCommands(router: router) }

        Window("Miniplayer", id: "miniplayer") {
            MiniplayerWindow()
                .environment(auth)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 330, height: 320)
        .defaultPosition(.bottomTrailing)

        Settings {
            SettingsView()
                .appAppearance()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?

    /// Height of the custom top bar. An invisible toolbar item this tall makes the native title bar
    /// grow to match, so macOS itself centres the window buttons on the same row as search.
    static let topBarHeight: CGFloat = 64

    func applicationDidFinishLaunching(_ notification: Notification) {
        perfLog.notice("launched")
        Bench.installSlowLogger()
        PhoneRemote.shared.startIfEnabled()
        _ = Updater.shared  // starts Sparkle's daily update check
        if !Bench.enabled {
            GlobalHotkeys.shared.start()
            StatusBarController.shared.start()
            NotchPlayer.shared.start()
            CommandServer.start()
            ContextMenus.install()
        }
        // Decode artwork for the screen the window is on (see ImageLoader.targetColorSpace).
        Self.updateImageColorSpace()
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Self.updateImageColorSpace() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { Self.handleKey(event) }
        }
    }

    /// Space toggles playback unless you're typing; ⌘-arrows edit text in a text field instead of
    /// skipping tracks or changing the volume (the menu would otherwise take them first).
    @MainActor private static func handleKey(_ event: NSEvent) -> NSEvent? {
        // An open menu takes the keys (arrows, Return, Esc, letters).
        if ShortcutRecorder.isRecording || MenuPresenter.shared.isOpen { return event }
        let window = NSApp.keyWindow
        let responder = window?.firstResponder
        let typing = responder is NSText || isInsideWebView(responder)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let arrows: Set<UInt16> = [123, 124, 125, 126]
        if typing, arrows.contains(event.keyCode), flags.contains(.command), let responder {
            responder.keyDown(with: event)
            return nil
        }
        // Delete / forward-delete removes selected songs from your playlist or history.
        if [51, 117].contains(event.keyCode), flags.subtracting([.numericPad, .function]).isEmpty, !typing,
           window?.sheetParent == nil, window?.attachedSheet == nil, SelectionDelete.handler?() == true {
            return nil
        }
        // ⌘A / ⌘C / ⌘X / ⌘V on songs (when no text field has focus).
        let clipboardKeys: [UInt16: Character] = [0: "a", 8: "c", 7: "x", 9: "v"]
        if let key = clipboardKeys[event.keyCode], flags == .command, !typing,
           ["YT Musicfast", "Miniplayer"].contains(window?.title ?? ""),
           window?.sheetParent == nil, window?.attachedSheet == nil, handleClipboard(key) {
            return nil
        }
        // The full screen player works like a TV remote: arrows, Return, Space and Esc (see
        // TVPlayerState.handleKey); ⌘← ⌘→ still skip songs.
        if Router.shared.showFullPlayer, !typing, window?.sheetParent == nil, window?.attachedSheet == nil {
            let tv = TVPlayerState.shared
            if flags.subtracting([.numericPad, .function]).isEmpty {
                if tv.handleKey(event.keyCode) { return nil }
                if event.keyCode == 53 {
                    withAnimation(.easeInOut(duration: 0.3)) { Router.shared.showFullPlayer = false }
                    return nil
                }
            } else {
                tv.wake()
            }
        }
        // Esc leaves the player page or lyrics, back to where you were.
        if event.keyCode == 53, flags.subtracting([.numericPad, .function]).isEmpty, !typing,
           window?.title == "YT Musicfast", window?.sheetParent == nil, window?.attachedSheet == nil,
           [.nowPlaying, .lyrics].contains(Router.shared.route) {
            let router = Router.shared
            if router.canGoBack { router.goBack() } else { router.navigate(.home) }
            return nil
        }
        // ⌘K searches too (⌘F is the menu's shortcut; a second menu item would show "Search" twice).
        if event.keyCode == 40, flags == .command, window?.attachedSheet == nil, window?.sheetParent == nil {
            Router.shared.focusSearch()
            return nil
        }
        // ↑ / ↓ / Return move through and play the selected songs (⇧ extends the selection).
        let navigation: [UInt16: SelectionKeys.Key] = [126: .up, 125: .down, 36: .play, 76: .play]
        if let key = navigation[event.keyCode], !typing, window?.sheetParent == nil, window?.attachedSheet == nil,
           flags.subtracting([.numericPad, .function, .shift]).isEmpty, !(key == .play && flags.contains(.shift)),
           SelectionKeys.handler?(key, flags.contains(.shift)) == true {
            return nil
        }
        // The menu key (on PC keyboards), or ⇧F10: the selected song's menu.
        if event.keyCode == 110 || (event.keyCode == 109 && flags.contains(.shift)), !typing,
           window?.sheetParent == nil, window?.attachedSheet == nil, !MenuPresenter.shared.isOpen,
           flags.subtracting([.numericPad, .function, .shift]).isEmpty, SelectionKeys.handler?(.menu, false) == true {
            return nil
        }
        // One-key shortcuts (M, B, S, R, Q, L, F, /, ?) while no text field has focus.
        if !typing, window?.sheetParent == nil, window?.attachedSheet == nil,
           ["YT Musicfast", "Miniplayer", FullPlayerWindow.title].contains(window?.title ?? ""),
           flags.subtracting([.numericPad, .function, .shift]).isEmpty,
           let key = event.charactersIgnoringModifiers, handleLetter(key) {
            return nil
        }
        // Not in sheets (sign-in, dialogs) or while typing.
        guard event.keyCode == 49, flags.subtracting([.numericPad, .function]).isEmpty, !typing,
              window?.sheetParent == nil, window?.attachedSheet == nil else { return event }
        PlayerController.shared.togglePlayPause()
        return nil
    }

    @MainActor private static func handleClipboard(_ key: Character) -> Bool {
        switch key {
        case "a": return ListClipboard.perform(.selectAll)
        case "c": return ListClipboard.perform(.copy)
        case "x": return ListClipboard.perform(.cut)
        case "v":
            let ids = ListClipboard.songIds()
            if ListClipboard.perform(.paste(ids)) { return true }
            // Not into a playlist: a YouTube Music link opens it (a song plays).
            if let text = NSPasteboard.general.string(forType: .string), let link = MusicLink(text) {
                link.open()
                return true
            }
            return false
        default: return false
        }
    }

    @MainActor private static func handleLetter(_ key: String) -> Bool {
        let player = PlayerController.shared
        let router = Router.shared
        switch key {
        case "m", "M": player.toggleMute()
        case "b", "B":
            guard let track = player.current, !track.isLocal else { return false }
            player.toggleLike()
        case "s", "S": player.toggleShuffle()
        case "r", "R": player.cycleRepeat()
        case "q", "Q": withAnimation(.spring(duration: 0.3)) { router.togglePanel(.queue) }
        case "l", "L": router.toggleLyrics()
        case "f", "F": withAnimation(.easeInOut(duration: 0.3)) { router.showFullPlayer.toggle() }
        case "/": router.focusSearch()
        case "?": router.showShortcuts = true
        default: return false
        }
        return true
    }

    @MainActor private static func isInsideWebView(_ responder: NSResponder?) -> Bool {
        var view = responder as? NSView
        while let current = view {
            if current is WKWebView { return true }
            view = current.superview
        }
        return false
    }

    /// `ytmusicfast://` links (and YouTube Music links handed over by the command-line tool).
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls {
                guard let link = MusicLink(url.absoluteString) else { continue }
                if case .song = link {} else { StatusBarController.showMainWindow() }
                link.open()
            }
        }
    }

    /// Right-clicking the Dock icon: transport controls, like other music apps.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        MainActor.assumeIsolated {
            let player = PlayerController.shared
            let menu = NSMenu()
            if let track = player.current {
                let info = NSMenuItem(title: "\(track.title) — \(track.artistLine)", action: nil, keyEquivalent: "")
                info.isEnabled = false
                menu.addItem(info)
                menu.addItem(.separator())
            }
            menu.addItem(DockMenuItem(player.isPlaying ? String(localized: "Pause") : String(localized: "Play")) { player.togglePlayPause() })
            menu.addItem(DockMenuItem(String(localized: "Next")) { player.next() })
            menu.addItem(DockMenuItem(String(localized: "Previous")) { player.previous() })
            if player.current != nil {
                menu.addItem(.separator())
                menu.addItem(DockMenuItem(player.likeStatus == .like ? String(localized: "Remove like") : String(localized: "Like")) { player.toggleLike() })
                menu.addItem(DockMenuItem(String(localized: "Start Radio")) { if let track = player.current { player.playRadio(from: track) } })
            }
            menu.addItem(.separator())
            menu.addItem(DockMenuItem(player.shuffle ? String(localized: "Shuffle: On") : String(localized: "Shuffle: Off")) { player.toggleShuffle() })
            return menu
        }
    }

    @MainActor private static func updateImageColorSpace() {
        let window = NSApp.windows.first { $0.isVisible && $0.title == "YT Musicfast" }
        ImageLoader.targetColorSpace = (window?.screen ?? NSScreen.main)?.colorSpace?.cgColorSpace
    }

        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

private final class DockMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { MainActor.assumeIsolated { handler() } }
}

/// Supplies one invisible, fixed-height toolbar item whose only job is to set the title bar height.
final class TitleBarSizer: NSObject, NSToolbarDelegate {
    private static let identifier = NSToolbarItem.Identifier("titleBarHeight")
    private static let shared = TitleBarSizer()

    /// Gives the window a title bar as tall as our top bar, with the window buttons centred in it.
    @MainActor
    static func configure(_ window: NSWindow) {
        guard window.toolbar?.identifier != "YTMusicfastTitleBar" else { return }
        let toolbar = NSToolbar(identifier: "YTMusicfastTitleBar")
        toolbar.delegate = shared
        toolbar.showsBaselineSeparator = false
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        let titleBar = window.frame.height - window.contentLayoutRect.maxY
        appLog.notice("title bar height \(titleBar, privacy: .public)")
        TrafficLights.watch(window)
        WindowState.shared.watchFullScreen(window)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.identifier] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.identifier] }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        let spacer = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: AppDelegate.topBarHeight - 12))
        spacer.widthAnchor.constraint(equalToConstant: 1).isActive = true
        spacer.heightAnchor.constraint(equalToConstant: AppDelegate.topBarHeight - 12).isActive = true
        item.view = spacer
        item.isBordered = false
        item.visibilityPriority = .high
        return item
    }
}

/// Whether the main window is in full screen. There the window buttons are hidden and the sizing
/// toolbar must go: macOS would otherwise reserve a strip for it above the content and slide it
/// over the top bar whenever the pointer reaches the top of the screen. (The full screen player
/// doesn't use this: it has a window of its own, see `FullPlayerWindow`.)
@MainActor
@Observable
final class WindowState {
    static let shared = WindowState()
    private(set) var isFullScreen = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    func watchFullScreen(_ window: NSWindow) {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        func on(_ name: Notification.Name, _ action: @escaping @MainActor (WindowState, NSWindow) -> Void) -> NSObjectProtocol {
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let window = note.object as? NSWindow else { return }
                    action(self, window)
                }
            }
        }
        // The title bar changes only once an animation has finished: macOS animates full screen
        // from snapshots of the window, and changing it meanwhile can strand the animation.
        observers = [
            on(NSWindow.willEnterFullScreenNotification) { state, _ in state.isFullScreen = true },
            on(NSWindow.didEnterFullScreenNotification) { _, window in window.toolbar?.isVisible = false },
            on(NSWindow.willExitFullScreenNotification) { state, _ in state.isFullScreen = false },
            on(NSWindow.didExitFullScreenNotification) { _, window in
                // Even "did exit" comes a moment before macOS has put the window back on its
                // Space; bringing the title bar back right then stranded it on the full screen
                // Space with the animation's snapshot left on the desktop.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak window] in
                    guard let window, !window.styleMask.contains(.fullScreen) else { return }
                    window.toolbar?.isVisible = true
                    // Lay the taller title bar out now, so the buttons are centred on its final
                    // size rather than the one it had a moment ago.
                    window.contentView?.superview?.layoutSubtreeIfNeeded()
                    TrafficLights.align(window)
                    DispatchQueue.main.async { TrafficLights.align(window) }
                    Self.refreshCorners(window)
                }
            },
        ]
        isFullScreen = window.styleMask.contains(.fullScreen)
        if isFullScreen { window.toolbar?.isVisible = false }
        Self.refreshCorners(window)
    }

    /// The window's outline and shadow are worked out for the title bar it has at that moment. When the
    /// title bar comes back after full screen (or the window first gets it), macOS can keep the old
    /// outline while the content is cut to the new corners — leaving a square corner where whatever is
    /// behind the window shows through. Redrawing the shadow after things settle makes them agree.
    static func refreshCorners(_ window: NSWindow) {
        window.invalidateShadow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak window] in
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            window.invalidateShadow()
            window.contentView?.superview?.needsDisplay = true
        }
    }
}

/// Keeps the window buttons vertically centred on our top bar's row.
/// macOS re-lays them out on resize/fullscreen, so we re-apply whenever their frame changes.
@MainActor
enum TrafficLights {
    /// Distance from the window's top edge to the top bar's centre line, measured by SwiftUI.
    static var centerFromTop: CGFloat = AppDelegate.topBarHeight / 2
    private static var observers: [ObjectIdentifier: [NSObjectProtocol]] = [:]

    static func watch(_ window: NSWindow) {
        guard let close = window.standardWindowButton(.closeButton), observers[ObjectIdentifier(window)] == nil else { return }
        // The buttons, and the strip they sit in: when the title bar comes back after full screen
        // the strip grows while the buttons' own frames stay put, so only the strip says so.
        let views = [close, close.superview].compactMap { $0 }
        observers[ObjectIdentifier(window)] = views.map { view in
            view.postsFrameChangedNotifications = true
            return NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: .main) { [weak window] _ in
                MainActor.assumeIsolated { if let window { align(window) } }
            }
        }
        align(window)
    }

    static func align(_ window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for (index, type) in types.enumerated() {
            guard let button = window.standardWindowButton(type), let container = button.superview else { continue }
            // Titlebar views are not flipped: y is measured from the bottom of the container.
            let containerTopInWindow = container.convert(NSPoint(x: 0, y: container.bounds.height), to: nil).y
            let targetMidY = window.frame.height - centerFromTop - (window.frame.height - containerTopInWindow)
            let y = (container.bounds.height - (window.frame.height - containerTopInWindow) - centerFromTop) - button.frame.height / 2
            _ = targetMidY
            let origin = NSPoint(x: 20 + CGFloat(index) * 20, y: y.rounded())
            if abs(button.frame.origin.y - origin.y) > 0.5 || abs(button.frame.origin.x - origin.x) > 0.5 {
                button.setFrameOrigin(origin)
            }
        }
    }

    static func update(centerFromTop value: CGFloat) {
        guard abs(value - centerFromTop) > 0.5 else { return }
        centerFromTop = value
        for window in NSApp.windows where window.toolbar?.identifier == "YTMusicfastTitleBar" { align(window) }
    }
}

struct PlaybackCommands: Commands {
    let router: Router
    @Environment(\.openSettings) private var openSettings
    private var player: PlayerController { .shared }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { Updater.shared.checkForUpdates() }
                .disabled(!Updater.shared.canCheck)
        }
        CommandGroup(replacing: .newItem) {
            Button("New Playlist") {
                guard AuthManager.shared.isSignedIn else { router.showSignIn = true; return }
                Task { await LibraryActions.createPlaylist(router: router) }
            }
            .keyboardShortcut("n")
            Button("Save Queue as Playlist") {
                guard AuthManager.shared.isSignedIn else { router.showSignIn = true; return }
                Task { await LibraryActions.saveQueue(router: router) }
            }
            .disabled(player.queue.isEmpty)
        }

        CommandGroup(after: .sidebar) {
            Button("Search") { router.focusSearch() }
                .keyboardShortcut("f")
            Button("Home") { router.navigate(.home) }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button(router.rightPanel == .queue ? String(localized: "Hide Queue") : String(localized: "Show Queue")) {
                withAnimation(.spring(duration: 0.3)) { router.togglePanel(.queue) }
            }
            .keyboardShortcut("u", modifiers: [.command, .option])  // ⌥⌘Q is macOS's String(localized: "Quit and Keep Windows")
            Button(router.rightPanel == .nowPlaying ? String(localized: "Hide Now Playing View") : String(localized: "Show Now Playing View")) {
                withAnimation(.spring(duration: 0.3)) { router.togglePanel(.nowPlaying) }
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
            Button(router.libraryCollapsed ? String(localized: "Expand Your Library") : String(localized: "Collapse Your Library")) {
                withAnimation(.spring(duration: 0.3)) { router.libraryCollapsed.toggle() }
            }
            .keyboardShortcut("b", modifiers: [.command, .option])
            Button("Liked Music") { router.open(Router.likedSongs) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            // The song behind a music video playing in its place: a video has no album of its own.
            Button("Go to Playing Artist") {
                if let artist = player.currentSong?.artists.first(where: { $0.browseId != nil }) { router.open(artist: artist) }
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(player.currentSong?.artists.contains { $0.browseId != nil } != true)
            Button("Go to Playing Album") {
                if let album = player.currentSong?.album { router.open(album: album) }
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .disabled(player.currentSong?.album?.browseId == nil)
            Button("Your Stats") { router.navigate(.stats) }
            Button("Lyrics") { router.toggleLyrics() }
                .keyboardShortcut("l", modifiers: [.command, .option])
            Button(router.route == .nowPlaying ? String(localized: "Hide Player Page") : String(localized: "Show Player Page")) {
                router.toggleNowPlayingPage()
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            Button("Full Screen Player") {
                withAnimation(.easeInOut(duration: 0.3)) { router.showFullPlayer.toggle() }
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            Divider()
            Button("Back") { router.goBack() }
                .keyboardShortcut("[")
                .disabled(!router.canGoBack)
            Button("Forward") { router.goForward() }
                .keyboardShortcut("]")
                .disabled(!router.canGoForward)
            Divider()
        }

        CommandMenu("Playback") {
            let nothingPlaying = player.current == nil
            let canLike = player.current.map { !$0.isLocal } ?? false
            Button(player.isPlaying ? String(localized: "Pause") : String(localized: "Play")) { player.togglePlayPause() }
                .disabled(nothingPlaying)
            Button("Next") { player.next() }
                .keyboardShortcut(.rightArrow)
                .disabled(nothingPlaying)
            Button("Previous") { player.previous() }
                .keyboardShortcut(.leftArrow)
                .disabled(nothingPlaying)
            Button("Forward 10 Seconds") { player.skip(by: 10) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(nothingPlaying)
            Button("Back 10 Seconds") { player.skip(by: -10) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(nothingPlaying)
            Divider()
            Button("Volume Up") { player.volume = min(1, player.volume + 0.1) }
                .keyboardShortcut(.upArrow)
            Button("Volume Down") { player.volume = max(0, player.volume - 0.1) }
                .keyboardShortcut(.downArrow)
            Button(player.isMuted ? String(localized: "Unmute (M)") : String(localized: "Mute (M)")) { player.toggleMute() }
            Divider()
            Button("Shuffle") { player.toggleShuffle() }
                .keyboardShortcut("s")
            Button("Repeat") { player.cycleRepeat() }
                .keyboardShortcut("r")
            Button("Start Radio from Current Song") {
                if let track = player.current { player.playRadio(from: track) }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!canLike)
            Divider()
            Button(player.likeStatus == .like ? String(localized: "Remove like") : String(localized: "Like")) { player.toggleLike() }
                .keyboardShortcut("l")
                .disabled(!canLike)
            Button(player.likeStatus == .dislike ? String(localized: "Remove Dislike") : String(localized: "Dislike")) {
                if let track = player.current { player.setDisliked(player.likeStatus != .dislike, track) }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(!canLike)
            Button("Add to Playlist…") {
                guard let track = player.current else { return }
                router.addToPlaylist([track])
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(!canLike)
            Divider()
            Menu("Sleep Timer") {
                ForEach([5, 15, 30, 45, 60, 90], id: \.self) { minutes in
                    Button("\(minutes) Minutes") { player.setSleepTimer(minutes: minutes) }
                }
                Button("End of Song") { player.setSleepTimerEndOfTrack() }
                Divider()
                Button("Off") { player.cancelSleepTimer() }.disabled(player.sleepTimer == .off)
            }
            Picker("Speed", selection: Binding(get: { player.playbackRate }, set: { player.playbackRate = $0 })) {
                ForEach(PlaybackOptionsMenu.speeds, id: \.self) { speed in
                    Text(speed == 1 ? String(localized: "Normal") : "\(speed.formatted())×").tag(speed)
                }
            }
            Divider()
            // Same as the Song/Video switch: also switches the playing song to its other version.
            Toggle("Video Mode", isOn: Binding(get: { VideoController.shared.videoMode }, set: { on in
                if player.current.map({ !$0.isLocal }) ?? false { SongVideoToggle.select(video: on) }
                else { VideoController.shared.videoMode = on }
            }))
            Button(player.smartShuffle ? String(localized: "Turn Off Smart Shuffle") : String(localized: "Smart Shuffle")) {
                if !player.shuffle { player.cycleShuffle() }
                player.cycleShuffle()
            }
            Toggle("Private Session", isOn: Binding(get: { player.privateSession }, set: { player.privateSession = $0 }))
            Toggle("Offline Mode", isOn: Binding(get: { player.offlineMode }, set: { player.offlineMode = $0 }))
            Divider()
            Button("Equalizer…") {
                UserDefaults.standard.set("equalizer", forKey: "settingsTab")
                openSettings()
            }
            .keyboardShortcut("e", modifiers: [.command, .option])
        }

        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { router.showShortcuts = true }
                .keyboardShortcut("/")
            Button("YouTube Music Help") { NSWorkspace.shared.open(URL(string: "https://support.google.com/youtubemusic")!) }
        }
    }
}

struct SettingsView: View {
    /// Opens Settings on a tab (the Equalizer menu item).
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings(openTab: { tab = $0 }).tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            EqualizerSettings().tabItem { Label("Equalizer", systemImage: "slider.vertical.3") }.tag("equalizer")
            FilterSettings().tabItem { Label("Content Filter", systemImage: "line.3.horizontal.decrease.circle") }.tag("filter")
            LibrarySettings().tabItem { Label("Library", systemImage: "books.vertical") }.tag("library")
        }
        .frame(width: 560, height: 660)
    }
}

/// Sparkle's preferences: check daily, and optionally install without asking.
private struct UpdatesSection: View {
    @Bindable private var updater = Updater.shared

    var body: some View {
        Section("Updates") {
            Toggle("Check for updates automatically", isOn: $updater.automaticallyChecks)
            Toggle("Download and install updates automatically", isOn: $updater.automaticallyDownloads)
                .disabled(!updater.automaticallyChecks)
            LabeledContent("Version \(UpdateChecker.shared.currentVersion)") {
                Button("Check Now") { updater.checkForUpdates() }
                    .disabled(!updater.canCheck)
            }
        }
    }
}

/// Song-change banners, with a note when macOS has them turned off.
private struct NotificationToggle: View {
    @Bindable private var notifications = SongNotifications.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Show a notification when the song changes", isOn: $notifications.enabled)
            if notifications.enabled, notifications.denied {
                HStack(spacing: 4) {
                    Text("Notifications are off for YT Musicfast in System Settings.")
                    Button("Open Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    }
                    .buttonStyle(.link)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

private struct GeneralSettings: View {
    /// Switches Settings to another tab (a search result there).
    var openTab: (String) -> Void
    @Bindable private var player = PlayerController.shared
    @Bindable private var video = VideoController.shared
    @Bindable private var eq = Equalizer.shared
    @AppStorage("audioQuality") private var audioQuality = "high"
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.dark
    @AppStorage(VisualizerMode.key) private var visualizer = VisualizerMode.off
    @AppStorage(VisualizerMode.fpsKey) private var visualizerFPS = 30
    @AppStorage(NotchPlayer.key) private var notchPlayer = false
    @State private var query = ""
    @State private var cacheSize = 0
    @AppStorage("replayCacheGB") private var replayCacheGB = 2.0
    @State private var pagesSize = 0
    @State private var downloadsSize = 0
    @State private var confirmRemoveDownloads = false
    @State private var confirmClearStats = false
    @AppStorage(StatusBarController.showIconKey) private var showMenuBarIcon = true
    @AppStorage(StatusBarController.showTitleKey) private var showMenuBarTitle = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                Section {
                    TextField("Search settings", text: $query, prompt: Text("Search settings"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    sections
                } else {
                    SettingsSearchResults(query: query) { entry in
                        query = ""
                        if entry.tab == "general" {
                            Task {
                                try? await Task.sleep(for: .milliseconds(50))
                                withAnimation { proxy.scrollTo(entry.section, anchor: .top) }
                            }
                        } else {
                            openTab(entry.tab)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .onAppear(perform: refreshSizes)
        .confirmationDialog("Remove all downloads?", isPresented: $confirmRemoveDownloads) {
            Button("Remove All", role: .destructive) {
                DownloadManager.shared.removeAll()
                refreshSizes()
            }
        } message: {
            Text("Downloaded albums and playlists will need the internet again.")
        }
        .confirmationDialog("Clear your listening stats?", isPresented: $confirmClearStats) {
            Button("Clear Stats", role: .destructive) { ListeningStats.shared.clear() }
        } message: {
            Text("Your top songs, artists and minutes start again from zero. Your YouTube Music history isn't affected.")
        }
    }

    @ViewBuilder
    private var sections: some View {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                }
                Picker("Player bar visualizer", selection: $visualizer) {
                    ForEach(VisualizerMode.allCases) { Text($0.title).tag($0) }
                }
                if visualizer != .off {
                    Text("⌥-click the player bar to switch between them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Visualizer frame rate", selection: $visualizerFPS) {
                        Text("30 fps (saves energy)").tag(30)
                        Text("60 fps").tag(60)
                    }
                }
                if NotchPlayer.hasNotch {
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("Show what's playing around the notch", isOn: $notchPlayer)
                        Text("While YT Musicfast is in the background. Hover it for controls.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .id("appearance")
            Section("Playback") {
                Toggle("Normalize volume", isOn: $player.normalizeVolume)
                Toggle("Autoplay similar songs when the queue ends", isOn: $player.autoplay)
                LabeledContent("Crossfade") {
                    HStack {
                        Slider(value: $player.crossfadeSeconds, in: 0...12, step: 1)
                            .frame(width: 180)
                        Text(player.crossfadeSeconds == 0 ? String(localized: "Off (gapless)") : "\(Int(player.crossfadeSeconds)) s")
                            .monospacedDigit()
                            .frame(width: 90, alignment: .leading)
                    }
                }
                Picker("Speed", selection: $player.playbackRate) {
                    ForEach(PlaybackOptionsMenu.speeds, id: \.self) { speed in
                        Text(speed == 1 ? String(localized: "Normal") : "\(speed.formatted())×").tag(speed)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Picker("Streaming quality", selection: $audioQuality) {
                        Text("High (Opus 160 kbps, 256 kbps with Premium)").tag("high")
                        Text("Data saver (48 kbps)").tag("low")
                    }
                    Text("Data saver turns on by itself in macOS Low Data Mode. On a slow connection songs stream as they download, so they start sooner.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Show music videos (video mode)", isOn: $video.videoMode)
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Skip non-music parts of music videos", isOn: $player.skipNonMusic)
                    Text("Intros, skits and outros marked by the SponsorBlock community.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                NotificationToggle()
                LabeledContent("Balance") {
                    HStack(spacing: 8) {
                        Text("L").font(.caption).foregroundStyle(.secondary)
                        Slider(value: Binding(get: { eq.balance }, set: { eq.balance = abs($0) < 0.04 ? 0 : $0 }), in: -1...1)
                            .frame(width: 180)
                        Text("R").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle("Mono audio", isOn: $eq.mono)
            }
            .id("playback")
            Section("Menu bar") {
                Toggle("Show YT Musicfast in the menu bar", isOn: $showMenuBarIcon)
                Toggle("Show the song's name next to the icon", isOn: $showMenuBarTitle)
                    .disabled(!showMenuBarIcon)
            }
            .id("menubar")
            Section {
                ForEach(GlobalHotkeys.Action.allCases) { action in
                    LabeledContent(action.title) { ShortcutRecorder(action: action) }
                }
            } header: {
                Text("Global shortcuts")
            } footer: {
                Text("These work even when another app is in front. Media keys always work.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .id("shortcuts")
            PhoneRemoteSection()
                .id("remote")
            CommandLineSection()
                .id("cli")
            Section("Privacy") {
                Toggle("Add songs I play to my YouTube Music history", isOn: $player.syncHistory)
                Toggle("Private session (don't remember what I play)", isOn: $player.privateSession)
                Toggle("Offline Mode (only play downloaded music)", isOn: $player.offlineMode)
                LabeledContent("Listening stats") {
                    HStack {
                        Text("\(Format.count(ListeningStats.shared.plays.count, .play)) on this Mac").foregroundStyle(.secondary)
                        Button("Clear…") { confirmClearStats = true }
                            .disabled(ListeningStats.shared.plays.isEmpty)
                    }
                }
            }
            .id("privacy")
            Section("Startup") {
                Toggle("Open YT Musicfast when I log in", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
            .id("startup")
            Section("Storage") {
                LabeledContent("Replay cache") {
                    HStack {
                        Text(Format.bytes(cacheSize)).foregroundStyle(.secondary)
                        Button("Clear") { AudioCache.clear(); refreshSizes() }
                        Button("Show in Finder") { NSWorkspace.shared.open(AudioCache.directory) }
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Picker("Replay cache size", selection: $replayCacheGB) {
                        Text("500 MB").tag(0.5)
                        Text("1 GB").tag(1.0)
                        Text("2 GB").tag(2.0)
                        Text("5 GB").tag(5.0)
                        Text("10 GB").tag(10.0)
                    }
                    .onChange(of: replayCacheGB) { _, _ in
                        DispatchQueue.global(qos: .utility).async {
                            AudioCache.trim(pruningMetadata: false)
                            DispatchQueue.main.async { refreshSizes() }
                        }
                    }
                    Text("Songs you've played stay on this Mac so replays start instantly and use no data. It never takes more than a quarter of your free disk space.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Saved pages") {
                    HStack {
                        Text(Format.bytes(pagesSize)).foregroundStyle(.secondary)
                        Button("Clear") {
                            DiskCache.clear()
                            Task {
                                try? await Task.sleep(for: .milliseconds(300))
                                refreshSizes()
                            }
                        }
                    }
                }
                LabeledContent("Downloads") {
                    HStack {
                        Text("\(Format.count(DownloadManager.shared.collections.count, .item)) · \(Format.bytes(downloadsSize))").foregroundStyle(.secondary)
                        Button("Remove All…") { confirmRemoveDownloads = true }
                            .disabled(DownloadManager.shared.collections.isEmpty)
                    }
                }
            }
            .id("storage")
            UpdatesSection()
                .id("updates")
            Section("About") {
                LabeledContent("Version", value: UpdateChecker.shared.currentVersion)
                Text("YT Musicfast is an independent open-source project and isn't affiliated with or endorsed by Google or YouTube. It uses YouTube Music's private web API, which can change at any time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
    }

    private func refreshSizes() {
        cacheSize = AudioCache.totalBytes
        pagesSize = DiskCache.totalBytes
        downloadsSize = DownloadManager.shared.totalBytes
    }
}

/// "Control from your phone": the address, a QR code and the PIN.
private struct PhoneRemoteSection: View {
    @Bindable private var remote = PhoneRemote.shared

    var body: some View {
        Section {
            Toggle("Control YT Musicfast from your phone", isOn: $remote.enabled)
            if remote.enabled {
                if let address = remote.address {
                    HStack(alignment: .top, spacing: 16) {
                        if let qr = remote.qrCode() {
                            Image(nsImage: qr).interpolation(.none).resizable().frame(width: 120, height: 120)
                                .background(Color.white).clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Scan with your phone's camera, or open:").font(.caption).foregroundStyle(.secondary)
                            Text(address).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Text("PIN: \(remote.pin)").font(.headline.monospacedDigit())
                            Button("New PIN") { remote.newCode() }.controlSize(.small)
                            if let error = remote.lastError { Text(error).font(.caption).foregroundStyle(.red) }
                        }
                    }
                } else {
                    Text("Connect this Mac to Wi‑Fi to use the remote.").font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Phone remote")
        } footer: {
            Text("Your phone must be on the same Wi‑Fi. Only people with the PIN can control playback.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The equalizer: presets and ten sliders.
private struct EqualizerSettings: View {
    @Bindable private var eq = Equalizer.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Toggle("Equalizer", isOn: $eq.enabled).toggleStyle(.switch).font(.headline)
                Spacer()
                Picker("Preset", selection: Binding(get: { eq.presetName }, set: { eq.apply(preset: $0) })) {
                    ForEach(Equalizer.presets, id: \.name) { Text($0.name).tag($0.name) }
                    if eq.presetName == "Custom" { Text("Custom").tag("Custom") }
                }
                .frame(width: 220)
                .disabled(!eq.enabled)
            }
            HStack(alignment: .bottom, spacing: 0) {
                VStack {
                    Text("+12 dB"); Spacer(); Text("0 dB"); Spacer(); Text("−12 dB")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(height: 220)
                .padding(.bottom, 22)
                ForEach(Equalizer.frequencies.indices, id: \.self) { index in
                    VStack(spacing: 6) {
                        Slider(value: Binding(get: { eq.gains[index] }, set: { eq.gains[index] = ($0 * 2).rounded() / 2 }),
                               in: Equalizer.range)
                            .frame(width: 220)
                            .rotationEffect(.degrees(-90))
                            .frame(width: 40, height: 220)
                        Text(Self.label(Equalizer.frequencies[index]))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .disabled(!eq.enabled)
            .opacity(eq.enabled ? 1 : 0.45)
            HStack {
                Text("Applies to everything you play, including downloads and local files — except recordings longer than about 25 minutes (podcasts, long mixes) and songs streamed over a slow connection, which macOS plays in a way that can't be equalized.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset") { eq.apply(preset: String(localized: "Flat")) }.disabled(!eq.enabled)
            }
            Spacer()
        }
        .padding(24)
    }

    private static func label(_ frequency: Double) -> String {
        frequency >= 1000 ? "\(Int(frequency / 1000))k" : "\(Int(frequency))"
    }
}

/// What never plays: AI-generated music, explicit songs, and what you've hidden.
private struct FilterSettings: View {
    @Bindable private var filter = ContentFilter.shared
    @State private var refreshing = false
    @State private var refreshFailed = false

    var body: some View {
        Form {
            Section {
                Toggle("Hide AI-generated music", isOn: $filter.hideAI)
                Toggle("Check YouTube's “altered or synthetic content” label before songs play", isOn: $filter.checkYouTubeLabels)
                    .disabled(!filter.hideAI)
                Toggle("Hide explicit songs", isOn: $filter.hideExplicit)
                Toggle("Hide songs that can't be played", isOn: $filter.hideUnavailable)
            } footer: {
                Text("Hidden songs disappear from search, Home and radio, and are skipped in the queue. On album and playlist pages they stay, dimmed. With AI hiding off, AI songs show an “AI” badge instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Shared AI artist list") {
                TextField("List URL", text: $filter.communityListURL, prompt: Text("https://… (one artist or channel id per line)"))
                HStack {
                    if let updated = filter.communityUpdated, !filter.communityAI.isEmpty {
                        Text("\(Format.count(filter.communityAI.count, .artist)) · updated \(updated.formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if refreshFailed {
                        Text("Couldn't load that list").font(.caption).foregroundStyle(.red)
                    }
                    Spacer()
                    if refreshing { ProgressView().controlSize(.small) }
                    Button("Update Now") {
                        refreshing = true
                        Task {
                            refreshFailed = !(await filter.refreshCommunityList(force: true)) && !filter.communityListURL.isEmpty
                            refreshing = false
                        }
                    }
                }
            }
            entries(String(localized: "AI artists you marked"), filter.aiArtists) { filter.unmarkAI(songId: nil, artistId: $0.id) }
            entries(String(localized: "Songs you marked as AI"), filter.aiSongs) { filter.unmarkAI(songId: $0.id, artistId: nil) }
            entries(String(localized: "Artists you don't want to hear"), filter.hiddenArtists) { filter.unhide(artistId: $0.id) }
            entries(String(localized: "Hidden songs"), filter.hiddenSongs) { filter.unhide(songId: $0.id) }
            if !filter.unavailable.isEmpty {
                Section {
                    LabeledContent("\(Format.count(filter.unavailable.count, .song)) couldn't be played") {
                        Button("Try Them Again") { filter.clearUnavailable() }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func entries(_ title: String, _ list: [ContentFilter.Entry], remove: @escaping (ContentFilter.Entry) -> Void) -> some View {
        if !list.isEmpty {
            Section(title) {
                ForEach(list) { entry in
                    HStack {
                        Text(entry.name).lineLimit(1)
                        Spacer()
                        Button("Remove") { remove(entry) }.buttonStyle(.borderless)
                    }
                }
            }
        }
    }
}

/// Local Files folders.
private struct LibrarySettings: View {
    private var local: LocalFiles { .shared }

    var body: some View {
        Form {
            Section {
                ForEach(local.folders, id: \.self) { folder in
                    HStack {
                        Image(systemName: "folder")
                        Text(folder).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Remove") { local.remove(folder: folder) }.buttonStyle(.borderless)
                    }
                }
                HStack {
                    Button("Add Folder…", action: LocalFilesView.chooseFolder)
                    if !local.folders.isEmpty {
                        Button("Rescan") { Task { await local.rescan() } }.disabled(local.scanning)
                    }
                    Spacer()
                    if local.scanning { ProgressView().controlSize(.small) }
                    Text(Format.count(local.tracks.count, .song)).foregroundStyle(.secondary)
                }
            } header: {
                Text("Local Files")
            } footer: {
                Text("Music in these folders shows up as “Local Files” in Your Library and plays alongside YouTube Music.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
