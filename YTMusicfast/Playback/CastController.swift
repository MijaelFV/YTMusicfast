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
/// on it. The queue stays in this app; the device just plays one song at a time from
/// `CastMediaServer`, and its status drives the player bar.
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
        remotePlaying = false
        if let awake { ProcessInfo.processInfo.endActivity(awake) }
        awake = nil
        CastMediaServer.shared.stop()
        PlayerController.shared.castingEnded(at: position, playing: wasPlaying && resumeLocally)
    }

    private func connectionChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            send(Namespace.connection, ["type": "CONNECT"], to: "receiver-0")
            send(Namespace.receiver, ["type": "LAUNCH", "appId": Self.mediaReceiver], to: "receiver-0")
            heartbeat?.invalidate()
            let timer = Timer(timeInterval: 5, repeats: true) { _ in
                MainActor.assumeIsolated { _ = CastController.shared.send(Namespace.heartbeat, ["type": "PING"], to: "receiver-0") }
            }
            RunLoop.main.add(timer, forMode: .common)
            heartbeat = timer
        case .failed(let error):
            fail(error.localizedDescription)
        case .cancelled:
            if device != nil, self.state != .idle { fail(String(localized: "The connection was closed")) }
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
        // A newer load (quick skips) makes this one stale: only the latest reaches the device.
        loadGeneration += 1
        let generation = loadGeneration
        // Shown at once; the device's own reports take over once it has the song.
        loadedVideoId = track.videoId
        loadedTrack = track
        loadedAsVideo = false
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
        let send = { [weak self] in
            guard let self, self.transportId != nil else { return }
            Task {
                // A music video as HLS; its sound alone when it can't be (see CastVideo).
                let video = !soundOnly && self.castsVideo(track) ? await CastMediaServer.shared.videoURL(for: track) : nil
                guard generation == self.loadGeneration else { return }
                let url: URL
                if let video {
                    url = video
                } else {
                    guard let sound = try? await CastMediaServer.shared.url(for: track) else {
                        self.fail(String(localized: "This Mac has no network address"))
                        return
                    }
                    url = sound
                }
                guard generation == self.loadGeneration, let transportId = self.transportId else { return }
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
                    self.loadedAsVideo = true
                }
                if let duration = track.duration, duration.isFinite, duration > 0 { media["duration"] = duration }
                castLog.notice("load \(track.videoId, privacy: .public) at \(position) as \(video == nil ? "sound" : "video", privacy: .public)")
                self.loadRequestId = self.send(Namespace.media, ["type": "LOAD", "media": media, "autoplay": autoplay, "currentTime": position], to: transportId)
            }
        }
        if transportId != nil { send() } else { onReady = send }
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
        pendingPlayingSent = mediaCommand(playing ? "PLAY" : "PAUSE")
        PlayerController.shared.castStatusChanged()
    }

    func seek(to seconds: TimeInterval) {
        remoteTime = seconds
        remoteTimeAt = Date()
        pendingSeek = mediaCommand("SEEK", ["currentTime": seconds]) ? nil : seconds
    }

    /// The receiver's own volume (0…1), like the TV's.
    func setVolume(_ level: Double, muted: Bool) {
        send(Namespace.receiver, ["type": "SET_VOLUME", "volume": ["level": min(1, max(0, level)), "muted": muted]], to: "receiver-0")
    }

    /// Sends a command for the song on the device; false when there's no session to send it to yet.
    @discardableResult
    private func mediaCommand(_ type: String, _ extra: [String: Any] = [:]) -> Bool {
        guard let transportId, let mediaSessionId else { return false }
        var payload = extra
        payload["type"] = type
        payload["mediaSessionId"] = mediaSessionId
        send(Namespace.media, payload, to: transportId)
        return true
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
        case (Namespace.receiver, "LAUNCH_ERROR"):
            fail(type)
        case (Namespace.connection, "CLOSE") where message.sourceId == transportId || message.sourceId == "receiver-0":
            // Someone else took over the device (or it went to sleep).
            if state == .connected { disconnect(resumeLocally: true) }
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
    /// For `ytmusicfast debug-cast`.
    var debugState: [String: Any] {
        ["device": device?.name ?? "", "state": "\(state)", "videoId": loadedVideoId ?? "", "asVideo": loadedAsVideo,
         "videoRefused": videoRefused, "playing": remotePlaying, "buffering": remoteBuffering, "settling": settling,
         "position": (position * 10).rounded() / 10, "session": mediaSessionId ?? -1]
    }
    #endif

    private func receiverStatus(_ json: [String: Any]) {
        let status = json["status"] as? [String: Any]
        if let volume = status?["volume"] as? [String: Any], let level = volume["level"] as? Double, state == .connected {
            PlayerController.shared.castVolumeChanged(level)
        }
        let apps = status?["applications"] as? [[String: Any]] ?? []
        guard let app = apps.first(where: { $0["appId"] as? String == Self.mediaReceiver }),
              let transport = app["transportId"] as? String else {
            // Our receiver isn't running any more (closed from the TV's remote, or the TV moved on).
            if transportId != nil, state == .connected { disconnect(resumeLocally: true) }
            return
        }
        sessionId = app["sessionId"] as? String
        guard transport != transportId else { return }
        transportId = transport
        send(Namespace.connection, ["type": "CONNECT"], to: transport)
        let starting = state != .connected
        state = .connected
        if starting {
            if awake == nil {
                awake = ProcessInfo.processInfo.beginActivity(options: .idleSystemSleepDisabled, reason: "Casting to \(device?.name ?? "a Cast device")")
            }
            PlayerController.shared.castingStarted()
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
            if let pendingPlaying, !pendingPlayingSent { pendingPlayingSent = mediaCommand(pendingPlaying ? "PLAY" : "PAUSE") }
            if let pendingSeek, mediaCommand("SEEK", ["currentTime": pendingSeek]) { self.pendingSeek = nil }
        }
        let playerState = status["playerState"] as? String ?? ""
        castLog.debug("status \(playerState, privacy: .public) session \(id ?? -1) at \(status["currentTime"] as? Double ?? -1) reason \(status["idleReason"] as? String ?? "-", privacy: .public)")
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
            case "FINISHED": PlayerController.shared.castFinishedSong(loadedVideoId)
            case "ERROR": fail(reason)
            default: break
            }
        }
        PlayerController.shared.castStatusChanged()
    }
}
