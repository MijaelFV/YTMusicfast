import CryptoKit
import Foundation
import os

private let log = Logger(subsystem: "dev.ytmusicfast", category: "InnerTube")

enum InnerTubeError: LocalizedError {
    case http(Int)
    case unplayable(String)
    case noAudio

    var errorDescription: String? {
        switch self {
        case .http(let code): "YouTube returned HTTP \(code)"
        case .unplayable(let reason): reason
        case .noAudio: "No playable audio stream"
        }
    }
}

/// Google session cookies captured from the sign-in web view.
struct Credentials: Sendable, Equatable {
    var cookieHeader: String

    var sapisid: String? {
        let pairs = cookieHeader.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        for name in ["SAPISID", "__Secure-3PAPISID"] {
            if let pair = pairs.first(where: { $0.hasPrefix(name + "=") }) {
                return String(pair.dropFirst(name.count + 1))
            }
        }
        return nil
    }
}

/// Talks to YouTube Music's private InnerTube API (`music.youtube.com/youtubei/v1`).
actor InnerTube {
    static let shared = InnerTube()

    static let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    private static let origin = "https://music.youtube.com"

    private let session: URLSession
    private var credentials: Credentials?
    private var visitorData: String?

    init() {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)
    }

    var isAuthenticated: Bool { credentials?.sapisid != nil }

    func setCredentials(_ credentials: Credentials?) {
        self.credentials = credentials
    }

    private static var clientVersion: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "1.\(formatter.string(from: Date().addingTimeInterval(-86_400))).01.00"
    }

    private var context: [String: Any] {
        let locale = Locale.current
        var client: [String: Any] = [
            "clientName": "WEB_REMIX",
            "clientVersion": Self.clientVersion,
            "hl": locale.language.languageCode?.identifier ?? "en",
            "gl": locale.region?.identifier ?? "US",
        ]
        if let visitorData { client["visitorData"] = visitorData }
        return ["client": client, "user": [:] as [String: Any]]
    }

    /// POSTs to an InnerTube endpoint such as `browse`, `search` or `next`.
    func post(_ endpoint: String, body: [String: Any]) async throws -> JSON {
        var payload = body
        payload["context"] = context

        var request = URLRequest(url: URL(string: "\(Self.origin)/youtubei/v1/\(endpoint)?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.safariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.origin, forHTTPHeaderField: "Origin")
        request.setValue(Self.origin, forHTTPHeaderField: "X-Origin")
        request.setValue("67", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(Self.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        if let visitorData { request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id") }

        if let credentials, let sapisid = credentials.sapisid {
            request.setValue(credentials.cookieHeader, forHTTPHeaderField: "Cookie")
            request.setValue(Self.sapisidHash(sapisid), forHTTPHeaderField: "Authorization")
            request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
        }

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw InnerTubeError.http(http.statusCode)
        }
        let json = try JSON(data: ScreenshotNames.apply(data))
        if credentials != nil {
            // Diagnostics only: whether YouTube treated this request as signed in. Never logs cookies.
            let loggedIn = json.at("responseContext", "serviceTrackingParams").array
                .flatMap { $0["params"].array }
                .first { $0["key"].string == "logged_in" }?["value"].string ?? "?"
            log.notice("\(endpoint, privacy: .public) status=\((response as? HTTPURLResponse)?.statusCode ?? 0) logged_in=\(loggedIn, privacy: .public)")
        }
        if visitorData == nil, let vd = json.at("responseContext", "visitorData").string {
            visitorData = vd
        }
        return json
    }

    private static var webClientVersion: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "2.\(formatter.string(from: Date().addingTimeInterval(-86_400))).00.00"
    }

    /// An anonymous request to the regular YouTube site (WEB client, English, so labels can be
    /// matched by their text). Used for data YouTube Music doesn't return, like AI disclosures.
    func postWeb(_ endpoint: String, body: [String: Any], signedIn: Bool = false) async throws -> JSON {
        var payload = body
        payload["context"] = ["client": ["clientName": "WEB", "clientVersion": Self.webClientVersion, "hl": "en", "gl": "US"]]
        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/\(endpoint)?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.safariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("1", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(Self.webClientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        if signedIn, let headers = authHeaders(origin: "https://www.youtube.com") {
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw InnerTubeError.http(http.statusCode)
        }
        return try JSON(data: ScreenshotNames.apply(data))
    }

    /// Signed-in headers for a request to another YouTube origin (the hash covers the origin).
    func authHeaders(origin: String) -> [String: String]? {
        guard let credentials, let sapisid = credentials.sapisid else { return nil }
        return [
            "Cookie": credentials.cookieHeader,
            "Authorization": Self.sapisidHash(sapisid, origin: origin),
            "X-Goog-AuthUser": "0",
            "Origin": origin,
        ]
    }

    /// YouTube Music uploads: a resumable upload to upload.youtube.com (as the website does).
    func uploadMusic(_ file: URL) async throws {
        guard let headers = authHeaders(origin: Self.origin) else { throw InnerTubeError.unplayable("Sign in to upload music") }
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else { throw InnerTubeError.unplayable("That file is empty") }

        var start = URLRequest(url: URL(string: "https://upload.youtube.com/upload/usermusic/http?authuser=0")!)
        start.httpMethod = "POST"
        for (key, value) in headers { start.setValue(value, forHTTPHeaderField: key) }
        start.setValue(Self.safariUserAgent, forHTTPHeaderField: "User-Agent")
        start.setValue("application/x-www-form-urlencoded;charset=utf-8", forHTTPHeaderField: "Content-Type")
        start.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        start.setValue(String(size), forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        start.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        start.httpBody = Data("filename=\(file.lastPathComponent)".utf8)
        let (_, response) = try await session.data(for: start)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let uploadURL = http.value(forHTTPHeaderField: "X-Goog-Upload-URL").flatMap(URL.init(string:))
        else { throw InnerTubeError.unplayable("YouTube didn't accept the upload") }

        var upload = URLRequest(url: uploadURL)
        upload.httpMethod = "POST"
        for (key, value) in headers { upload.setValue(value, forHTTPHeaderField: key) }
        upload.setValue(Self.safariUserAgent, forHTTPHeaderField: "User-Agent")
        upload.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        upload.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        upload.timeoutInterval = 600
        let (_, done) = try await session.upload(for: upload, fromFile: file)
        guard let status = (done as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw InnerTubeError.unplayable("The upload failed")
        }
    }

    /// A signed-in GET (playback stats pings), with the same cookies and auth as `post` — only to
    /// YouTube: the address comes from a response, and the session must never go anywhere else.
    func get(_ url: URL) async throws {
        var request = URLRequest(url: url)
        request.setValue(Self.safariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.origin, forHTTPHeaderField: "Origin")
        let host = url.host?.lowercased() ?? ""
        let youtube = url.scheme == "https" && (host == "youtube.com" || host.hasSuffix(".youtube.com"))
        if youtube, let credentials, let sapisid = credentials.sapisid {
            request.setValue(credentials.cookieHeader, forHTTPHeaderField: "Cookie")
            request.setValue(Self.sapisidHash(sapisid), forHTTPHeaderField: "Authorization")
            request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
        }
        let (_, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw InnerTubeError.http(http.statusCode)
        }
    }

    private static func sapisidHash(_ sapisid: String, origin: String = InnerTube.origin) -> String {
        let timestamp = Int(Date().timeIntervalSince1970)
        let digest = Insecure.SHA1.hash(data: Data("\(timestamp) \(sapisid) \(origin)".utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "SAPISIDHASH \(timestamp)_\(hex)"
    }
}
