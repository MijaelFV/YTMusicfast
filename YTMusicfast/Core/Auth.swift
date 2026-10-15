import Foundation
import Observation
import Security
import WebKit
import os

private let authLog = Logger(subsystem: "dev.ytmusicfast", category: "Auth")

/// Google account session. Sign-in happens in a WKWebView on Google's own page. The web view's
/// persistent store (like a browser profile, private to this app) is the source of truth; on launch
/// and periodically we read the current youtube.com cookies from it to authenticate InnerTube.
@MainActor
@Observable
final class AuthManager {
    static let shared = AuthManager()

    private(set) var isSignedIn = false
    private(set) var accountName: String?
    /// Bumped on sign-in/out so views reload personalized content.
    private(set) var sessionVersion = 0
    /// Whose pages the on-disk cache holds. Remembered across launches, so the app can show the
    /// last account's Home and library before the session has loaded.
    private(set) var cacheIdentity = UserDefaults.standard.string(forKey: "cacheIdentity") ?? "signed-out" {
        didSet { UserDefaults.standard.set(cacheIdentity, forKey: "cacheIdentity") }
    }
    /// The saved session has been read. Until then nothing personal is fetched (it would come
    /// back signed out and replace the cached pages).
    private(set) var restored = false

    private var refreshTask: Task<Void, Never>?
    /// WebKit only loads the persistent cookie store once a web view using it exists in the process.
    private var storeWarmup: WKWebView?

    /// The cookies YouTube needs to treat requests as signed in (not just the first one Google sets).
    nonisolated static func isComplete(_ cookies: [HTTPCookie]) -> Bool {
        let names = Set(cookies.filter { $0.domain.hasSuffix("youtube.com") }.map(\.name))
        let hasAPISID = names.contains("SAPISID") || names.contains("__Secure-3PAPISID")
        let hasSID = names.contains("SID") || names.contains("__Secure-3PSID")
        return hasAPISID && hasSID
    }

    private var didRestore = false

    func restore() async {
        guard !didRestore else { return }
        didRestore = true
        Keychain.delete() // Older builds kept a cookie snapshot here; the web store replaces it.
        await reloadFromWebStore(announce: true)
        restored = true
        if !isSignedIn {
            if cacheIdentity != "signed-out" { DiskCache.clear() }
            cacheIdentity = "signed-out"
            // Views waiting for the session load now.
            sessionVersion += 1
        }
        startRefreshing()
    }

    func completeSignIn() async {
        await reloadFromWebStore(announce: true)
        startRefreshing()
    }

    private func startRefreshing() {
        refreshTask?.cancel()
        refreshTask = Task {
            // Google rotates some session cookies; pick up fresh values every half hour.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1800))
                await reloadFromWebStore(announce: false)
            }
        }
    }

    func signOut() async {
        refreshTask?.cancel()
        await InnerTube.shared.setCredentials(nil)
        await WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        isSignedIn = false
        accountName = nil
        // Whether the account has Premium audio is found out again for the next one.
        UserDefaults.standard.removeObject(forKey: "premiumAudio")
        // The last account's pages must not show for whoever signs in next.
        if cacheIdentity != "signed-out" { DiskCache.clear() }
        cacheIdentity = "signed-out"
        sessionVersion += 1
    }

    private func reloadFromWebStore(announce: Bool) async {
        if storeWarmup == nil {
            storeWarmup = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        }
        var cookies: [HTTPCookie] = []
        // Right after the store spins up it can briefly report no cookies; give it a moment.
        for attempt in 0..<8 {
            cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
                .filter { $0.domain.hasSuffix("youtube.com") && ($0.expiresDate ?? .distantFuture) > Date() }
            if !cookies.isEmpty || attempt == 7 { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        authLog.notice("web store youtube cookies: \(cookies.map(\.name).sorted().joined(separator: ","), privacy: .public) complete=\(Self.isComplete(cookies), privacy: .public)")
        guard Self.isComplete(cookies) else {
            if isSignedIn { await signOut() }
            return
        }
        let credentials = Credentials(cookieHeader: cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; "))
        await InnerTube.shared.setCredentials(credentials)
        guard announce || !isSignedIn else { return }
        // The account's name first: it decides whether the cached pages are this account's.
        let name = await MusicAPI.accountName()
        // Offline the name can't be fetched: assume it's still the last account (cookies are local).
        let identity = name.map { "account:\($0)" } ?? (cacheIdentity.hasPrefix("account:") ? cacheIdentity : "account:unknown")
        if identity != cacheIdentity { DiskCache.clear() }
        cacheIdentity = identity
        restored = true
        isSignedIn = true
        accountName = name
        sessionVersion += 1
    }
}

private enum Keychain {
    static func delete() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "dev.ytmusicfast.session"]
        SecItemDelete(query as CFDictionary)
    }
}
