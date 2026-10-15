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
    @ObservationIgnored private var loadedVideoId: String?
    @ObservationIgnored private var onReady: (() -> Void)?
    /// What to resume locally if casting stops.
    @ObservationIgnored private var lastKnownPosition: TimeInterval = 0

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
        loadedVideoId = nil
        remotePlaying = false
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
                MainActor.assumeIsolated { CastController.shared.send(Namespace.heartbeat, ["type": "PING"], to: "receiver-0") }
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

    /// Loads a song on the receiver (the player calls this for every song while casting).
    func load(_ track: Track, at position: TimeInterval, autoplay: Bool) {
        let send = { [weak self] in
            guard let self, let transportId = self.transportId else { return }
            Task {
                guard let url = try? await CastMediaServer.shared.url(for: track) else {
                    self.fail(String(localized: "This Mac has no network address"))
                    return
                }
                self.loadedVideoId = track.videoId
                self.remoteTime = position
                self.remoteTimeAt = Date()
                self.remoteBuffering = true
                var metadata: [String: Any] = ["metadataType": 3, "title": track.title, "artist": track.artistLine]
                if let album = track.album?.name { metadata["albumName"] = album }
                if let art = Artwork.url(track.thumbnail, size: 720) { metadata["images"] = [["url": art.absoluteString]] }
                var media: [String: Any] = ["contentId": url.absoluteString, "contentType": "audio/mp4", "streamType": "BUFFERED", "metadata": metadata]
                if let duration = track.duration { media["duration"] = duration }
                self.send(Namespace.media, ["type": "LOAD", "media": media, "autoplay": autoplay, "currentTime": position], to: transportId)
            }
        }
        if transportId != nil { send() } else { onReady = send }
    }

    func play() { mediaCommand("PLAY") }
    func pause() { mediaCommand("PAUSE") }

    func seek(to seconds: TimeInterval) {
        remoteTime = seconds
        remoteTimeAt = Date()
        mediaCommand("SEEK", ["currentTime": seconds])
    }

    /// The receiver's own volume (0…1), like the TV's.
    func setVolume(_ level: Double, muted: Bool) {
        send(Namespace.receiver, ["type": "SET_VOLUME", "volume": ["level": min(1, max(0, level)), "muted": muted]], to: "receiver-0")
    }

    private func mediaCommand(_ type: String, _ extra: [String: Any] = [:]) {
        guard let transportId, let mediaSessionId else { return }
        var payload = extra
        payload["type"] = type
        payload["mediaSessionId"] = mediaSessionId
        send(Namespace.media, payload, to: transportId)
    }

    // MARK: Messages

    private func send(_ namespace: String, _ payload: [String: Any], to destination: String) {
        guard let connection else { return }
        var payload = payload
        if payload["type"] as? String != "PING", payload["type"] as? String != "PONG",
           payload["type"] as? String != "CONNECT", payload["type"] as? String != "CLOSE" {
            payload["requestId"] = requestId
            requestId += 1
        }
        guard let json = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let message = CastMessage(sourceId: Self.senderId, destinationId: destination, namespace: namespace,
                                  payload: String(decoding: json, as: UTF8.self))
        connection.send(content: message.framed(), completion: .contentProcessed { _ in })
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
        case (Namespace.media, "LOAD_FAILED"), (Namespace.media, "LOAD_CANCELLED"), (Namespace.receiver, "LAUNCH_ERROR"):
            fail(type)
        case (Namespace.connection, "CLOSE") where message.sourceId == transportId || message.sourceId == "receiver-0":
            // Someone else took over the device (or it went to sleep).
            if state == .connected { disconnect(resumeLocally: true) }
        default:
            break
        }
    }

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
        if starting { PlayerController.shared.castingStarted() }
        onReady?()
        onReady = nil
    }

    private func mediaStatus(_ json: [String: Any]) {
        guard let status = (json["status"] as? [[String: Any]])?.first else { return }
        if let id = status["mediaSessionId"] as? Int { mediaSessionId = id }
        if let time = status["currentTime"] as? Double {
            remoteTime = time
            remoteTimeAt = Date()
        }
        let playerState = status["playerState"] as? String ?? ""
        remotePlaying = playerState == "PLAYING" || playerState == "BUFFERING"
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
