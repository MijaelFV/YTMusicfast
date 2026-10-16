import AppKit
import AVFoundation
import Foundation
import Network
import Observation

struct QueueEntry: Identifiable, Hashable {
    /// Kept when the song is switched to its video (or back): it's still the same play.
    var id = UUID()
    var track: Track
    /// Added by Smart Shuffle, not by you.
    var isRecommendation = false
    /// After "Switch to video": the song version, to switch back to.
    var songVersion: Track?
    /// After a music video was switched to its song: the video, to switch back to.
    var videoVersion: Track?
}

enum RepeatMode: String, CaseIterable {
    case off, all, one
}

/// Pause playback after a while (YouTube Music's sleep timer).
enum SleepTimer: Equatable {
    case off
    case at(Date)
    case endOfTrack
}

/// Owns playback: the queue, AVQueuePlayer, prefetching of the next track and radio/autoplay.
@MainActor
@Observable
final class PlayerController {
    static let shared = PlayerController()

    private(set) var queue: [QueueEntry] = []
    private(set) var currentIndex: Int?
    private(set) var isPlaying = false {
        didSet { if oldValue, !isPlaying { WatchTime.shared.paused() } }
    }
    private(set) var isBuffering = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var shuffle = false
    /// Smart Shuffle: shuffle plus recommended songs mixed in.
    private(set) var smartShuffle = false
    private(set) var errorMessage: String?

    var volume: Double = UserDefaults.standard.object(forKey: "volume") as? Double ?? 0.8 {
        didSet {
            UserDefaults.standard.set(volume, forKey: "volume")
            // Turning the volume up is also "unmute".
            if isMuted, volume > oldValue { isMuted = false }
            smoothUserLevel()
            sendCastVolume()
        }
    }

    /// Mute (M, the speaker button) keeps the volume to come back to.
    var isMuted = false {
        didSet {
            smoothUserLevel()
            sendCastVolume()
        }
    }

    func toggleMute() { isMuted.toggle() }

    var repeatMode: RepeatMode = .off {
        didSet {
            player.actionAtItemEnd = repeatMode == .one ? .none : .advance
            resyncUpcoming()
        }
    }

    var normalizeVolume = UserDefaults.standard.object(forKey: "normalizeVolume") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(normalizeVolume, forKey: "normalizeVolume")
            applyVolume()
        }
    }

    /// Keep playing similar music once the queue runs out.
    var autoplay = UserDefaults.standard.object(forKey: "autoplay") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoplay, forKey: "autoplay") }
    }

    /// Seconds of overlap between songs; 0 keeps strict gapless playback.
    var crossfadeSeconds = UserDefaults.standard.object(forKey: "crossfade") as? Double ?? 0 {
        didSet { UserDefaults.standard.set(crossfadeSeconds, forKey: "crossfade") }
    }

    /// Playback speed (0.5–2×), pitch-corrected.
    var playbackRate = UserDefaults.standard.object(forKey: "playbackRate") as? Double ?? 1 {
        didSet {
            UserDefaults.standard.set(playbackRate, forKey: "playbackRate")
            applyRate()
        }
    }

    /// Add songs you play to your YouTube Music history (signed in).
    var syncHistory = UserDefaults.standard.object(forKey: "syncHistory") as? Bool ?? true {
        didSet { UserDefaults.standard.set(syncHistory, forKey: "syncHistory") }
    }

    /// Private session: nothing you play is remembered, here or on YouTube.
    var privateSession = false

    /// Skip the non-music parts of music videos (intros, skits, outros) using SponsorBlock.
    var skipNonMusic = UserDefaults.standard.bool(forKey: "skipNonMusic") {
        didSet {
            UserDefaults.standard.set(skipNonMusic, forKey: "skipNonMusic")
            loadSkipSegments()
        }
    }

    /// Offline Mode: only downloaded, cached and local songs play; nothing is streamed.
    var offlineMode = UserDefaults.standard.bool(forKey: "offlineMode") {
        didSet {
            UserDefaults.standard.set(offlineMode, forKey: "offlineMode")
            Router.shared.showToast(offlineMode ? String(localized: "Offline Mode on — only downloaded music plays") : String(localized: "Offline Mode off"),
                                    icon: offlineMode ? "icloud.slash.fill" : "icloud.fill")
            if offlineMode, let index = currentIndex {
                queue = Array(queue[...index]) + queue.dropFirst(index + 1).filter { Self.availableOffline($0.track) }
                resyncUpcoming()
            }
        }
    }

    /// Plays without the internet: downloaded, in the replay cache, or a local file.
    static func availableOffline(_ track: Track) -> Bool {
        track.isLocal || AudioCache.isAvailable(track.videoId)
    }

    /// Tuning chips for the radio that's playing ("Popular", "Discover", "Deep cuts"…), and the one picked.
    private(set) var radioTuners: [RadioTuner] = []
    private(set) var selectedTuner: String?
    private(set) var tuning = false

    private(set) var sleepTimer: SleepTimer = .off {
        didSet {
            // A new or cancelled timer undoes any fade-out in progress.
            guard sleepFadeLevel != 1 else { return }
            sleepFadeLevel = 1
            applyVolume()
        }
    }

    private(set) var likeStatus: LikeStatus = .indifferent

    var current: Track? { currentIndex.flatMap { queue.indices.contains($0) ? queue[$0].track : nil } }
    /// The song behind what's playing: the song itself, also while its music video plays in its
    /// place (Song/Video switch). What's shown about it stays the same either way (YouTube Music).
    var currentSong: Track? {
        currentIndex.flatMap { queue.indices.contains($0) ? (queue[$0].songVersion ?? queue[$0].track) : nil }
    }
    var upNext: ArraySlice<QueueEntry> { currentIndex.map { queue.dropFirst($0 + 1) } ?? [] }
    /// Songs of the queue already played (YouTube Music keeps them in the queue, above the one playing).
    var played: ArraySlice<QueueEntry> { currentIndex.map { queue.prefix($0) } ?? [] }

    @ObservationIgnored private var player = PlayerController.makeDeck()
    /// The outgoing player while a crossfade is running.
    @ObservationIgnored private var fadingDeck: AVQueuePlayer?
    @ObservationIgnored private var fadeTimer: Timer?
    @ObservationIgnored private var fadeLevel = 1.0
    /// The sleep timer's fade-out over its last seconds.
    @ObservationIgnored private var sleepFadeLevel = 1.0
    /// Volume and mute as heard: follows them over 30 ms, so dragging the slider never clicks.
    @ObservationIgnored private var userLevel = 0.0
    /// The ~50 ms fade around play, pause and skips, so audio never starts or stops
    /// mid-waveform with a click.
    @ObservationIgnored private var transportLevel = 1.0
    /// Running level ramps, by level. Each timer lives only for the few milliseconds of its ramp.
    @ObservationIgnored private var ramps: [PartialKeyPath<PlayerController>: Timer] = [:]
    /// What to do once the fade before a pause or skip ends.
    @ObservationIgnored private var afterFadeOut: (() -> Void)?
    /// `afterFadeOut` is a pause (not a skip).
    @ObservationIgnored private var fadingOutToPause = false
    @ObservationIgnored private let resolver = ChainedStreamResolver.shared
    @ObservationIgnored private var sources: [String: ChunkedAudioSource] = [:]
    @ObservationIgnored private var itemEntries: [ObjectIdentifier: UUID] = [:]
    @ObservationIgnored private var unshuffledOrder: [UUID]?
    @ObservationIgnored private var radioContinuation: String?
    /// The continuation loads more of the playlist being played, not autoplay radio.
    @ObservationIgnored private var continuationIsContext = false
    /// Bumped whenever a new queue starts or upcoming songs are cleared: radio and playlist batches
    /// fetched for an older queue are dropped instead of landing on the new one.
    @ObservationIgnored private var generation = 0
    /// The queue generation a radio/continuation fetch is running for.
    @ObservationIgnored private var extendingFor: Int?
    /// Next was pressed at the end while more songs were on their way: advance once they land.
    @ObservationIgnored private var advanceWhenExtended = false
    /// Bumped by every play request; a slow one (collection or playlist fetch) loses to a newer one.
    @ObservationIgnored private var latestRequest = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// The queue entry whose sound is loading, until it starts (or stays paused). Meanwhile play
    /// and pause only decide whether it starts once ready: the load carries on either way.
    @ObservationIgnored private var loadingEntry: UUID?
    /// The song loading starts paused once ready (pause pressed while it loads).
    @ObservationIgnored private var loadStartsPaused = false
    /// When the last song change began, to tell a burst of skips from a single one.
    @ObservationIgnored private var lastStart = Date.distantPast
    /// When the song now loading was asked for, until its sound starts (logged for timing).
    @ObservationIgnored private var soundAsked: (videoId: String, at: Date)?
    @ObservationIgnored private var soundObserver: Any?
    @ObservationIgnored private var enqueueTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSKeyValueObservation] = []
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private lazy var nowPlaying = NowPlayingCenter(player: self)
    @ObservationIgnored private var pendingSeek: TimeInterval?
    /// Seeks still in flight. Until they land, the player keeps reporting the old position,
    /// which would snap the progress bar back for a moment.
    @ObservationIgnored private var seeksInFlight = 0
    @ObservationIgnored private var lastSave = Date.distantPast
    /// Queue entries already reported to YouTube's history (once per play).
    /// Each song's playback-stats address from its stream, in case the player request for it fails.
    @ObservationIgnored private(set) var statsURLs: [String: URL] = [:]
    /// Last clock position, to measure how much of a song is actually heard.
    @ObservationIgnored private var lastTickPosition: TimeInterval?
    /// SponsorBlock non-music segments for the current song, and the ones already skipped.
    @ObservationIgnored private var skipSegments: [SponsorBlock.Segment] = []
    @ObservationIgnored private var skippedSegments: Set<SponsorBlock.Segment> = []

    private init() {
        userLevel = volume * volume
        applyVolume()
        attach(player)
        NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.itemDidFinish(note.object as? AVPlayerItem) }
        }
        NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                // Only the song that's playing: the next song's download or the muted music
                // video failing must not skip what you're listening to.
                guard let self, let item = note.object as? AVPlayerItem, let entryId = self.itemEntries[ObjectIdentifier(item)],
                      let index = self.currentIndex, self.queue.indices.contains(index), self.queue[index].id == entryId else { return }
                self.handleFailure(note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error ?? InnerTubeError.noAudio)
            }
        }
        // A benchmark copy must not take the media keys or touch the saved queue.
        guard !Bench.enabled else { return }
        _ = nowPlaying
        AudioCache.removeStalePartials()
        AudioCache.trim()
        watchOutputDevice()
        restoreSession()
        // Work the first song would otherwise wait for, done just after launch instead (the same
        // requests, earlier — nothing extra).
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(2))
            await ChainedStreamResolver.shared.warmUp()
            try? await Task.sleep(for: .seconds(8))
            await PremiumAudio.shared.prepareInBackground()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.saveSession()
                PlayTracker.shared.finish()
                WatchTime.shared.finish()
            }
        }
    }

    // MARK: Decks

    private static func makeDeck() -> AVQueuePlayer {
        let deck = AVQueuePlayer()
        deck.automaticallyWaitsToMinimizeStalling = false
        deck.actionAtItemEnd = .advance
        deck.defaultRate = Float(UserDefaults.standard.object(forKey: "playbackRate") as? Double ?? 1)
        deck.audioOutputDeviceUniqueID = UserDefaults.standard.string(forKey: "outputDeviceUID")
        return deck
    }

    // MARK: Output device

    /// Where audio plays (the Connect panel's list of this Mac's outputs). Nil: system default.
    var outputDeviceUID: String? = UserDefaults.standard.string(forKey: "outputDeviceUID") {
        didSet {
            UserDefaults.standard.set(outputDeviceUID, forKey: "outputDeviceUID")
            player.audioOutputDeviceUniqueID = outputDeviceUID
            fadingDeck?.audioOutputDeviceUniqueID = outputDeviceUID
        }
    }

    @ObservationIgnored private var deviceListener: AnyObject?

    /// A chosen output that goes away (headphones switched off, a USB speaker unplugged) would
    /// leave the player sending sound nowhere — playing on in silence. So: pause, go back
    /// to this Mac's own output, and say so. Core Audio events, no polling; nothing runs while
    /// the system default is in use.
    private func watchOutputDevice() {
        func check(announce: Bool) {
            guard let uid = outputDeviceUID, !OutputDevices.all().contains(where: { $0.uid == uid }) else { return }
            outputDeviceUID = nil
            guard announce else { return }
            if isPlaying, !CastController.shared.isActive {
                if fadingDeck != nil { finishCrossfade() }
                afterFadeOut = nil
                player.pause()
                transportLevel = 1
            }
            Router.shared.showToast(String(localized: "Your audio device disconnected — switched to this Mac"), icon: "speaker.slash.fill")
        }
        // Saved from last time but not here now: quietly use the default.
        check(announce: false)
        deviceListener = OutputDevices.observe { check(announce: true) }
    }

    /// The player AirPlay routes (the AirPlay picker in "Connect to a device").
    var routingPlayer: AVPlayer { player }

    /// Playing on an AirPlay speaker or TV.
    var isAirPlaying: Bool { player.isExternalPlaybackActive }

    /// The exact playhead (`currentTime` is only published once a second), for syncing video.
    var playbackPosition: TimeInterval {
        if CastController.shared.isActive { return CastController.shared.position }
        return localPosition
    }

    /// Where this Mac's own player is (also once casting has begun, when `playbackPosition`
    /// already follows the device).
    private var localPosition: TimeInterval {
        let time = player.currentTime().seconds
        return time.isFinite ? time : currentTime
    }

    private func applyRate() {
        player.defaultRate = Float(playbackRate)
        if player.timeControlStatus != .paused { player.rate = Float(playbackRate) }
        nowPlaying.updatePlayback()
    }

    private func attach(_ deck: AVQueuePlayer) {
        timeObserver = deck.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
        observers = [
            deck.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.currentItemChanged() }
            },
            deck.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] deck, _ in
                Task { @MainActor in
                    // While casting, the device's state is what's shown, not this (silent) player's.
                    guard let self, deck === self.player, !CastController.shared.isActive else { return }
                    self.showPlayerState()
                    self.watchForStall()
                    self.nowPlaying.updatePlayback()
                    ListenTogether.shared.playerChanged()
                    VideoController.shared.syncNow()
                }
            },
        ]
    }

    /// Playing / buffering as shown: the player's own state, except while a song loads, when it's
    /// whether that song will start (see `loadingEntry`).
    private func showPlayerState() {
        if loadingEntry != nil {
            isPlaying = !loadStartsPaused
            isBuffering = !loadStartsPaused
        } else {
            isPlaying = player.timeControlStatus != .paused
            isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        }
    }

    /// An item made for a song that won't play after all: no longer counted as that song's
    /// (another item may later get the same identity).
    private func forget(_ item: AVPlayerItem) {
        itemEntries[ObjectIdentifier(item)] = nil
    }

    private func detach() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        observers.forEach { $0.invalidate() }
        observers = []
    }

    /// Crossfade: hand the already-queued next item to a fresh deck and fade the two decks across.
    /// Each deck keeps its own continuous audio, so there's no seek/sync glitch at the handoff.
    private func startCrossfade() {
        guard fadingDeck == nil, let queued = player.items().dropFirst().first,
              let entryId = itemEntries[ObjectIdentifier(queued)] else { return }
        // A long recording streams as HLS, which can't start on a fresh player mid-fade: the queue
        // moves on gaplessly into it instead.
        guard (queued.asset as? AVURLAsset)?.url.scheme != "http" else { return }
        let old = player
        detach()
        old.remove(queued)
        itemEntries[ObjectIdentifier(queued)] = nil
        old.actionAtItemEnd = .pause

        // An AVPlayerItem can only ever belong to one player, so rebuild it on the same
        // (already downloading/cached) asset for the incoming deck.
        let next = AVPlayerItem(asset: queued.asset)
        next.audioTimePitchAlgorithm = .spectral
        Task { await Equalizer.shared.attach(to: next) }
        next.preferredForwardBufferDuration = queued.preferredForwardBufferDuration
        next.forwardPlaybackEndTime = queued.forwardPlaybackEndTime
        itemEntries[ObjectIdentifier(next)] = entryId

        let deck = Self.makeDeck()
        deck.actionAtItemEnd = repeatMode == .one ? .none : .advance
        deck.insert(next, after: nil)
        handOff(from: old, to: deck, length: max(crossfadeSeconds, 0.5))
    }

    /// Makes `deck` the player and fades `old` out under it (equal power) over `length` seconds.
    private func handOff(from old: AVQueuePlayer, to deck: AVQueuePlayer, length: TimeInterval) {
        if old === player { detach() }
        old.actionAtItemEnd = .pause
        player = deck
        fadingDeck = old
        fadeLevel = 0
        applyVolume()
        attach(deck)
        deck.play()
        currentItemChanged()

        let start = Date()
        let startVolume = old.volume
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let progress = min(1, Date().timeIntervalSince(start) / length)
                // Equal-power curves keep perceived loudness constant through the fade.
                old.volume = startVolume * Float(cos(progress * .pi / 2))
                self.fadeLevel = sin(progress * .pi / 2)
                self.applyVolume()
                if progress >= 1 { self.finishCrossfade() }
            }
        }
        // Common modes: keeps fading while you scroll or drag (the default mode pauses then).
        RunLoop.main.add(timer, forMode: .common)
        fadeTimer = timer
    }

    private func finishCrossfade() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        fadingDeck?.pause()
        fadingDeck?.removeAllItems()
        fadingDeck = nil
        fadeLevel = 1
        applyVolume()
    }

    // MARK: Likes

    /// Likes set or learned in this session, by video ID. They beat what a page said when it loaded.
    private var knownLikes: [String: Bool] = [:]

    /// Whether a song is in Liked Music (the ✓ on song rows).
    func isLiked(_ track: Track) -> Bool {
        knownLikes[track.videoId] ?? (track.likeStatus == .like)
    }

    func toggleLike() {
        guard let track = current else { return }
        setLiked(likeStatus != .like, track)
    }

    func setLiked(_ liked: Bool, _ track: Track) {
        guard AuthManager.shared.isSignedIn else { Router.shared.showSignIn = true; return }
        let status: LikeStatus = liked ? .like : .indifferent
        knownLikes[track.videoId] = liked
        knownDislikes.remove(track.videoId)
        if track.videoId == current?.videoId { likeStatus = status }
        Task { try? await MusicAPI.setLike(status, videoId: track.videoId) }
    }

    /// Songs disliked in this session (YouTube Music's 👎).
    private(set) var knownDislikes: Set<String> = []

    func isDisliked(_ track: Track) -> Bool {
        knownDislikes.contains(track.videoId) || (knownLikes[track.videoId] == nil && track.likeStatus == .dislike)
    }

    /// 👎: YouTube plays less like it, and — like the website — a disliked song that's playing is skipped.
    func setDisliked(_ disliked: Bool, _ track: Track) {
        guard AuthManager.shared.isSignedIn else { Router.shared.showSignIn = true; return }
        if disliked {
            knownDislikes.insert(track.videoId)
            knownLikes[track.videoId] = false
        } else {
            knownDislikes.remove(track.videoId)
        }
        if track.videoId == current?.videoId {
            likeStatus = disliked ? .dislike : .indifferent
            if disliked { next() }
        }
        Task { try? await MusicAPI.setLike(disliked ? .dislike : .indifferent, videoId: track.videoId) }
    }

    private func refreshLikeStatus() {
        likeStatus = current.map { isLiked($0) } == true ? .like : .indifferent
        guard AuthManager.shared.isSignedIn, let track = current, !track.isLocal else { return }
        let videoId = track.videoId
        Task {
            let status = await MusicAPI.likeStatus(videoId: videoId)
            knownLikes[videoId] = status == .like
            if status == .dislike { knownDislikes.insert(videoId) }
            if current?.videoId == videoId { likeStatus = status }
        }
    }

    // MARK: Session persistence

    private struct Session: Codable {
        var tracks: [Track]
        var index: Int
        var time: TimeInterval
        var context: BrowseTarget?
        var contextTrackIds: [String]?
    }

    private static let sessionKey = "playbackSession"

    func saveSession() {
        guard !Bench.enabled else { return }
        lastSave = Date()
        rememberPosition()
        guard let index = currentIndex else { return }
        // Keep a window around the current track so the saved session stays small.
        let lower = max(0, index - 50)
        let upper = min(queue.count, index + 150)
        let session = Session(tracks: queue[lower..<upper].map(\.track), index: index - lower, time: currentTime,
                              context: context, contextTrackIds: Array(contextTrackIds))
        if let data = try? JSONEncoder().encode(session) {
            UserDefaults.standard.set(data, forKey: Self.sessionKey)
        }
    }

    /// Restores the last queue paused at the saved position; audio loads on the first play.
    private func restoreSession() {
        guard let data = UserDefaults.standard.data(forKey: Self.sessionKey),
              let session = try? JSONDecoder().decode(Session.self, from: data),
              session.tracks.indices.contains(session.index) else { return }
        queue = session.tracks.map { QueueEntry(track: $0) }
        currentIndex = session.index
        context = session.context
        contextTrackIds = Set(session.contextTrackIds ?? [])
        currentTime = session.time
        duration = knownDuration(session.tracks[session.index])
        pendingSeek = session.time > 5 ? session.time : nil
        nowPlaying.updateTrack()
    }

    // MARK: Starting playback

    /// The album/playlist/artist the queue was started from.
    private(set) var context: BrowseTarget?
    /// Songs that belong to `context`; autoplay and radio added after them don't.
    private var contextTrackIds: Set<String> = []

    /// What the current song is playing from (Your Library highlight, "Playing from").
    /// Nil once the context's own songs are done and autoplay has taken over.
    var playingContext: BrowseTarget? {
        guard let context, let current, contextTrackIds.contains(current.videoId) else { return nil }
        return context
    }

    func isPlaying(from target: BrowseTarget) -> Bool {
        playingContext?.browseId == target.browseId
    }

    /// What a song's or collection's play button shows: loading from the click until the sound
    /// starts, then pause while it plays (and play again when paused), like the player bar.
    enum ItemPlayState { case idle, loading, playing, paused }

    /// The album, playlist or artist a click is starting, while its songs load.
    private(set) var startingBrowseId: String?

    func playState(of track: Track) -> ItemPlayState {
        guard current?.videoId == track.videoId || currentSong?.videoId == track.videoId else { return .idle }
        if isBuffering { return .loading }
        return isPlaying ? .playing : .paused
    }

    func playState(of target: BrowseTarget) -> ItemPlayState {
        if startingBrowseId == target.browseId { return .loading }
        guard isPlaying(from: target) else { return .idle }
        if isBuffering { return .loading }
        return isPlaying ? .playing : .paused
    }

    /// A page's big Play button: pause or resume when the page is already what's playing, else start it.
    func playOrToggle(_ tracks: [Track], from target: BrowseTarget) {
        if isPlaying(from: target) { togglePlayPause() } else { play(tracks, from: target) }
    }

    /// Starts a new queue. `shuffled` nil keeps the current shuffle setting (as most players do, where
    /// shuffle stays on): the chosen song plays first and the rest are shuffled behind it.
    func play(_ tracks: [Track], startAt index: Int = 0, shuffled: Bool? = nil, from context: BrowseTarget? = nil) {
        latestRequest += 1
        startingBrowseId = nil
        startQueue(tracks, startAt: index, shuffled: shuffled, from: context)
    }

    private func startQueue(_ tracks: [Track], startAt index: Int = 0, shuffled: Bool? = nil, from context: BrowseTarget? = nil) {
        guard !tracks.isEmpty else { return }
        generation += 1
        dropWaitingSkip()
        self.context = context
        contextTrackIds = context == nil ? [] : Set(tracks.map(\.videoId))
        continuationIsContext = false
        // Hidden songs (AI, explicit, ones you hid) are left out — except the one you chose.
        let chosen = tracks.indices.contains(index) ? tracks[index].videoId : nil
        let filter = ContentFilter.shared
        let offline = offlineMode
        let kept = tracks.enumerated().filter {
            ($0.element.videoId == chosen || !filter.isHidden($0.element)) && (!offline || Self.availableOffline($0.element))
        }
        guard !kept.isEmpty else {
            if offline { Router.shared.showToast(String(localized: "None of these songs are downloaded — turn off Offline Mode to stream"), icon: "icloud.slash") }
            return
        }
        var entries = kept.map { QueueEntry(track: $0.element) }
        var start = kept.firstIndex { $0.offset == index } ?? 0
        smartShuffle = smartShuffle && (shuffled ?? shuffle)
        unshuffledOrder = nil
        shuffle = shuffled ?? shuffle
        if shuffle {
            unshuffledOrder = entries.map(\.id)
            if shuffled == true {
                // Shuffle play: any song can come first.
                entries.shuffle()
            } else {
                let first = entries.remove(at: start)
                entries.shuffle()
                entries.insert(first, at: 0)
            }
            start = 0
        }
        queue = entries
        radioContinuation = nil
        radioTuners = []
        selectedTuner = nil
        currentIndex = start
        startCurrent()
        if smartShuffle { Task { await addRecommendations() } }
    }

    /// Plays a single song followed by its radio — YouTube Music's default when tapping a song.
    func playRadio(from track: Track) {
        // The song that's playing (YouTube Music): it keeps playing, uninterrupted; what comes
        // after it becomes its radio. Played songs stay in the queue above it.
        if let index = currentIndex, queue.indices.contains(index), queue[index].track.videoId == track.videoId,
           !track.isLocal, remoteControl == nil {
            clearUpcoming()
            context = nil
            contextTrackIds = []
            continuationIsContext = false
            shuffle = false
            smartShuffle = false
            unshuffledOrder = nil
            radioTuners = []
            selectedTuner = nil
            Router.shared.showToast(String(localized: "Radio started from “\(track.title)”"), icon: "dot.radiowaves.left.and.right")
            Task {
                await appendRadio(seed: track.videoId, replacingUpcoming: true)
                saveSession()
            }
            return
        }
        play([track], shuffled: false)
        Task { await appendRadio(seed: track.videoId, replacingUpcoming: true) }
    }

    /// A song known only by its id (a pasted or opened link): YouTube's radio for it starts with
    /// the song itself, details included, so play that.
    func playSong(videoId: String) {
        latestRequest += 1
        let request = latestRequest
        Task {
            guard let result = try? await MusicAPI.radio(videoId: videoId), request == latestRequest else {
                if request == latestRequest {
                    Router.shared.showToast(String(localized: "Couldn't open that song"), icon: "exclamationmark.triangle.fill")
                }
                return
            }
            var tracks = result.tracks
            if !tracks.contains(where: { $0.videoId == videoId }) {
                tracks.insert(Track(videoId: videoId, title: String(localized: "Unknown song")), at: 0)
            }
            startQueue(tracks, startAt: tracks.firstIndex { $0.videoId == videoId } ?? 0, shuffled: false)
            radioContinuation = result.continuation
            radioTuners = result.tuners
            selectedTuner = result.selectedTuner
        }
    }

    /// Plays an album, playlist or artist page without opening it.
    func playCollection(_ target: BrowseTarget, playlistId: String? = nil, shuffled: Bool? = nil) {
        if let playlistId {
            playPlaylist(id: playlistId, shuffled: shuffled, from: target)
            return
        }
        latestRequest += 1
        let request = latestRequest
        // The songs load first: the top bar's spinner shows the click was taken, and a failure says so.
        Activity.shared.begin(.starting)
        startingBrowseId = target.browseId
        Task {
            defer {
                Activity.shared.end(.starting)
                if request == latestRequest { startingBrowseId = nil }
            }
            let page: BrowsePage
            do {
                page = try await MusicAPI.browse(target)
            } catch {
                if request == latestRequest { Router.shared.showToast(String(localized: "Couldn't play \(target.title)"), icon: "exclamationmark.triangle.fill") }
                return
            }
            guard request == latestRequest else { return }
            let tracks = target.kind == .artist ? (page.shelves.first { $0.style == .list }?.tracks ?? []) : page.mainTracks
            guard !tracks.isEmpty else {
                Router.shared.showToast(String(localized: "Nothing to play in \(target.title)"), icon: "music.note")
                return
            }
            startQueue(tracks, shuffled: shuffled, from: target)
        }
    }

    func playPlaylist(id playlistId: String, params: String? = nil, shuffled: Bool? = nil, from context: BrowseTarget? = nil) {
        latestRequest += 1
        let request = latestRequest
        Activity.shared.begin(.starting)
        startingBrowseId = context?.browseId
        Task {
            defer {
                Activity.shared.end(.starting)
                if request == latestRequest { startingBrowseId = nil }
            }
            do {
                let result = try await MusicAPI.radio(playlistId: playlistId, params: params)
                guard request == latestRequest else { return }
                startQueue(result.tracks, shuffled: shuffled, from: context)
                radioContinuation = result.continuation
                continuationIsContext = context != nil
                radioTuners = result.tuners
                selectedTuner = result.selectedTuner
            } catch {
                guard request == latestRequest else { return }
                errorMessage = Self.friendlyMessage(for: error)
                // With nothing playing, the player bar has nowhere to show it.
                if current == nil { Router.shared.showToast(Self.friendlyMessage(for: error), icon: "exclamationmark.triangle.fill") }
            }
        }
    }

    /// More of the collection that's playing finished loading on its page: keep it in the queue,
    /// so a long playlist doesn't hand over to autoplay after its first batch.
    func extendContext(_ target: BrowseTarget, with tracks: [Track]) {
        guard context?.browseId == target.browseId, radioContinuation == nil || !continuationIsContext else { return }
        contextTrackIds.formUnion(tracks.map(\.videoId))
        appendUnique(tracks)
    }

    /// The playlist being played was deleted: stop showing "Playing from" it.
    func forgetContext(_ target: BrowseTarget) {
        guard context?.browseId == target.browseId else { return }
        context = nil
        contextTrackIds = []
        saveSession()
    }

    /// Signed in, out or as someone else: likes learned for the old account no longer apply.
    func accountChanged() {
        knownLikes = [:]
        knownDislikes = []
        refreshLikeStatus()
    }

    /// YouTube Music's "Start radio" / "Start mix" for an album, playlist or artist: an endless mix
    /// built from it (not the collection itself).
    func startRadio(for item: MediaItem, header: PageHeader? = nil) {
        latestRequest += 1
        let request = latestRequest
        Task {
            guard let radioId = await Self.radioPlaylistId(for: item, header: header) else {
                Router.shared.showToast(String(localized: "Couldn't start a radio for this"), icon: "exclamationmark.triangle.fill")
                return
            }
            guard request == latestRequest else { return }
            playPlaylist(id: radioId, params: "wAEB", shuffled: false)
        }
    }

    /// The playlist id of an album's, playlist's or artist's radio (an artist's is their mix).
    static func radioPlaylistId(for item: MediaItem, header: PageHeader?) async -> String? {
        var header = header
        if header == nil, item.target.kind == .artist || (item.playlistId == nil && item.target.kind == .album) {
            header = (try? await MusicAPI.browse(item.target))?.header
        }
        let source: String? = switch item.target.kind {
        case .artist: header?.radioPlaylistId
        case .album: item.playlistId ?? header?.playlistId
        case .playlist: item.playlistId ?? (item.target.browseId.hasPrefix("VL") ? String(item.target.browseId.dropFirst(2)) : item.target.browseId)
        case .other, .podcast, .episode: nil
        }
        guard let source else { return nil }
        return item.target.kind == .artist || source.hasPrefix("RDAMPL") ? source : "RDAMPL\(source)"
    }

    // MARK: Sleep timer

    func setSleepTimer(minutes: Int) {
        sleepTimer = .at(Date().addingTimeInterval(TimeInterval(minutes * 60)))
        Router.shared.showToast(String(localized: "Sleep timer set for \(minutes) min"), icon: "moon.fill")
    }

    func setSleepTimerEndOfTrack() {
        sleepTimer = .endOfTrack
        Router.shared.showToast(String(localized: "Playback will stop after this song"), icon: "moon.fill")
    }

    func cancelSleepTimer() {
        sleepTimer = .off
        Router.shared.showToast(String(localized: "Sleep timer off"), icon: "moon")
    }

    private func checkSleepTimer(position: TimeInterval) {
        switch sleepTimer {
        case .off:
            return
        case .at(let date):
            // Drift off: fade out over the last few seconds instead of stopping mid-phrase.
            let remaining = date.timeIntervalSinceNow
            let level = min(1, max(0, remaining / 8))
            if level != sleepFadeLevel {
                sleepFadeLevel = level
                applyVolume()
            }
            guard remaining <= 0 else { return }
        case .endOfTrack:
            guard duration > 0, position >= duration - 0.4 else { return }
        }
        if fadingDeck != nil { finishCrossfade() }
        if CastController.shared.isActive { CastController.shared.pause() } else { player.pause() }
        // After pausing: turning the timer off restores the faded volume.
        sleepTimer = .off
    }

    // MARK: Transport

    /// Set while you're a guest in a listening session: your controls go to the host instead.
    @ObservationIgnored var remoteControl: ((ListenTogether.Request) -> Void)?

    func togglePlayPause() {
        if let remoteControl { remoteControl(.togglePlayPause); return }
        if current == nil { return }
        // Paused while a skip waits for more songs: the next one starts paused too.
        if advanceWhenExtended { startPausedOnce = isPlaying }
        if CastController.shared.isActive {
            let cast = CastController.shared
            if cast.remotePlaying { cast.pause() } else { cast.play() }
            return
        }
        if fadingDeck != nil { finishCrossfade() }
        // Pressed again while fading out to pause: keep playing.
        if afterFadeOut != nil, fadingOutToPause {
            afterFadeOut = nil
            fadingOutToPause = false
            ramp(\.transportLevel, to: 1, over: 0.05)
            return
        }
        finishPendingSkip()
        if loadingEntry != nil {
            // Still loading: the press decides whether it starts once ready (shown at once);
            // the load carries on either way, so playing again doesn't start over.
            loadStartsPaused.toggle()
            if loadStartsPaused { player.pause() }
            showPlayerState()
            nowPlaying.updatePlayback()
            return
        }
        if player.currentItem == nil {
            startCurrent(keepingPendingSeek: true)
            return
        }
        if isPlaying {
            fadeOut { [weak self] in
                self?.player.pause()
                self?.transportLevel = 1
            }
            fadingOutToPause = afterFadeOut != nil
        } else {
            // Played again by hand: a later return of the connection mustn't restart it.
            networkWait = nil
            transportLevel = 0
            applyVolume()
            player.play()
            ramp(\.transportLevel, to: 1, over: 0.05)
        }
    }

    // MARK: Fades

    /// Fades out over 50 ms, then runs `action` (pause, or change songs). Immediate when nothing
    /// is audible, or when another fade-out is already waiting (fast repeated skips all count).
    private func fadeOut(then action: @escaping () -> Void) {
        fadingOutToPause = false
        if let pending = afterFadeOut {
            afterFadeOut = nil
            stopRamp(\.transportLevel)
            pending()
            transportLevel = 1
            applyVolume()
            action()
            return
        }
        guard isPlaying, player.currentItem != nil, fadingDeck == nil, !isMuted, volume > 0 else {
            action()
            return
        }
        afterFadeOut = action
        ramp(\.transportLevel, to: 0, over: 0.05) { [weak self] in
            guard let self, let action = self.afterFadeOut else { return }
            self.afterFadeOut = nil
            self.fadingOutToPause = false
            action()
        }
    }

    /// A skip still fading out happens now, so a press right after it (play/pause, a seek)
    /// applies to the song it lands on rather than the one leaving.
    private func finishPendingSkip() {
        guard let pending = afterFadeOut, !fadingOutToPause else { return }
        afterFadeOut = nil
        stopRamp(\.transportLevel)
        transportLevel = 1
        pending()
    }

    /// A skip: fade out, change songs, and fade the new one in.
    private func skipWithFade(_ change: @escaping () -> Void) {
        fadeOut { [weak self] in
            change()
            guard let self else { return }
            self.transportLevel = 0
            self.applyVolume()
            self.ramp(\.transportLevel, to: 1, over: 0.05)
        }
    }

    private func smoothUserLevel() {
        ramp(\.userLevel, to: isMuted ? 0 : volume * volume, over: 0.03)
    }

    /// Moves a level to `target` over `duration` (a few timer steps), applying the volume each step.
    private func ramp(_ level: ReferenceWritableKeyPath<PlayerController, Double>, to target: Double, over duration: TimeInterval,
                      completion: (() -> Void)? = nil) {
        stopRamp(level)
        let start = self[keyPath: level]
        guard abs(start - target) > 0.001 else {
            self[keyPath: level] = target
            applyVolume()
            completion?()
            return
        }
        let began = Date()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let progress = min(1, Date().timeIntervalSince(began) / duration)
                self[keyPath: level] = start + (target - start) * progress
                self.applyVolume()
                if progress >= 1 {
                    timer.invalidate()
                    self.ramps[level] = nil
                    completion?()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ramps[level] = timer
    }

    private func stopRamp(_ level: PartialKeyPath<PlayerController>) {
        ramps[level]?.invalidate()
        ramps[level] = nil
    }

    func next() {
        if let remoteControl { remoteControl(.next); return }
        guard let index = currentIndex else { return }
        if fadingDeck != nil { finishCrossfade() }
        // Pressed while the last skip is still fading out: that one runs first, so this one
        // goes on from wherever it lands rather than being dropped.
        let chained = afterFadeOut != nil
        if index + 1 < queue.count {
            skipWithFade { [weak self] in
                guard let self, let now = self.currentIndex, chained || now == index, now + 1 < self.queue.count else { return }
                // Decided now, after the fade: the upcoming song may have been re-queued meanwhile
                // (a Song/Video switch, a queue edit).
                if self.player.items().count > 1, let nextItem = self.player.items().dropFirst().first,
                   self.itemEntries[ObjectIdentifier(nextItem)] == self.queue[now + 1].id {
                    // Already queued in AVQueuePlayer: advancing is instant and gapless.
                    self.player.advanceToNextItem()
                    self.player.play()
                    // Now, not when the player reports it: a skip pressed right after goes on from here.
                    self.currentItemChanged()
                } else {
                    self.currentIndex = now + 1
                    self.startCurrent()
                }
            }
        } else if repeatMode == .all, !queue.isEmpty {
            skipWithFade { [weak self] in
                self?.currentIndex = 0
                self?.startCurrent()
            }
        } else if extendingFor == generation {
            // More songs are already on their way.
            advanceWhenExtended = true
        } else if autoplay, !offlineMode, let last = queue.last {
            advanceWhenExtended = true
            Task { await appendRadio(seed: last.track.videoId, replacingUpcoming: false) }
        }
    }

    /// Forgets a skip waiting for more songs, and the pause pressed meanwhile that it would have
    /// carried over (or the next song you pick would start paused).
    private func dropWaitingSkip() {
        guard advanceWhenExtended else { return }
        advanceWhenExtended = false
        startPausedOnce = false
    }

    func previous() {
        if let remoteControl { remoteControl(.previous); return }
        guard let index = currentIndex else { return }
        // Going back drops a skip still waiting for more songs.
        dropWaitingSkip()
        let chained = afterFadeOut != nil
        if !chained, currentTime > 3 || index == 0 {
            seek(to: 0)
        } else {
            skipWithFade { [weak self] in
                guard let self, let now = self.currentIndex, chained || now == index, now > 0 else { return }
                self.currentIndex = now - 1
                self.startCurrent()
            }
        }
    }

    func jump(to entry: QueueEntry) {
        dropWaitingSkip()
        skipWithFade { [weak self] in
            guard let self, let index = self.queue.firstIndex(of: entry) else { return }
            self.currentIndex = index
            self.startCurrent()
        }
    }

    func seek(to seconds: TimeInterval) {
        if let remoteControl { remoteControl(.seek(seconds)); return }
        performSeek(to: seconds)
    }

    private func performSeek(to seconds: TimeInterval) {
        finishPendingSkip()
        currentTime = seconds
        if CastController.shared.isActive {
            CastController.shared.seek(to: seconds)
            nowPlaying.updatePlayback()
            return
        }
        if player.currentItem == nil || loadingEntry != nil {
            // Nothing loaded yet (restored session) or still loading: apply it when the song is ready.
            pendingSeek = seconds > 0 ? seconds : nil
            nowPlaying.updatePlayback()
            return
        }
        seeksInFlight += 1
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.seeksInFlight -= 1
                self.nowPlaying.updatePlayback()
                VideoController.shared.syncNow()
            }
        }
    }

    func skip(by delta: TimeInterval) {
        seek(to: min(max(0, currentTime + delta), max(duration - 1, 0)))
    }

    /// Off → Shuffle → Smart Shuffle → off.
    func cycleShuffle() {
        if !shuffle {
            toggleShuffle()
        } else if !smartShuffle {
            smartShuffle = true
            Router.shared.showToast(String(localized: "Smart Shuffle on — recommendations mixed in"), icon: "sparkles")
            Task { await addRecommendations() }
        } else {
            toggleShuffle()
        }
    }

    /// Smart Shuffle: one recommended song after every few of yours, from a radio of what's queued.
    private func addRecommendations() async {
        guard smartShuffle, let index = currentIndex else { return }
        let upcoming = Array(queue.dropFirst(index + 1))
        guard let seed = (upcoming.randomElement() ?? queue[index]).track.videoId as String?,
              let radio = try? await MusicAPI.radio(videoId: seed), smartShuffle, let now = currentIndex else { return }
        let known = Set(queue.map(\.track.videoId))
        var picks = ContentFilter.shared.filter(radio.tracks).filter { !known.contains($0.videoId) && !isDisliked($0) }.shuffled().prefix(12)
        guard !picks.isEmpty else { return }
        var head = Array(queue[...now])
        var rest = Array(queue.dropFirst(now + 1))
        var mixed: [QueueEntry] = []
        for (offset, entry) in rest.enumerated() {
            mixed.append(entry)
            if offset % 3 == 2, let pick = picks.popFirst() { mixed.append(QueueEntry(track: pick, isRecommendation: true)) }
        }
        while let pick = picks.popFirst(), mixed.count < rest.count + 4 { mixed.append(QueueEntry(track: pick, isRecommendation: true)) }
        rest = mixed
        head += rest
        queue = head
        resyncUpcoming()
    }

    private func removeRecommendations() {
        guard let index = currentIndex else { return }
        queue = Array(queue[...index]) + queue.dropFirst(index + 1).filter { !$0.isRecommendation }
        resyncUpcoming()
    }

    /// Smart Shuffle's ➕: keep a recommended song for good (it stays in the queue, unmarked).
    func keepRecommendation(_ entry: QueueEntry) {
        guard let index = queue.firstIndex(of: entry) else { return }
        queue[index].isRecommendation = false
    }

    func toggleShuffle() {
        // Turning shuffle off (⌘S, the Dock, the phone remote) ends Smart Shuffle too.
        if shuffle, smartShuffle {
            smartShuffle = false
            removeRecommendations()
        }
        guard let index = currentIndex else { shuffle.toggle(); return }
        shuffle.toggle()
        let head = Array(queue[...index])
        var upcoming = Array(queue.dropFirst(index + 1))
        if shuffle {
            unshuffledOrder = queue.map(\.id)
            upcoming.shuffle()
        } else if let order = unshuffledOrder {
            let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
            upcoming.sort { (rank[$0.id] ?? .max) < (rank[$1.id] ?? .max) }
            unshuffledOrder = nil
        }
        queue = head + upcoming
        resyncUpcoming()
    }

    func cycleRepeat() {
        let all = RepeatMode.allCases
        repeatMode = all[(all.firstIndex(of: repeatMode)! + 1) % all.count]
    }

    // MARK: Queue editing

    func playNext(_ track: Track) {
        playNext([track])
    }

    func playNext(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        if let remoteControl { remoteControl(.playNext(tracks)); return }
        guard let index = currentIndex else { play(tracks); return }
        queue.insert(contentsOf: tracks.map { QueueEntry(track: $0) }, at: index + 1)
        resyncUpcoming()
    }

    func addToQueue(_ tracks: [Track]) {
        if let remoteControl, !tracks.isEmpty { remoteControl(.addToQueue(tracks)); return }
        guard currentIndex != nil else { play(tracks); return }
        queue += tracks.map { QueueEntry(track: $0) }
        resyncUpcoming()
    }

    func remove(_ entry: QueueEntry) {
        guard let index = queue.firstIndex(of: entry), index != currentIndex else { return }
        let wasPlayed = currentIndex.map { index < $0 } ?? false
        queue.remove(at: index)
        if let current = currentIndex, index < current { currentIndex = current - 1 }
        resyncUpcoming()
        Router.shared.showToast(String(localized: "Removed from queue"), icon: "minus.circle",
                                undoName: String(localized: "Remove from Queue")) { [weak self] in
            guard let self, let current = self.currentIndex else { return }
            if wasPlayed {
                // Back where it was, before the song that's playing.
                self.queue.insert(entry, at: min(index, current))
                self.currentIndex = current + 1
            } else {
                self.queue.insert(entry, at: min(max(index, current + 1), self.queue.count))
            }
            self.resyncUpcoming()
        }
    }

    /// Several songs out of the queue at once (never the one playing), with Undo putting them back
    /// where they were.
    func remove(_ entries: [QueueEntry]) {
        if entries.count == 1, let entry = entries.first { remove(entry); return }
        guard let current = currentIndex else { return }
        let playing = queue[current].id
        let ids = Set(entries.map(\.id)).subtracting([playing])
        // With their places, first to last, so putting them back in order lands each where it was.
        let removed = queue.enumerated().filter { ids.contains($0.element.id) }
        guard !removed.isEmpty else { return }
        queue.removeAll { ids.contains($0.id) }
        currentIndex = queue.firstIndex { $0.id == playing }
        resyncUpcoming()
        Router.shared.showToast(String(localized: "Removed \(removed.count) songs from queue"), icon: "minus.circle",
                                undoName: String(localized: "Remove from Queue")) { [weak self] in
            guard let self, let now = self.currentIndex else { return }
            let playing = self.queue[now].id
            for (offset, entry) in removed where !self.queue.contains(where: { $0.id == entry.id }) {
                self.queue.insert(entry, at: min(offset, self.queue.count))
            }
            self.currentIndex = self.queue.firstIndex { $0.id == playing }
            self.resyncUpcoming()
        }
    }

    /// Songs from anywhere in the queue to just after the one playing, keeping their order.
    func moveToTop(_ entries: [QueueEntry]) {
        guard let current = currentIndex else { return }
        let playing = queue[current].id
        let ids = Set(entries.map(\.id)).subtracting([playing])
        let moving = queue.filter { ids.contains($0.id) }
        guard !moving.isEmpty else { return }
        queue.removeAll { ids.contains($0.id) }
        guard let now = queue.firstIndex(where: { $0.id == playing }) else { return }
        queue.insert(contentsOf: moving, at: now + 1)
        currentIndex = now
        resyncUpcoming()
    }

    /// "Clear queue", with Undo putting everything back.
    func clearUpcomingWithUndo() {
        guard let index = currentIndex else { return }
        let removed = Array(queue.dropFirst(index + 1))
        let continuation = radioContinuation
        clearUpcoming()
        guard !removed.isEmpty else { return }
        Router.shared.showToast(String(localized: "Queue cleared"), icon: "list.bullet", undoName: String(localized: "Clear Queue")) { [weak self] in
            guard let self, self.currentIndex != nil else { return }
            self.queue += removed.filter { entry in !self.queue.contains { $0.id == entry.id } }
            self.radioContinuation = continuation
            self.resyncUpcoming()
        }
    }

    func moveUpcoming(from source: IndexSet, to destination: Int) {
        guard let index = currentIndex else { return }
        var upcoming = Array(queue.dropFirst(index + 1))
        upcoming.move(fromOffsets: source, toOffset: destination)
        queue = Array(queue[...index]) + upcoming
        resyncUpcoming()
    }

    func clearUpcoming() {
        guard let index = currentIndex else { return }
        generation += 1
        dropWaitingSkip()
        queue = Array(queue[...index])
        radioContinuation = nil
        resyncUpcoming()
    }

    // MARK: Listening together (guest side)

    /// Plays what the host is playing, from where they are.
    func follow(_ tracks: [Track], at position: TimeInterval, playing: Bool) {
        latestRequest += 1
        pendingSeek = position > 1 ? position : nil
        startQueueKeepingSeek(tracks)
        if !playing {
            Task {
                try? await Task.sleep(for: .milliseconds(800))
                player.pause()
            }
        }
    }

    private func startQueueKeepingSeek(_ tracks: [Track]) {
        let seek = pendingSeek
        startQueue(tracks, shuffled: false)
        if let seek {
            pendingSeek = seek
            currentTime = seek
        }
    }

    /// Stays in step with the host: same play/pause, re-seeked when more than two seconds apart.
    func followSync(position: TimeInterval, playing: Bool) {
        if loadingEntry != nil || player.currentItem == nil {
            // Not loaded yet (loading, paused, or a restored session): show the host's position
            // now and start from it on play.
            pendingSeek = position > 1 ? position : nil
            currentTime = position
            if loadingEntry != nil {
                if !playing { player.pause() }
                loadStartsPaused = !playing
                showPlayerState()
            } else if playing {
                startCurrent(keepingPendingSeek: true)
            }
            return
        }
        if abs(playbackPosition - position) > 2 { performSeek(to: position) }
        if playing, !isPlaying { player.play() } else if !playing, isPlaying { player.pause() }
    }

    // MARK: Content filter

    /// Something was hidden or marked AI: drop such songs from what's coming up, and skip the
    /// playing one if you just hid it.
    func contentFilterChanged() {
        guard let index = currentIndex else { return }
        let filter = ContentFilter.shared
        let before = queue.count
        queue = Array(queue[...index]) + queue.dropFirst(index + 1).filter { !filter.isHidden($0.track) }
        if queue.count != before { resyncUpcoming() }
        if let track = current, filter.isHiddenByYou(track) || (filter.hideAI && filter.isAI(track)) { next() }
    }

    /// YouTube's AI disclosure for the playing song and the next few, checked in the background.
    private func checkUpcomingLabels() {
        guard let index = currentIndex else { return }
        let tracks = Array(queue[index...].prefix(5).map(\.track))
        let playing = queue[index].id
        Task {
            let flagged = await ContentFilter.shared.checkLabels(tracks)
            guard !flagged.isEmpty, ContentFilter.shared.hideAI, let now = currentIndex else { return }
            let before = queue.count
            queue = Array(queue[...now]) + queue.dropFirst(now + 1).filter { !flagged.contains($0.track.videoId) }
            if queue.count != before { resyncUpcoming() }
            if queue[now].id == playing, flagged.contains(queue[now].track.videoId) {
                Router.shared.showToast(String(localized: "Skipped an AI-generated song"), icon: "sparkles")
                next()
            }
        }
    }

    // MARK: Resume points

    /// Where you stopped in long recordings (podcast episodes, mixes), by video id.
    private var resumePositions: [String: TimeInterval] = UserDefaults.standard.dictionary(forKey: "resumePositions") as? [String: TimeInterval] ?? [:]

    /// How far into a long recording you got, for "x min left" on episode rows.
    func resumePosition(for track: Track) -> TimeInterval? { resumePositions[track.videoId] }

    private func rememberPosition() {
        guard let track = current, duration >= 900 else { return }
        if currentTime > 30, currentTime < duration - 60 {
            resumePositions[track.videoId] = currentTime
        } else if currentTime >= duration - 60 {
            resumePositions[track.videoId] = nil
        } else {
            return
        }
        if resumePositions.count > 300 { resumePositions = Dictionary(uniqueKeysWithValues: resumePositions.suffix(200).map { ($0.key, $0.value) }) }
        UserDefaults.standard.set(resumePositions, forKey: "resumePositions")
    }

    // MARK: Song / video

    /// Where the Song/Video switch is heading while the other version loads (it shows that at
    /// once); nil when not switching.
    private(set) var versionTarget: Bool?
    @ObservationIgnored private var versionTask: Task<Void, Never>?
    /// The queue entry the switch in progress is for.
    @ObservationIgnored private var versionEntry: UUID?

    /// YouTube Music's Song/Video switch: the music video version of the current song from the
    /// same point (or back to the song). The current version keeps playing while the other loads,
    /// then the two cross-fade — no silence, and it's still the same play (no new notification,
    /// history entry or stats play).
    /// `automatic`: a new song following the mode you're in, rather than a click — with no other
    /// version it quietly stays as it is, and the mode stays too.
    func switchVersion(toVideo: Bool, automatic: Bool = false) {
        guard let index = currentIndex, queue.indices.contains(index) else { return }
        let entry = queue[index]
        guard entry.track.isVideo != toVideo, !entry.track.isLocal else { return }
        // Casting: only a switch you ask for, and it goes to the device (nothing plays here).
        if automatic, CastController.shared.isActive { return }
        versionTask?.cancel()
        versionTarget = toVideo
        versionEntry = entry.id
        let started = Date()
        func ms() -> Int { Int(Date().timeIntervalSince(started) * 1000) }
        videoLog.notice("switch to \(toVideo ? "video" : "song", privacy: .public) from \(entry.track.videoId, privacy: .public)")
        versionTask = Task {
            // Done, given up, or the song changed meanwhile: the switch stops showing it's on its way.
            // (A newer switch, which cancelled this one, shows its own.)
            defer {
                if !Task.isCancelled {
                    versionTarget = nil
                    versionEntry = nil
                }
            }
            /// Still the song playing, in the version it had when the switch was asked for.
            @MainActor func stillCurrent() -> Bool {
                !Task.isCancelled && currentIndex == index && queue.indices.contains(index) && queue[index].id == entry.id
                    && queue[index].track.videoId == entry.track.videoId
            }
            guard let target = await Self.otherVersion(of: entry, video: toVideo) else {
                guard !Task.isCancelled, !automatic else { return }
                if toVideo {
                    VideoController.shared.videoMode = false
                    Router.shared.showToast(String(localized: "No music video found for this song"), icon: "video.slash")
                } else {
                    Router.shared.showToast(String(localized: "No song version found for this video"), icon: "music.note")
                }
                return
            }
            guard stillCurrent() else { return }
            videoLog.notice("switch: other version \(target.videoId, privacy: .public) found at \(ms()) ms")
            let replacement = Self.entry(entry, as: target, video: toVideo)
            let cast = CastController.shared
            if cast.isActive {
                queue[index] = replacement
                cast.load(replacement.track, at: cast.position, autoplay: cast.remotePlaying)
                if !toVideo { VideoController.shared.videoMode = false }
                nowPlaying.updateTrack()
                return
            }
            // Its sound hasn't started yet (just skipped to): load the other version instead, from
            // where it was going to start, playing or paused as asked meanwhile.
            if loadingEntry == entry.id {
                restartLoad(as: replacement, at: index)
                if !toVideo { VideoController.shared.videoMode = false }
                return
            }
            // The picture starts loading alongside the sound.
            if toVideo { VideoController.shared.prepare(videoId: target.videoId) }
            do {
                let item = try await makeItem(for: replacement)
                guard stillCurrent() else { forget(item); return }
                videoLog.notice("switch: its sound ready at \(ms()) ms")
                if loadingEntry == entry.id {
                    // Reloading meanwhile (a stall): the other version loads in its place.
                    forget(item)
                    restartLoad(as: replacement, at: index)
                } else {
                    await swapVersion(to: replacement, item: item, at: index)
                    videoLog.notice("switch: swapped at \(ms()) ms")
                }
                if !toVideo { VideoController.shared.videoMode = false }
            } catch {
                guard !Task.isCancelled else { return }
                Router.shared.showToast(String(localized: "Couldn't switch versions"), icon: "exclamationmark.triangle.fill")
            }
        }
    }

    /// The playing entry, still loading, becomes `replacement` (its other version) and loads afresh.
    private func restartLoad(as replacement: QueueEntry, at index: Int) {
        queue[index] = replacement
        startPausedOnce = loadStartsPaused
        startCurrent(keepingPendingSeek: true)
    }

    /// The song's music video, or the video's song: one already known for this entry, or looked up.
    private static func otherVersion(of entry: QueueEntry, video: Bool) async -> Track? {
        if let known = video ? entry.videoVersion : entry.songVersion { return known }
        return video ? await VersionLookup.video(for: entry.track) : await VersionLookup.song(for: entry.track)
    }

    /// The same queue entry (still the same play), now playing `version`.
    private static func entry(_ entry: QueueEntry, as version: Track, video: Bool) -> QueueEntry {
        var replacement = QueueEntry(track: version, isRecommendation: entry.isRecommendation)
        replacement.id = entry.id
        replacement.songVersion = video ? (entry.songVersion ?? entry.track) : nil
        replacement.videoVersion = video ? nil : entry.track
        return replacement
    }

    /// Whether an entry plays in the other version from the one the Song/Video switch is on.
    private static func needsOtherVersion(_ entry: QueueEntry) -> Bool {
        !entry.track.isLocal && entry.track.isVideo != VideoController.shared.videoMode
    }

    /// A new song plays in the mode you're in (YouTube Music): its music video in Video mode, the
    /// song in Song mode. Usually the next one was matched before it started (see `enqueueNext`).
    private func followVersionMode() {
        guard let index = currentIndex, queue.indices.contains(index), Self.needsOtherVersion(queue[index]),
              !CastController.shared.isActive, remoteControl == nil else { return }
        switchVersion(toVideo: VideoController.shared.videoMode, automatic: true)
    }

    /// The Song/Video switch moved: the next song is matched to it again.
    func versionModeChanged() {
        guard !CastController.shared.isActive else { prepareNextForCast(); return }
        resyncUpcoming()
    }

    /// Casting: the next song, in the mode you're in and its stream looked up, goes on the device's
    /// queue, so it follows without a new load (and the TV shows it's up next). Called whenever
    /// the next song may have changed: a new song, the queue edited, shuffle, repeat, Song/Video.
    private func prepareNextForCast() {
        castNextTask?.cancel()
        guard repeatMode != .one, let index = currentIndex,
              let nextIndex = index + 1 < queue.count ? index + 1 : (repeatMode == .all ? 0 : nil),
              queue.indices.contains(nextIndex), nextIndex != index else {
            CastController.shared.setNext(nil)
            return
        }
        let next = queue[nextIndex]
        castNextTask = Task {
            var entry = next
            if Self.needsOtherVersion(entry), let other = await Self.otherVersion(of: entry, video: VideoController.shared.videoMode),
               !Task.isCancelled, let at = queue.firstIndex(where: { $0.id == entry.id }), at != currentIndex {
                entry = Self.entry(entry, as: other, video: VideoController.shared.videoMode)
                queue[at] = entry
            }
            // The TV's YouTube app fetches songs itself.
            if !CastController.shared.viaYouTubeApp { await CastMediaServer.shared.prepare(entry.track) }
            guard !Task.isCancelled, CastController.shared.isActive else { return }
            CastController.shared.setNext(entry.track)
        }
    }

    /// The switch was flipped back before the other version arrived.
    func cancelVersionSwitch() {
        versionTask?.cancel()
        versionTask = nil
        versionTarget = nil
        versionEntry = nil
    }

    /// Puts the other version in place of the playing one, from where the music is now.
    private func swapVersion(to replacement: QueueEntry, item: AVPlayerItem, at index: Int) async {
        let playing = isPlaying
        if fadingDeck != nil { finishCrossfade() }
        let old = player
        let deck = Self.makeDeck()
        deck.actionAtItemEnd = repeatMode == .one ? .none : .advance
        deck.insert(item, after: nil)
        // The music kept going while the other version loaded: start it a moment ahead of where
        // the current one is, to allow for the seek.
        let position = playbackPosition
        if position > 0.5 {
            await deck.seek(to: CMTime(seconds: position + (playing ? 0.15 : 0), preferredTimescale: 600),
                            toleranceBefore: .zero, toleranceAfter: .zero)
        }
        // Skipped, crossfaded or reloading meanwhile: this deck is no longer the one to hand over to.
        guard queue.indices.contains(index), currentIndex == index, player === old, loadingEntry == nil else {
            deck.removeAllItems()
            forget(item)
            return
        }
        queue[index] = replacement
        for stale in old.items() { itemEntries[ObjectIdentifier(stale)] = nil }
        // Over AirPlay the route belongs to the old player: replace in place instead (no fade).
        if old.isExternalPlaybackActive {
            deck.removeAllItems()
            let inPlace = AVPlayerItem(asset: item.asset)
            inPlace.audioTimePitchAlgorithm = .spectral
            inPlace.forwardPlaybackEndTime = item.forwardPlaybackEndTime
            await Equalizer.shared.attach(to: inPlace)
            itemEntries[ObjectIdentifier(inPlace)] = replacement.id
            old.removeAllItems()
            old.insert(inPlace, after: nil)
            if position > 0.5 { await old.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
            if playing { old.play() }
        } else if playing {
            handOff(from: old, to: deck, length: 0.35)
        } else {
            // Paused: swap silently and stay paused.
            detach()
            old.pause()
            old.removeAllItems()
            player = deck
            applyVolume()
            attach(deck)
        }
        versionDidChange()
    }

    /// The other version is in: what depends on the song itself follows it; what depends on the
    /// play (history, notification, stats, recents) doesn't happen again.
    private func versionDidChange() {
        guard let track = current else { return }
        duration = knownDuration(track)
        refreshLikeStatus()
        loadSkipSegments()
        VideoController.shared.trackChanged()
        ListenTogether.shared.playerChanged()
        nowPlaying.updateTrack()
        saveSession()
        pruneSources()
        enqueueNext()
    }

    // MARK: Casting

    /// Playing back here after casting ends while the device was paused.
    @ObservationIgnored private var startPausedOnce = false
    @ObservationIgnored private var castClock: Timer?
    @ObservationIgnored private var applyingCastVolume = false
    @ObservationIgnored private var castVolumeTask: Task<Void, Never>?
    @ObservationIgnored private var castNextTask: Task<Void, Never>?

    /// Casting began: what's playing moves to the device, from where it is, and this Mac goes quiet.
    func castingStarted() {
        // The device counts as connected already, so playbackPosition would be its 0.
        let position = localPosition
        let playing = isPlaying || isBuffering
        if fadingDeck != nil { finishCrossfade() }
        loadTask?.cancel()
        loadingEntry = nil
        enqueueTask?.cancel()
        // A song/video switch started here would swap in a player on this Mac.
        cancelVersionSwitch()
        // The picture plays on the TV now, not here.
        VideoController.shared.trackChanged()
        player.pause()
        player.removeAllItems()
        itemEntries.removeAll()
        pruneSources()
        guard let track = current else { return }
        CastController.shared.load(track, at: position, autoplay: playing)
        prepareNextForCast()
        sendCastVolume()
        castClock?.invalidate()
        // The device reports its position now and then; between reports the clock runs here,
        // feeding the same bookkeeping as local playback (lyrics, stats, sleep timer, history).
        let clock = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.castTick() }
        }
        RunLoop.main.add(clock, forMode: .common)
        castClock = clock
    }

    /// Casting ended: carry on here from where the device was (playing only if it was).
    func castingEnded(at position: TimeInterval, playing: Bool) {
        castClock?.invalidate()
        castClock = nil
        castNextTask?.cancel()
        isPlaying = false
        guard current != nil else { return }
        pendingSeek = position > 1 ? position : nil
        currentTime = position
        startPausedOnce = !playing
        startCurrent(keepingPendingSeek: true)
    }

    /// The device's playing / paused / buffering state changed.
    /// The device says how long the song is. Casting, nothing loads here to tell (and some songs
    /// come without a length), so its figure is the one to show.
    func castDurationReported(_ seconds: TimeInterval) {
        guard CastController.shared.isActive, seconds.isFinite, seconds > 0, abs(seconds - duration) > 1 else { return }
        duration = seconds
        nowPlaying.updatePlayback()
    }

    func castStatusChanged() {
        let cast = CastController.shared
        guard cast.isActive else { return }
        isPlaying = cast.remotePlaying
        isBuffering = cast.remoteBuffering
        currentTime = cast.position
        nowPlaying.updatePlayback()
        ListenTogether.shared.playerChanged()
        VideoController.shared.syncNow()
    }

    /// The device finished a song: the queue moves on here (and loads the next one there).
    func castFinishedSong(_ videoId: String?) {
        guard let videoId, videoId == current?.videoId else { return }
        if repeatMode == .one {
            CastController.shared.seek(to: 0)
            CastController.shared.play()
        } else {
            next()
        }
    }

    /// The device went on by itself to the song queued there: the queue here follows, and nothing
    /// loads. Should that song not be next here any more, the next one here plays instead.
    func castAdvanced(to videoId: String) {
        guard let index = currentIndex else { return }
        guard let now = CastQueueSync.indexAfterAdvance(queue: queue.map(\.track.videoId), current: index, to: videoId,
                                                        repeatAll: repeatMode == .all) else {
            next()
            return
        }
        dropWaitingSkip()
        currentIndex = now
        currentTime = 0
        pendingSeek = nil
        trackDidChange()
        castStatusChanged()
    }

    /// The volume was changed on the device (its remote, Google Home).
    func castVolumeChanged(_ level: Double) {
        guard abs(level - volume) > 0.01 else { return }
        applyingCastVolume = true
        volume = level
        applyingCastVolume = false
    }

    private func sendCastVolume() {
        guard CastController.shared.isActive, !applyingCastVolume else { return }
        // Dragging the slider sends many changes: pass on the latest every 100 ms.
        castVolumeTask?.cancel()
        castVolumeTask = Task {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            CastController.shared.setVolume(volume, muted: isMuted)
        }
    }

    private func castTick() {
        let cast = CastController.shared
        guard cast.isActive else { return }
        let position = cast.position
        tick(CMTime(seconds: position, preferredTimescale: 600))
        // Some receivers report a longer length than the song has: move on at its real end. (The
        // TV's YouTube app says when its video ends, and goes on by itself.)
        if duration > 0, position >= duration + 1, cast.remotePlaying, !cast.viaYouTubeApp { castFinishedSong(current?.videoId) }
    }

    // MARK: Internals

    private func startCurrent(keepingPendingSeek: Bool = false) {
        if !keepingPendingSeek { pendingSeek = nil }
        // A new queue replaces whatever a fade-out was about to do.
        afterFadeOut = nil
        stopRamp(\.transportLevel)
        transportLevel = 1
        if fadingDeck != nil { finishCrossfade() }
        loadTask?.cancel()
        enqueueTask?.cancel()
        player.removeAllItems()
        itemEntries.removeAll()
        errorMessage = nil
        loadingEntry = nil
        // Whatever was waiting for the connection is superseded by this.
        networkWait = nil
        // Paused by whoever asked for this start (back from a paused Cast device, offline while
        // paused); a song you pick or skip to plays.
        let startsPaused = startPausedOnce
        startPausedOnce = false

        guard let index = currentIndex, queue.indices.contains(index) else { return }
        let entry = queue[index]
        // A Song/Video switch for the song before has nothing left to switch.
        if let versionEntry, versionEntry != entry.id { cancelVersionSwitch() }
        soundAsked = (entry.track.videoId, Date())
        perfLog.notice("play \(entry.track.videoId, privacy: .public)")
        // Skipping through songs quickly: only the one you stop on loads, and the downloads of
        // those passed by stop. Otherwise each would go on resolving and downloading, and the
        // song you land on would wait behind them all.
        let burst = Date().timeIntervalSince(lastStart) < 0.6
        lastStart = Date()
        pruneSources()
        currentTime = 0
        duration = knownDuration(entry.track)
        // Podcasts and other long recordings pick up where you left off.
        if pendingSeek == nil, let resume = resumePositions[entry.track.videoId] {
            pendingSeek = resume
            currentTime = resume
        }
        // Casting: the device plays it (from this Mac's media server); nothing loads here.
        if CastController.shared.isActive {
            isBuffering = true
            nowPlaying.updateTrack()
            VideoController.shared.trackChanged()
            soundAsked = nil
            let position = pendingSeek ?? 0, autoplay = !startsPaused
            pendingSeek = nil
            if Self.needsOtherVersion(entry) {
                // In the mode you're in (its music video in Video mode), found before the device
                // loads anything, so it loads once. Usually already matched (see prepareNextForCast).
                Task {
                    let other = await Self.otherVersion(of: entry, video: VideoController.shared.videoMode)
                    guard let index = currentIndex, queue.indices.contains(index), queue[index].id == entry.id,
                          CastController.shared.isActive else { return }
                    if let other {
                        queue[index] = Self.entry(entry, as: other, video: VideoController.shared.videoMode)
                        versionDidChange()
                    }
                    CastController.shared.load(queue[index].track, at: position, autoplay: autoplay)
                }
            } else {
                CastController.shared.load(entry.track, at: position, autoplay: autoplay)
            }
            // Its next song goes on the device's queue from here (see enqueueNext).
            trackDidChange()
            return
        }

        // What's shown from now until it's ready: whether it will start (play/pause meanwhile
        // only changes that), not the empty player's own state.
        loadingEntry = entry.id
        loadStartsPaused = startsPaused
        // Left playing, the player would start the new song by itself before it's ready.
        if startsPaused { player.pause() }
        isPlaying = !startsPaused
        isBuffering = !startsPaused
        nowPlaying.updateTrack()
        // A music video's picture loads alongside its sound, not after it.
        VideoController.shared.trackChanged()

        loadTask = Task {
            var made: AVPlayerItem?
            /// Still the song to play: not skipped past, cancelled, or switched to its other version.
            @MainActor func stillWanted() -> Bool {
                !Task.isCancelled && loadingEntry == entry.id && current?.videoId == entry.track.videoId
            }
            do {
                // Another skip within this moment cancels it before anything is fetched.
                if burst { try await Task.sleep(for: .milliseconds(350)) }
                let item = try await makeItem(for: entry)
                made = item
                guard stillWanted() else { forget(item); return }
                player.insert(item, after: nil)
                // Play only once it's ready: a long recording (HLS) told to play before then is
                // quietly reset to paused and would never start.
                await Self.untilDecided(item, timeout: 10)
                guard stillWanted() else { return }
                if item.status == .failed { throw item.error ?? InnerTubeError.noAudio }
                // Exact: a streamed recording would otherwise resume at the start of its
                // fragment, up to ten seconds back. Seeks made meanwhile land here too.
                while let target = pendingSeek {
                    pendingSeek = nil
                    seeksInFlight += 1
                    await player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                    seeksInFlight -= 1
                    guard stillWanted() else { return }
                }
                loadingEntry = nil
                if loadStartsPaused { player.pause() } else { player.play(); logWhenSoundStarts() }
                // The player may already be in that state, and then reports no change.
                showPlayerState()
                trackDidChange()
            } catch is CancellationError {
                if let made { forget(made) }
            } catch {
                if let made { forget(made) }
                guard stillWanted() else { return }
                loadingEntry = nil
                handleFailure(error)
            }
        }
    }

    /// Logs (category Perf) when the song asked for has played its first 10 ms.
    private func logWhenSoundStarts() {
        guard let asked = soundAsked, asked.videoId == current?.videoId else { return }
        soundAsked = nil
        let deck = player
        if let soundObserver { deck.removeTimeObserver(soundObserver) }
        let at = CMTimeAdd(deck.currentTime(), CMTime(value: 1, timescale: 100))
        soundObserver = deck.addBoundaryTimeObserver(forTimes: [NSValue(time: at)], queue: .main) { [weak self, weak deck] in
            MainActor.assumeIsolated {
                perfLog.notice("sound \(asked.videoId, privacy: .public) after \(Int(Date().timeIntervalSince(asked.at) * 1000)) ms")
                if let observer = self?.soundObserver { deck?.removeTimeObserver(observer) }
                self?.soundObserver = nil
            }
        }
    }

    /// A Premium account online skips a lower-quality replay copy, so the song is fetched (and
    /// cached) again in Premium quality.
    private func upgradesToPremium(_ videoId: String, cached file: URL) -> Bool {
        PremiumAudio.isPremiumAccount && AuthManager.shared.isSignedIn && Connectivity.shared.isOnline
            && UserDefaults.standard.string(forKey: "audioQuality") != "low"
            && file != DownloadManager.fileURL(for: videoId) && AudioCache.isBelowPremium(videoId)
    }

    private func makeItem(for entry: QueueEntry) async throws -> AVPlayerItem {
        let videoId = entry.track.videoId
        let item: AVPlayerItem
        if let path = entry.track.localPath {
            guard FileManager.default.fileExists(atPath: path) else { throw InnerTubeError.unplayable(String(localized: "The file is no longer on this Mac")) }
            item = AVPlayerItem(url: URL(fileURLWithPath: path))
        } else if let file = AudioCache.cachedFile(for: videoId), !upgradesToPremium(videoId, cached: file) {
            // Saved before the header fix: correct it once (a few bytes, in place).
            await Task.detached(priority: .userInitiated) { FragmentedMP4.fixFile(file) }.value
            item = AVPlayerItem(url: file)
        } else {
            let source: ChunkedAudioSource
            if let existing = sources[videoId] {
                source = existing
            } else {
                let started = Date()
                let info = try await resolver.resolve(videoId: videoId)
                perfLog.notice("resolved \(videoId, privacy: .public) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
                // Skipped past while it resolved: don't start downloading it.
                try Task.checkCancellation()
                source = makeSource(videoId: videoId, info: info)
            }
            item = AVPlayerItem(asset: await source.makeAsset())
            try Task.checkCancellation()
        }
        item.preferredForwardBufferDuration = 30
        // Keeps voices natural when the playback speed isn't 1×.
        item.audioTimePitchAlgorithm = .spectral
        // With the header fixed AVFoundation knows the true length; this end point is a backstop
        // (a file it couldn't fix would otherwise play on in silence), a moment past the end so
        // a song's last note is never cut.
        let length = knownDuration(entry.track)
        if length > 0, !entry.track.isLocal { item.forwardPlaybackEndTime = CMTime(seconds: length + 0.4, preferredTimescale: 1000) }
        await Equalizer.shared.attach(to: item)
        itemEntries[ObjectIdentifier(item)] = entry.id
        return item
    }

    /// Queues the following track in AVQueuePlayer (and downloads it) so the transition is gapless.
    private func enqueueNext() {
        enqueueTask?.cancel()
        // Casting: the next song goes on the device's queue instead.
        if CastController.shared.isActive { prepareNextForCast(); return }
        guard repeatMode != .one, let index = currentIndex else { return }
        let nextIndex = index + 1 < queue.count ? index + 1 : (repeatMode == .all ? 0 : nil)
        guard let nextIndex, queue.indices.contains(nextIndex), nextIndex != index else { return }
        let entry = queue[nextIndex]

        enqueueTask = Task {
            var entry = entry
            // In the mode you're in before it starts, so it doesn't switch once it's playing.
            if Self.needsOtherVersion(entry), let other = await Self.otherVersion(of: entry, video: VideoController.shared.videoMode),
               !Task.isCancelled, let at = queue.firstIndex(where: { $0.id == entry.id }) {
                entry = Self.entry(entry, as: other, video: VideoController.shared.videoMode)
                queue[at] = entry
            }
            guard let item = try? await makeItem(for: entry) else { return }
            guard !Task.isCancelled, player.items().count == 1, let last = player.items().last else { forget(item); return }
            player.insert(item, after: last)
            sources[entry.track.videoId]?.prefetch()
        }
    }

    /// Drops whatever is queued after the current item and re-queues the (possibly new) next track.
    private func resyncUpcoming() {
        for item in player.items().dropFirst() {
            player.remove(item)
            itemEntries[ObjectIdentifier(item)] = nil
        }
        enqueueNext()
    }

    private func currentItemChanged() {
        guard let item = player.currentItem else {
            // The end of the queue (not the empty player of a song that's loading).
            if loadingEntry == nil, repeatMode != .one, let index = currentIndex, index + 1 >= queue.count { isPlaying = false }
            return
        }
        guard let entryId = itemEntries[ObjectIdentifier(item)],
              let index = queue.firstIndex(where: { $0.id == entryId }) else { return }
        if index != currentIndex {
            currentIndex = index
            currentTime = 0
            trackDidChange()
        }
    }

    /// AVPlayerItem.duration is unreliable for these streams (reported at 2x), so use YouTube's metadata.
    private func knownDuration(_ track: Track) -> TimeInterval {
        AudioCache.duration(for: track.videoId) ?? track.duration ?? 0
    }

    private func trackDidChange() {
        consecutiveFailures = 0
        networkRetries = 0
        if let track = current {
            duration = knownDuration(track)
            if !privateSession { LocalLibrary.shared.recordPlay(track) }
            SongNotifications.shared.trackChanged(track)
        }
        lastTickPosition = nil
        loadSkipSegments()
        checkUpcomingLabels()
        VideoController.shared.trackChanged()
        ListenTogether.shared.playerChanged()
        refreshLikeStatus()
        saveSession()
        applyVolume()
        nowPlaying.updateTrack()
        pruneSources()
        enqueueNext()
        extendQueueIfNeeded()
        followVersionMode()
    }

    private func itemDidFinish(_ item: AVPlayerItem?) {
        guard let item, let entryId = itemEntries[ObjectIdentifier(item)],
              let index = currentIndex, queue.indices.contains(index), queue[index].id == entryId else { return }
        if repeatMode == .one {
            PlayTracker.shared.finish()
            WatchTime.shared.finish()
            performSeek(to: 0)
            player.play()
        } else if !player.items().contains(where: { $0 !== item }) {
            // Nothing queued behind it (still resolving, or end of queue).
            next()
        }
    }

    private func handleFailure(_ error: Error) {
        isBuffering = false
        // The connection dropped: skipping would just fail through the whole queue. Wait where we
        // are and carry on when it's back.
        if Self.isNetworkError(error) || !Connectivity.shared.isOnline {
            waitForNetwork()
            return
        }
        errorMessage = Self.friendlyMessage(for: error)
        // Playing it again later starts afresh (a new address, a new download), not from the
        // state that just failed.
        if let id = current?.videoId, let source = sources[id] {
            source.cancel()
            sources[id] = nil
            let resolver = self.resolver
            Task { await resolver.invalidate(id) }
        }
        // A genuinely unplayable song (removed, region-locked) — not a bot check or a network blip.
        if case InnerTubeError.unplayable(let reason) = error, !reason.localizedCaseInsensitiveContains("bot"),
           let track = current, !track.isLocal {
            ContentFilter.shared.markUnavailable(track.videoId)
        }
        consecutiveFailures += 1
        // Something bigger is wrong (YouTube changed, a bot check): stop instead of racing through
        // the queue failing every song.
        guard consecutiveFailures < 5 else {
            errorMessage = Self.friendlyMessage(for: InnerTubeError.noAudio)
            player.pause()
            showPlayerState()
            return
        }
        guard let index = currentIndex, index + 1 < queue.count else {
            player.pause()
            showPlayerState()
            return
        }
        let failedId = queue[index].id
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if currentIndex.map({ queue[$0].id }) == failedId { next() }
        }
    }

    // MARK: Staying alive

    /// Songs that failed in a row (reset by one that plays).
    @ObservationIgnored private var consecutiveFailures = 0
    @ObservationIgnored private var stallTimer: Timer?
    /// Reloads of the current song after stalls, so a hopeless one gives up eventually.
    @ObservationIgnored private var stallRecoveries: (entry: UUID, count: Int)?

    /// Waiting for audio for long (a download that stopped, a dropped connection): reload the song
    /// from where it was rather than sit there silent.
    private func watchForStall() {
        stallTimer?.invalidate()
        stallTimer = nil
        guard player.timeControlStatus == .waitingToPlayAtSpecifiedRate, player.currentItem != nil,
              !CastController.shared.isActive else { return }
        let timer = Timer(timeInterval: 8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.recoverFromStall() }
        }
        RunLoop.main.add(timer, forMode: .common)
        stallTimer = timer
    }

    private func recoverFromStall() {
        guard player.timeControlStatus == .waitingToPlayAtSpecifiedRate, let index = currentIndex, queue.indices.contains(index) else { return }
        guard Connectivity.shared.isOnline else { waitForNetwork(); return }
        let entry = queue[index]
        let count = stallRecoveries?.entry == entry.id ? stallRecoveries!.count : 0
        guard count < 2 else {
            stallRecoveries = nil
            handleFailure(InnerTubeError.noAudio)
            return
        }
        stallRecoveries = (entry.id, count + 1)
        // Still downloading the whole song on a connection that's turned out slow: stream it
        // instead, from what's needed now.
        let id = entry.track.videoId
        if let source = sources[id], source.fetchesWholeFile, !source.isComplete, NetworkSpeed.shared.isSlow(for: 4 << 20) {
            source.cancel()
            sources[id] = nil
        }
        // A fresh player item from where it stopped; what's downloaded so far is kept.
        pendingSeek = playbackPosition > 1 ? playbackPosition : nil
        startCurrent(keepingPendingSeek: true)
    }

    /// Waiting for the connection to pick up the playing song again. Any other start (a skip,
    /// play pressed meanwhile) clears it, so a late return doesn't restart over what's playing.
    @ObservationIgnored private var networkWait: UUID?
    /// Retries while the Mac says it's online but YouTube can't be reached (backs off).
    @ObservationIgnored private var networkRetries = 0

    /// Offline: say so, and pick up from the same spot once the connection is back.
    private func waitForNetwork() {
        errorMessage = String(localized: "You're offline — playback continues when you're back online.")
        guard networkWait == nil, let index = currentIndex, queue.indices.contains(index) else { return }
        let wait = UUID()
        networkWait = wait
        let entryId = queue[index].id
        let position = playbackPosition
        let wasPlaying = isPlaying
        player.pause()
        showPlayerState()
        let delay = min(30, 3 * pow(2, Double(networkRetries)))
        networkRetries += 1
        Connectivity.shared.whenOnline(retryAfter: delay) { [weak self] in
            guard let self, self.networkWait == wait else { return }
            self.networkWait = nil
            self.errorMessage = nil
            guard let index = self.currentIndex, self.queue.indices.contains(index), self.queue[index].id == entryId else { return }
            self.pendingSeek = position > 1 ? position : nil
            self.startPausedOnce = !wasPlaying
            self.startCurrent(keepingPendingSeek: true)
        }
    }

    static func isNetworkError(_ error: Error) -> Bool {
        let networkCodes: Set<Int> = [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut,
                                      NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed,
                                      NSURLErrorInternationalRoamingOff, NSURLErrorDataNotAllowed]
        var current: NSError? = error as NSError
        // AVFoundation wraps the download's error; look through it.
        while let error = current {
            if error.domain == NSURLErrorDomain, networkCodes.contains(error.code) { return true }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// Users shouldn't see raw errors. Most failures are either one unavailable song (skip it)
    /// or YouTube having changed something (needs an app update).
    private static func friendlyMessage(for error: Error) -> String {
        switch error {
        case InnerTubeError.unplayable(let reason) where !reason.localizedCaseInsensitiveContains("bot"):
            return reason
        case let urlError as URLError where [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(urlError.code):
            return String(localized: "You're offline — songs you've played before still work.")
        default:
            return UpdateChecker.shared.updateAvailable
                ? String(localized: "Playback failed. A newer version of YT Musicfast is available.")
                : String(localized: "Playback failed — YouTube may have changed something.")
        }
    }

    private func extendQueueIfNeeded() {
        guard !offlineMode, let index = currentIndex, queue.count - index <= 3, extendingFor != generation else { return }
        if let token = radioContinuation {
            let gen = generation
            extendingFor = gen
            Task {
                defer { if extendingFor == gen { extendingFor = nil } }
                guard let result = try? await MusicAPI.radioContinuation(token), gen == generation else { return }
                radioContinuation = result.continuation
                if continuationIsContext { contextTrackIds.formUnion(result.tracks.map(\.videoId)) }
                appendUnique(result.tracks)
            }
        } else if autoplay, let last = queue.last {
            Task { await appendRadio(seed: last.track.videoId, replacingUpcoming: false) }
        }
    }

    private func appendRadio(seed videoId: String, replacingUpcoming: Bool) async {
        guard extendingFor != generation else { return }
        let gen = generation
        extendingFor = gen
        defer { if extendingFor == gen { extendingFor = nil } }
        guard let result = try? await MusicAPI.radio(videoId: videoId), gen == generation else { return }
        radioContinuation = result.continuation
        continuationIsContext = false
        if replacingUpcoming, let index = currentIndex, current?.videoId == videoId {
            queue = Array(queue[...index])
            radioTuners = result.tuners
            selectedTuner = result.selectedTuner
        }
        appendUnique(result.tracks)
    }

    /// Picks a tuning chip: the upcoming songs are replaced by that version of the radio,
    /// starting from what's playing now.
    func tuneRadio(_ tuner: RadioTuner) {
        guard let track = current, !track.isLocal, tuner.title != selectedTuner, !tuning else { return }
        let previous = selectedTuner
        selectedTuner = tuner.title
        tuning = true
        let gen = generation
        Task {
            defer { tuning = false }
            guard let result = try? await MusicAPI.radio(videoId: track.videoId, playlistId: tuner.playlistId, params: tuner.params ?? "wAEB"),
                  gen == generation, current?.videoId == track.videoId, let index = currentIndex else {
                if gen == generation { selectedTuner = previous }
                Router.shared.showToast(String(localized: "Couldn't change the radio"), icon: "exclamationmark.triangle.fill")
                return
            }
            queue = Array(queue[...index])
            radioContinuation = result.continuation
            continuationIsContext = false
            appendUnique(result.tracks)
            resyncUpcoming()
            saveSession()
        }
    }

    private func appendUnique(_ tracks: [Track]) {
        let known = Set(queue.map(\.track.videoId))
        // Radio and autoplay never bring back songs you disliked.
        var fresh = ContentFilter.shared.filter(tracks).filter {
            !known.contains($0.videoId) && !isDisliked($0) && (!offlineMode || Self.availableOffline($0))
        }
        guard !fresh.isEmpty else { return }
        if shuffle { fresh.shuffle() }
        queue += fresh.map { QueueEntry(track: $0) }
        if advanceWhenExtended, let index = currentIndex, index + 1 < queue.count {
            advanceWhenExtended = false
            next()
            return
        }
        if player.items().count <= 1 { enqueueNext() }
    }

    /// Returns as soon as the item is ready (or failed) — told by AVFoundation, not by checking
    /// every few milliseconds — or after `timeout` seconds.
    private static func untilDecided(_ item: AVPlayerItem, timeout: TimeInterval) async {
        guard item.status == .unknown else { return }
        final class Waiter: @unchecked Sendable {
            var continuation: CheckedContinuation<Void, Never>?
            var observation: NSKeyValueObservation?
            func finish() {
                observation?.invalidate()
                observation = nil
                continuation?.resume()
                continuation = nil
            }
        }
        let waiter = Waiter()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiter.continuation = continuation
                waiter.observation = item.observe(\.status, options: [.initial, .new]) { item, _ in
                    guard item.status != .unknown else { return }
                    DispatchQueue.main.async { waiter.finish() }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { waiter.finish() }
            }
        } onCancel: {
            // Another song was chosen meanwhile: stop waiting for this one.
            DispatchQueue.main.async { waiter.finish() }
        }
    }

    /// A song's download (kept in `sources`), with what its stream says about it remembered.
    private func makeSource(videoId: String, info: StreamInfo) -> ChunkedAudioSource {
        if let existing = sources[videoId] { return existing }
        if let loudness = info.loudnessDb { AudioCache.setLoudness(loudness, for: videoId) }
        if let length = info.duration { AudioCache.setDuration(length, for: videoId) }
        if let stats = info.statsURL { statsURLs[videoId] = stats }
        let resolver = self.resolver
        let streaming = NetworkSpeed.shared.isSlow(for: info.opus?.contentLength ?? info.contentLength)
        let source = ChunkedAudioSource(videoId: videoId, info: info, streaming: streaming) {
            await resolver.invalidate(videoId)
            return try await resolver.resolve(videoId: videoId)
        }
        sources[videoId] = source
        return source
    }

    private func pruneSources() {
        guard let index = currentIndex else { return }
        let keep = Set(queue[index...].prefix(2).map(\.track.videoId))
        for (id, source) in sources where !keep.contains(id) {
            source.cancel()
            sources[id] = nil
        }
    }

    private func tick(_ time: CMTime) {
        if time.isNumeric, seeksInFlight == 0 {
            // Publishing the position redraws every progress bar; the clock only changes once a
            // second, so update at 1 Hz — except for synced lyrics, which want finer timing.
            let seconds = time.seconds
            if Router.shared.route == .lyrics || (Router.shared.showFullPlayer && TVPlayerState.shared.showsLyrics) || seconds < currentTime || seconds - currentTime >= 1 {
                currentTime = seconds
            }
        }
        if isPlaying, Date().timeIntervalSince(lastSave) > 10 { saveSession() }
        if time.isNumeric {
            checkSleepTimer(position: time.seconds)
            trackListening(position: time.seconds)
            skipNonMusicIfNeeded(position: time.seconds)
        }
        // Not over AirPlay: the route belongs to this player, and a crossfade hands the music to a
        // second one (which would play on the Mac). Songs change gaplessly there instead.
        // Not while a pause is fading out (the next song would play on) or a Song/Video switch is
        // about to hand over to another player.
        if crossfadeSeconds > 0, isPlaying, fadingDeck == nil, afterFadeOut == nil, versionTarget == nil, repeatMode != .one,
           !player.isExternalPlaybackActive,
           duration > crossfadeSeconds * 3, currentTime >= duration - crossfadeSeconds, player.items().count > 1 {
            startCrossfade()
        }
    }

    /// Feeds the stats with time actually heard (seeks and pauses don't count).
    private func trackListening(position: TimeInterval) {
        defer { lastTickPosition = isPlaying && seeksInFlight == 0 ? position : nil }
        guard isPlaying, seeksInFlight == 0, let last = lastTickPosition, let index = currentIndex,
              queue.indices.contains(index) else { return }
        let delta = position - last
        guard delta > 0, delta < 1.5 else { return }
        let entry = queue[index]
        PlayTracker.shared.advance(entry: entry.id, track: entry.track, by: delta, privateSession: privateSession)
        WatchTime.shared.heard(entry: entry.id, track: entry.track, from: last, to: position)
    }

    private func loadSkipSegments() {
        skipSegments = []
        skippedSegments = []
        guard skipNonMusic, !offlineMode, let track = current, !track.isLocal else { return }
        let videoId = track.videoId
        Task {
            let segments = await SponsorBlock.segments(for: videoId)
            if current?.videoId == videoId { skipSegments = segments }
        }
    }

    private func skipNonMusicIfNeeded(position: TimeInterval) {
        guard skipNonMusic, !skipSegments.isEmpty, isPlaying, seeksInFlight == 0, remoteControl == nil,
              let segment = skipSegments.first(where: { position >= $0.start && position < $0.end - 0.5 }),
              !skippedSegments.contains(segment) else { return }
        skippedSegments.insert(segment)
        if duration > 0, segment.end >= duration - 2 {
            next()
        } else {
            performSeek(to: segment.end)
        }
        Router.shared.showToast(String(localized: "Skipped a non-music section"), icon: "forward.fill")
    }

    /// Loudness normalization: YouTube reports how many dB a track is above its reference level.
    private func applyVolume() {
        var gain = 1.0
        if normalizeVolume, let videoId = current?.videoId, let loudness = AudioCache.loudness(for: videoId), loudness > 0 {
            gain = pow(10, -loudness / 20)
        }
        player.volume = Float(userLevel * gain * fadeLevel * sleepFadeLevel * transportLevel)
    }
}

#if DEBUG
extension PlayerController {
    /// What the playback stress test (scripts/playback-stress.py, via `ytmusicfast debug-state`)
    /// checks after each step. Debug builds only.
    var debugState: [String: Any] {
        let index = currentIndex ?? -1
        let entry = queue.indices.contains(index) ? queue[index] : nil
        let itemEntry = player.currentItem.flatMap { itemEntries[ObjectIdentifier($0)] }
        let timeControl = switch player.timeControlStatus {
        case .paused: "paused"
        case .playing: "playing"
        default: "waiting"
        }
        return [
            "index": index,
            "queueCount": queue.count,
            "videoId": entry?.track.videoId ?? "",
            "songVideoId": currentSong?.videoId ?? "",
            "title": entry?.track.title ?? "",
            "isVideo": entry?.track.isVideo ?? false,
            "nextVideoId": upNext.first?.track.videoId ?? "",
            "playing": isPlaying,
            "buffering": isBuffering,
            "loading": loadingEntry != nil,
            "loadStartsPaused": loadStartsPaused,
            "timeControl": timeControl,
            "rate": player.rate,
            "position": playbackPosition,
            "shownPosition": currentTime,
            "duration": duration,
            "hasItem": player.currentItem != nil,
            "itemMatchesEntry": entry != nil && itemEntry == entry?.id,
            "deckItems": player.items().count,
            "crossfading": fadingDeck != nil,
            "crossfade": crossfadeSeconds,
            "repeat": repeatMode.rawValue,
            "videoMode": VideoController.shared.videoMode,
            "versionTarget": versionTarget.map { $0 ? "video" : "song" } ?? "",
            "offlineMode": offlineMode,
            "autoplay": autoplay,
            "advanceWhenExtended": advanceWhenExtended,
            "extending": extendingFor == generation,
            "waitingForNetwork": networkWait != nil,
            "error": errorMessage ?? "",
            "outputDevice": outputDeviceUID ?? "",
            "volume": volume,
        ]
    }
}
#endif

/// Whether this Mac is online, from the system's own network path updates (no polling).
@MainActor
final class Connectivity {
    static let shared = Connectivity()

    private(set) var isOnline = true
    private let monitor = NWPathMonitor()
    private var waiting: [() -> Void] = []

    private init() {
        monitor.pathUpdateHandler = { path in
            let online = path.status == .satisfied
            NetworkSpeed.shared.networkChanged(lowDataMode: path.isConstrained)
            Task { @MainActor in Connectivity.shared.update(online) }
        }
        monitor.start(queue: .main)
    }

    /// Runs `action` once the connection is back — or, when the system says it already is (but a
    /// request still failed), after `retryAfter` seconds.
    func whenOnline(retryAfter delay: TimeInterval = 3, _ action: @escaping () -> Void) {
        if isOnline, monitor.currentPath.status == .satisfied {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        } else {
            waiting.append(action)
        }
    }

    private func update(_ online: Bool) {
        isOnline = online
        guard online, !waiting.isEmpty else { return }
        let actions = waiting
        waiting = []
        // A moment for DNS and routes to settle after the network comes back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { actions.forEach { $0() } }
    }
}
