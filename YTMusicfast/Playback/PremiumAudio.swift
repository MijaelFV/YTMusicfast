import AVFoundation
import Foundation
import JavaScriptCore
import os

private let premiumLog = Logger(subsystem: "dev.ytmusicfast", category: "Premium")

/// YouTube Music Premium's own audio for Premium accounts: Opus at about 256 kbps (itag 774) and
/// AAC at 256 kbps (141), versus 160 kbps for everyone else.
///
/// YouTube hands these only to its website client, with addresses that only the code of its web
/// player can complete. So this fetches that code (once per player version, kept on disk) and
/// runs it through yt-dlp's open-source solver (github.com/yt-dlp/ejs, bundled in
/// Resources/Solver) in macOS's JavaScript engine. Premium accounts need no other token.
/// Anything that doesn't work out returns nil and the standard 160 kbps stream plays instead.
actor PremiumAudio {
    static let shared = PremiumAudio()

    /// What's needed from YouTube Music's web player, for one player version.
    private struct Player: Codable {
        var id: String
        var signatureTimestamp: Int
        var clientVersion: String
        var fetched: Date
    }

    private static let accountKey = "premiumAudio"

    /// The signed-in account got Premium audio last time it was asked (cheap; any thread).
    nonisolated static var isPremiumAccount: Bool { UserDefaults.standard.bool(forKey: accountKey) }

    private var player: Player?
    /// Set when the account turned out not to be Premium, or YouTube changed something the
    /// solver can't follow: the standard stream is used until then without asking again.
    private var pausedUntil = Date.distantPast
    private var preparing: Task<Player?, Never>?
    /// The solver and the player's functions (several MB together): loaded while songs are
    /// coming, let go after a minute without any.
    private var solver: (context: JSContext, functions: String, playerId: String)?
    private var solverIdle: Task<Void, Never>?

    private let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("YTMusicfast/Player", isDirectory: true)
    }()

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    /// The solver's digest of the player's code — just the functions it needs — kept on disk
    /// rather than in memory.
    private var functionsFile: URL { directory.appendingPathComponent("player-functions.js") }

    private init() {
        player = (try? Data(contentsOf: directory.appendingPathComponent("player.json")))
            .flatMap { try? JSONDecoder().decode(Player.self, from: $0) }
        if !FileManager.default.fileExists(atPath: functionsFile.path) { player = nil }
    }

    /// The Premium stream for a song, or nil (not signed in, not Premium, or it didn't work).
    func resolve(videoId: String) async -> StreamInfo? {
        guard Date() > pausedUntil, await InnerTube.shared.isAuthenticated else { return nil }
        guard let player = await currentPlayer() else { return nil }
        do {
            return try await streams(videoId: videoId, player: player)
        } catch where Task.isCancelled {
            // The song was skipped past: that says nothing about Premium or the player.
        } catch PremiumError.notPremium {
            premiumLog.notice("no Premium formats offered; using the standard stream")
            pausedUntil = Date().addingTimeInterval(6 * 3600)
        } catch PremiumError.refused, PremiumError.unsolved {
            // The player may have changed under us: read it afresh next time.
            premiumLog.error("Premium address not usable; checking the player again later")
            self.player = nil
            pausedUntil = Date().addingTimeInterval(15 * 60)
        } catch {
            premiumLog.error("Premium stream failed: \(String(describing: error), privacy: .public)")
        }
        return nil
    }

    /// Whether the signed-in account gets Premium audio (for `ytmusicfast diagnose`).
    func describe(videoId: String) async -> String {
        guard await InnerTube.shared.isAuthenticated else { return "Premium audio: not signed in" }
        let started = Date()
        guard let player = await currentPlayer(waiting: true) else { return "Premium audio: couldn't read YouTube Music's player" }
        let prepared = Date()
        do {
            guard let info = try await streams(videoId: videoId, player: player) else { return "Premium audio: not offered" }
            var opus = info.opus.map { "Opus 256k \($0.contentLength / 1024) KB ✓" } ?? "no Opus"
            // The whole Opus file, repackaged as it would be for playback.
            if let variant = info.opus, let webm = await Self.whole(variant) {
                if let layout = WebMOpus.layout(webm) {
                    let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
                    defer { try? FileManager.default.removeItem(at: file) }
                    try? WebMOpus.write(layout, from: webm, to: file)
                    let asset = AVURLAsset(url: file)
                    let playable = (try? await asset.load(.isPlayable)) ?? false
                    let seconds = (try? await asset.load(.duration).seconds) ?? 0
                    opus += String(format: " (repackaged: %d packets, plays %@, %.1f s)", layout.packets.count, playable ? "✓" : "✗", seconds)
                } else {
                    opus += " (DOESN'T repackage)"
                }
            }
            return String(format: "Premium audio (player %@): %@, %@ %d KB ✓ — player %.2fs, song %.2fs", player.id, opus,
                          info.mimeType == "audio/mp4" ? "AAC 256k" : "main", info.contentLength / 1024,
                          prepared.timeIntervalSince(started), Date().timeIntervalSince(prepared))
        } catch {
            return "Premium audio (player \(player.id)): \(error)"
        }
    }

    private enum PremiumError: Error {
        case notPremium, refused, unsolved, noAddress
    }

    // MARK: The song's streams

    private func streams(videoId: String, player: Player) async throws -> StreamInfo? {
        guard let headers = await InnerTube.shared.authHeaders(origin: "https://music.youtube.com") else { return nil }
        var request = URLRequest(url: URL(string: "https://music.youtube.com/youtubei/v1/player?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "context": ["client": [
                "clientName": "WEB_REMIX", "clientVersion": player.clientVersion, "hl": "en",
                "gl": Locale.current.region?.identifier ?? "US", "userAgent": InnerTube.safariUserAgent,
            ]],
            "videoId": videoId,
            "playbackContext": ["contentPlaybackContext": ["signatureTimestamp": player.signatureTimestamp]],
            "contentCheckOk": true, "racyCheckOk": true,
        ] as [String: Any])
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(InnerTube.safariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("67", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(player.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let json = try JSON(data: data)
        guard json.at("playabilityStatus", "status").string == "OK" else { return nil }
        let formats = json.at("streamingData", "adaptiveFormats").array
        let opusFormat = formats.first { $0["itag"].int == 774 }
        let aacFormat = formats.first { $0["itag"].int == 141 }
        guard opusFormat != nil || aacFormat != nil else {
            UserDefaults.standard.set(false, forKey: Self.accountKey)
            throw PremiumError.notPremium
        }
        UserDefaults.standard.set(true, forKey: Self.accountKey)

        // All addresses in one go (running the solver is the slow part).
        let opus = try opusFormat.map(Self.pieces)
        let aac = try aacFormat.map(Self.pieces)
        let all = [opus, aac].compactMap { $0 }
        // Solves run one at a time: one for a song already skipped past mustn't hold up the next.
        try Task.checkCancellation()
        let solved = try solve(sig: all.compactMap(\.sig), n: all.compactMap(\.n), player: player)
        func address(_ piece: Pieces) throws -> URL {
            guard var components = URLComponents(url: piece.url, resolvingAgainstBaseURL: false) else { throw PremiumError.noAddress }
            var items = components.queryItems ?? []
            if let sig = piece.sig {
                guard let value = solved[sig] else { throw PremiumError.unsolved }
                items.append(URLQueryItem(name: piece.sigParameter, value: value))
            }
            if let n = piece.n {
                guard let value = solved[n] else { throw PremiumError.unsolved }
                items = items.map { $0.name == "n" ? URLQueryItem(name: "n", value: value) : $0 }
            }
            components.queryItems = items
            guard let url = components.url else { throw PremiumError.noAddress }
            return url
        }

        let opusVariant = try opus.map { StreamInfo.Variant(url: try address($0), contentLength: $0.length) }
        let aacVariant = try aac.map { StreamInfo.Variant(url: try address($0), contentLength: $0.length) }
        // Make sure YouTube lets them download before betting the song on them.
        async let opusWorks = Self.downloads(opusVariant)
        async let aacWorks = Self.downloads(aacVariant)
        let works = await (opusWorks, aacWorks)
        try Task.checkCancellation()
        guard works.0, works.1 else { throw PremiumError.refused }
        // The AAC is the main stream (long recordings, Cast); without it there's nothing to
        // fall back to here, so the standard stream plays instead.
        guard let aacVariant else { return nil }
        let expire = URLComponents(url: aacVariant.url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "expire" }?.value.flatMap(TimeInterval.init)
        return StreamInfo(
            url: aacVariant.url,
            contentLength: aacVariant.contentLength,
            mimeType: "audio/mp4",
            expiresAt: expire.map(Date.init(timeIntervalSince1970:)) ?? Date().addingTimeInterval(3 * 3600),
            loudnessDb: json.at("playerConfig", "audioConfig", "loudnessDb").double,
            duration: aacFormat?["approxDurationMs"].double.map { $0 / 1000 } ?? json.at("videoDetails", "lengthSeconds").double,
            statsURL: json.at("playbackTracking", "videostatsPlaybackUrl", "baseUrl").string.flatMap(URL.init(string:)),
            opus: opusVariant
        )
    }

    private struct Pieces {
        var url: URL
        var length: Int
        var sig: String?
        var sigParameter: String
        var n: String?
    }

    private static func pieces(_ format: JSON) throws -> Pieces {
        guard let length = format["contentLength"].int, length > 0 else { throw PremiumError.noAddress }
        var address = format["url"].string
        var sig: String?
        var parameter = "signature"
        if let cipher = format["signatureCipher"].string {
            var fields: [String: String] = [:]
            for pair in cipher.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                if parts.count == 2 { fields[String(parts[0])] = String(parts[1]).removingPercentEncoding }
            }
            address = fields["url"]
            sig = fields["s"]
            parameter = fields["sp"] ?? "signature"
        }
        // No address at all: YouTube wants its newer streaming protocol, which isn't supported.
        guard let address, let url = URL(string: address) else { throw PremiumError.noAddress }
        let n = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "n" }?.value
        return Pieces(url: url, length: length, sig: sig, sigParameter: parameter, n: n)
    }

    /// A whole file, in 1 MB pieces (for `describe`).
    private static func whole(_ variant: StreamInfo.Variant) async -> Data? {
        var data = Data(capacity: variant.contentLength)
        while data.count < variant.contentLength {
            let end = min(variant.contentLength, data.count + (1 << 20)) - 1
            guard var components = URLComponents(url: variant.url, resolvingAgainstBaseURL: false) else { return nil }
            components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "range", value: "\(data.count)-\(end)")]
            guard let url = components.url else { return nil }
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue(InnerTube.safariUserAgent, forHTTPHeaderField: "User-Agent")
            guard let (piece, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200, piece.count == end - data.count + 1 else { return nil }
            data += piece
        }
        return data
    }

    private static func downloads(_ variant: StreamInfo.Variant?) async -> Bool {
        guard let variant else { return true }
        guard var components = URLComponents(url: variant.url, resolvingAgainstBaseURL: false) else { return false }
        let end = min(variant.contentLength, 4096) - 1
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "range", value: "0-\(end)")]
        guard let url = components.url else { return false }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue(InnerTube.safariUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200 && data.count == end + 1
    }

    // MARK: The solver

    /// Runs the player's functions on `sig` and `n` values.
    private func solve(sig: [String], n: [String], player: Player) throws -> [String: String] {
        guard !sig.isEmpty || !n.isEmpty else { return [:] }
        let solver = try solverContext(for: player)
        var requests: [[String: Any]] = []
        if !sig.isEmpty { requests.append(["type": "sig", "challenges": Array(Set(sig))]) }
        if !n.isEmpty { requests.append(["type": "n", "challenges": Array(Set(n))]) }
        let input: [String: Any] = ["type": "preprocessed", "preprocessed_player": solver.functions, "requests": requests]
        guard let output = solver.context.objectForKeyedSubscript("jsc")?.call(withArguments: [input])?.toDictionary(),
              let responses = output["responses"] as? [[String: Any]] else { throw PremiumError.unsolved }
        var solved: [String: String] = [:]
        for response in responses {
            guard response["type"] as? String == "result", let data = response["data"] as? [String: String] else {
                premiumLog.error("solver: \(String(describing: response["error"] ?? "no result"), privacy: .public)")
                throw PremiumError.unsolved
            }
            solved.merge(data) { first, _ in first }
        }
        scheduleSolverRelease()
        return solved
    }

    /// The solver, kept while songs keep coming (see `scheduleSolverRelease`).
    private func solverContext(for player: Player) throws -> (context: JSContext, functions: String, playerId: String) {
        if let solver, solver.playerId == player.id { return solver }
        guard let context = Self.loadSolver(),
              let functions = try? String(contentsOf: functionsFile, encoding: .utf8) else { throw PremiumError.unsolved }
        let loaded = (context, functions, player.id)
        solver = loaded
        return loaded
    }

    /// Collects what the solver allocated and lets it go (JavaScriptCore otherwise keeps its heap
    /// for a while).
    private func releaseSolver() {
        if let context = solver?.context { JSGarbageCollect(context.jsGlobalContextRef) }
        solver = nil
    }

    /// Each solver runs in its own JavaScript machine, so letting it go returns all of its memory.
    private static func loadSolver() -> JSContext? {
        guard let lib = script("yt.solver.lib.min"), let core = script("yt.solver.core.min"),
              let context = JSContext(virtualMachine: JSVirtualMachine()) else { return nil }
        context.evaluateScript(lib)
        context.evaluateScript("Object.assign(globalThis, lib);")
        context.evaluateScript(core)
        guard context.exception == nil, context.objectForKeyedSubscript("jsc")?.isObject == true else {
            premiumLog.error("solver didn't load: \(String(describing: context.exception), privacy: .public)")
            return nil
        }
        return context
    }

    /// The solver's memory goes back after a minute without songs to resolve.
    private func scheduleSolverRelease() {
        solverIdle?.cancel()
        solverIdle = Task {
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            self.releaseSolver()
        }
    }

    private static func script(_ name: String) -> String? {
        Bundle.main.url(forResource: name, withExtension: "js").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    // MARK: YouTube Music's web player

    /// The player to use: the saved one for up to three days, else whatever YouTube Music serves
    /// now. YouTube rotates between player versions all day, and an older one keeps working, so
    /// there's no need to follow each (reading a new one takes a couple of seconds and, briefly,
    /// over 100 MB). One that stops working is replaced at once (see `resolve`).
    /// `waiting` false (a song about to play): never waits for a player to be read — an older
    /// one is used while the new one is read in the background, and with none at all the song
    /// plays in standard quality this once.
    private func currentPlayer(waiting: Bool = false) async -> Player? {
        if let player, Date().timeIntervalSince(player.fetched) < 3 * 86400 { return player }
        let task = preparing ?? Task { await prepare() }
        if preparing == nil {
            preparing = task
            Task {
                let fresh = await task.value
                if let fresh { player = fresh }
                preparing = nil
            }
        }
        guard waiting else { return player }
        return await task.value ?? player
    }

    /// Reads YouTube Music's player ahead of the first song (after launch, Premium accounts only),
    /// so no song ever waits for it.
    func prepareInBackground() async {
        guard Self.isPremiumAccount, await InnerTube.shared.isAuthenticated else { return }
        _ = await currentPlayer(waiting: false)
    }

    /// Reads which player YouTube Music uses; when it's a new one, downloads its code and has the
    /// solver pick out the functions it needs (a second or two, once per player version).
    private func prepare() async -> Player? {
        var request = URLRequest(url: URL(string: "https://music.youtube.com/")!)
        request.setValue(InnerTube.safariUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await session.data(for: request) else { return nil }
        let page = String(decoding: data, as: UTF8.self)
        guard let path = Self.first(#""jsUrl":"(/s/player/([A-Za-z0-9_-]+)/[^"]+/base\.js)""#, in: page, groups: 2), path.count == 2,
              let clientVersion = Self.first(#""INNERTUBE_CLIENT_VERSION":"([0-9.]+)""#, in: page)?.first else { return nil }
        let id = path[1]
        if var same = player, same.id == id {
            same.clientVersion = clientVersion
            same.fetched = Date()
            save(same)
            return same
        }
        guard let codeURL = URL(string: "https://music.youtube.com" + path[0]),
              let (code, _) = try? await session.data(from: codeURL) else { return nil }
        let source = String(decoding: code, as: UTF8.self)
        guard let stamp = Self.first(#"signatureTimestamp:(\d+)"#, in: source)?.first.flatMap(Int.init),
              let preprocessed = Self.preprocess(source) else {
            premiumLog.error("couldn't read player \(id, privacy: .public)")
            return nil
        }
        let fresh = Player(id: id, signatureTimestamp: stamp, clientVersion: clientVersion, fetched: Date())
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(preprocessed.utf8).write(to: functionsFile, options: .atomic)
        } catch {
            return nil
        }
        releaseSolver()
        save(fresh)
        premiumLog.notice("prepared player \(id, privacy: .public)")
        return fresh
    }

    /// Runs the full solver (with its parser) once over the player's code; that context is
    /// thrown away afterwards.
    private static func preprocess(_ source: String) -> String? {
        guard let context = loadSolver() else { return nil }
        let input: [String: Any] = ["type": "player", "player": source, "requests": [], "output_preprocessed": true]
        defer { JSGarbageCollect(context.jsGlobalContextRef) }
        guard let output = context.objectForKeyedSubscript("jsc")?.call(withArguments: [input])?.toDictionary(),
              let preprocessed = output["preprocessed_player"] as? String, !preprocessed.isEmpty else { return nil }
        return preprocessed
    }

    private func save(_ player: Player) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(player) {
            try? data.write(to: directory.appendingPathComponent("player.json"), options: .atomic)
        }
    }

    private static func first(_ pattern: String, in text: String, groups: Int = 1) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1...groups).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
    }
}
