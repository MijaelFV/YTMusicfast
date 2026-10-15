import Foundation
import Observation
import os

private let loungeLog = Logger(subsystem: "dev.ytmusicfast", category: "Lounge")

/// Which TVs play through their own YouTube app instead of this Mac's media server, so this Mac
/// can sleep while they play (the Connect panel's switch). Off for every TV until turned on.
@MainActor
@Observable
final class TVYouTubeApp {
    static let shared = TVYouTubeApp()
    private static let key = "castViaYouTubeApp"
    private(set) var deviceIds = Set(UserDefaults.standard.stringArray(forKey: TVYouTubeApp.key) ?? [])

    private init() {}

    /// Speakers have no YouTube app.
    func isOn(for device: CastDevice) -> Bool { !device.isSpeaker && deviceIds.contains(device.id) }

    func set(_ on: Bool, for device: CastDevice) {
        guard on != isOn(for: device), !device.isSpeaker || !on else { return }
        if on { deviceIds.insert(device.id) } else { deviceIds.remove(device.id) }
        UserDefaults.standard.set(deviceIds.sorted(), forKey: Self.key)
        CastController.shared.youTubeAppSettingChanged(for: device)
    }
}

/// A remote-control session with the YouTube app on a TV (see `Lounge`): pairs with its screen
/// id, sends commands one at a time, in order, and passes on what the TV reports. Listens with a
/// long poll that comes back by itself after this Mac sleeps or the network drops, binding a new
/// session (or getting a new token) when the old one is gone.
///
/// Exists only while playing through the TV's YouTube app; nothing of it runs otherwise.
actor YouTubeLounge {
    enum Failure: Error { case noToken, noSession, status(Int) }

    let screenId: String
    private let onEvent: @Sendable (Lounge.Event) -> Void
    private let session: URLSession
    /// This remote, to the TV (a new one each pairing).
    private let remoteId = UUID().uuidString.lowercased()
    private var token: String?
    private var sid: String?
    private var gsessionId: String?
    /// Request numbers, from a random start (as the protocol expects), and commands sent.
    private var rid = Int.random(in: 10_000..<90_000)
    private var offset = 0
    /// The newest event heard, so the server doesn't repeat the ones before.
    private var lastEventId = 0
    private var binding: Task<Void, Error>?
    private var listening: Task<Void, Never>?
    private var lastCommand: Task<Bool, Never>?
    private var closed = false

    init(screenId: String, onEvent: @escaping @Sendable (Lounge.Event) -> Void) {
        self.screenId = screenId
        self.onEvent = onEvent
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        session = URLSession(configuration: configuration)
    }

    /// Pairs with the TV and starts listening. Throws when the TV can't be paired with.
    func connect() async throws {
        try await bind()
        listening = Task { await listen() }
    }

    /// Sends a command after the ones before it; false when the TV couldn't be reached.
    @discardableResult
    func send(_ command: Lounge.Command) async -> Bool {
        let previous = lastCommand
        let task = Task<Bool, Never> {
            _ = await previous?.value
            return await post(command)
        }
        lastCommand = task
        return await task.value
    }

    /// Ends the session (the TV shows the remote leaving; what it plays carries on).
    func close() async {
        guard !closed else { return }
        closed = true
        listening?.cancel()
        listening = nil
        guard let sid, let gsessionId, let token else { return }
        var request = URLRequest(url: url("bc/bind", ["RID": "\(nextRid())", "SID": sid, "gsessionid": gsessionId, "VER": "8", "v": "2",
                                                       "name": Lounge.remoteName, "loungeIdToken": token, "TYPE": "terminate"]))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Lounge.form([("ui", ""), ("TYPE", "terminate"),
                                        ("clientDisconnectReason", "MDX_SESSION_DISCONNECT_REASON_DISCONNECTED_BY_USER")])
        _ = try? await session.data(for: request)
        session.invalidateAndCancel()
    }

    // MARK: Pairing

    private func refreshToken() async throws {
        var request = URLRequest(url: Lounge.base.appending(path: "pairing/get_lounge_token_batch"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Lounge.form([("screen_ids", screenId)])
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let answer = Lounge.loungeToken(in: data, screenId: screenId) else {
            loungeLog.error("no lounge token (HTTP \(status))")
            throw Failure.noToken
        }
        token = answer.token
    }

    /// Binds a new remote session (one at a time: others wait for it).
    private func bind() async throws {
        if let binding { return try await binding.value }
        let task = Task<Void, Error> {
            if token == nil { try await refreshToken() }
            do { try await bindOnce() } catch Failure.status(let status) where status == 401 || status == 403 {
                // An old token: a new one, once.
                try await refreshToken()
                try await bindOnce()
            }
        }
        binding = task
        defer { binding = nil }
        try await task.value
    }

    private func bindOnce() async throws {
        guard let token else { throw Failure.noToken }
        sid = nil
        gsessionId = nil
        lastEventId = 0
        offset = 0
        var request = URLRequest(url: url("bc/bind", ["RID": "\(nextRid())", "VER": "8", "CVER": "1", "auth_failure_option": "send_error"]))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "X-YouTube-LoungeId-Token")
        request.httpBody = Lounge.form(Lounge.bindForm(remoteId: remoteId))
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            loungeLog.error("bind failed (HTTP \(status))")
            throw Failure.status(status)
        }
        var reader = Lounge.ChunkReader()
        let events = reader.append(data)
        guard let ids = Lounge.session(in: events) else {
            loungeLog.error("bind answered without a session")
            throw Failure.noSession
        }
        sid = ids.sid
        gsessionId = ids.gsessionId
        loungeLog.notice("paired with the TV")
        deliver(events)
    }

    // MARK: Commands

    private func post(_ command: Lounge.Command) async -> Bool {
        for attempt in 0..<2 where !closed {
            if sid == nil {
                do { try await bind() } catch { return false }
            }
            guard let sid, let gsessionId, let token else { return false }
            var request = URLRequest(url: url("bc/bind", ["RID": "\(nextRid())", "SID": sid, "gsessionid": gsessionId, "AID": "\(lastEventId)",
                                                           "VER": "8", "v": "2", "name": Lounge.remoteName, "loungeIdToken": token]))
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Lounge.form(Lounge.commandForm(command, offset: offset))
            offset += 1
            let status: Int
            do {
                let (_, response) = try await session.data(for: request)
                status = (response as? HTTPURLResponse)?.statusCode ?? 0
            } catch {
                loungeLog.error("\(command.name, privacy: .public) not sent: \(error.localizedDescription, privacy: .public)")
                return false
            }
            if status == 200 { return true }
            loungeLog.notice("\(command.name, privacy: .public): HTTP \(status) (attempt \(attempt))")
            // The session is gone (it expires, and this Mac may have slept): pair again and retry.
            guard [400, 401, 403, 404, 410].contains(status) else { return false }
            self.sid = nil
            if status == 401 || status == 403 { self.token = nil }
        }
        return false
    }

    // MARK: Listening

    /// The long poll: each request streams events until the server ends it; then the next.
    private func listen() async {
        var failures = 0
        while !Task.isCancelled, !closed {
            do {
                if sid == nil { try await bind() }
                guard let sid, let gsessionId, let token else { throw Failure.noSession }
                var request = URLRequest(url: url("bc/bind", ["RID": "rpc", "SID": sid, "gsessionid": gsessionId, "AID": "\(lastEventId)",
                                                               "CI": "0", "TYPE": "xmlhttp", "VER": "8", "v": "2", "device": "REMOTE_CONTROL",
                                                               "name": Lounge.remoteName, "loungeIdToken": token]))
                // The server holds it open for minutes, sending a "noop" now and then.
                request.timeoutInterval = 300
                let (bytes, response) = try await session.bytes(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else {
                    if [400, 404, 410].contains(status) { self.sid = nil }
                    if status == 401 || status == 403 { self.sid = nil; self.token = nil }
                    throw Failure.status(status)
                }
                failures = 0
                var reader = Lounge.ChunkReader()
                for try await byte in bytes {
                    let events = reader.append(byte)
                    if !events.isEmpty { deliver(events) }
                }
            } catch {
                if Task.isCancelled || closed { return }
                failures += 1
                loungeLog.notice("listening stopped (\(String(describing: error), privacy: .public)); again in a moment")
                // Quickly at first (the server ending a poll is normal), slower when it keeps failing.
                try? await Task.sleep(for: .seconds(min(30, failures <= 1 ? 1 : 2 << min(failures, 4))))
            }
        }
    }

    private func deliver(_ events: [Lounge.Event]) {
        for event in events {
            lastEventId = max(lastEventId, event.id)
            if event.name == "noop" || event.name == "c" || event.name == "S" { continue }
            onEvent(event)
        }
    }

    // MARK: Helpers

    private func nextRid() -> Int {
        rid += 1
        return rid
    }

    private func url(_ path: String, _ query: [String: String]) -> URL {
        var components = URLComponents(url: Lounge.base.appending(path: path), resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = Lounge.formString(query.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
        return components.url!
    }
}
