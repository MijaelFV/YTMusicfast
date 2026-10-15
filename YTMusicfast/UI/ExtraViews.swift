import AVFoundation
import AVKit
import SwiftUI

// MARK: - Local Files

/// The Local Files page: songs from your music folders, played like any other list.
struct LocalFilesView: View {
    @FocusState private var queryFocused: Bool
    private var local: LocalFiles { .shared }
    @State private var query = ""

    private var shown: [Track] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return local.tracks }
        return local.tracks.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed) || $0.artistLine.localizedCaseInsensitiveContains(trimmed)
                || ($0.album?.name.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .bottom, spacing: 24) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(LinearGradient(colors: [Color(red: 0.1, green: 0.55, blue: 0.4), Color(red: 0.05, green: 0.25, blue: 0.3)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 180, height: 180)
                        .overlay(Image(systemName: "folder.fill").font(.system(size: 64)).foregroundStyle(.white))
                        .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Playlist").font(.system(size: 14, weight: .medium))
                        Text("Local Files").font(.system(size: 64, weight: .black)).tracking(-1.5)
                        Text("\(Format.count(local.tracks.count, .song)) from \(Format.count(local.folders.count, .folder)) on this Mac")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.secondary)
                    }
                }
                .padding(.top, 40)
                .padding(.horizontal, Theme.pagePadding)

                HStack(spacing: 16) {
                    PlayCircleButton(size: 56, isPlaying: false) { PlayerController.shared.play(local.tracks) }
                        .disabled(local.tracks.isEmpty)
                    IconButton(systemImage: "shuffle", size: 26, label: String(localized: "Shuffle play")) {
                        PlayerController.shared.play(local.tracks, shuffled: true)
                    }
                    Button("Add Folder…", action: LocalFilesView.chooseFolder)
                        .buttonStyle(.bordered)
                    if local.scanning { ProgressView().controlSize(.small) }
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary)
                        TextField("Search Local Files", text: $query).textFieldStyle(.plain).frame(width: 180)
                            .focused($queryFocused)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.text.opacity(0.1)))
                    .endEditingOnOutsideClick(isActive: queryFocused) { queryFocused = false }
                }
                .padding(.horizontal, Theme.pagePadding)

                if local.folders.isEmpty {
                    ContentUnavailableView {
                        Label("No music folders yet", systemImage: "folder.badge.plus")
                    } description: {
                        Text("Add a folder of MP3, AAC, ALAC, FLAC or WAV files to play them here.")
                    } actions: {
                        Button("Add Folder…", action: LocalFilesView.chooseFolder)
                    }
                    .padding(.top, 30)
                } else if local.tracks.isEmpty, !local.scanning {
                    ContentUnavailableView {
                        Label("No songs found", systemImage: "music.note")
                    } description: {
                        Text("These folders have no MP3, AAC, ALAC, FLAC or WAV files. Add another folder, or check the files are on this Mac.")
                    } actions: {
                        Button("Add Folder…", action: LocalFilesView.chooseFolder)
                    }
                    .padding(.top, 30)
                } else if shown.isEmpty, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    ContentUnavailableView.search(text: query.trimmingCharacters(in: .whitespaces))
                        .padding(.top, 30)
                } else {
                    TrackList(tracks: shown, showHeader: true)
                        .padding(.horizontal, Theme.pagePadding - 12)
                }
            }
            .padding(.bottom, 32)
        }
        .environment(\.playContext, LocalFiles.target)
        .task { if !local.folders.isEmpty, local.tracks.isEmpty { await local.rescan() } }
    }

    static func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add Folder")
        panel.message = String(localized: "Choose folders with music to play in YT Musicfast")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { LocalFiles.shared.add(folder: url) }
    }
}

// MARK: - Song credits

/// YouTube Music's "Song credits": who performed, wrote and produced the song.
struct CreditsSheet: View {
    let track: Track
    @State private var credits: [CreditRole]?
    @State private var failed = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ArtworkView(url: track.thumbnail, size: 56, cornerRadius: 6)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Song credits").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondary)
                    Text(track.title).font(.system(size: 18, weight: .bold)).lineLimit(2)
                    Text(track.artistLine).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                IconButton(systemImage: "xmark", size: 14, label: String(localized: "Close")) { dismiss() }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let credits, !credits.isEmpty {
                        ForEach(credits, id: \.role) { credit in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(credit.role).font(.system(size: 15, weight: .bold))
                                ForEach(credit.names, id: \.self) { name in
                                    Text(name).font(.system(size: 14)).foregroundStyle(Theme.secondary).textSelection(.enabled)
                                }
                            }
                        }
                    } else if credits != nil || failed {
                        Text(failed ? String(localized: "Couldn't load the credits.") : String(localized: "YouTube Music has no credits for this song."))
                            .foregroundStyle(Theme.secondary)
                    } else {
                        SkeletonRows(count: 4, artwork: false)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
        .frame(width: 440, height: 480)
        .background(Theme.elevated)
        .task {
            do { credits = try await MusicAPI.credits(videoId: track.videoId) } catch { failed = true }
        }
    }
}

// MARK: - Keyboard shortcuts

/// ⌘/ — every shortcut in one place.
struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let groups: [(String, [(String, String)])] = [
        (String(localized: "Playback"), [
            (String(localized: "Play / pause"), String(localized: "Space")), (String(localized: "Next"), "⌘→"), (String(localized: "Previous"), "⌘←"), (String(localized: "Forward 10 seconds"), "⌥⌘→"),
            (String(localized: "Back 10 seconds"), "⌥⌘←"), (String(localized: "Volume up / down"), "⌘↑ / ⌘↓"), (String(localized: "Shuffle"), "⌘S"), (String(localized: "Repeat"), "⌘R"),
            (String(localized: "Start radio from current song"), "⇧⌘R"), (String(localized: "Equalizer"), "⌥⌘E"),
            (String(localized: "Mute"), "M"), (String(localized: "Shuffle / repeat"), "S / R"),
        ]),
        (String(localized: "Your music"), [
            (String(localized: "Like"), "⌘L / B"), (String(localized: "Dislike"), "⇧⌘D"), (String(localized: "Add current song to a playlist"), "⇧⌘P"),
            (String(localized: "Liked Music"), "⇧⌘L"), (String(localized: "Playing artist / album"), "⇧⌘A / ⇧⌘B"),
            (String(localized: "New playlist"), "⌘N"), (String(localized: "Undo (while a toast shows)"), "⌘Z"),
        ]),
        (String(localized: "Navigation"), [
            (String(localized: "Search"), "⌘F / ⌘K / /"), (String(localized: "Search filters (on Search)"), "⌘1–⌘9 / ⌃Tab"), (String(localized: "Home"), "⇧⌘H"), (String(localized: "Back / forward"), "⌘[ / ⌘]"), (String(localized: "Lyrics"), "⌥⌘L / L"),
            (String(localized: "Queue"), "⌥⌘U / Q"), (String(localized: "Now Playing view"), "⌥⌘N"), (String(localized: "Collapse Your Library"), "⌥⌘B"),
            (String(localized: "Player page"), "⌥⌘P"), (String(localized: "Full-screen player"), "⇧⌘F / F"), (String(localized: "Keyboard shortcuts"), "⌘/ / ?"), (String(localized: "Settings"), "⌘,"),
        ]),
        (String(localized: "Full-screen player"), [
            (String(localized: "Seek 10 seconds (controls hidden)"), "← / →"), (String(localized: "Volume (controls hidden)"), "↑ / ↓"),
            (String(localized: "Move the highlight (controls showing)"), "← → ↑ ↓"), (String(localized: "Press the highlighted button"), String(localized: "Return")),
            (String(localized: "Lyrics / Up next"), "L / Q"), (String(localized: "Keep the controls showing"), "P"), (String(localized: "Close the rail, then leave"), String(localized: "Esc")),
        ]),
        (String(localized: "Lists"), [
            (String(localized: "Play a song"), String(localized: "Double-click")), (String(localized: "Select several songs"), "⌘-click / ⇧-click"),
            (String(localized: "Move the selection"), "↑ / ↓ (⇧ to extend)"), (String(localized: "Play the selected song"), String(localized: "Return")),
            (String(localized: "Clear the selection"), String(localized: "Esc")), (String(localized: "Reorder your playlist"), String(localized: "Drag a song")),
            (String(localized: "Add songs to a playlist"), String(localized: "Drag onto it in Your Library")),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Keyboard shortcuts").font(.system(size: 22, weight: .bold))
                Spacer()
                IconButton(systemImage: "xmark", size: 14, label: String(localized: "Close")) { dismiss() }
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 32, alignment: .top), GridItem(.flexible(), alignment: .top)],
                          alignment: .leading, spacing: 24) {
                    ForEach(groups, id: \.0) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.0).font(.system(size: 15, weight: .bold))
                            ForEach(group.1, id: \.0) { item in
                                HStack {
                                    Text(item.0).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                                    Spacer(minLength: 12)
                                    Text(item.1)
                                        .font(.system(size: 12, weight: .semibold).monospaced())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.text.opacity(0.1)))
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 720, height: 560)
        .background(Theme.elevated)
    }
}

// MARK: - Connect to a device

/// The device list, for this Mac's outputs: speakers, headphones, AirPlay.
/// The player bar's Connect button: opens the Connect panel on the right. Lit while the
/// music plays somewhere other than the Mac's default output.
struct DevicePicker: View {
    @Environment(Router.self) private var router
    @State private var hovering = false
    private var player: PlayerController { .shared }

    /// Lit while the music isn't (only) on this Mac's default output: another device, AirPlay,
    /// or a listening session.
    private var elsewhere: Bool {
        player.outputDeviceUID != nil || player.isAirPlaying || CastController.shared.device != nil || ListenTogether.shared.role != .off
    }
    private var open: Bool { router.rightPanel == .devices }

    var body: some View {
        Button {
            withAnimation(.spring(duration: 0.3)) { router.togglePanel(.devices) }
        } label: {
            Image(systemName: elsewhere ? "hifispeaker.2.fill" : "hifispeaker.2")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(elsewhere || open ? Theme.accent : hovering ? Theme.text : Theme.secondary)
                .frame(width: 31, height: 31)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .tooltip(String(localized: "Connect to a device"))
        .accessibilityLabel("Connect to a device")
    }
}

// MARK: - Video

/// Shows the music video (muted; the audio comes from the player) while it's on screen.
struct VideoSurface: NSViewRepresentable {
    /// Fill the view when that trims only a sliver (a 16:9 video on a 16:10 screen), like a TV's
    /// fill mode; a video much narrower or wider keeps its bars.
    var fills = false
    /// Changes once the picture is ready, so the fill can follow the video's real shape.
    var ready = false

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = VideoController.shared.player
        view.fills = fills
        return view
    }

    func updateNSView(_ nsView: PlayerLayerView, context: Context) {
        nsView.fills = fills
        nsView.updateGravity()
    }

    final class PlayerLayerView: NSView {
        let playerLayer = AVPlayerLayer()
        var fills = false

        /// Up to this much of the picture may be trimmed to fill the view.
        private static let maxTrim: CGFloat = 0.15

        func updateGravity() {
            var gravity = AVLayerVideoGravity.resizeAspect
            if fills, let size = playerLayer.player?.currentItem?.presentationSize, size.width > 0, size.height > 0,
               bounds.width > 0, bounds.height > 0 {
                let video = size.width / size.height, view = bounds.width / bounds.height
                if 1 - min(video, view) / max(video, view) <= Self.maxTrim { gravity = .resizeAspectFill }
            }
            if playerLayer.videoGravity != gravity { playerLayer.videoGravity = gravity }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            playerLayer.videoGravity = .resizeAspect
            playerLayer.backgroundColor = NSColor.black.cgColor
            layer = playerLayer
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        // Tells the video player how big it's shown, so it picks a matching size of the video.
        override func layout() {
            super.layout()
            updateGravity()
            reportSize()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reportSize()
        }

        private func reportSize() {
            let scale = window?.backingScaleFactor ?? 2
            let pixels = window == nil ? .zero : CGSize(width: bounds.width * scale, height: bounds.height * scale)
            VideoController.shared.surface(self, isShownAt: pixels)
        }
    }
}

/// Artwork, or the music video when video mode is on and the song has one.
struct NowPlayingVisual: View {
    var track: Track
    var size: CGFloat
    var cornerRadius: CGFloat = 8
    /// The full screen player: the picture spans the screen, and fills it when that option is on
    /// (Video quality menu → Fill screen; see `VideoSurface.fills`).
    var fullScreen = false
    private var video: VideoController { .shared }

    var body: some View {
        Group {
            if video.videoMode, track.isVideo, !track.isLocal {
                if fullScreen {
                    picture.clipped()
                } else {
                    // A steady 16:9 frame: the cover waits inside it until the picture is ready and
                    // lined up with the music, then the picture fades in over it (no jump, no flash).
                    picture
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .frame(maxWidth: size)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                }
            } else {
                ArtworkView(url: track.thumbnail, size: size, cornerRadius: cornerRadius, resizable: true)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: video.hasVideo)
        .onAppear { video.surfaceAppeared() }
        .onDisappear { video.surfaceDisappeared() }
    }

    private var picture: some View {
        ZStack {
            Color.black
            ArtworkView(url: track.thumbnail, size: size, cornerRadius: 0, resizable: true)
            // There from the start, invisible until ready: with nowhere to draw, AVFoundation
            // switches the picture off and lining it up with the music never finishes.
            VideoSurface(fills: fullScreen && video.fillsScreen, ready: video.hasVideo)
                .opacity(video.hasVideo ? 1 : 0)
            if !video.hasVideo, video.loading {
                ProgressView().controlSize(.regular)
            }
        }
    }
}

/// YouTube Music's Song / Video switch.
struct SongVideoToggle: View {
    @Namespace private var pill
    private var player: PlayerController { .shared }
    private var video: VideoController { .shared }

    var body: some View {
        if let track = player.current, !track.isLocal {
            // New songs follow the switch (see PlayerController.followVersionMode), so it shows the
            // mode — also for a song with no video, which stays on its cover.
            let actual = video.videoMode
            // Where it's going while the other version loads: the switch moves at once.
            let showingVideo = player.versionTarget ?? actual
            HStack(spacing: 0) {
                segment(String(localized: "Song"), selected: !showingVideo) { Self.select(video: false) }
                segment(String(localized: "Video"), selected: showingVideo) { Self.select(video: true) }
            }
            .padding(3)
            .background(Capsule().fill(Theme.text.opacity(0.1)))
            .overlay(alignment: .trailing) {
                if player.versionTarget != nil {
                    ProgressView().controlSize(.small).offset(x: 28).transition(.opacity)
                }
            }
            .animation(.spring(duration: 0.3, bounce: 0.15), value: showingVideo)
            .animation(.easeOut(duration: 0.2), value: player.versionTarget != nil)
            // Find the video ahead of a click, so switching doesn't wait for a search.
            .task(id: track.videoId) { VersionLookup.prefetch(track) }
        }
    }

    /// Song or Video for the playing song (the switch's buttons, or Return in the full screen player).
    @MainActor static func select(video wantsVideo: Bool) {
        let player = PlayerController.shared, video = VideoController.shared
        guard let track = player.current, !track.isLocal, wantsVideo != (player.versionTarget ?? video.videoMode) else { return }
        if wantsVideo {
            if player.versionTarget == false { player.cancelVersionSwitch() }
            video.videoMode = true
            if !track.isVideo { player.switchVersion(toVideo: true) }
        } else {
            video.videoMode = false
            if player.versionTarget == true { player.cancelVersionSwitch() }
            if track.isVideo { player.switchVersion(toVideo: false) }
        }
    }

    /// The other one of Song and Video.
    @MainActor static func flip() {
        select(video: !(PlayerController.shared.versionTarget ?? VideoController.shared.videoMode))
    }

    private func segment(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(selected ? Theme.onContrast : Theme.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background {
                    if selected { Capsule().fill(Theme.contrast).matchedGeometryEffect(id: "pill", in: pill) }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
