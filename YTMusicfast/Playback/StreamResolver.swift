import Foundation

struct StreamInfo: Sendable {
    var url: URL
    var contentLength: Int
    var mimeType: String
    var expiresAt: Date
    /// Loudness relative to YouTube's reference level, used for volume normalization.
    var loudnessDb: Double?
    /// Real track length (from YouTube's metadata). AVFoundation used to read YouTube's files at
    /// twice their length — see FragmentedMP4.
    var duration: TimeInterval?
    /// YouTube's playback-stats ping for this play (used to add the song to your history).
    var statsURL: URL? = nil
    /// The same audio as Opus in WebM (itag 251, ~130–160 kbps — better than the AAC above), for
    /// players that repackage it (see WebMOpus). Nil when not offered or on Data saver.
    var opus: Variant? = nil

    struct Variant: Sendable {
        var url: URL
        var contentLength: Int
    }

    var isExpired: Bool { Date() > expiresAt.addingTimeInterval(-300) }
}

/// Resolves a video id into a directly playable audio URL.
///
/// Kept behind a protocol on purpose: the undocumented client used here will eventually
/// be patched by YouTube, and we want to swap in another strategy without touching playback.
protocol StreamResolver: Sendable {
    func resolve(videoId: String) async throws -> StreamInfo
}

/// One size of a music video's picture (video only; the sound comes from the song's stream).
struct VideoFormat: Sendable, Equatable {
    var url: URL
    var width: Int
    var height: Int
    var bitrate: Int
    var fps: Int
    /// As HLS wants it, e.g. "avc1.640028" or "av01.0.08M.08".
    var codecs: String
    var isAV1: Bool { codecs.hasPrefix("av01") }

    init?(_ format: JSON) {
        guard let mime = format["mimeType"].string, mime.hasPrefix("video/mp4"),
              let start = mime.range(of: "codecs=\""), let end = mime[start.upperBound...].firstIndex(of: "\""),
              let url = format["url"].string.flatMap(URL.init(string:)),
              let width = format["width"].int, let height = format["height"].int, height > 0 else { return nil }
        let codecs = String(mime[start.upperBound..<end])
        guard codecs.hasPrefix("avc1") || codecs.hasPrefix("av01") else { return nil }
        self.url = url
        self.width = width
        self.height = height
        self.bitrate = format["bitrate"].int ?? format["averageBitrate"].int ?? height * 2500
        self.fps = format["fps"].int ?? 30
        self.codecs = codecs
    }
}

/// How the app introduces itself to YouTube when asking for a stream: an InnerTube client that
/// returns plain (un-ciphered) addresses with no PO token or JS player needed. YouTube retires
/// these from time to time; see `ClientProfiles` for how the app keeps up without an update.
struct ClientProfile: Codable, Sendable, Equatable {
    var clientName: String
    var clientVersion: String
    /// The `X-YouTube-Client-Name` number.
    var clientNameId: String
    var userAgent: String
    var deviceMake: String?
    var deviceModel: String?
    var osName: String?
    var osVersion: String?

    /// Mirrors yt-dlp's default as of 2026-08.
    static let builtIn = [ClientProfile(
        clientName: "VISIONOS", clientVersion: "1.02", clientNameId: "101",
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
        deviceMake: "Apple", deviceModel: "RealityDevice17,1", osName: "visionOS", osVersion: "26.5.23O471"
    )]

    /// Plain names and numbers only: a profile from the network can't smuggle anything in.
    var isValid: Bool {
        let name = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ_0123456789")
        let fields = [clientVersion, userAgent, deviceMake ?? "", deviceModel ?? "", osName ?? "", osVersion ?? ""]
        return !clientName.isEmpty && clientName.count < 40 && clientName.unicodeScalars.allSatisfy(name.contains)
            && !clientNameId.isEmpty && clientNameId.count < 6 && clientNameId.allSatisfy(\.isASCII) && clientNameId.allSatisfy(\.isNumber)
            && !clientVersion.isEmpty && !userAgent.isEmpty
            && fields.allSatisfy { $0.count < 300 && $0.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7F } }
    }

    func context(visitor: String) -> [String: Any] {
        var client: [String: Any] = [
            "clientName": clientName, "clientVersion": clientVersion, "userAgent": userAgent,
            "hl": "en", "gl": Locale.current.region?.identifier ?? "US", "visitorData": visitor,
        ]
        if let deviceMake { client["deviceMake"] = deviceMake }
        if let deviceModel { client["deviceModel"] = deviceModel }
        if let osName { client["osName"] = osName }
        if let osVersion { client["osVersion"] = osVersion }
        return client
    }
}

/// The client profiles to use: any published in the project's `clients.json`, then the built-in
/// one. When YouTube retires a client, publishing a working profile there fixes playback for
/// every install within hours — no app update, no key, no account. Checked twice a day, and
/// right away when YouTube refuses every profile the app knows. Profiles only ever describe the
/// client; requests still go to youtube.com and nowhere else.
actor ClientProfiles {
    static let shared = ClientProfiles()
    static let address = URL(string: "https://raw.githubusercontent.com/MijaelFV/YTMusicfast/main/clients.json")!

    private struct Published: Codable {
        var audio: [ClientProfile]
    }

    private var published: [ClientProfile]
    private var lastCheck = Date.distantPast
    private var checking: Task<Bool, Never>?
    private let file: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("YTMusicfast/clients.json")
    }()

    private init() {
        published = (try? Data(contentsOf: file)).flatMap(Self.decode) ?? []
    }

    /// Published profiles first (they're newer), then the built-in ones.
    func profiles() -> [ClientProfile] {
        if Date().timeIntervalSince(lastCheck) > 12 * 3600 { Task { _ = await check() } }
        return published + ClientProfile.builtIn.filter { !published.contains($0) }
    }

    /// Looks for newly published profiles; true if they changed. At most once every 10 minutes.
    func check() async -> Bool {
        if let checking { return await checking.value }
        guard Date().timeIntervalSince(lastCheck) > 600 else { return false }
        lastCheck = Date()
        let task = Task { () -> Bool in
            var request = URLRequest(url: Self.address, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            request.setValue("YTMusicfast", forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200, data.count < 64 * 1024,
                  let fresh = Self.decode(data) else { return false }
            return adopt(fresh, data: data)
        }
        checking = task
        let changed = await task.value
        checking = nil
        return changed
    }

    private func adopt(_ fresh: [ClientProfile], data: Data) -> Bool {
        guard fresh != published else { return false }
        published = fresh
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        return true
    }

    static func decode(_ data: Data) -> [ClientProfile]? {
        guard let profiles = try? JSONDecoder().decode(Published.self, from: data).audio.filter(\.isValid).prefix(5),
              !profiles.isEmpty else { return nil }
        return Array(profiles)
    }
}

/// Resolves songs through InnerTube client profiles (see `ClientProfile`), trying each in turn.
actor VisionOSStreamResolver: StreamResolver {
    private let session: URLSession
    private var visitorData: String?
    private var cache: [String: StreamInfo] = [:]

    /// AVFoundation plays AAC-in-MP4 natively; prefer 128k, fall back to 48k HE-AAC
    /// (or the other way round with Settings → Streaming quality → Data saver, or in macOS's Low
    /// Data Mode). Songs play the Opus variant when there is one (see `StreamInfo.opus`).
    private static var dataSaver: Bool {
        UserDefaults.standard.string(forKey: "audioQuality") == "low" || NetworkSpeed.shared.isLowDataMode
    }

    private static var preferredItags: [Int] { dataSaver ? [139, 140] : [140, 139] }

    private static var wantsOpus: Bool { !dataSaver }

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)
    }

    func invalidate(_ videoId: String) {
        cache[videoId] = nil
    }

    /// The one-time hello every first song would otherwise wait for (the visitor id), done at
    /// launch instead.
    func warmUp() async {
        guard visitorData == nil, let profile = await ClientProfiles.shared.profiles().first else { return }
        _ = try? await visitorId(profile)
    }

    func resolve(videoId: String) async throws -> StreamInfo {
        if let cached = cache[videoId], !cached.isExpired { return cached }
        guard !Self.dataSaver else { return try await resolveStandard(videoId: videoId) }
        // Premium accounts get YouTube Music Premium's 256 kbps audio (see PremiumAudio). Asked
        // for alongside the standard stream, so neither waits on the other; the standard one
        // plays when there's no Premium (or it didn't work out).
        async let premium = PremiumAudio.shared.resolve(videoId: videoId)
        let standard: Result<StreamInfo, Error>
        do { standard = .success(try await resolveStandard(videoId: videoId)) } catch { standard = .failure(error) }
        if let premium = await premium {
            cache[videoId] = premium
            return premium
        }
        return try standard.get()
    }

    private func resolveStandard(videoId: String) async throws -> StreamInfo {
        do {
            return try await resolveWithAnyProfile(videoId: videoId, signedIn: false)
        } catch InnerTubeError.unplayable(let reason) where !reason.localizedCaseInsensitiveContains("bot") {
            // Your uploads and other private songs only play for your account. If that doesn't
            // work either, the song's own reason is the one worth showing.
            guard await InnerTube.shared.isAuthenticated,
                  let info = try? await resolveWithAnyProfile(videoId: videoId, signedIn: true) else {
                throw InnerTubeError.unplayable(reason)
            }
            return info
        }
    }

    /// Each profile in turn while YouTube refuses the client itself (not the song); when all
    /// are refused, checks once for newly published profiles and tries those.
    private func resolveWithAnyProfile(videoId: String, signedIn: Bool) async throws -> StreamInfo {
        var lastError: Error = InnerTubeError.noAudio
        for round in 0..<2 {
            for profile in await ClientProfiles.shared.profiles() {
                do {
                    return try await resolve(videoId: videoId, signedIn: signedIn, profile: profile)
                } catch where Self.isClientProblem(error) {
                    lastError = error
                }
            }
            guard round == 0, await ClientProfiles.shared.check() else { break }
        }
        throw lastError
    }

    /// YouTube turning the client away (an HTTP error, a bot check, addresses it won't give out)
    /// rather than the song being unavailable or the network being down.
    static func isClientProblem(_ error: Error) -> Bool {
        switch error as? InnerTubeError {
        case .http, .noAudio: true
        case .unplayable(let reason): reason.localizedCaseInsensitiveContains("bot")
        case nil: false
        }
    }

    private func playerRequest(videoId: String, profile: ClientProfile, signedIn: Bool) async throws -> JSON {
        let visitor = try await visitorId(profile)
        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "context": ["client": profile.context(visitor: visitor)],
            "videoId": videoId, "contentCheckOk": true, "racyCheckOk": true,
        ] as [String: Any])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(profile.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(profile.clientNameId, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(profile.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue(visitor, forHTTPHeaderField: "X-Goog-Visitor-Id")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        if signedIn, let headers = await InnerTube.shared.authHeaders(origin: "https://www.youtube.com") {
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        }
        let (data, response) = try await session.data(for: request)
        if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            throw InnerTubeError.http(status)
        }
        let json = try JSON(data: data)
        guard json.at("playabilityStatus", "status").string == "OK" else {
            let reason = json.at("playabilityStatus", "reason").string
            if reason?.contains("bot") == true { visitorData = nil }
            throw InnerTubeError.unplayable(reason ?? "This track can't be played")
        }
        return json
    }

    private func resolve(videoId: String, signedIn: Bool, profile: ClientProfile) async throws -> StreamInfo {
        let json = try await playerRequest(videoId: videoId, profile: profile, signedIn: signedIn)
        let formats = json.at("streamingData", "adaptiveFormats").array
        for itag in Self.preferredItags {
            guard let format = formats.first(where: { $0["itag"].int == itag }),
                  let urlString = format["url"].string, let url = URL(string: urlString),
                  let length = format["contentLength"].int
            else { continue }

            let expire = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "expire" }?.value.flatMap(TimeInterval.init)
            let info = StreamInfo(
                url: url,
                contentLength: length,
                mimeType: format["mimeType"].string ?? "audio/mp4",
                expiresAt: expire.map(Date.init(timeIntervalSince1970:)) ?? Date().addingTimeInterval(3 * 3600),
                loudnessDb: json.at("playerConfig", "audioConfig", "loudnessDb").double,
                duration: format["approxDurationMs"].double.map { $0 / 1000 }
                    ?? json.at("videoDetails", "lengthSeconds").double,
                statsURL: json.at("playbackTracking", "videostatsPlaybackUrl", "baseUrl").string.flatMap(URL.init(string:)),
                opus: Self.wantsOpus ? formats.first(where: { $0["itag"].int == 251 }).flatMap { format in
                    guard let url = format["url"].string.flatMap(URL.init(string:)), let length = format["contentLength"].int,
                          length > 0 else { return nil }
                    return StreamInfo.Variant(url: url, contentLength: length)
                } : nil
            )
            cache[videoId] = info
            return info
        }
        throw InnerTubeError.noAudio
    }

    /// A video-only H.264 stream for the music video view (audio keeps coming from `resolve`).
    /// Picks the highest quality up to `maxHeight`.
    /// Every size of a music video's picture YouTube offers in MP4 (H.264, and AV1), video only.
    func videoFormats(videoId: String) async throws -> [VideoFormat] {
        var lastError: Error = InnerTubeError.noAudio
        for profile in await ClientProfiles.shared.profiles() {
            do {
                let json = try await playerRequest(videoId: videoId, profile: profile, signedIn: false)
                let formats = json.at("streamingData", "adaptiveFormats").array.compactMap(VideoFormat.init)
                guard !formats.isEmpty else { throw InnerTubeError.noAudio }
                return formats
            } catch where Self.isClientProblem(error) {
                lastError = error
            }
        }
        throw lastError
    }

    /// For `ytmusicfast diagnose`: which audio each client offers for a song, signed out and in,
    /// and whether YouTube lets it download (two pieces, the start and further in). Reports
    /// format numbers and yes/no only — never addresses or cookies.
    func diagnose(videoId: String) async -> String {
        let others = [
            ClientProfile(clientName: "IOS_MUSIC", clientVersion: "7.27.0", clientNameId: "26",
                          userAgent: "com.google.ios.youtubemusic/7.27.0 (iPhone16,2; U; CPU iOS 18_1 like Mac OS X;)",
                          deviceMake: "Apple", deviceModel: "iPhone16,2", osName: "iPhone", osVersion: "18.1.0.22B83"),
            ClientProfile(clientName: "ANDROID_VR", clientVersion: "1.65.10", clientNameId: "28",
                          userAgent: "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
                          deviceMake: "Oculus", deviceModel: "Quest 3", osName: "Android", osVersion: "12L"),
            ClientProfile(clientName: "WEB_REMIX", clientVersion: "1.20250122.01.00", clientNameId: "67",
                          userAgent: InnerTube.safariUserAgent),
        ]
        let names = [139: "AAC 48k", 140: "AAC 128k", 141: "AAC 256k (Premium)", 249: "Opus 50k", 250: "Opus 70k",
                     251: "Opus 160k", 774: "Opus 256k (Premium)"]
        let signedInToo = await InnerTube.shared.isAuthenticated
        var lines = ["Signed in: \(signedInToo ? "yes" : "no")"]
        for profile in await ClientProfiles.shared.profiles() + others {
            for signedIn in signedInToo ? [false, true] : [false] {
                var line = "\(profile.clientName) \(signedIn ? "signed in" : "signed out"): "
                do {
                    let json = try await playerRequest(videoId: videoId, profile: profile, signedIn: signedIn)
                    let audio = json.at("streamingData", "adaptiveFormats").array.filter { ($0["mimeType"].string ?? "").hasPrefix("audio/") }
                    var parts: [String] = []
                    for format in audio {
                        guard let itag = format["itag"].int else { continue }
                        var part = "\(itag) \(names[itag] ?? "")"
                        if let address = format["url"].string.flatMap(URL.init(string:)), let length = format["contentLength"].int {
                            let start = await Self.downloads(address, 0, min(length, 1 << 20) - 1)
                            let later = length > 3 << 20 ? await Self.downloads(address, 2 << 20, (3 << 20) - 1) : start
                            part += start && later ? " ✓" : start ? " (refused after the start)" : " (refused)"
                        } else {
                            part += format["signatureCipher"].exists ? " (scrambled address)" : " (no address)"
                        }
                        parts.append(part)
                    }
                    line += parts.isEmpty ? "no audio" : parts.joined(separator: ", ")
                } catch {
                    line += "refused — \(error.localizedDescription)"
                }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func downloads(_ address: URL, _ start: Int, _ end: Int) async -> Bool {
        guard var components = URLComponents(url: address, resolvingAgainstBaseURL: false) else { return false }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "range", value: "\(start)-\(end)")]
        guard let url = components.url else { return false }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(InnerTube.safariUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200 && data.count == end - start + 1
    }

    /// Anonymous visitor id; without it most requests hit "Sign in to confirm you're not a bot".
    private func visitorId(_ profile: ClientProfile) async throws -> String {
        if let visitorData { return visitorData }
        var request = URLRequest(url: URL(string: "https://www.youtube.com/sw.js_data")!)
        request.setValue(profile.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: request)
        // Response is prefixed with ")]}'\n" to defeat JSON hijacking.
        let json = try JSON(data: data.dropFirst(5))
        guard let id = json.at(0, 2, 0, 0, 13).string else { throw InnerTubeError.unplayable("Couldn't get a visitor id") }
        visitorData = id
        return id
    }
}

/// Fallback that shells out to a locally installed `yt-dlp`, which tracks YouTube's changes
/// daily. Slower (~2–3 s per track) but keeps playback working when our own client breaks.
actor YtDlpStreamResolver: StreamResolver {
    private let candidates: [URL]
    private var chosen: URL?

    init(candidates: [URL]) {
        self.candidates = candidates
    }

    /// Finds yt-dlp in the usual install locations (GUI apps don't inherit the shell PATH).
    /// Cheap: only checks the files exist; versions are compared on first use.
    static func locate() -> YtDlpStreamResolver? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp", "\(home)/.local/bin/yt-dlp", "/usr/bin/yt-dlp"]
        let found = paths.filter { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
        return found.isEmpty ? nil : YtDlpStreamResolver(candidates: found)
    }

    /// Several copies are common (Homebrew, pip, standalone); an outdated one is useless against
    /// YouTube, so use the newest. Versions are dates like `2026.08.19`.
    private func executable() async throws -> URL {
        if let chosen { return chosen }
        var best: (url: URL, version: [Int])?
        for url in candidates {
            guard let output = try? await Self.run(url, ["--version"]), output.status == 0 else { continue }
            let version = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".").compactMap { Int($0) }
            if best == nil || best!.version.lexicographicallyPrecedes(version) {
                best = (url, version)
            }
        }
        guard let best else { throw InnerTubeError.noAudio }
        chosen = best.url
        return best.url
    }

    private static func run(_ executable: URL, _ arguments: [String]) async throws -> (status: Int32, stdout: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // Make sure yt-dlp finds python and a JS runtime (deno/node) for YouTube's challenges.
        var env = ProcessInfo.processInfo.environment
        let home = env["HOME"] ?? ""
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(home)/.local/bin:\(home)/.deno/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        process.environment = env
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let data: Data = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { _ in
                continuation.resume(returning: output.fileHandleForReading.readDataToEndOfFile())
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func resolve(videoId: String) async throws -> StreamInfo {
        let output = try await Self.run(try await executable(), [
            "--no-warnings", "--no-playlist", "--no-progress",
            "-f", "140/139/bestaudio[ext=m4a]",
            "--print", "%(url)s", "--print", "%(filesize,filesize_approx)s", "--print", "%(duration)s",
            "https://music.youtube.com/watch?v=\(videoId)",
        ])
        let lines = output.stdout.split(separator: "\n").map(String.init)
        guard output.status == 0, lines.count >= 2, let url = URL(string: lines[0]) else {
            throw InnerTubeError.noAudio
        }
        var length = Int(lines[1]) ?? 0
        if length == 0 {
            // Some formats only report an approximate size; ask the CDN for the real one.
            length = Int(URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "clen" }?.value ?? "") ?? 0
        }
        guard length > 0 else { throw InnerTubeError.noAudio }
        let expire = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "expire" }?.value.flatMap(TimeInterval.init)
        return StreamInfo(
            url: url,
            contentLength: length,
            mimeType: "audio/mp4",
            expiresAt: expire.map(Date.init(timeIntervalSince1970:)) ?? Date().addingTimeInterval(3 * 3600),
            loudnessDb: nil,
            duration: lines.count > 2 ? Double(lines[2]) : nil
        )
    }
}

/// Tries each resolver in order and remembers which one last worked.
actor ChainedStreamResolver: StreamResolver {
    private let resolvers: [any StreamResolver]

    init(_ resolvers: [any StreamResolver]) {
        self.resolvers = resolvers
    }

    /// One resolver for the app: playback and downloads share its cache of stream URLs.
    static let shared = ChainedStreamResolver.standard()

    static func standard() -> ChainedStreamResolver {
        var chain: [any StreamResolver] = [VisionOSStreamResolver()]
        if let ytdlp = YtDlpStreamResolver.locate() { chain.append(ytdlp) }
        return ChainedStreamResolver(chain)
    }

    /// See `VisionOSStreamResolver.warmUp`.
    func warmUp() async {
        for case let client as VisionOSStreamResolver in resolvers { await client.warmUp() }
    }

    /// See `VisionOSStreamResolver.diagnose`.
    func diagnose(videoId: String) async -> String {
        var report = "No InnerTube client"
        for case let client as VisionOSStreamResolver in resolvers { report = await client.diagnose(videoId: videoId) }
        return report + "\n" + (await PremiumAudio.shared.describe(videoId: videoId))
    }

    /// The music video's picture (VISIONOS client; yt-dlp isn't asked for video).
    func videoFormats(videoId: String) async throws -> [VideoFormat] {
        for case let visionOS as VisionOSStreamResolver in resolvers {
            return try await visionOS.videoFormats(videoId: videoId)
        }
        throw InnerTubeError.noAudio
    }

    func invalidate(_ videoId: String) async {
        for case let visionOS as VisionOSStreamResolver in resolvers { await visionOS.invalidate(videoId) }
    }

    func resolve(videoId: String) async throws -> StreamInfo {
        var lastError: Error = InnerTubeError.noAudio
        for resolver in resolvers {
            try Task.checkCancellation()
            do {
                return try await resolver.resolve(videoId: videoId)
            } catch {
                // Skipped past: not a reason to try the next one (yt-dlp is a whole process).
                if Task.isCancelled { throw CancellationError() }
                lastError = error
                // A genuine "this track can't be played" (removed, region-locked) won't be fixed by
                // yt-dlp either, but bot checks and missing formats might be — so keep going.
            }
        }
        throw lastError
    }
}
