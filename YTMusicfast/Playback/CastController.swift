import AppKit
import Foundation
import Network
import Observation
import os

private let castLog = Logger(subsystem: "dev.ytmusicfast", category: "Cast")

/// A Chromecast, Google TV or Cast speaker on the network.
struct CastDevice: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var model: String
    var endpoint: NWEndpoint

    /// TVs show a picture; Nest/Home speakers and Cast Audio don't.
    var isSpeaker: Bool {
        let model = model.lowercased()
        return model.contains("audio") || model.contains("speaker") || model.contains("home") || model.contains("nest") && !model.contains("hub")
    }

    var symbol: String { isSpeaker ? "hifispeaker" : "tv" }
}

/// Google Cast, without Google's SDK (it has none for Mac apps): finds Cast devices with Bonjour,
/// opens the TLS channel, launches Google's standard media receiver and plays what's playing here
/// on it. The queue stays in this app: the device holds the song playing and the next one (so it
/// moves on without a new load, and shows what's up next), both from `CastMediaServer`, and its
/// status drives the player bar.
///
/// Discovery runs only while the Connect panel is open; nothing runs while not casting.
@MainActor
@Observable
final class CastController {
    static let shared = CastController()

    enum State: Equatable { case idle, connecting, connected, failed(String) }

    private(set) var devices: [CastDevice] = []
    /// Why Cast devices can't be looked for (macOS's Local Network permission), if so.
    private(set) var needsLocalNetworkPermission = false
    private(set) var searching = false
    /// The current search has looked once (so an empty list means none were found).
    private(set) var searchedOnce = false
    private(set) var device: CastDevice?
    private(set) var state: State = .idle
    /// Playing on a Cast device (the player sends everything there).
    var isActive: Bool { device != nil && state == .connected }

    // Receiver playback, as last reported (positions are extrapolated in between).
    private(set) var remotePlaying = false
    private(set) var remoteBuffering = false
    @ObservationIgnored private var remoteTime: TimeInterval = 0
    @ObservationIgnored private var remoteTimeAt = Date()

    @ObservationIgnored private var discovery: Task<Void, Never>?
    @ObservationIgnored private var browsers = 0
    @ObservationIgnored private var connection: NWConnection?
    @ObservationIgnored private var heartbeat: Timer?
    @ObservationIgnored private var requestId = 1
    @ObservationIgnored private var transportId: String?
    @ObservationIgnored private var sessionId: String?
    @ObservationIgnored private var mediaSessionId: Int?
    /// The song loaded on the receiver, to tell its "finished" from an older one's.
    @ObservationIgnored private(set) var loadedVideoId: String?
    /// What's loaded on the receiver, to load its sound alone instead if the video doesn't play.
    @ObservationIgnored private var loadedTrack: Track?
    @ObservationIgnored private var loadedAsVideo = false
    /// The video loaded has played (so a later error is the stream's, not the device refusing it).
    @ObservationIgnored private var videoPlayed = false
    /// This device didn't play a music video: songs' sound only from now on, while connected.
    @ObservationIgnored private var videoRefused = false
    @ObservationIgnored private var onReady: (() -> Void)?
    /// Keeps this Mac from sleeping while casting: the device plays from its media server (the
    /// Mac's own player is paused, so nothing else would).
    @ObservationIgnored private var awake: NSObjectProtocol?
    /// What to resume locally if casting stops.
    @ObservationIgnored private var lastKnownPosition: TimeInterval = 0
    @ObservationIgnored private var loadGeneration = 0
    /// Media sessions of songs skipped away from.
    @ObservationIgnored private var staleSessionIds: Set<Int> = []
    /// Play/pause asked for and not yet confirmed by the device, and whether it was sent.
    @ObservationIgnored private var pendingPlaying: Bool?
    @ObservationIgnored private var pendingPlayingSent = false
    @ObservationIgnored private var pendingSince = Date()
    /// A seek asked for before the device had the song.
    @ObservationIgnored private var pendingSeek: TimeInterval?
    /// A song was just loaded and the device hasn't started (or paused) it yet.
    @ObservationIgnored private var settling = false
    @ObservationIgnored private var settlingSince = Date()
    /// The latest LOAD's request id: the device echoes it in the status that starts its session,
    /// which tells that session from one of a load a quick skip replaced.
    @ObservationIgnored private var loadRequestId: Int?
    /// The loaded song's address, and whether it went with its lyrics track (and that's on).
    @ObservationIgnored private var loadedContentId: String?
    @ObservationIgnored private var loadedWithLyrics = false
    @ObservationIgnored private var lyricsShown = false

    // The device's queue (see `CastQueueSync`): its items as last listed, the one playing, and the
    // next song as the app wants it there.
    @ObservationIgnored private var deviceItems: [CastQueueSync.Item] = []
    @ObservationIgnored private var currentItemId: Int?
    /// Items the device played before the one playing (their late reports are ignored).
    @ObservationIgnored private var playedItemIds: Set<Int> = []
    /// Items asked to be taken off, until the device says they're gone (a status sent before it
    /// got to them still lists them).
    @ObservationIgnored private var removedItemIds: Set<Int> = []
    @ObservationIgnored private var wantedNext: QueuedSong?
    @ObservationIgnored private var nextGeneration = 0
    /// The next song's item is to be replaced (sent again) even though its address is the same.
    @ObservationIgnored private var replaceNext = false
    /// A QUEUE_INSERT on its way: its request id, the address it adds, and when it went.
    @ObservationIgnored private var insertRequestId: Int?
    @ObservationIgnored private var insertedContentId: String?
    @ObservationIgnored private var insertSentAt = Date()
    /// Skipped to the song queued on the device: the item it's moving to, and the request.
    @ObservationIgnored private var jumpItemId: Int?
    @ObservationIgnored private var jumpRequestId: Int?

    /// Playing through the TV's own YouTube app (see `TVYouTubeApp`): the TV fetches the songs
    /// itself and this Mac only sends it commands, so this Mac may sleep meanwhile.
    private(set) var viaYouTubeApp = false
    /// The app launched (or being launched) on the device: Google's media receiver or YouTube's.
    @ObservationIgnored private var launchedApp = CastController.mediaReceiver
    @ObservationIgnored private var lounge: YouTubeLounge?
    @ObservationIgnored private var pairingTimeout: Task<Void, Never>?
    @ObservationIgnored private var tvSending: Task<Void, Never>?
    /// The videos last sent to the TV (the first to play, the queue's next ones after it), and the
    /// one the TV last said it's on.
    @ObservationIgnored private var sentVideoIds: [String] = []
    @ObservationIgnored private var tvVideoId: String?
    /// The queue's next song, asked for while the TV was still starting the song (see `tvSetNext`).
    @ObservationIgnored private var tvWantedNext: Track?
    /// Switching between the two apps mid-song: where the new one carries on from.
    @ObservationIgnored private var handOver: (position: TimeInterval, playing: Bool)?

    /// A song sent to the device's queue, to play after the one playing.
    private struct QueuedSong {
        var track: Track
        var contentId: String
        /// Asked for as its music video (`castsVideo`) and with its lyrics, and sent as that.
        var askedVideo: Bool
        var askedLyrics: Bool
        var asVideo: Bool
        var withLyrics: Bool
        var media: [String: Any]
    }

    /// Synced lyrics as captions over music videos on a TV (Settings → Playback).
    var lyricsOnTV = UserDefaults.standard.object(forKey: "castLyrics") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(lyricsOnTV, forKey: "castLyrics")
            lyricsSettingChanged()
        }
    }

    /// Casting a music video to a TV: the lyrics buttons show or hide its captions there.
    var lyricsButtonsControlTV: Bool {
        isActive && device?.isSpeaker == false && PlayerController.shared.current.map(castsVideo) == true
    }

    func toggleLyricsOnTV() {
        lyricsOnTV.toggle()
        let name = device?.name ?? ""
        Router.shared.showToast(lyricsOnTV ? String(localized: "Lyrics on \(name)") : String(localized: "Lyrics off on \(name)"),
                                icon: "music.mic")
    }

    /// Lyrics go to the device: the setting is on and it's a TV.
    var wantsLyrics: Bool { lyricsOnTV && device?.isSpeaker == false }

    /// A song's lyrics go with it: as captions over its music video (the receiver shows none over
    /// a song's cover).
    func wantsLyrics(_ track: Track) -> Bool { wantsLyrics && castsVideo(track) }

    private static let senderId = "sender-ytmusicfast"
    private static let mediaReceiver = "CC1AD845"
    private enum Namespace {
        static let connection = "urn:x-cast:com.google.cast.tp.connection"
        static let heartbeat = "urn:x-cast:com.google.cast.tp.heartbeat"
        static let receiver = "urn:x-cast:com.google.cast.receiver"
        static let media = "urn:x-cast:com.google.cast.media"
    }

    private init() {}

    /// Where the receiver is in the song now.
    var position: TimeInterval {
        remotePlaying && !remoteBuffering ? remoteTime + Date().timeIntervalSince(remoteTimeAt) : remoteTime
    }

    // MARK: Discovery

    /// The Connect panel opened: look for devices until it closes.
    func startDiscovery() {
        browsers += 1
        guard discovery == nil else { return }
        searching = true
        searchedOnce = false
        discovery = Task {
            var seen: [String: (device: CastDevice, at: Date)] = [:]
            while !Task.isCancelled {
                let answer = await Task.detached(priority: .utility) { MDNS.browse("_googlecast._tcp.local") }.value
                guard !Task.isCancelled else { break }
                needsLocalNetworkPermission = answer == nil
                for service in answer ?? [] {
                    let id = service.txt["id"] ?? service.instance
                    let device = CastDevice(id: id, name: service.txt["fn"] ?? "Chromecast", model: service.txt["md"] ?? "",
                                            endpoint: .hostPort(host: NWEndpoint.Host(service.address), port: NWEndpoint.Port(rawValue: service.port) ?? 8009))
                    seen[id] = (device, Date())
                }
                // A device that stops answering for a minute has gone (unplugged, off the network).
                seen = seen.filter { Date().timeIntervalSince($0.value.at) < 60 }
                devices = seen.values.map(\.device).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                if !searchedOnce { searchedOnce = true }
                castLog.notice("cast discovery: \(self.devices.count) devices")
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    func stopDiscovery() {
        browsers = max(0, browsers - 1)
        guard browsers == 0 else { return }
        discovery?.cancel()
        discovery = nil
        searching = false
    }

    // MARK: Connecting

    /// Starts casting to a device: what's playing moves there, from where it is.
    func cast(to device: CastDevice) {
        if self.device?.id == device.id, state == .connected { return }
        if self.device != nil { disconnect(resumeLocally: false) }
        self.device = device
        videoRefused = false
        launchedApp = TVYouTubeApp.shared.isOn(for: device) ? Lounge.castAppId : Self.mediaReceiver
        state = .connecting
        let tls = NWProtocolTLS.Options()
        // Cast devices present a self-signed certificate (as with Google's own senders).
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, .main)
        let connection = NWConnection(to: device.endpoint, using: NWParameters(tls: tls, tcp: .init()))
        connection.stateUpdateHandler = { state in
            Task { @MainActor in CastController.shared.connectionChanged(state) }
        }
        self.connection = connection
        connection.start(queue: .main)
        receive(on: connection)
    }

    /// Stops casting; unless told otherwise, the music carries on on this Mac from the same point.
    func disconnect(resumeLocally: Bool = true) {
        guard device != nil else { return }
        let wasPlaying = remotePlaying
        let position = self.position
        // Without the Cast connection (this Mac slept) the YouTube app can't be closed: it pauses.
        endYouTubeApp(pausingTV: connection == nil)
        viaYouTubeApp = false
        handOver = nil
        if let sessionId { send(Namespace.receiver, ["type": "STOP", "sessionId": sessionId], to: "receiver-0") }
        if let transportId { send(Namespace.connection, ["type": "CLOSE"], to: transportId) }
        heartbeat?.invalidate()
        heartbeat = nil
        let connection = self.connection
        // Let the goodbyes go out first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { connection?.cancel() }
        self.connection = nil
        device = nil
        state = .idle
        transportId = nil
        sessionId = nil
        mediaSessionId = nil
        staleSessionIds = []
        pendingPlaying = nil
        pendingSeek = nil
        loadedVideoId = nil
        loadedTrack = nil
        loadedAsVideo = false
        loadedContentId = nil
        loadedWithLyrics = false
        lyricsShown = false
        resetQueue()
        wantedNext = nil
        nextGeneration += 1
        remotePlaying = false
        if let awake { ProcessInfo.processInfo.endActivity(awake) }
        awake = nil
        CastMediaServer.shared.stop()
        TVYouTubeApp.shared.castEnded()
        PlayerController.shared.castingEnded(at: position, playing: wasPlaying && resumeLocally)
    }

    private func connectionChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            send(Namespace.connection, ["type": "CONNECT"], to: "receiver-0")
            send(Namespace.receiver, ["type": "LAUNCH", "appId": launchedApp], to: "receiver-0")
            if launchedApp == Lounge.castAppId { startPairingTimeout() }
            heartbeat?.invalidate()
            let timer = Timer(timeInterval: 5, repeats: true) { _ in
                MainActor.assumeIsolated { _ = CastController.shared.send(Namespace.heartbeat, ["type": "PING"], to: "receiver-0") }
            }
            RunLoop.main.add(timer, forMode: .common)
            heartbeat = timer
        case .failed(let error):
            if viaYouTubeApp { castChannelLost() } else { fail(error.localizedDescription) }
        case .cancelled:
            guard device != nil, self.state != .idle else { break }
            if viaYouTubeApp { castChannelLost() } else { fail(String(localized: "The connection was closed")) }
        default:
            break
        }
    }

    private func fail(_ reason: String) {
        let name = device?.name ?? "the device"
        Router.shared.showToast(String(localized: "Couldn't play on \(name)"), icon: "exclamationmark.triangle.fill")
        state = .failed(reason)
        disconnect(resumeLocally: true)
    }

    // MARK: Playing

    /// Whether a song goes to the device as its music video (Video mode, a TV, and a device that
    /// plays them), rather than as sound only.
    func castsVideo(_ track: Track) -> Bool {
        track.isVideo && !track.isLocal && VideoController.shared.videoMode && device?.isSpeaker == false && !videoRefused
    }

    /// Loads a song on the receiver (the player calls this for every song while casting).
    /// `soundOnly`: its sound even if it's a music video (the video didn't play).
    func load(_ track: Track, at position: TimeInterval, autoplay: Bool, soundOnly: Bool = false) {
        let position = position.isFinite ? max(0, position) : 0
        if viaYouTubeApp { loadOnTV(track, at: position, autoplay: autoplay); return }
        // Already queued on the device (a skip to the next song, or its end): it moves on to it,
        // sooner than a new load.
        if !soundOnly, autoplay, position < 1, jumpToQueued(track) { return }
        // A newer load (quick skips) makes this one stale: only the latest reaches the device.
        loadGeneration += 1
        let generation = loadGeneration
        // Shown at once; the device's own reports take over once it has the song.
        loadedVideoId = track.videoId
        loadedTrack = track
        loadedAsVideo = false
        loadedContentId = nil
        loadedWithLyrics = false
        lyricsShown = false
        videoPlayed = false
        remoteTime = position
        remoteTimeAt = Date()
        remoteBuffering = true
        remotePlaying = autoplay
        pendingPlaying = nil
        pendingSeek = nil
        settling = true
        settlingSince = Date()
        loadRequestId = nil
        // The old song's session goes on reporting for a moment: ignore it from now on.
        if staleSessionIds.count > 20 { staleSessionIds = [] }
        if let mediaSessionId { staleSessionIds.insert(mediaSessionId) }
        mediaSessionId = nil
        // A load replaces the device's queue; the next song goes back on once this one plays.
        resetQueue()
        if !soundOnly, wantsLyrics(track) { Task { await lookUpLyrics(track) } }
        let send = { [weak self] in
            guard let self, self.transportId != nil else { return }
            Task {
                let made = await self.media(for: track, soundOnly: soundOnly)
                guard generation == self.loadGeneration else { return }
                guard let made else {
                    self.fail(String(localized: "This Mac has no network address"))
                    return
                }
                guard let transportId = self.transportId else { return }
                self.loadedAsVideo = made.asVideo
                self.loadedContentId = made.media["contentId"] as? String
                self.loadedWithLyrics = made.withLyrics
                self.lyricsShown = made.withLyrics
                castLog.notice("load \(track.videoId, privacy: .public) at \(position) as \(made.asVideo ? "video" : "sound", privacy: .public)\(made.withLyrics ? " with lyrics" : "", privacy: .public)")
                self.loadRequestId = self.send(Namespace.media, ["type": "LOAD", "media": made.media, "autoplay": autoplay, "currentTime": position,
                                                                 "activeTrackIds": made.withLyrics ? [Self.lyricsTrackId] : []], to: transportId)
            }
        }
        if transportId != nil { send() } else { onReady = send }
    }

    private static let lyricsTrackId = 1

    /// What the device gets for a song: its address (the music video as HLS, or the sound), what
    /// it shows about it, and its synced lyrics as a text track. Nil without a network address.
    private func media(for track: Track, soundOnly: Bool) async -> (media: [String: Any], asVideo: Bool, withLyrics: Bool)? {
        // A music video as HLS; its sound alone when it can't be (see CastVideo).
        let video = !soundOnly && castsVideo(track) ? await CastMediaServer.shared.videoURL(for: track) : nil
        var sound: URL?
        if video == nil { sound = try? await CastMediaServer.shared.url(for: track) }
        guard let url = video ?? sound else { return nil }
        var metadata: [String: Any] = ["metadataType": 3, "title": track.title, "artist": track.artistLine]
        if let album = track.album?.name { metadata["albumName"] = album }
        if let art = Artwork.url(track.thumbnail, size: 720) { metadata["images"] = [["url": art.absoluteString]] }
        var media: [String: Any] = ["contentId": url.absoluteString, "contentType": "audio/mp4", "streamType": "BUFFERED", "metadata": metadata]
        if video != nil {
            // Fragmented MP4 pieces (the receiver otherwise expects MPEG-TS from HLS).
            media["contentType"] = "application/x-mpegurl"
            media["hlsSegmentFormat"] = "fmp4"
            media["hlsVideoSegmentFormat"] = "fmp4"
            // As a video, not a music track: the receiver then shows the picture full screen
            // (its music layout shows the artwork over it, and its bar stays up).
            metadata["metadataType"] = 0
            metadata["subtitle"] = track.artistLine
            media["metadata"] = metadata
        }
        if let duration = track.duration, duration.isFinite, duration > 0 { media["duration"] = duration }
        // Lyrics over a music video (the receiver shows no captions with a song's cover), unless
        // it's known to have no synced ones (still being looked up, the track goes along and is
        // turned off if none turn up).
        var withLyrics = false
        if video != nil, wantsLyrics, CastMediaServer.shared.hasSyncedLyrics(track.videoId) != false,
           let lyrics = CastMediaServer.shared.lyricsURL(for: track) {
            media["tracks"] = [["trackId": Self.lyricsTrackId, "type": "TEXT", "subtype": "SUBTITLES", "name": String(localized: "Lyrics"),
                                "trackContentId": lyrics.absoluteString, "trackContentType": "text/vtt"]]
            media["textTrackStyle"] = ["fontScale": 1.2, "foregroundColor": "#FFFFFFFF", "backgroundColor": "#00000099", "edgeType": "NONE"]
            withLyrics = true
        }
        return (media, video != nil, withLyrics)
    }

    /// Looks up a song's lyrics while it loads; with none, its lyrics track is turned off.
    private func lookUpLyrics(_ track: Track) async {
        await CastMediaServer.shared.prepareLyrics(track)
        if loadedVideoId == track.videoId { applyLyrics() }
    }

    /// Shows or hides the lyrics track of the song on the device, as the setting and the lyrics
    /// found say (only a song loaded with the track has one to show).
    private func applyLyrics() {
        guard loadedWithLyrics, let videoId = loadedVideoId, !settling else { return }
        let show = lyricsOnTV && CastMediaServer.shared.hasSyncedLyrics(videoId) != false
        guard show != lyricsShown, mediaCommand("EDIT_TRACKS_INFO", ["activeTrackIds": show ? [Self.lyricsTrackId] : []]) != nil else { return }
        lyricsShown = show
        castLog.notice("lyrics \(show ? "on" : "off", privacy: .public) for \(videoId, privacy: .public)")
    }

    private func lyricsSettingChanged() {
        guard isActive else { return }
        applyLyrics()
        // The next song goes again, with or without its lyrics.
        if let wanted = wantedNext {
            wantedNext = nil
            replaceNext = true
            setNext(wanted.track)
        }
    }

    // MARK: The device's queue

    /// The song to play after this one on the device (nil for none: the end of the queue, Repeat
    /// One). The player calls this whenever its next song may have changed.
    func setNext(_ track: Track?) {
        if viaYouTubeApp { tvSetNext(track); return }
        guard isActive, let track else {
            nextGeneration += 1
            if wantedNext != nil {
                wantedNext = nil
                syncQueue()
            }
            return
        }
        let askedVideo = castsVideo(track)
        let askedLyrics = wantsLyrics(track) && CastMediaServer.shared.hasSyncedLyrics(track.videoId) != false
        if let wanted = wantedNext, wanted.track.videoId == track.videoId, wanted.askedVideo == askedVideo,
           wanted.askedLyrics == askedLyrics { return }
        nextGeneration += 1
        let generation = nextGeneration
        Task {
            guard let made = await media(for: track, soundOnly: false), generation == nextGeneration, isActive,
                  let contentId = made.media["contentId"] as? String else { return }
            wantedNext = QueuedSong(track: track, contentId: contentId, askedVideo: askedVideo, askedLyrics: askedLyrics,
                                    asVideo: made.asVideo, withLyrics: made.withLyrics, media: made.media)
            syncQueue()
        }
    }

    /// A new load replaces the device's queue: nothing known about it until the device says.
    private func resetQueue() {
        deviceItems = []
        currentItemId = nil
        playedItemIds = []
        removedItemIds = []
        insertRequestId = nil
        insertedContentId = nil
        jumpItemId = nil
        jumpRequestId = nil
        replaceNext = false
    }

    /// Makes the device's queue match: the playing song, then the next one (once the song playing
    /// has started, so nothing gets in the way of it).
    private func syncQueue() {
        guard let transportId, let mediaSessionId, currentItemId != nil, !settling, jumpItemId == nil else { return }
        // An insert the device never answered is given up on.
        if insertRequestId != nil, Date().timeIntervalSince(insertSentAt) > 8 {
            insertRequestId = nil
            insertedContentId = nil
        }
        var plan = CastQueueSync.plan(items: deviceItems, currentItemId: currentItemId, next: replaceNext ? nil : wantedNext?.contentId,
                                      inserting: insertRequestId != nil)
        if replaceNext, insertRequestId == nil {
            replaceNext = false
            plan.insert = wantedNext != nil
        }
        if !plan.remove.isEmpty {
            send(Namespace.media, ["type": "QUEUE_REMOVE", "mediaSessionId": mediaSessionId, "itemIds": plan.remove], to: transportId)
            deviceItems.removeAll { plan.remove.contains($0.id) }
            removedItemIds.formUnion(plan.remove)
            castLog.notice("queue: removed \(plan.remove.map(String.init).joined(separator: ","), privacy: .public)")
        }
        guard plan.insert, let next = wantedNext else { return }
        var item: [String: Any] = ["media": next.media, "autoplay": true, "preloadTime": 20]
        if next.withLyrics { item["activeTrackIds"] = [Self.lyricsTrackId] }
        insertRequestId = send(Namespace.media, ["type": "QUEUE_INSERT", "mediaSessionId": mediaSessionId, "items": [item]], to: transportId)
        insertedContentId = next.contentId
        insertSentAt = Date()
        castLog.notice("queue: next is \(next.track.videoId, privacy: .public) as \(next.asVideo ? "video" : "sound", privacy: .public)")
    }

    /// The device's queue as it lists it: in a status (`items`), or as ids alone (QUEUE_ITEM_IDS,
    /// QUEUE_CHANGE). An item that's new is the one being inserted.
    private func learnItems(_ listed: [(id: Int, contentId: String?)], complete: Bool) {
        if complete { removedItemIds.formIntersection(listed.map(\.id)) }
        let listed = listed.filter { !removedItemIds.contains($0.id) }
        var items = complete ? [] : deviceItems
        // Inserted items go at the end: the last one not known yet.
        let inserted = listed.last { item in
            item.contentId == nil && item.id != currentItemId && !deviceItems.contains { $0.id == item.id }
        }?.id
        for (id, contentId) in listed {
            let known = deviceItems.first { $0.id == id }?.contentId
            var address = contentId ?? known
            if address == nil, id == currentItemId { address = loadedContentId }
            if address == nil, id == inserted, let insertedContentId {
                address = insertedContentId
                self.insertedContentId = nil
            }
            items.removeAll { $0.id == id }
            items.append(.init(id: id, contentId: address ?? ""))
        }
        if let inserted = insertedContentId, items.contains(where: { $0.contentId == inserted && $0.id != currentItemId }) {
            insertedContentId = nil
        }
        if insertedContentId == nil { insertRequestId = nil }
        deviceItems = items
    }

    /// Skips to the song queued on the device, if it's this one: it's already there (and loading
    /// near the end of the song before), so it starts sooner than a new load.
    private func jumpToQueued(_ track: Track) -> Bool {
        guard let next = wantedNext, next.track.videoId == track.videoId, next.askedVideo == castsVideo(track),
              !settling, jumpItemId == nil,
              let item = deviceItems.first(where: { $0.id != currentItemId && $0.contentId == next.contentId }),
              let request = mediaCommand("QUEUE_UPDATE", ["currentItemId": item.id]) else { return false }
        castLog.notice("skip to queued \(track.videoId, privacy: .public) (item \(item.id))")
        loadGeneration += 1
        becameCurrent(next)
        remoteTime = 0
        remoteTimeAt = Date()
        remoteBuffering = true
        remotePlaying = true
        pendingPlaying = nil
        pendingSeek = nil
        settling = true
        settlingSince = Date()
        loadRequestId = nil
        jumpItemId = item.id
        jumpRequestId = request
        return true
    }

    /// The queued song is the one playing now (skipped to, or the device moved on by itself).
    private func becameCurrent(_ next: QueuedSong) {
        loadedVideoId = next.track.videoId
        loadedTrack = next.track
        loadedAsVideo = next.asVideo
        loadedContentId = next.contentId
        loadedWithLyrics = next.withLyrics
        lyricsShown = next.withLyrics
        videoPlayed = false
        wantedNext = nil
        nextGeneration += 1
    }

    /// The jump to the queued song didn't happen: it loads the usual way.
    private func jumpFailed() {
        guard jumpItemId != nil, let track = loadedTrack else { return }
        castLog.notice("skip to queued \(track.videoId, privacy: .public) didn't happen: loading it")
        jumpItemId = nil
        jumpRequestId = nil
        load(track, at: 0, autoplay: true)
    }

    /// Play and pause show at once and reach the device as soon as it can take them (right after
    /// a song starts it can't yet); until the device confirms, its reports don't undo them.
    func play() { request(playing: true) }
    func pause() { request(playing: false) }

    private func request(playing: Bool) {
        // Freeze (or restart) the clock where it is.
        remoteTime = position
        remoteTimeAt = Date()
        remotePlaying = playing
        if !playing { remoteBuffering = false }
        pendingPlaying = playing
        pendingSince = Date()
        pendingPlayingSent = viaYouTubeApp ? tvCommand(playing ? .play : .pause) : mediaCommand(playing ? "PLAY" : "PAUSE") != nil
        PlayerController.shared.castStatusChanged()
    }

    func seek(to seconds: TimeInterval) {
        remoteTime = seconds
        remoteTimeAt = Date()
        let sent = viaYouTubeApp ? tvCommand(.seek(seconds)) : mediaCommand("SEEK", ["currentTime": seconds]) != nil
        pendingSeek = sent ? nil : seconds
    }

    /// The receiver's own volume (0…1), like the TV's.
    func setVolume(_ level: Double, muted: Bool) {
        // The device's volume needs the Cast connection; without it, the YouTube app's own.
        if viaYouTubeApp, connection == nil {
            _ = tvCommand(.setVolume(muted ? 0 : Int((min(1, max(0, level)) * 100).rounded())))
            return
        }
        send(Namespace.receiver, ["type": "SET_VOLUME", "volume": ["level": min(1, max(0, level)), "muted": muted]], to: "receiver-0")
    }

    /// Sends a command for the song on the device; its request id, nil when there's no session to
    /// send it to yet.
    @discardableResult
    private func mediaCommand(_ type: String, _ extra: [String: Any] = [:]) -> Int? {
        guard let transportId, let mediaSessionId else { return nil }
        var payload = extra
        payload["type"] = type
        payload["mediaSessionId"] = mediaSessionId
        return send(Namespace.media, payload, to: transportId)
    }

    // MARK: Messages

    /// Sends a message; returns the request id it carries (nil when not sent or not numbered).
    @discardableResult
    private func send(_ namespace: String, _ payload: [String: Any], to destination: String) -> Int? {
        guard let connection else { return nil }
        var payload = payload
        var id: Int?
        if payload["type"] as? String != "PING", payload["type"] as? String != "PONG",
           payload["type"] as? String != "CONNECT", payload["type"] as? String != "CLOSE" {
            payload["requestId"] = requestId
            id = requestId
            requestId += 1
        }
        // JSONSerialization raises an Objective-C exception (which `try?` doesn't catch) on NaN or
        // infinite numbers: check first rather than take the app down.
        guard JSONSerialization.isValidJSONObject(payload), let json = try? JSONSerialization.data(withJSONObject: payload) else {
            castLog.error("not sent, invalid JSON: \(payload["type"] as? String ?? "?", privacy: .public)")
            return nil
        }
        let message = CastMessage(sourceId: Self.senderId, destinationId: destination, namespace: namespace,
                                  payload: String(decoding: json, as: UTF8.self))
        connection.send(content: message.framed(), completion: .contentProcessed { _ in })
        return id
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, done, error in
            guard let header, header.count == 4, error == nil, !done else { return }
            let length = header.reduce(0) { $0 << 8 | Int($1) }
            guard length > 0, length < 1 << 20 else { return }
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { body, _, _, _ in
                if let body, let message = CastMessage.decode(body) {
                    Task { @MainActor in CastController.shared.handle(message) }
                }
                Task { @MainActor in
                    guard CastController.shared.connection === connection else { return }
                    CastController.shared.receive(on: connection)
                }
            }
        }
    }

    private func handle(_ message: CastMessage) {
        guard let json = (try? JSONSerialization.jsonObject(with: Data(message.payload.utf8))) as? [String: Any],
              let type = json["type"] as? String else { return }
        // The YouTube app reports through the lounge (its media messages aren't for the media receiver's bookkeeping).
        if message.namespace == Namespace.media, launchedApp != Self.mediaReceiver { return }
        #if DEBUG
        if message.namespace == Namespace.media { castLog.debug("media: \(message.payload.prefix(1500), privacy: .public)") }
        #endif
        switch (message.namespace, type) {
        case (Namespace.heartbeat, "PING"):
            send(Namespace.heartbeat, ["type": "PONG"], to: message.sourceId)
        case (Namespace.receiver, "RECEIVER_STATUS"):
            receiverStatus(json)
        case (Namespace.media, "MEDIA_STATUS"):
            mediaStatus(json)
        case (Namespace.media, "LOAD_FAILED"), (Namespace.media, "LOAD_CANCELLED"):
            // A quick skip replaces a load still in progress, and the device cancels that one:
            // only the latest load's failure means anything.
            guard let id = json["requestId"] as? Int, id == loadRequestId else {
                castLog.notice("ignored \(type, privacy: .public) of an earlier load")
                return
            }
            if type == "LOAD_FAILED", loadedAsVideo { soundInstead(); return }
            fail(type)
        case (Namespace.media, "QUEUE_ITEM_IDS"):
            learnItems((json["itemIds"] as? [Int] ?? []).map { ($0, nil) }, complete: true)
            syncQueue()
        case (Namespace.media, "QUEUE_CHANGE"):
            let ids = json["itemIds"] as? [Int] ?? []
            switch json["changeType"] as? String {
            case "INSERT": learnItems(ids.map { ($0, nil) }, complete: false)
            case "REMOVE":
                deviceItems.removeAll { ids.contains($0.id) }
                removedItemIds.subtract(ids)
            default: break
            }
        case (Namespace.media, "INVALID_REQUEST"), (Namespace.media, "ERROR"):
            let id = json["requestId"] as? Int
            castLog.notice("\(type, privacy: .public) for request \(id ?? -1): \(json["reason"] as? String ?? json["detailedErrorCode"].map { "\($0)" } ?? "-", privacy: .public)")
            if let id, id == insertRequestId {
                insertRequestId = nil
                insertedContentId = nil
            }
            if let id, id == jumpRequestId { jumpFailed() }
        case (Lounge.mdxNamespace, "mdxSessionStatus"):
            if let screenId = Lounge.screenId(inMdxMessage: json) { pair(with: screenId) }
        case (Namespace.receiver, "LAUNCH_ERROR"):
            if launchedApp == Lounge.castAppId, !viaYouTubeApp { playFromThisMacInstead("it didn't launch"); return }
            fail(type)
        case (Namespace.connection, "CLOSE") where message.sourceId == transportId || message.sourceId == "receiver-0":
            // Someone else took over the device (or it went to sleep). The YouTube app plays on
            // without the connection; the lounge says if it closes.
            if viaYouTubeApp { castChannelLost() } else if state == .connected { disconnect(resumeLocally: true) }
        default:
            break
        }
    }

    /// The music video didn't play on the device: its sound instead, from the same point. A video
    /// refused outright means this device doesn't take them (songs only from now on); one that
    /// stopped partway was just that video's stream.
    private func soundInstead() {
        guard let track = loadedTrack else { return }
        if !videoPlayed {
            videoRefused = true
            let name = device?.name ?? "the device"
            Router.shared.showToast(String(localized: "\(name) can't show music videos: playing the sound"), icon: "video.slash")
        }
        castLog.notice("video \(track.videoId, privacy: .public) didn't play (played before: \(self.videoPlayed)): sound instead")
        load(track, at: position, autoplay: remotePlaying, soundOnly: true)
    }

    #if DEBUG
    /// For `ytmusicfast debug-cast drop-channel`.
    func debugDropCastChannel() {
        if viaYouTubeApp { castChannelLost() }
    }

    /// For `ytmusicfast debug-cast`.
    var debugState: [String: Any] {
        ["device": device?.name ?? "", "state": "\(state)", "videoId": loadedVideoId ?? "", "asVideo": loadedAsVideo,
         "videoRefused": videoRefused, "playing": remotePlaying, "buffering": remoteBuffering, "settling": settling,
         "position": (position * 10).rounded() / 10, "session": mediaSessionId ?? -1,
         "lyrics": loadedWithLyrics ? (lyricsShown ? "on" : "off") : "none", "nextVideoId": wantedNext?.track.videoId ?? "",
         "currentItem": currentItemId ?? -1, "items": deviceItems.map { "\($0.id):\(CastQueueSync.videoId(fromContentId: $0.contentId) ?? "?")" },
         "viaYouTubeApp": viaYouTubeApp, "castChannel": connection != nil, "sentToTV": sentVideoIds.count]
    }
    #endif

    private func receiverStatus(_ json: [String: Any]) {
        let status = json["status"] as? [String: Any]
        if let volume = status?["volume"] as? [String: Any], let level = volume["level"] as? Double, state == .connected {
            PlayerController.shared.castVolumeChanged(level)
        }
        let apps = status?["applications"] as? [[String: Any]] ?? []
        guard let app = apps.first(where: { $0["appId"] as? String == launchedApp }),
              let transport = app["transportId"] as? String else {
            // Our receiver isn't running any more (closed from the TV's remote, or the TV moved on).
            if transportId != nil, state == .connected { disconnect(resumeLocally: true) }
            return
        }
        sessionId = app["sessionId"] as? String
        guard transport != transportId else { return }
        transportId = transport
        send(Namespace.connection, ["type": "CONNECT"], to: transport)
        if launchedApp == Lounge.castAppId {
            // The YouTube app: its screen id pairs a remote session (see `pair`).
            if !viaYouTubeApp { send(Lounge.mdxNamespace, ["type": "getMdxSessionStatus"], to: transport) }
            return
        }
        let starting = state != .connected
        state = .connected
        if starting {
            if awake == nil {
                awake = ProcessInfo.processInfo.beginActivity(options: .idleSystemSleepDisabled, reason: "Casting to \(device?.name ?? "a Cast device")")
            }
            if !resumeHandOver() { PlayerController.shared.castingStarted() }
        }
        onReady?()
        onReady = nil
    }

    private func mediaStatus(_ json: [String: Any]) {
        guard let status = (json["status"] as? [[String: Any]])?.first else { return }
        let id = status["mediaSessionId"] as? Int
        // The song before a skip, still reporting: not what's playing any more.
        if let id, staleSessionIds.contains(id) { return }
        // Which session is the latest load's: the one answering its request (or, should a device
        // not say, any new one once a few seconds have passed).
        if mediaSessionId == nil, let id {
            let answersLoad = loadRequestId != nil && json["requestId"] as? Int == loadRequestId
            guard answersLoad || Date().timeIntervalSince(settlingSince) > 6 else { return }
        } else if let id, id != mediaSessionId {
            // Another sender (or the TV's own app) took over: follow it.
            castLog.notice("session changed to \(id)")
        }
        if let id, id != mediaSessionId {
            mediaSessionId = id
            // What was asked for before the device could take it.
            if let pendingPlaying, !pendingPlayingSent { pendingPlayingSent = mediaCommand(pendingPlaying ? "PLAY" : "PAUSE") != nil }
            if let pendingSeek, mediaCommand("SEEK", ["currentTime": pendingSeek]) != nil { self.pendingSeek = nil }
        }
        // Its length, when it's about the song shown here (the device may be on its queued next).
        if let media = status["media"] as? [String: Any], let length = media["duration"] as? Double,
           let loaded = loadedVideoId, (media["contentId"] as? String)?.contains(loaded) == true {
            PlayerController.shared.castDurationReported(length)
        }
        let playerState = status["playerState"] as? String ?? ""
        let itemId = status["currentItemId"] as? Int
        castLog.debug("status \(playerState, privacy: .public) session \(id ?? -1) item \(itemId ?? -1) at \(status["currentTime"] as? Double ?? -1) reason \(status["idleReason"] as? String ?? "-", privacy: .public)")
        // The device's queue, as it lists it (or, answering an insert without the list, asked for).
        if let items = status["items"] as? [[String: Any]] {
            learnItems(items.compactMap { item in
                (item["itemId"] as? Int).map { ($0, (item["media"] as? [String: Any])?["contentId"] as? String) }
            }, complete: true)
        } else if let request = json["requestId"] as? Int, request == insertRequestId {
            mediaCommand("QUEUE_GET_ITEM_IDS")
        }
        // Skipped to the queued song: until the device is on it, what it reports is the song before.
        if let jumpItemId {
            guard itemId == jumpItemId else {
                if Date().timeIntervalSince(settlingSince) > 8 { jumpFailed(); return }
                remoteBuffering = true
                PlayerController.shared.castStatusChanged()
                return
            }
            self.jumpItemId = nil
            jumpRequestId = nil
            if let currentItemId { playedItemIds.insert(currentItemId) }
            currentItemId = itemId
        } else if let itemId, playedItemIds.contains(itemId) {
            // The song before, still reporting.
            return
        } else if let itemId, itemId != currentItemId {
            let before = currentItemId
            currentItemId = itemId
            if let before {
                playedItemIds.insert(before)
                if !settling { deviceMovedOn(to: itemId, status: status) }
            }
        }
        if let currentItemId, !deviceItems.contains(where: { $0.id == currentItemId }) {
            deviceItems.append(.init(id: currentItemId, contentId: loadedContentId ?? ""))
        }
        // Right after a load the device reports idle and buffering at 0:00 before it seeks to
        // the asked-for point: until it's actually playing or paused, keep showing the load.
        if settling, playerState == "PLAYING" || playerState == "PAUSED" || Date().timeIntervalSince(settlingSince) > 20 {
            settling = false
        }
        if settling {
            if playerState == "IDLE", status["idleReason"] as? String == "ERROR" {
                if loadedAsVideo { soundInstead() } else { fail("ERROR") }
                return
            }
            remoteBuffering = true
            PlayerController.shared.castStatusChanged()
            return
        }
        // A video that stopped with an error: its sound instead, from where it was (before this
        // report's idle 0:00 replaces that).
        if playerState == "IDLE", status["idleReason"] as? String == "ERROR", loadedAsVideo {
            soundInstead()
            return
        }
        if playerState == "PLAYING", loadedAsVideo { videoPlayed = true }
        let reportedPlaying = playerState == "PLAYING" || playerState == "BUFFERING"
        // Until the device confirms a play or pause (or a few seconds pass), its older reports
        // don't flip the button back; the position waits too.
        let waiting = pendingPlaying.map { $0 != reportedPlaying && Date().timeIntervalSince(pendingSince) < 4 } ?? false
        if !waiting {
            pendingPlaying = nil
            remotePlaying = reportedPlaying
            if pendingSeek == nil, let time = status["currentTime"] as? Double {
                remoteTime = time
                remoteTimeAt = Date()
            }
        }
        remoteBuffering = playerState == "BUFFERING"
        if playerState == "IDLE", let reason = status["idleReason"] as? String {
            switch reason {
            case "FINISHED" where nextIsQueued:
                // The device goes on to the queued song by itself; should it not, the player does.
                let finished = loadedVideoId
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    MainActor.assumeIsolated {
                        let cast = CastController.shared
                        guard cast.isActive, cast.loadedVideoId == finished, cast.jumpItemId == nil, !cast.settling else { return }
                        PlayerController.shared.castFinishedSong(finished)
                    }
                }
            case "FINISHED": PlayerController.shared.castFinishedSong(loadedVideoId)
            case "ERROR": fail(reason)
            default: break
            }
        }
        PlayerController.shared.castStatusChanged()
        syncQueue()
        applyLyrics()
    }

    /// The next song is on the device's queue, after the one playing.
    private var nextIsQueued: Bool {
        guard let next = wantedNext else { return false }
        return deviceItems.contains { $0.id != currentItemId && $0.contentId == next.contentId }
    }

    /// The device went on to another item of its queue by itself (the song playing ended).
    private func deviceMovedOn(to itemId: Int, status: [String: Any]) {
        let contentId = deviceItems.first { $0.id == itemId }?.contentId ?? (status["media"] as? [String: Any])?["contentId"] as? String
        guard let next = wantedNext, contentId == next.contentId else {
            // Not the song the app has next (its queue changed just then): the app's next one loads.
            castLog.notice("moved on to an item that isn't next (\(contentId.flatMap(CastQueueSync.videoId(fromContentId:)) ?? "?", privacy: .public)): loading the next song")
            PlayerController.shared.castFinishedSong(loadedVideoId)
            return
        }
        castLog.notice("moved on to queued \(next.track.videoId, privacy: .public)")
        loadGeneration += 1
        becameCurrent(next)
        remoteTime = status["currentTime"] as? Double ?? 0
        remoteTimeAt = Date()
        PlayerController.shared.castAdvanced(to: next.track.videoId)
    }

    // MARK: The TV's own YouTube app

    /// The Connect panel's switch changed for a device. Playing on it now, the other app takes
    /// over in place, from where the song is.
    func youTubeAppSettingChanged(for device: CastDevice) {
        guard self.device?.id == device.id, state == .connected || state == .connecting else { return }
        let wanted = TVYouTubeApp.shared.isOn(for: device) ? Lounge.castAppId : Self.mediaReceiver
        guard wanted != launchedApp else { return }
        guard connection != nil else {
            // The Cast connection went while this Mac slept: connect again.
            disconnect(resumeLocally: false)
            cast(to: device)
            return
        }
        castLog.notice("switching to \(wanted == Lounge.castAppId ? "the TV's YouTube app" : "the media receiver", privacy: .public)")
        if state == .connected, PlayerController.shared.current != nil { handOver = (position, remotePlaying) }
        endYouTubeApp(pausingTV: false)
        viaYouTubeApp = false
        if let sessionId { send(Namespace.receiver, ["type": "STOP", "sessionId": sessionId], to: "receiver-0") }
        if let transportId { send(Namespace.connection, ["type": "CLOSE"], to: transportId) }
        sessionId = nil
        transportId = nil
        mediaSessionId = nil
        staleSessionIds = []
        resetQueue()
        wantedNext = nil
        nextGeneration += 1
        loadGeneration += 1
        settling = false
        if wanted == Lounge.castAppId {
            CastMediaServer.shared.stop()
            if let awake { ProcessInfo.processInfo.endActivity(awake) }
            awake = nil
        }
        launchedApp = wanted
        state = .connecting
        send(Namespace.receiver, ["type": "LAUNCH", "appId": wanted], to: "receiver-0")
        if wanted == Lounge.castAppId { startPairingTimeout() }
    }

    /// Carries on from where the app before left off (see `youTubeAppSettingChanged`).
    private func resumeHandOver() -> Bool {
        guard let handOver else { return false }
        self.handOver = nil
        if let track = PlayerController.shared.current { load(track, at: handOver.position, autoplay: handOver.playing) }
        PlayerController.shared.castStatusChanged()
        return true
    }

    /// The YouTube app has a while to start and pair; then this Mac plays to the TV instead.
    private func startPairingTimeout() {
        pairingTimeout?.cancel()
        pairingTimeout = Task {
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            playFromThisMacInstead("no answer")
        }
    }

    /// The YouTube app told its screen id: a remote session with it, as a phone's.
    private func pair(with screenId: String) {
        guard launchedApp == Lounge.castAppId, lounge == nil, device != nil else { return }
        castLog.notice("TV's YouTube app: pairing")
        let lounge = YouTubeLounge(screenId: screenId) { event in
            Task { @MainActor in CastController.shared.tvEvent(event) }
        }
        self.lounge = lounge
        Task {
            do {
                try await lounge.connect()
            } catch {
                guard self.lounge === lounge else { return }
                playFromThisMacInstead("pairing failed (\(error))")
                return
            }
            guard self.lounge === lounge, device != nil else { await lounge.close(); return }
            pairingTimeout?.cancel()
            pairingTimeout = nil
            // The TV's own "up next" after the songs sent would play what the queue here doesn't have.
            await lounge.send(.setAutoplay(false))
            guard self.lounge === lounge, device != nil else { return }
            castLog.notice("TV's YouTube app: paired")
            viaYouTubeApp = true
            state = .connected
            // Nothing keeps this Mac awake: the TV plays on without it.
            if let awake { ProcessInfo.processInfo.endActivity(awake) }
            awake = nil
            if !resumeHandOver() { PlayerController.shared.castingStarted() }
        }
    }

    /// The YouTube app didn't start or pair: Google's media receiver plays from this Mac instead.
    private func playFromThisMacInstead(_ reason: String) {
        guard device != nil, connection != nil, launchedApp == Lounge.castAppId, !viaYouTubeApp else { return }
        castLog.error("TV's YouTube app: \(reason, privacy: .public); casting from this Mac instead")
        endYouTubeApp(pausingTV: false)
        if let sessionId { send(Namespace.receiver, ["type": "STOP", "sessionId": sessionId], to: "receiver-0") }
        if let transportId { send(Namespace.connection, ["type": "CLOSE"], to: transportId) }
        sessionId = nil
        transportId = nil
        launchedApp = Self.mediaReceiver
        Router.shared.showToast(String(localized: "The TV's YouTube app didn't answer: playing from this Mac"), icon: "exclamationmark.triangle.fill")
        send(Namespace.receiver, ["type": "LAUNCH", "appId": Self.mediaReceiver], to: "receiver-0")
    }

    /// Ends the remote session (the TV plays on unless paused here).
    private func endYouTubeApp(pausingTV: Bool) {
        pairingTimeout?.cancel()
        pairingTimeout = nil
        if let lounge {
            let previous = tvSending
            Task {
                await previous?.value
                if pausingTV { await lounge.send(.pause) }
                await lounge.close()
            }
        }
        lounge = nil
        tvSending = nil
        sentVideoIds = []
        tvVideoId = nil
        tvWantedNext = nil
    }

    /// The Cast connection went while the YouTube app plays (this Mac slept, or the TV dropped
    /// it): the app plays on, and commands go to it directly.
    private func castChannelLost() {
        guard connection != nil else { return }
        castLog.notice("TV's YouTube app: Cast connection gone, carrying on without it")
        heartbeat?.invalidate()
        heartbeat = nil
        let old = connection
        connection = nil
        old?.cancel()
        transportId = nil
        sessionId = nil
    }

    /// Sends a command to the TV after the ones before; false while the TV is still starting the
    /// song (it goes once it has).
    private func tvCommand(_ command: Lounge.Command) -> Bool {
        guard lounge != nil, !settling else { return false }
        sendToTV(command)
        return true
    }

    private func sendToTV(_ command: Lounge.Command) {
        guard let lounge else { return }
        let previous = tvSending
        tvSending = Task {
            await previous?.value
            if !(await lounge.send(command)) { castLog.error("TV's YouTube app: \(command.name, privacy: .public) didn't go through") }
        }
    }

    /// Plays a song on the TV's YouTube app, with the queue's next songs after it: the TV goes on
    /// by itself while this Mac sleeps, and the queue here follows when it hears (`tvMovedOn`).
    private func loadOnTV(_ track: Track, at position: TimeInterval, autoplay: Bool) {
        let before = loadedVideoId, wasPlaying = !settling
        loadGeneration += 1
        let generation = loadGeneration
        loadedVideoId = track.videoId
        loadedTrack = track
        remoteTime = position
        remoteTimeAt = Date()
        remoteBuffering = true
        remotePlaying = autoplay
        // Starting paused: the pause goes once the TV has the song.
        pendingPlaying = autoplay ? nil : false
        pendingPlayingSent = false
        pendingSince = Date()
        pendingSeek = nil
        settling = true
        settlingSince = Date()
        guard !track.isLocal else {
            // A file on this Mac: the TV's YouTube app can't have it, so this Mac streams it (and
            // the rest of this cast) instead.
            if let device { DispatchQueue.main.async { TVYouTubeApp.shared.suspend(for: device) } }
            return
        }
        let player = PlayerController.shared
        let upcoming = player.repeatMode == .one ? [] : player.upNext.prefix(50).prefix { !$0.track.isLocal }.map(\.track.videoId)
        // The TV's next one (`tvSetNext` keeps it the queue's): the TV skips to it itself, sooner.
        if autoplay, position < 1, wasPlaying, let at = sentVideoIds.firstIndex(where: { $0 == before }), sentVideoIds.indices.contains(at + 1),
           sentVideoIds[at + 1] == track.videoId {
            castLog.notice("TV's YouTube app: next, to \(track.videoId, privacy: .public)")
            sendToTV(.next)
            return
        }
        Task {
            // Skipping through songs quickly: only the one stopped on goes to the TV.
            try? await Task.sleep(for: .milliseconds(150))
            guard generation == loadGeneration, lounge != nil else { return }
            sentVideoIds = [track.videoId] + upcoming
            castLog.notice("TV's YouTube app: play \(track.videoId, privacy: .public) at \(position) (\(upcoming.count) after it)")
            sendToTV(.setPlaylist(videoIds: sentVideoIds, index: 0, time: position))
        }
    }

    /// The queue's next song changed (matched to the Song/Video switch, or the queue was edited):
    /// it goes after the song playing in the TV's list, so the TV goes on to it.
    private func tvSetNext(_ track: Track?) {
        tvWantedNext = track
        guard let track, !track.isLocal, !settling, let at = sentVideoIds.firstIndex(where: { $0 == loadedVideoId }) else { return }
        tvWantedNext = nil
        let old = sentVideoIds.indices.contains(at + 1) ? sentVideoIds[at + 1] : nil
        guard old != track.videoId else { return }
        // The one it replaces goes, unless it's still to come (something was put before it).
        if let old, !PlayerController.shared.upNext.dropFirst().contains(where: { $0.track.videoId == old }) {
            sendToTV(.removeVideo(old))
            sentVideoIds.remove(at: at + 1)
        }
        castLog.notice("TV's YouTube app: next is \(track.videoId, privacy: .public)")
        sendToTV(.insertVideo(track.videoId))
        sentVideoIds.insert(track.videoId, at: at + 1)
    }

    private func tvEvent(_ event: Lounge.Event) {
        guard viaYouTubeApp, isActive else { return }
        switch event.name {
        case "nowPlaying", "onStateChange":
            if let playback = Lounge.Playback(event) { tvPlayback(playback) }
        case "loungeScreenDisconnected":
            // The YouTube app closed on the TV.
            castLog.notice("TV's YouTube app: closed on the TV")
            disconnect(resumeLocally: true)
        default:
            castLog.debug("TV's YouTube app: \(event.name, privacy: .public)")
        }
    }

    /// The TV's player, mapped to what the player bar shows, as `mediaStatus` does for the media
    /// receiver: a load shows until the TV plays it, and play/pause asked for here aren't undone by
    /// the TV's older reports.
    private func tvPlayback(_ playback: Lounge.Playback) {
        if let video = playback.videoId { tvVideoId = video }
        castLog.debug("TV: \(self.tvVideoId ?? "-", privacy: .public) \(String(describing: playback.state), privacy: .public) at \(playback.currentTime ?? -1)")
        if settling {
            // An ad before the song: it plays when that's over.
            if playback.state == .advertisement { settlingSince = Date() }
            let started = tvVideoId == loadedVideoId && (playback.state == .playing || playback.state == .paused)
            guard started else {
                if Date().timeIntervalSince(settlingSince) > 20 {
                    // The TV didn't play it (not available there): the next song.
                    castLog.notice("TV's YouTube app didn't play \(self.loadedVideoId ?? "-", privacy: .public): next song")
                    settling = false
                    PlayerController.shared.castFinishedSong(loadedVideoId)
                    return
                }
                remoteBuffering = true
                PlayerController.shared.castStatusChanged()
                return
            }
            settling = false
            // What was asked for before the TV had the song.
            if let pendingPlaying, !pendingPlayingSent { pendingPlayingSent = tvCommand(pendingPlaying ? .play : .pause) }
            if let pendingSeek, tvCommand(.seek(pendingSeek)) { self.pendingSeek = nil }
            if let tvWantedNext { tvSetNext(tvWantedNext) }
        } else if let video = tvVideoId, video != loadedVideoId {
            tvMovedOn(to: video, playback)
            return
        }
        guard let state = playback.state else { return }
        // An ad's position and length aren't the song's.
        if state != .advertisement, tvVideoId == loadedVideoId, let length = playback.duration {
            PlayerController.shared.castDurationReported(length)
        }
        let reportedPlaying: Bool
        switch state {
        case .playing, .buffering, .unstarted, .advertisement: reportedPlaying = true
        case .paused, .cued, .ended: reportedPlaying = false
        case .unknown: return
        }
        let waiting = pendingPlaying.map { $0 != reportedPlaying && Date().timeIntervalSince(pendingSince) < 4 } ?? false
        if !waiting {
            pendingPlaying = nil
            remotePlaying = reportedPlaying
            if pendingSeek == nil, state != .advertisement, let time = playback.currentTime {
                remoteTime = time
                remoteTimeAt = Date()
            }
        }
        remoteBuffering = state == .buffering || state == .unstarted || state == .advertisement
        if state == .ended { tvFinishedSong() }
        PlayerController.shared.castStatusChanged()
    }

    /// The song ended on the TV. With the queue's next song after it there, the TV goes on by
    /// itself (should it not, the player does); otherwise the player loads the next.
    private func tvFinishedSong() {
        let finished = loadedVideoId
        let upNext = PlayerController.shared.upNext.map(\.track.videoId)
        guard let at = sentVideoIds.firstIndex(where: { $0 == finished }), sentVideoIds.indices.contains(at + 1),
              Lounge.songsAhead(to: sentVideoIds[at + 1], sent: Array(sentVideoIds[at...]), upNext: upNext) == 1 else {
            PlayerController.shared.castFinishedSong(finished)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            MainActor.assumeIsolated {
                let cast = CastController.shared
                guard cast.isActive, cast.viaYouTubeApp, cast.loadedVideoId == finished, !cast.settling else { return }
                PlayerController.shared.castFinishedSong(finished)
            }
        }
    }

    /// The TV went on to another video by itself: its list ran on (this Mac may have slept through
    /// a few songs), and the queue here follows. Anything else (picked on the TV) gives way to the
    /// queue's next song.
    private func tvMovedOn(to video: String, _ playback: Lounge.Playback) {
        let player = PlayerController.shared
        guard let at = sentVideoIds.firstIndex(where: { $0 == loadedVideoId }),
              let ahead = Lounge.songsAhead(to: video, sent: Array(sentVideoIds[at...]), upNext: player.upNext.map(\.track.videoId)) else {
            castLog.notice("TV's YouTube app went to \(video, privacy: .public), not next here: playing the next song")
            player.castFinishedSong(loadedVideoId)
            return
        }
        castLog.notice("TV's YouTube app went on \(ahead) to \(video, privacy: .public)")
        loadGeneration += 1
        for id in sentVideoIds[(at + 1)...(at + ahead)] {
            loadedVideoId = id
            player.castAdvanced(to: id)
        }
        loadedTrack = player.current
        loadedVideoId = video
        remoteTime = playback.currentTime ?? 0
        remoteTimeAt = Date()
        tvPlayback(playback)
    }
}
