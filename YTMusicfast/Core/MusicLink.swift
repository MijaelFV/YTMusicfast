import Foundation

/// A YouTube Music (or YouTube) link the app can open: pasted with ⌘V, opened from another app
/// with the `ytmusicfast://` scheme, or handed to the command-line tool.
///
/// `ytmusicfast://watch?v=…` mirrors `https://music.youtube.com/watch?v=…`; `ytmusicfast://search?q=…`
/// opens Search.
enum MusicLink: Equatable {
    case song(videoId: String)
    case page(BrowseTarget)
    case search(String)

    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isNewline), var components = URLComponents(string: trimmed) else { return nil }
        let scheme = components.scheme?.lowercased()
        // ytmusicfast://watch?v=… → host "watch"; treat it as music.youtube.com/watch?v=…
        if scheme == "ytmusicfast" {
            components.path = "/" + [components.host ?? "", components.path].joined().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            components.host = "music.youtube.com"
        } else {
            guard scheme == "https" || scheme == "http" else { return nil }
        }
        guard let host = components.host?.lowercased() else { return nil }
        let query = { (name: String) in components.queryItems?.first { $0.name == name }?.value }
        let parts = components.path.split(separator: "/").map(String.init)

        if host == "youtu.be" || host.hasSuffix(".youtu.be") {
            guard let id = parts.first, !id.isEmpty else { return nil }
            self = .song(videoId: id)
            return
        }
        guard host == "youtube.com" || host.hasSuffix(".youtube.com") else { return nil }
        switch parts.first {
        case "watch":
            if let id = query("v"), !id.isEmpty {
                self = .song(videoId: id)
            } else if let list = query("list") {
                self = .page(BrowseTarget(browseId: "VL" + list, kind: .playlist, title: ""))
            } else {
                return nil
            }
        case "playlist":
            guard let list = query("list") else { return nil }
            self = .page(BrowseTarget(browseId: list.hasPrefix("VL") ? list : "VL" + list, kind: .playlist, title: ""))
        case "browse":
            guard parts.count > 1 else { return nil }
            let id = parts[1]
            let kind: PageKind = id.hasPrefix("MPREb") ? .album : id.hasPrefix("UC") ? .artist
                : id.hasPrefix("VL") ? .playlist : id.hasPrefix("MPSP") ? .podcast : .other
            self = .page(BrowseTarget(browseId: id, kind: kind, title: ""))
        case "channel":
            guard parts.count > 1 else { return nil }
            self = .page(BrowseTarget(browseId: parts[1], kind: .artist, title: ""))
        case "search":
            self = .search(query("q") ?? "")
        default:
            return nil
        }
    }
}
