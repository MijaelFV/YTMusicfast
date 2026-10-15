import AppKit
import MultipeerConnectivity
import Observation

/// Listen together with people nearby: one shared queue everyone can control.
///
/// One Mac hosts; others nearby join and play in step with it. Everyone can control playback:
/// a guest's play/pause, skip, seek and "add to queue" go to the host, and the host's state comes
/// back to everyone. No server: Macs find each other with Bonjour (MultipeerConnectivity).
@MainActor
@Observable
final class ListenTogether: NSObject {
    static let shared = ListenTogether()

    enum Role: Equatable {
        case off
        case hosting
        case joined(host: String)
    }

    /// What the host shares with everyone.
    struct SharedState: Codable {
        var track: Track?
        var upNext: [Track]
        var position: TimeInterval
        var isPlaying: Bool
        var sentAt: Date
    }

    enum Request: Codable {
        case togglePlayPause, next, previous
        case seek(TimeInterval)
        case addToQueue([Track])
        case playNext([Track])
    }

    private enum Message: Codable {
        case state(SharedState)
        case request(Request, from: String)
    }

    private(set) var role: Role = .off
    /// Sessions hosted nearby (while looking for one to join).
    private(set) var nearby: [MCPeerID] = []
    /// Who's listening along (host) or who's in the session (guest).
    private(set) var people: [String] = []
    private(set) var hostState: SharedState?
    private(set) var lastError: String?

    @ObservationIgnored private static let service = "ytf-together"
    @ObservationIgnored private lazy var me = MCPeerID(displayName: Self.displayName)
    @ObservationIgnored private var session: MCSession?
    @ObservationIgnored private var advertiser: MCNearbyServiceAdvertiser?
    @ObservationIgnored private var browser: MCNearbyServiceBrowser?
    @ObservationIgnored private var hostPeer: MCPeerID?
    /// People the host let in this session (they may reconnect without being asked again).
    @ObservationIgnored private var allowed: Set<String> = []
    @ObservationIgnored private var broadcastTimer: Timer?
    @ObservationIgnored private var lastTrackId: String?
    @ObservationIgnored private var lastPlaying: Bool?

    private static var displayName: String {
        let name = AuthManager.shared.accountName ?? Host.current().localizedName ?? "Mac"
        return String(name.prefix(60))
    }

    var isGuest: Bool { if case .joined = role { true } else { false } }

    // MARK: Hosting

    func startHosting() {
        leave()
        let session = makeSession()
        let advertiser = MCNearbyServiceAdvertiser(peer: me, discoveryInfo: nil, serviceType: Self.service)
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        self.session = session
        self.advertiser = advertiser
        role = .hosting
        people = []
        lastError = nil
        broadcastTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.broadcastIfNeeded(force: true) }
        }
        Router.shared.showToast(String(localized: "Listening session started — people nearby can join"), icon: "person.2.wave.2.fill")
    }

    /// The player changed (track, play/pause): tell everyone at once.
    func playerChanged() {
        guard role == .hosting else { return }
        broadcastIfNeeded(force: false)
    }

    private func broadcastIfNeeded(force: Bool) {
        let player = PlayerController.shared
        let changed = player.current?.videoId != lastTrackId || player.isPlaying != lastPlaying
        guard force || changed else { return }
        lastTrackId = player.current?.videoId
        lastPlaying = player.isPlaying
        let state = SharedState(track: player.current.map(Self.shareable), upNext: player.upNext.prefix(20).map { Self.shareable($0.track) },
                                position: player.playbackPosition, isPlaying: player.isPlaying, sentAt: Date())
        send(.state(state))
    }

    // MARK: Joining

    func lookForSessions() {
        guard browser == nil else { return }
        nearby = []
        let browser = MCNearbyServiceBrowser(peer: me, serviceType: Self.service)
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser
    }

    func stopLooking() {
        browser?.stopBrowsingForPeers()
        browser = nil
    }

    func join(_ host: MCPeerID) {
        if role != .off { leave() }
        let session = makeSession()
        self.session = session
        hostPeer = host
        // Long enough for the host to answer "wants to join".
        browser?.invitePeer(host, to: session, withContext: nil, timeout: 60)
        role = .joined(host: host.displayName)
        lastError = nil
    }

    func leave() {
        allowed = []
        broadcastTimer?.invalidate()
        broadcastTimer = nil
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
        session?.disconnect()
        session = nil
        hostPeer = nil
        hostState = nil
        people = []
        if role != .off { Router.shared.showToast(String(localized: "Left the listening session"), icon: "person.2.slash") }
        role = .off
        PlayerController.shared.remoteControl = nil
    }

    // MARK: Guest side

    /// Follows the host: same song (and what's next), same position, same play/pause.
    private func apply(_ state: SharedState) {
        hostState = state
        let player = PlayerController.shared
        player.remoteControl = { [weak self] request in self?.send(.request(request, from: Self.displayName)) }
        guard let track = state.track else { return }
        let expected = state.position + (state.isPlaying ? Date().timeIntervalSince(state.sentAt) : 0)
        if player.current?.videoId != track.videoId {
            player.follow([track] + state.upNext, at: expected, playing: state.isPlaying)
            return
        }
        player.followSync(position: expected, playing: state.isPlaying)
    }

    // MARK: Host side

    private func handle(_ request: Request, from name: String) {
        let player = PlayerController.shared
        switch request {
        case .togglePlayPause: player.togglePlayPause()
        case .next: player.next()
        case .previous: player.previous()
        case .seek(let time): player.seek(to: time)
        case .addToQueue(let tracks):
            let tracks = Self.fromGuest(tracks)
            guard !tracks.isEmpty else { return }
            player.addToQueue(tracks)
            Router.shared.showToast("\(name) added \(tracks.first?.title ?? "a song")", icon: "person.2.fill")
        case .playNext(let tracks):
            let tracks = Self.fromGuest(tracks)
            guard !tracks.isEmpty else { return }
            player.playNext(tracks)
            Router.shared.showToast("\(name) queued \(tracks.first?.title ?? "a song") next", icon: "person.2.fill")
        }
        broadcastIfNeeded(force: true)
    }

    /// A file on this Mac means nothing elsewhere, and its path is nobody else's business.
    private static func shareable(_ track: Track) -> Track {
        var track = track
        track.localPath = nil
        return track
    }

    /// Songs a guest adds: YouTube Music songs only — never a file path on this Mac.
    private static func fromGuest(_ tracks: [Track]) -> [Track] {
        tracks.filter { $0.localPath == nil && !$0.videoId.isEmpty }
    }

    /// The host says who joins: someone nearby could otherwise take over
    /// the music. Asked once per person per session.
    private func askToJoin(_ name: String, answer: @escaping (Bool) -> Void) {
        if allowed.contains(name) { answer(true); return }
        let alert = NSAlert()
        alert.messageText = String(localized: "\(name) wants to join your listening session")
        alert.informativeText = String(localized: "They'll be able to play, pause, skip and add songs.")
        alert.addButton(withTitle: String(localized: "Let Them Join"))
        alert.addButton(withTitle: String(localized: "Don't Allow"))
        NSApp.requestUserAttention(.informationalRequest)
        let decide: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            let yes = response == .alertFirstButtonReturn
            if yes { self?.allowed.insert(name) }
            answer(yes)
        }
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.title == "YT Musicfast" }), window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: decide)
        } else {
            decide(alert.runModal())
        }
    }

    // MARK: Transport

    private func makeSession() -> MCSession {
        let session = MCSession(peer: me, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        return session
    }

    private func send(_ message: Message) {
        guard let session, !session.connectedPeers.isEmpty, let data = try? JSONEncoder().encode(message) else { return }
        let targets = isGuest ? session.connectedPeers.filter { $0 == hostPeer } : session.connectedPeers
        guard !targets.isEmpty else { return }
        try? session.send(data, toPeers: targets, with: .reliable)
    }

    private func received(_ data: Data, from peer: MCPeerID) {
        guard let message = try? JSONDecoder().decode(Message.self, from: data) else { return }
        switch message {
        case .state(let state) where isGuest && peer == hostPeer:
            apply(state)
        case .request(let request, let name) where role == .hosting:
            handle(request, from: name)
        default:
            break
        }
    }

    private func peersChanged() {
        people = session?.connectedPeers.map(\.displayName) ?? []
        if role == .hosting { broadcastIfNeeded(force: true) }
        if isGuest, let hostPeer, session?.connectedPeers.contains(hostPeer) == false, hostState != nil {
            lastError = String(localized: "The host ended the session")
            leave()
        }
    }
}

// MARK: - MultipeerConnectivity callbacks (arrive on background queues)

extension ListenTogether: MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in self.peersChanged() }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in self.received(data, from: peerID) }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                                withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        nonisolated(unsafe) let handler = invitationHandler
        Task { @MainActor in
            guard self.role == .hosting else { handler(false, nil); return }
            self.askToJoin(peerID.displayName) { yes in
                guard yes, self.role == .hosting else { handler(false, nil); return }
                handler(true, self.session)
                Router.shared.showToast("\(peerID.displayName) joined", icon: "person.2.fill")
            }
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor in self.lastError = String(localized: "Couldn't start the session: \(error.localizedDescription)") }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            if !self.nearby.contains(peerID) { self.nearby.append(peerID) }
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in self.nearby.removeAll { $0 == peerID } }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor in self.lastError = String(localized: "Couldn't look for sessions: \(error.localizedDescription)") }
    }
}
